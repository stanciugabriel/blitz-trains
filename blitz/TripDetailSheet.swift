import SwiftUI
internal import UIKit
import CoreLocation
import WeatherKit
import Combine
import CoreImage.CIFilterBuiltins
#if canImport(VisionKit)
import VisionKit
internal import Vision
#endif

struct TripDetailSheet: View {
    let trip: Trip
    let pastTrips: [Trip]
    var onClose: (() -> Void)?
    var onUpdateTrip: ((Trip) -> Void)?

    @State private var timing = TripTimingSnapshot()
    @State private var destinationWeather: DestinationWeather?
    @State private var isWeatherLoading = false
    @State private var hasAttemptedWeather = false
    @State private var now = Date()
    @State private var isSyncingDelay = false
    @State private var liveDelayInfo: DelayInfo?
    @State private var syncStatusText: String?
    @State private var shouldSkipNextSync = false
    @State private var isPresentingSeatEditor = false
    @State private var seatEditorCar = ""
    @State private var seatEditorSeats = ""
    @State private var ticketCode: String?
    @State private var isPresentingTicketSheet = false

    private let dataSource = GTFSDataSource.shared
    private let secondTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init(
        trip: Trip,
        pastTrips: [Trip] = [],
        onClose: (() -> Void)? = nil,
        onUpdateTrip: ((Trip) -> Void)? = nil
    ) {
        self.trip = trip
        self.pastTrips = pastTrips
        self.onClose = onClose
        self.onUpdateTrip = onUpdateTrip
        _ticketCode = State(initialValue: trip.ticketQRCode)
        _liveDelayInfo = State(initialValue: LiveDelayStore.shared.info(for: trip.id))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        VStack(alignment: .leading, spacing: 20) {
                            if let status = syncStatusText {
                                Text(status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Divider()
                            if hasSegmentData {
                                VStack(alignment: .leading, spacing: 24) {
                                    TerminalInfoView(
                                        icon: "arrow.up.right.circle.fill",
                                        title: trip.originName ?? "Origin",
                                        timeText: formattedTime(adjustedDepartureDate),
                                        originalTimeText: hasActiveDelay ? formattedTime(timing.departureDate) : nil,
                                        relativeText: departureRelativeText,
                                        statusText: statusLabel,
                                        statusColor: statusColor,
                                        platformText: platformText(trip.originPlatform),
                                        isDelayed: hasActiveDelay
                                    )

                                    if shouldShowTravelSummaryRow {
                                        HStack(spacing: 12) {
                                            HStack(spacing: 8) {
                                                Image(systemName: "clock.arrow.circlepath")
                                                travelSummaryContent
                                                    .fixedSize(horizontal: true, vertical: false)
                                            }
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)

                                            Rectangle()
                                                .fill(Color(.systemGray4))
                                                .frame(height: 1)
                                                .frame(maxWidth: .infinity)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 4)
                                    }

                                    TerminalInfoView(
                                        icon: "arrow.down.right.circle.fill",
                                        title: trip.destinationName ?? "Destination",
                                        timeText: formattedTime(adjustedArrivalDate),
                                        originalTimeText: hasActiveDelay ? formattedTime(timing.arrivalDate) : nil,
                                        relativeText: arrivalRelativeText,
                                        statusText: statusLabel,
                                        statusColor: statusColor,
                                        platformText: platformText(trip.destinationPlatform),
                                        showsNextDayBadge: isOvernightTrip,
                                        isDelayed: hasActiveDelay
                                    )
                                    seatInfoGrid
                                    goodToKnowSection
                                    historySection
                                }
                            } else {
                                Text("Schedule information unavailable for this trip.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal)
                        .padding(.top, 4)
                    } header: {
                        header
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                            .background(Color.white)
                    }
                }
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button(action: {
                    if shouldSkipNextSync {
                        shouldSkipNextSync = false
                        return
                    }
                    syncDelay()
                }) {
                    Label("Sync", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                .simultaneousGesture(LongPressGesture().onEnded { _ in
                    shouldSkipNextSync = true
                    forgetDelay()
                })
                .disabled(isSyncingDelay)
            }

            ToolbarItem(placement: .bottomBar) {
                Button(action: openTicketSheet) {
                    Label("Ticket", systemImage: "qrcode")
                }
            }
        }
        .task(id: trip.id) {
            loadTiming()
            await loadDestinationWeather()
        }
        .onReceive(secondTimer) { value in
            guard shouldTickEverySecond else { return }
            now = value
        }
        .onReceive(minuteTimer) { value in
            guard shouldTickEveryMinute else { return }
            now = value
        }
        .sheet(isPresented: $isPresentingSeatEditor) {
            SeatEditorSheet(
                carText: $seatEditorCar,
                seatsText: $seatEditorSeats,
                onSave: saveSeatEditor,
                onCancel: { isPresentingSeatEditor = false }
            )
        }
        .sheet(isPresented: $isPresentingTicketSheet) {
            TicketQRSheet(
                code: $ticketCode,
                onScan: handleTicketScan,
                onDismiss: { isPresentingTicketSheet = false }
            )
        }
        .onChange(of: trip.ticketQRCode ?? "") { _ in
            ticketCode = trip.ticketQRCode
        }
        .onChange(of: trip.id) { _ in
            ticketCode = trip.ticketQRCode
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            CompanyLogoView()

            VStack(alignment: .leading, spacing: 4) {
                Text(headerLine)
                    .font(.headline)
                Text(routeLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: { onClose?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 32, height: 32)
                    .background(.regularMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var hasSegmentData: Bool {
        trip.originStopId != nil && trip.destinationStopId != nil
    }

    private var headerLine: String {
        if let dateText = trip.detailDate ?? parsedDateComponent, !dateText.isEmpty {
            return "\(trip.title) • \(dateText)"
        }
        return trip.title
    }

    private var routeLine: String {
        trip.detailRoute ?? parsedRouteComponent ?? trip.subtitle
    }

    private var parsedRouteComponent: String? {
        parsedComponents.first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedDateComponent: String? {
        guard parsedComponents.count > 1 else { return nil }
        return parsedComponents[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedComponents: [String] {
        trip.subtitle.split(separator: "·", maxSplits: 1, omittingEmptySubsequences: true).map { String($0) }
    }

    private var statusColor: Color {
        currentDelayMinutes > 0 ? .red : .green
    }

    private var statusLabel: String {
        if currentDelayMinutes > 0 {
            return "Delayed by \(currentDelayMinutes) min"
        }
        return "On time"
    }

    private var activeDelayMinutes: Int? {
        liveDelayInfo?.delayMinutes ?? trip.delayMinutes
    }

    private var currentDelayMinutes: Int {
        activeDelayMinutes ?? 0
    }

    private var hasActiveDelay: Bool {
        currentDelayMinutes > 0
    }

    private var departureRelativeText: String {
        timeRemainingText(for: adjustedDepartureDate, type: .departure)
    }

    private var arrivalRelativeText: String {
        timeRemainingText(for: adjustedArrivalDate, type: .arrival)
    }

    private var isOvernightTrip: Bool {
        guard let departure = timing.departureDate, let arrival = timing.arrivalDate else { return false }
        return !Calendar.current.isDate(arrival, inSameDayAs: departure)
    }

    private var shouldShowTravelSummaryRow: Bool {
        travelSummaryText != nil || isOvernightTrip
    }

    private var nextEventInterval: TimeInterval? {
        let upcoming = [timing.departureDate, timing.arrivalDate].compactMap { date -> TimeInterval? in
            guard let date else { return nil }
            let delta = date.timeIntervalSince(now)
            return delta > 0 ? delta : nil
        }
        return upcoming.min()
    }

    private var shouldTickEverySecond: Bool {
        guard let interval = nextEventInterval else { return false }
        return interval <= 3600
    }

    private var shouldTickEveryMinute: Bool {
        guard let interval = nextEventInterval else { return false }
        return interval <= 24 * 3600 && interval > 3600
    }

    private var travelSummaryText: String? {
        let distance = effectiveDistanceText
        guard let duration = timing.duration, duration > 0 else { return distance }
        let durationText = Self.durationFormatter.string(from: duration) ?? ""
        if let distance {
            return "\(durationText) • \(distance)"
        }
        return durationText
    }

    private var travelSummaryContent: some View {
        HStack(spacing: 6) {
            if let summaryText = travelSummaryText {
                Text(summaryText)
            }

            if isOvernightTrip {
                if travelSummaryText != nil {
                    Text("•")
                }

                HStack(spacing: 4) {
                    Image(systemName: "moon.stars.fill")
                    Text("Overnight")
                }
            }
        }
        .layoutPriority(1)
    }

    private var effectiveDistanceText: String? {
        if let stored = trip.detailDistance, !stored.isEmpty {
            return stored
        }
        guard let kilometers = distanceFromStops(for: trip) else { return nil }
        return formattedDistanceText(for: kilometers)
    }

    private func platformText(_ value: String?) -> String {
        if let override = liveDelayInfo?.platform, !override.isEmpty {
            return "Platform \(override)"
        }
        return "Platform \(value ?? "—")"
    }

    private var adjustedDepartureDate: Date? {
        guard let base = timing.departureDate else { return nil }
        return applyDelayIfNeeded(to: base)
    }

    private var adjustedArrivalDate: Date? {
        guard let base = timing.arrivalDate else { return nil }
        return applyDelayIfNeeded(to: base)
    }

    private func applyDelayIfNeeded(to date: Date) -> Date {
        guard hasActiveDelay else { return date }
        return date.addingTimeInterval(TimeInterval(currentDelayMinutes * 60))
    }

    private func formattedTime(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        return Self.timeFormatter.string(from: date)
    }

    private func timeRemainingText(for date: Date?, type: TerminalEventType) -> String {
        guard let date else { return "\(type.prefix) time unavailable" }
        let remaining = date.timeIntervalSince(now)

        if remaining <= 0 {
            return type.completedText
        }

        if remaining >= 24 * 60 * 60 {
            return "Scheduled"
        }

        if remaining >= 60 * 60 {
            let hours = Int(remaining) / 3600
            let minutes = (Int(remaining) % 3600) / 60
            return "\(type.prefix) in \(hours)h \(minutes)m"
        }

        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return "\(type.prefix) in \(minutes)m \(seconds)s"
    }

    private func loadTiming() {
        guard let snapshot = timingSnapshot(for: trip) else {
            timing = TripTimingSnapshot()
            return
        }
        timing = snapshot
    }

    private func timingSnapshot(for trip: Trip) -> TripTimingSnapshot? {
        guard
            let travelDate = trip.travelDate,
            let originId = trip.originStopId,
            let destinationId = trip.destinationStopId
        else {
            return nil
        }

        let base = Calendar.current.startOfDay(for: travelDate)
        let tripIdentifier = trip.gtfsTripId ?? trip.id
        let originSchedule = dataSource.stopSchedule(for: tripIdentifier, stopId: originId)
        let destinationSchedule = dataSource.stopSchedule(for: tripIdentifier, stopId: destinationId)

        let departure = originSchedule?.departureDate(on: base) ?? originSchedule?.arrivalDate(on: base)
        let arrival = destinationSchedule?.arrivalDate(on: base) ?? destinationSchedule?.departureDate(on: base)

        return TripTimingSnapshot(departureDate: departure, arrivalDate: arrival)
    }

    private func loadDestinationWeather() async {
        await MainActor.run {
            isWeatherLoading = true
            hasAttemptedWeather = true
        }
        guard let coordinate = destinationCoordinate else {
            await MainActor.run {
                destinationWeather = nil
                isWeatherLoading = false
            }
            return
        }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let weather = try await WeatherService.shared.weather(for: location)
            let summary = DestinationWeather(current: weather.currentWeather)
            await MainActor.run {
                destinationWeather = summary
                isWeatherLoading = false
            }
        } catch {
            await MainActor.run {
                destinationWeather = nil
                isWeatherLoading = false
            }
        }
    }

    private var destinationCoordinate: CLLocationCoordinate2D? {
        if let coordinate = coordinateFromStoredStops() {
            return coordinate
        }

        let tripIdentifier = trip.gtfsTripId ?? trip.id
        let gtfsStops = dataSource.stops(for: tripIdentifier)
        guard !gtfsStops.isEmpty else { return nil }

        if let id = trip.destinationStopId, let stop = gtfsStops.first(where: { $0.id == id }) {
            return CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
        }
        if let seq = trip.destinationSequence, let stop = gtfsStops.first(where: { $0.sequence == seq }) {
            return CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
        }
        guard let last = gtfsStops.last else { return nil }
        return CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
    }

    private func coordinateFromStoredStops() -> CLLocationCoordinate2D? {
        guard let stops = trip.stops else { return nil }
        if let id = trip.destinationStopId, let stop = stops.first(where: { $0.id == id }) {
            return stop.coordinate
        }
        if let seq = trip.destinationSequence, let stop = stops.first(where: { $0.sequence == seq }) {
            return stop.coordinate
        }
        return stops.sorted(by: { $0.sequence < $1.sequence }).last?.coordinate
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static let temperatureFormatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let distanceFormatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.maximumFractionDigits = 0
        formatter.numberFormatter.usesGroupingSeparator = true
        return formatter
    }()

    private static let totalDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.dropLeading, .dropTrailing]
        return formatter
    }()

    private enum TerminalEventType {
        case departure
        case arrival

        var prefix: String {
            switch self {
            case .departure: return "Departs"
            case .arrival: return "Arrives"
            }
        }

        var completedText: String {
            switch self {
            case .departure: return "Departed"
            case .arrival: return "Arrived"
            }
        }
    }
}
    
// MARK: - Sync Helpers

extension TripDetailSheet {
    private var syncResultSummary: String? {
        guard let info = liveDelayInfo else { return nil }
        var parts: [String] = []
        if let delay = info.delayMinutes {
            parts.append(delay == 0 ? "On time" : "Delay +\(delay)m")
        }
        if let platform = info.platform {
            parts.append("Platform \(platform)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func syncDelay() {
        guard let trainNumber = resolvedTrainNumber else {
            syncStatusText = "Train number unavailable"
            return
        }

        isSyncingDelay = true
        syncStatusText = "Refreshing session…"

        Task {
            print("[TripDetailSheet] Starting InfoFer sync for \(trainNumber)")
            await InfoFerSessionManager.shared.refreshSession(for: trainNumber)
            let info = await InfoFerScraper.shared.fetchDelay(for: trainNumber)
            print("[TripDetailSheet] Sync completed delay=\(info.delayMinutes ?? -1) platform=\(info.platform ?? "n/a")")

            await MainActor.run {
                liveDelayInfo = info
                LiveDelayStore.shared.save(info: info, for: trip.id)
                applyStationDelays(from: info)
                isSyncingDelay = false
                syncStatusText = "Synced at \(Self.timeFormatter.string(from: Date()))"
            }
        }
    }

    private func forgetDelay() {
        liveDelayInfo = nil
        LiveDelayStore.shared.clear(tripID: trip.id)
        syncStatusText = "Delay cleared"
    }

    private var resolvedTrainNumber: String? {
        let titleComponents = trip.title.split(separator: " ")
        if let last = titleComponents.last {
            let digits = last.filter { $0.isNumber }
            if !digits.isEmpty { return String(digits) }
        }

        if let code = trip.gtfsTripId, !code.isEmpty {
            return code
        }
        return nil
    }
}

private extension TripDetailSheet {
    func applyStationDelays(from info: DelayInfo) {
        guard !info.stationDelays.isEmpty else { return }
        guard let storedStops = trip.stops, !storedStops.isEmpty else { return }

        var lookup: [String: StationDelay] = [:]
        for detail in info.stationDelays {
            let key = normalizeStationName(detail.stationName)
            lookup[key] = detail
        }

        var updatedStops = storedStops
        var hasChanges = false

        for index in updatedStops.indices {
            let key = normalizeStationName(updatedStops[index].name)
            guard let detail = lookup[key] else { continue }

            if updatedStops[index].arrivalDelayMinutes != detail.arrivalDelayMinutes {
                updatedStops[index].arrivalDelayMinutes = detail.arrivalDelayMinutes
                hasChanges = true
            }

            if updatedStops[index].departureDelayMinutes != detail.departureDelayMinutes {
                updatedStops[index].departureDelayMinutes = detail.departureDelayMinutes
                hasChanges = true
            }
        }

        guard hasChanges, let onUpdateTrip else { return }
        let updatedTrip = trip.updatingStops(updatedStops)
        onUpdateTrip(updatedTrip)
    }

    func normalizeStationName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension TripDetailSheet {
    @ViewBuilder
    var goodToKnowSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Good to Know")
                .font(.system(size: 20, weight: .semibold))

            weatherCard
//            stationStatusCard(
//                title: "\(originStationName) Departures",
//                delayText: departureDelayText,
//                operationsTitle: "Normal Operations",
//                operationsSubtitle: "No irregular traffic"
//            )
//            stationStatusCard(
//                title: "\(destinationStationName) Arrivals",
//                delayText: arrivalDelayText,
//                operationsTitle: "Smooth Arrivals",
//                operationsSubtitle: "No irregular traffic"
//            )
        }
    }

    private var weatherIconName: String {
        if let weather = destinationWeather {
            return weather.symbolName
        }
        return isWeatherLoading || !hasAttemptedWeather ? "clock.arrow.circlepath" : "cloud.fill"
    }

    private var weatherDetailText: String {
        if let weather = destinationWeather {
            return weather.summary
        }
        return isWeatherLoading || !hasAttemptedWeather ? "Fetching latest weather…" : "Weather unavailable"
    }

    private var originStationName: String {
        trip.originName ?? "Origin"
    }

    private var destinationStationName: String {
        trip.destinationName ?? "Destination"
    }

    @ViewBuilder
    private var weatherCard: some View {
        HStack(spacing: 16) {
            Image(systemName: weatherIconName)
                .font(.system(size: 20))
                .symbolRenderingMode(destinationWeather == nil ? .monochrome : .multicolor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Arrival Weather")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(weatherDetailText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            Spacer(minLength: 0)
        }
        .padding()
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color(.systemGray3).opacity(0.9), lineWidth: 1)
        )
    }

    private var departureDelayText: String {
        mockDelayText(for: originStationName)
    }

    private var arrivalDelayText: String {
        mockDelayText(for: destinationStationName)
    }

    private func mockDelayText(for station: String) -> String {
        let minutes = (station.count % 7) + 6
        return "\(minutes)m delay"
    }

    private func stationStatusCard(
        title: String,
        delayText: String,
        operationsTitle: String,
        operationsSubtitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                Spacer()
                Image(systemName: "dot.radiowaves.up.forward")
                Text(delayText)
                    .font(.subheadline)
            }

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 26, height: 26)
                    Circle()
                        .fill(Color.green.opacity(0.45))
                        .frame(width: 19, height: 19)
                    Circle()
                        .fill(Color.green)
                        .frame(width: 13, height: 13)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(operationsTitle)
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    Text(operationsSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.3), lineWidth: 1)
        )
    }
}

private extension TripDetailSheet {
    @ViewBuilder
    var historySection: some View {
        let metrics = computeRouteHistoryMetrics()

        VStack(alignment: .leading, spacing: 5) {
            Text("My History on This Route")
                .font(.system(size: 20, weight: .semibold))
            Text(historyRouteSubtitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 60) {
                historyStatCard(
                    title: "Rides",
                    icon: "train.side.front.car",
                    value: "\(metrics.rideCount)"
                )
                historyStatCard(
                    title: "Distance",
                    icon: "arrow.left.and.right.circle.fill",
                    value: formattedHistoryDistance(from: metrics.totalDistance),
                    iconRotation: 45
                )
                historyStatCard(
                    title: "Ride Time",
                    icon: "clock.fill",
                    value: formattedHistoryDuration(from: metrics.totalDuration)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color(.systemGray3).opacity(0.9), lineWidth: 1)
        )
    }

    private var historyRouteSubtitle: String {
        "\(originStationName) → \(destinationStationName)"
    }

    private var seatInfoGrid: some View {
        HStack(spacing: 16) {
            Button(action: openSeatEditor) {
                SeatInfoCard(
                    icon: "train.side.rear.car",
                    title: "Coach",
                    value: seatCarText
                )
            }
            .buttonStyle(.plain)

            Button(action: openSeatEditor) {
                SeatInfoCard(
                    icon: "airplaneseat",
                    title: "Seats",
                    value: seatNumbersText
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var seatCarText: String {
        if let car = trip.seatCar, !car.trimmingCharacters(in: .whitespaces).isEmpty {
            return car
        }
        return "Add coach"
    }

    private var seatNumbersText: String {
        if let seats = trip.seatNumbers, !seats.isEmpty {
            return seats.joined(separator: ", ")
        }
        return "Add seats"
    }

    private func openSeatEditor() {
        seatEditorCar = trip.seatCar ?? ""
        seatEditorSeats = trip.seatNumbers?.joined(separator: ", ") ?? ""
        isPresentingSeatEditor = true
    }

    private func saveSeatEditor() {
        let trimmedCar = seatEditorCar.trimmingCharacters(in: .whitespacesAndNewlines)
        let carValue = trimmedCar.isEmpty ? nil : trimmedCar

        let seatTokens = seatEditorSeats
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let seatsValue = seatTokens.isEmpty ? nil : seatTokens

        guard let onUpdateTrip else {
            isPresentingSeatEditor = false
            return
        }

        let updatedTrip = trip.updatingSeatInfo(car: carValue, seats: seatsValue)
        onUpdateTrip(updatedTrip)
        isPresentingSeatEditor = false
    }

    private func openTicketSheet() {
        ticketCode = trip.ticketQRCode
        isPresentingTicketSheet = true
    }

    private func handleTicketScan(_ payload: String?) {
        ticketCode = payload
        guard let onUpdateTrip else { return }
        let updatedTrip = trip.updatingTicketQRCode(payload)
        onUpdateTrip(updatedTrip)
    }

    private func formattedHistoryDistance(from kilometers: Double?) -> String {
        guard let kilometers else { return "0km" }
        return formattedDistanceText(for: kilometers)
    }

    private func formattedHistoryDuration(from duration: TimeInterval?) -> String {
        guard let duration, duration > 0 else { return "0m" }
        return Self.totalDurationFormatter.string(from: duration) ?? "0m"
    }

    private func formattedDistanceText(for kilometers: Double) -> String {
        let measurement = Measurement(value: kilometers, unit: UnitLength.kilometers)
        return Self.distanceFormatter.string(from: measurement)
    }

    private func computeRouteHistoryMetrics() -> RouteHistoryMetrics {
        var rideCount = 0
        var totalDistance: Double = 0
        var totalDuration: TimeInterval = 0
        var hasDistance = false
        var hasDuration = false

        for historyTrip in pastTrips {
            guard isSameRoute(trip, historyTrip) else { continue }
            rideCount += 1

            if let distance = distanceInKilometers(for: historyTrip) {
                totalDistance += distance
                hasDistance = true
            }

            if let duration = travelDuration(for: historyTrip) {
                totalDuration += duration
                hasDuration = true
            }
        }

        return RouteHistoryMetrics(
            rideCount: rideCount,
            totalDistance: hasDistance ? totalDistance : nil,
            totalDuration: hasDuration ? totalDuration : nil
        )
    }

    private func distanceInKilometers(for trip: Trip) -> Double? {
        if let stored = trip.detailDistance, let parsed = parsedDistanceKilometers(from: stored) {
            return parsed
        }

        return distanceFromStops(for: trip)
    }

    private func distanceFromStops(for trip: Trip) -> Double? {
        guard let orderedStops = trip.stops?.sorted(by: { $0.sequence < $1.sequence }), orderedStops.count > 1 else {
            return nil
        }

        var totalMeters: CLLocationDistance = 0
        for pair in zip(orderedStops, orderedStops.dropFirst()) {
            let start = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let end = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
            totalMeters += start.distance(from: end)
        }

        guard totalMeters > 1000 else { return nil }
        let kilometers = totalMeters / 1000
        return kilometers > 0 ? kilometers : nil
    }

    private func parsedDistanceKilometers(from value: String) -> Double? {
        let sanitized = value.replacingOccurrences(of: ",", with: ".")
        let scanner = Scanner(string: sanitized)
        scanner.locale = Locale(identifier: "en_US_POSIX")
        scanner.charactersToBeSkipped = .whitespaces
        _ = scanner.scanUpToCharacters(from: CharacterSet(charactersIn: "0123456789.-"))
        return scanner.scanDouble()
    }

    private func travelDuration(for trip: Trip) -> TimeInterval? {
        guard let snapshot = timingSnapshot(for: trip),
              let departure = snapshot.departureDate,
              let arrival = snapshot.arrivalDate else { return nil }

        let delaySeconds = TimeInterval((trip.delayMinutes ?? 0) * 60)
        return arrival.addingTimeInterval(delaySeconds).timeIntervalSince(departure)
    }

    private func isSameRoute(_ lhs: Trip, _ rhs: Trip) -> Bool {
        if let lhsOrigin = lhs.originStopId,
           let rhsOrigin = rhs.originStopId,
           let lhsDestination = lhs.destinationStopId,
           let rhsDestination = rhs.destinationStopId,
           lhsOrigin == rhsOrigin,
           lhsDestination == rhsDestination {
            return true
        }

        if let lhsOriginName = normalizedText(lhs.originName),
           let rhsOriginName = normalizedText(rhs.originName),
           let lhsDestinationName = normalizedText(lhs.destinationName),
           let rhsDestinationName = normalizedText(rhs.destinationName),
           lhsOriginName == rhsOriginName,
           lhsDestinationName == rhsDestinationName {
            return true
        }

        if let lhsRoute = normalizedRouteDescriptor(for: lhs),
           let rhsRoute = normalizedRouteDescriptor(for: rhs),
           lhsRoute == rhsRoute {
            return true
        }

        return false
    }

    private func normalizedRouteDescriptor(for trip: Trip) -> String? {
        if let route = normalizedText(trip.detailRoute) {
            return route
        }
        let components = trip.subtitle.split(separator: "·", maxSplits: 1, omittingEmptySubsequences: true)
        if let first = components.first {
            return normalizedText(String(first))
        }
        return nil
    }

    private func normalizedText(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let folded = raw.folding(options: [.diacriticInsensitive], locale: Locale.current)
        return folded.lowercased()
    }

    private func historyStatCard(
        title: String,
        icon: String,
        value: String,
        iconRotation: Double = 0
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon)
                    .rotationEffect(.degrees(iconRotation))
                    .font(.system(size: 16, weight: .semibold))
                Text(value)
                    .font(.headline)
                    .fontWeight(.semibold)
            }
        }
        .padding(.vertical, 12)
    }
}

private struct RouteHistoryMetrics {
    let rideCount: Int
    let totalDistance: Double?
    let totalDuration: TimeInterval?
}

private struct TripTimingSnapshot {
    var departureDate: Date?
    var arrivalDate: Date?

    var duration: TimeInterval? {
        guard let departureDate, let arrivalDate else { return nil }
        return arrivalDate.timeIntervalSince(departureDate)
    }
}

private struct DestinationWeather {
    let symbolName: String
    let summary: String

    init(current: CurrentWeather) {
        symbolName = current.symbolName
        let tempText = TripDetailSheet.temperatureFormatter.string(from: current.temperature.converted(to: .celsius))
        let conditionText = current.condition.description.localizedCapitalized
        summary = "\(tempText) and \(conditionText)"
    }
}

private struct TerminalInfoView: View {
    let icon: String
    let title: String
    let timeText: String
    let originalTimeText: String?
    let relativeText: String
    let statusText: String
    let statusColor: Color
    let platformText: String
    let showsNextDayBadge: Bool
    let isDelayed: Bool

    init(
        icon: String,
        title: String,
        timeText: String,
        originalTimeText: String?,
        relativeText: String,
        statusText: String,
        statusColor: Color,
        platformText: String,
        showsNextDayBadge: Bool = false,
        isDelayed: Bool
    ) {
        self.icon = icon
        self.title = title
        self.timeText = timeText
        self.originalTimeText = originalTimeText
        self.relativeText = relativeText
        self.statusText = statusText
        self.statusColor = statusColor
        self.platformText = platformText
        self.showsNextDayBadge = showsNextDayBadge
        self.isDelayed = isDelayed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.title3)
                    .bold()
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(timeText)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(timeText == "--:--" ? .secondary : (isDelayed ? .red : statusColor))
                    .monospacedDigit()

                if isDelayed, let original = originalTimeText {
                    Text(original)
                        .font(.title3)
                        .foregroundStyle(.primary.opacity(0.4))
                        .strikethrough()
                        .monospacedDigit()
                }

                if showsNextDayBadge {
                    Text("+1")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(statusText)
                    .foregroundStyle(statusColor)
                Text("•")
                    .foregroundStyle(.secondary)
                Text(relativeText)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(platformText)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }
}

private struct SeatInfoCard: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3)
                    .fontWeight(.semibold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color(.systemGray3).opacity(0.9), lineWidth: 1)
        )
    }
}

private struct SeatEditorSheet: View {
    @Binding var carText: String
    @Binding var seatsText: String
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Coach") {
                    TextField("e.g. 12", text: $carText)
                        .textInputAutocapitalization(.characters)
                }

                Section("Seats") {
                    TextField("e.g. 22A, 22B", text: $seatsText)
                        .textInputAutocapitalization(.never)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("Seat Details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onSave) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

private struct TicketQRSheet: View {
    @Binding var code: String?
    var onScan: (String?) -> Void
    var onDismiss: () -> Void

    @State private var isScanning: Bool

    init(code: Binding<String?>, onScan: @escaping (String?) -> Void, onDismiss: @escaping () -> Void) {
        self._code = code
        self.onScan = onScan
        self.onDismiss = onDismiss
        _isScanning = State(initialValue: code.wrappedValue == nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if isScanning {
                    ScannerHostView(onScan: handleScan)
                        .frame(maxWidth: .infinity, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color(.systemGray4), lineWidth: 1)
                        )
                    Text("Point your camera at the QR code to save it for easy access.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if let value = code {
                    QRCodeDisplayView(code: value)
                    Button("Scan Again") {
                        isScanning = true
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("No QR code available.")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }

    private func handleScan(_ payload: String) {
        code = payload
        isScanning = false
        onScan(payload)
    }
}

private struct QRCodeDisplayView: View {
    let code: String

    var body: some View {
        VStack(spacing: 16) {
            if let image = QRCodeImageGenerator.makeImage(from: code) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)
            }

            Text(code)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct ScannerHostView: View {
    var onScan: (String) -> Void

    var body: some View {
        Group {
#if canImport(VisionKit)
            if #available(iOS 16.0, *), QRScannerView.isAvailable {
                QRScannerView(onScan: onScan)
            } else {
                ScannerUnavailableView()
            }
#else
            ScannerUnavailableView()
#endif
        }
    }
}

private struct ScannerUnavailableView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Scanner unavailable on this device.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
    }
}

#if canImport(VisionKit)
@available(iOS 16.0, *)
private struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.QR])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        DispatchQueue.main.async {
            try? controller.startScanning()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                if case let .barcode(barcode) = item, let payload = barcode.payloadStringValue {
                    onScan(payload)
                    try? dataScanner.stopScanning()
                    break
                }
            }
        }
    }
}
#endif

private enum QRCodeImageGenerator {
    static func makeImage(from string: String) -> UIImage? {
        let data = Data(string.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: transform)
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct CompanyLogoView: View {
    var body: some View {
        Image("cfr")
            .resizable()
            .scaledToFit()
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
    }
}
