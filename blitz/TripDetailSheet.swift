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
    let isPastTrip: Bool
    var onClose: (() -> Void)?
    var onUpdateTrip: ((Trip) -> Void)?
    @ObservedObject var locationPhaseDetector: TripLocationPhaseDetector

    @Environment(\.openURL) private var openURL
    @State private var timing = ResolvedTripTiming.empty
    @State private var destinationWeather: DestinationWeather?
    @State private var isWeatherLoading = false
    @State private var hasAttemptedWeather = false
    @State private var now = Date()
    @State private var liveDelayInfo: DelayInfo?
    @State private var isPresentingSeatEditor = false
    @State private var ticketCode: String?
    @State private var isPresentingTicketSheet = false
    @State private var segments: [GTFSSegment] = []
    @StateObject private var locationProvider = DeviceLocationProvider()
    @State private var isShowingSpeedPage = false
    @State private var isSpeedPageLoading = false
    @State private var isLiveActivityRunning = false
    @State private var liveActivityNotice: String?

    private let dataSource = GTFSDataSource.shared
    private let secondTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(
        trip: Trip,
        pastTrips: [Trip] = [],
        isPastTrip: Bool = false,
        onClose: (() -> Void)? = nil,
        onUpdateTrip: ((Trip) -> Void)? = nil,
        locationPhaseDetector: TripLocationPhaseDetector = TripLocationPhaseDetector()
    ) {
        self.trip = trip
        self.pastTrips = pastTrips
        self.isPastTrip = isPastTrip
        self.onClose = onClose
        self.onUpdateTrip = onUpdateTrip
        self.locationPhaseDetector = locationPhaseDetector
        _ticketCode = State(initialValue: trip.ticketQRCode)
        _liveDelayInfo = State(initialValue: LiveDelayStore.shared.info(for: trip.id))
    }

    var body: some View {
        NavigationStack {
            Group {
                if isShowingSpeedPage {
                    speedDashboard
                } else {
                    detailScrollContent
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button(action: toggleSpeedDashboard) {
                    Label(
                        isShowingSpeedPage ? "Details" : "Speed",
                        systemImage: isShowingSpeedPage ? "list.bullet" : "speedometer"
                    )
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)


            ToolbarItem(placement: .bottomBar) {
                Button(action: toggleLiveActivity) {
                    Label(
                        isLiveActivityRunning ? "Stop Live" : "Live",
                        systemImage: isLiveActivityRunning ? "bell.slash.fill" : "bell.badge.fill"
                    )
                }
                .disabled(isPastTrip)
            }


        }
        .task(id: trip.id) {
            liveDelayInfo = LiveDelayStore.shared.info(for: trip.id)
            await loadTiming()
            refreshLiveActivityState()
            // Segments, weather, and the formation section are independent
            // loads. Start the two detail requests together so weather never
            // delays the schedule/timeline from appearing.
            async let segmentsLoad: Void = loadSegments()
            async let weatherLoad: Void = loadDestinationWeather()
            _ = await (segmentsLoad, weatherLoad)
        }
        .onReceive(secondTimer) { value in
            now = value
            refreshLiveActivityState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .liveDelayInfoUpdated)) { notification in
            guard let updatedID = notification.object as? String, updatedID == trip.id else { return }
            liveDelayInfo = LiveDelayStore.shared.info(for: trip.id)
            Task { await loadTiming() }
        }
        .sheet(isPresented: $isPresentingSeatEditor) {
            SeatEditorSheet(
                trip: trip,
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
        .alert("Live Activity", isPresented: Binding(
            get: { liveActivityNotice != nil },
            set: { if !$0 { liveActivityNotice = nil } }
        )) {
            Button("OK", role: .cancel) { liveActivityNotice = nil }
        } message: {
            Text(liveActivityNotice ?? "")
        }
        .background(Color(.systemBackground))
        .onChange(of: trip.ticketQRCode ?? "") { _, _ in
            ticketCode = trip.ticketQRCode
        }
        .onChange(of: trip.id) { _, _ in
            ticketCode = trip.ticketQRCode
            exitSpeedDashboard()
        }
        .onDisappear {
            locationProvider.disableTracking()
        }
    }

    private var detailScrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    VStack(alignment: .leading, spacing: 20) {
                        if hasSegmentData {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                timetableSection(referenceDate: context.date)
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
                        .background(Color(.systemBackground))
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }

    private var speedDashboard: some View {
        ScrollView {
            VStack(spacing: 24) {
                if isSpeedPageLoading {
                    speedLoadingCard
                } else {
                    currentSpeedCard
                    gpsStatusCard
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 60)
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }

    private var speedLoadingCard: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.3)
            Text("Calibrating speed sensors…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(36)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
    }

    private var currentSpeedCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Current Speed")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(currentSpeedDisplayValue)
                    .font(.system(size: 68, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("km/h")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(currentSpeedDetailText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
    }

    private var gpsStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "location.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text("GPS Status")
                    .font(.headline)
            }

            Text(gpsStatusDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
    }

    private var currentSpeedKPH: Double? {
        guard let rawSpeed = locationProvider.currentSpeed, rawSpeed >= 0 else { return nil }
        let value = rawSpeed * 3.6
        return value.isFinite ? value : nil
    }

    private var currentSpeedDisplayValue: String {
        guard let speed = currentSpeedKPH else { return "--" }
        return String(format: "%.0f", speed)
    }

    private var currentSpeedDetailText: String {
        switch locationProvider.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if currentSpeedKPH == nil {
                return "Waiting for a fresh GPS reading…"
            }
            return "Based on your device's live GPS reading."
        case .notDetermined:
            return "Grant location access to measure your speed."
        case .denied:
            return "Location access denied. Enable it in Settings to track speed."
        case .restricted:
            return "Location access is restricted on this device."
        @unknown default:
            return "Awaiting GPS authorization."
        }
    }

    private var gpsStatusDescription: String {
        switch locationProvider.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if currentSpeedKPH == nil {
                return "GPS lock in progress. Stay near a window for a faster fix."
            }
            return "GPS lock acquired. Updating speed continuously."
        case .notDetermined:
            return "We need your permission to start measuring live speed."
        case .denied:
            return "Location is turned off for Blitz. Enable it in Settings to track speed."
        case .restricted:
            return "Location access is restricted by system controls."
        @unknown default:
            return "Awaiting GPS authorization."
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            OperatorLogoView(logoName: operatorLogoName)

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
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(Color(.secondarySystemBackground))
                    .overlay(
                        Circle()
                            .stroke(Color(.separator), lineWidth: 0.5)
                    )
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var hasSegmentData: Bool {
        trip.originStopId != nil && trip.destinationStopId != nil
    }

    private var tripIdentifier: String {
        trip.gtfsTripId ?? trip.id
    }

    @ViewBuilder
    private func timetableSection(referenceDate: Date) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            TerminalInfoView(
                icon: "arrow.up.right.circle.fill",
                title: trip.originName ?? "Origin",
                timeText: formattedTime(adjustedDepartureDate),
                originalTimeText: departureTerminalDisplay.originalTimeText,
                relativeText: timeRemainingText(for: adjustedDepartureDate, type: .departure, referenceDate: referenceDate),
                statusText: departureTerminalDisplay.statusText,
                statusColor: departureTerminalDisplay.statusColor,
                timeColor: departureTerminalDisplay.timeColor,
                platformText: departureTerminalDisplay.platformText,
                showsOriginalTime: departureTerminalDisplay.showsOriginalTime
            )

            if shouldShowTravelSummaryRow {
                travelSummaryRow
            }

            TerminalInfoView(
                icon: "arrow.down.right.circle.fill",
                title: trip.destinationName ?? "Destination",
                timeText: formattedTime(adjustedArrivalDate),
                originalTimeText: arrivalTerminalDisplay.originalTimeText,
                relativeText: timeRemainingText(for: adjustedArrivalDate, type: .arrival, referenceDate: referenceDate),
                statusText: arrivalTerminalDisplay.statusText,
                statusColor: arrivalTerminalDisplay.statusColor,
                timeColor: arrivalTerminalDisplay.timeColor,
                platformText: arrivalTerminalDisplay.platformText,
                showsNextDayBadge: isOvernightTrip,
                showsOriginalTime: arrivalTerminalDisplay.showsOriginalTime
            )
            seatInfoGrid
            goodToKnowSection
            historySection
            TripFormationSection(trip: trip)
            operatorSection
        }
    }

    private var travelSummaryRow: some View {
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

    private var activeDelayMinutes: Int? {
        timing.headerDelayMinutes ?? trip.delayMinutes
    }

    private var orderedStops: [StoredStop] {
        trip.stops?.sorted(by: { $0.sequence < $1.sequence }) ?? []
    }

    private var originStoredStop: StoredStop? {
        storedStop(for: trip.originStopId, sequence: trip.originSequence, fallback: orderedStops.first)
    }

    private var destinationStoredStop: StoredStop? {
        storedStop(for: trip.destinationStopId, sequence: trip.destinationSequence, fallback: orderedStops.last)
    }

    private var isOvernightTrip: Bool {
        guard let departure = timing.scheduledDeparture, let arrival = timing.scheduledArrival else { return false }
        return !GTFSDataSource.calendar.isDate(arrival, inSameDayAs: departure)
    }

    private var shouldShowTravelSummaryRow: Bool {
        travelSummaryText != nil || isOvernightTrip
    }

    private var travelSummaryText: String? {
        let distance = effectiveDistanceText
        guard let duration = adjustedTravelDuration, duration > 0 else { return distance }
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
        if let kilometers = distanceFromStops(for: trip) {
            return formattedDistanceText(for: kilometers)
        }
        return trip.detailDistance
    }

    private func platformText(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Platform —" }
        return "Platform \(value)"
    }

    private var adjustedDepartureDate: Date? {
        timing.adjustedDeparture
    }

    private var adjustedArrivalDate: Date? {
        timing.adjustedArrival
    }

    private var adjustedTravelDuration: TimeInterval? {
        guard let departure = adjustedDepartureDate, let arrival = adjustedArrivalDate else {
            return timing.duration
        }

        let duration = arrival.timeIntervalSince(departure)
        return duration > 0 ? duration : timing.duration
    }

    private func formattedTime(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        return Self.timeFormatter.string(from: date)
    }

    private func timeRemainingText(for date: Date?, type: TerminalEventType, referenceDate: Date) -> String {
        guard let date else { return "\(type.prefix) time unavailable" }
        let remaining = date.timeIntervalSince(referenceDate)

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

    private func loadTiming() async {
        let trip = self.trip
        let delayInfo = liveDelayInfo
        let referenceDate = now
        timing = TripTimingResolver().resolve(
            trip: trip,
            delayInfo: delayInfo,
            referenceDate: referenceDate
        )
    }

    private func loadSegments() async {
        let identifier = tripIdentifier
        let source = GTFSDataSource.shared
        segments = await Task.detached(priority: .userInitiated) {
            source.segments(for: identifier)
        }.value
    }

    private func toggleSpeedDashboard() {
        if isShowingSpeedPage {
            exitSpeedDashboard()
        } else {
            enterSpeedDashboard()
        }
    }

    private func enterSpeedDashboard() {
        guard !isShowingSpeedPage else { return }
        isShowingSpeedPage = true
        isSpeedPageLoading = true
        locationProvider.enableTracking()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if isShowingSpeedPage {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isSpeedPageLoading = false
                }
            }
        }
    }

    private func exitSpeedDashboard() {
        guard isShowingSpeedPage || isSpeedPageLoading else { return }
        isShowingSpeedPage = false
        isSpeedPageLoading = false
        locationProvider.disableTracking()
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
        formatter.timeZone = GTFSDataSource.calendar.timeZone
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
    
// MARK: - Live Activity Helpers

extension TripDetailSheet {
    private func toggleLiveActivity() {
        if isLiveActivityRunning {
            LiveActivityManager.shared.stopActivityByUser(for: trip)
            isLiveActivityRunning = false
            refreshLiveActivityState()
            return
        }

        LiveActivityManager.shared.allowAutomaticStart(for: trip)
        let result = LiveActivityManager.shared.startOrSchedule(for: trip, delayInfo: liveDelayInfo)
        if let result {
            switch result {
            case .started, .alreadyRunning:
                break
            default:
                liveActivityNotice = result.message
            }
        } else {
            liveActivityNotice = "Live Activity will start one hour before departure."
        }
        refreshLiveActivityState()
    }

    private func refreshLiveActivityState() {
        isLiveActivityRunning = LiveActivityManager.shared.isActivityRunning(for: trip.id)
    }

    func normalizeStationName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
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

    private var departureTerminalDisplay: TerminalStatusDisplay {
        terminalStatusDisplay(for: .departure, scheduledDate: timing.scheduledDeparture)
    }

    private var arrivalTerminalDisplay: TerminalStatusDisplay {
        terminalStatusDisplay(for: .arrival, scheduledDate: timing.scheduledArrival)
    }

    private var isWaitingAtOriginForDeparture: Bool {
        !isPastTrip && now >= (timing.adjustedDeparture ?? .distantFuture)
            && locationPhaseDetector.phase(for: trip) == .atOrigin
    }

    private var segmentStops: [StoredStop] {
        guard !orderedStops.isEmpty else { return [] }
        guard let start = trip.originSequence, let end = trip.destinationSequence else {
            return orderedStops
        }
        let lower = min(start, end)
        let upper = max(start, end)
        return orderedStops.filter { $0.sequence >= lower && $0.sequence <= upper }
    }

    private func storedStop(for stopId: String?, sequence: Int?, fallback: StoredStop?) -> StoredStop? {
        guard let stops = trip.stops else { return fallback }
        if let stopId, let match = stops.first(where: { $0.id == stopId }) {
            return match
        }
        if let sequence, let match = stops.first(where: { $0.sequence == sequence }) {
            return match
        }
        return fallback
    }

    private func isOriginStop(_ stop: StoredStop) -> Bool {
        if let originId = trip.originStopId, stop.id == originId { return true }
        if let originSeq = trip.originSequence, stop.sequence == originSeq { return true }
        return stop.id == segmentStops.first?.id
    }

    private func isDestinationStop(_ stop: StoredStop) -> Bool {
        if let destinationId = trip.destinationStopId, stop.id == destinationId { return true }
        if let destinationSeq = trip.destinationSequence, stop.sequence == destinationSeq { return true }
        return stop.id == segmentStops.last?.id
    }

    private func stationDelayFromLiveInfo(for type: TerminalEventType) -> StationDelay? {
        guard let info = liveDelayInfo else { return nil }
        let targetName: String?
        switch type {
        case .departure:
            targetName = trip.originName ?? originStoredStop?.name ?? orderedStops.first?.name
        case .arrival:
            targetName = trip.destinationName ?? destinationStoredStop?.name ?? orderedStops.last?.name
        }
        if let name = targetName {
            let normalizedName = normalizeStationName(name)
            if let match = info.stationDelays.first(where: { normalizeStationName($0.stationName) == normalizedName }) {
                return match
            }
        }
        switch type {
        case .departure:
            return info.stationDelays.first
        case .arrival:
            return info.stationDelays.last
        }
    }

    private func terminalDelayMinutes(for type: TerminalEventType) -> Int? {
        switch type {
        case .departure:
            return timing.originDelayMinutes
        case .arrival:
            return timing.destinationDelayMinutes
        }
    }

    private func terminalPlatform(for type: TerminalEventType) -> String? {
        switch type {
        case .departure:
            return sanitizedPlatform(stationDelayFromLiveInfo(for: .departure)?.platform)
                ?? staticPlatform(for: .departure)
                ?? sanitizedPlatform(originStoredStop?.platform)
                ?? sanitizedPlatform(trip.originPlatform)
        case .arrival:
            return sanitizedPlatform(stationDelayFromLiveInfo(for: .arrival)?.platform)
                ?? staticPlatform(for: .arrival)
                ?? sanitizedPlatform(destinationStoredStop?.platform)
                ?? sanitizedPlatform(trip.destinationPlatform)
        }
    }

    private func staticPlatform(for type: TerminalEventType) -> String? {
        let trainId = trip.gtfsTripId ?? trip.id
        let stopId: String?
        switch type {
        case .departure:
            stopId = trip.originStopId ?? originStoredStop?.id
        case .arrival:
            stopId = trip.destinationStopId ?? destinationStoredStop?.id
        }
        guard let stopId else { return nil }
        return sanitizedPlatform(StaticPlatformDataSource.shared.platform(trainId: trainId, stationId: stopId))
    }

    private func sanitizedPlatform(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func terminalStatusDisplay(for type: TerminalEventType, scheduledDate: Date?) -> TerminalStatusDisplay {
        let delay = terminalDelayMinutes(for: type)
        let statusText: String
        let statusColor: Color
        let timeColor: Color
        let showsOriginalTime: Bool

        if type == .departure && isWaitingAtOriginForDeparture {
            statusText = "Waiting to depart"
            statusColor = .orange
            timeColor = .orange
            showsOriginalTime = true
        } else if let delay {
            if delay > 0 {
                statusText = "Delay +\(delay)m"
                statusColor = .red
                timeColor = .red
                showsOriginalTime = true
            } else if delay < 0 {
                statusText = "\(abs(delay))m early"
                statusColor = .green
                timeColor = .green
                showsOriginalTime = false
            } else {
                statusText = "On time"
                statusColor = .green
                timeColor = .green
                showsOriginalTime = false
            }
        } else {
            statusText = "On time"
            statusColor = .secondary
            timeColor = .primary
            showsOriginalTime = false
        }

        let originalTimeText = showsOriginalTime ? formattedTime(scheduledDate) : nil
        let platformLabel = platformText(terminalPlatform(for: type))

        return TerminalStatusDisplay(
            statusText: statusText,
            statusColor: statusColor,
            timeColor: timeColor,
            showsOriginalTime: showsOriginalTime,
            originalTimeText: originalTimeText,
            platformText: platformLabel
        )
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

            HStack(spacing: 50) {
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

    @ViewBuilder
    var operatorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                OperatorLogoView(logoName: operatorLogoName)
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(operatorDisplayName)
                        .font(.headline)
                    Text(operatorSecondaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            if operatorHasActions {
                HStack(spacing: 12) {
                    if operatorHasWebsite {
                        OperatorActionButton(title: "Website") {
                            openOperatorWebsite()
                        }
                    }
                    if operatorHasPhone {
                        OperatorActionButton(title: "Phone") {
                            callOperator()
                        }
                    }
                }
            }

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
            editorInfoCard(
                icon: "train.side.rear.car",
                title: "Coach",
                value: seatCarText,
                isPlaceholder: isSeatCarPlaceholder
            )

            editorInfoCard(
                icon: "airplaneseat",
                title: "Seats",
                value: seatNumbersText,
                isPlaceholder: isSeatNumbersPlaceholder
            )
        }
    }

    private func editorInfoCard(
        icon: String,
        title: String,
        value: String,
        isPlaceholder: Bool
    ) -> some View {
        Button(action: openSeatEditor) {
            InfoTileCard(
                icon: icon,
                title: title,
                value: value,
                isPlaceholder: isPlaceholder
            )
        }
        .buttonStyle(.plain)
    }

    private var seatCarText: String {
        guard let car = trip.seatCar?.trimmingCharacters(in: .whitespacesAndNewlines), !car.isEmpty else {
            return "Add coach"
        }
        return car
    }

    private var isSeatCarPlaceholder: Bool {
        guard let car = trip.seatCar?.trimmingCharacters(in: .whitespacesAndNewlines), !car.isEmpty else {
            return true
        }
        return false
    }

    private var seatNumbersText: String {
        if let seats = trip.seatNumbers, !seats.isEmpty {
            return seats.joined(separator: ", ")
        }
        return "Add seats"
    }

    private var isSeatNumbersPlaceholder: Bool {
        guard let seats = trip.seatNumbers else { return true }
        return seats.isEmpty
    }

    private var operatorBranding: OperatorBranding {
        OperatorBrandingCatalog.branding(for: trip.agencyId)
    }

    private var operatorLogoName: String? {
        operatorBranding.logoName
    }

    private var operatorPhoneNumber: String? {
        operatorBranding.phoneNumber
    }

    private var operatorAgencyInfo: GTFSDataSource.AgencyInfo? {
        dataSource.agencyInfo(for: trip.agencyId)
    }

    private var operatorDisplayName: String {
        operatorAgencyInfo?.name ?? "Operator"
    }

    private var operatorSecondaryText: String {
        operatorLocationText ?? operatorWebsiteHost ?? "Switzerland"
    }

    private var operatorLocationText: String? {
        OperatorBrandingCatalog.city(for: trip.agencyId)
            ?? operatorWebsiteHost
    }

    private var operatorWebsiteString: String? {
        operatorAgencyInfo?.url
    }

    private var operatorWebsiteURL: URL? {
        guard let raw = operatorWebsiteString, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        return URL(string: "https://\(raw)")
    }

    private var operatorWebsiteHost: String? {
        guard let raw = operatorWebsiteString, !raw.isEmpty else { return nil }
        var sanitized = raw
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return sanitized.isEmpty ? nil : sanitized
    }

    private var operatorHasWebsite: Bool {
        operatorWebsiteURL != nil
    }

    private var operatorHasPhone: Bool {
        operatorPhoneNumber != nil
    }

    private var operatorHasActions: Bool {
        operatorHasWebsite || operatorHasPhone
    }

    private func openSeatEditor() {
        isPresentingSeatEditor = true
    }

    private func openOperatorWebsite() {
        guard let url = operatorWebsiteURL else { return }
        openURL(url)
    }

    private func callOperator() {
        guard let phone = operatorPhoneNumber else { return }
        let sanitized = phone.filter { $0.isNumber || $0 == "+" }
        guard !sanitized.isEmpty, let url = URL(string: "tel://\(sanitized)") else { return }
        openURL(url)
    }

    private func saveSeatEditor(car: String?, seats: [String]?) {
        guard let onUpdateTrip else {
            isPresentingSeatEditor = false
            return
        }

        let updatedTrip = trip.updatingSeatInfo(
            car: car,
            seats: seats,
            trainType: trip.trainType,
            trainLength: trip.trainLength,
            trainTonnage: trip.trainTonnage,
            trainIdentifier: trip.trainIdentifier,
            trainPower: trip.trainPower
        )
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

        let components: [(unit: Calendar.Component, label: String)] = [
            (.year, "y"),
            (.month, "mo"),
            (.weekOfYear, "w"),
            (.day, "d"),
            (.hour, "h"),
            (.minute, "m"),
            (.second, "s")
        ]

        var remaining = Int(duration)
        var parts: [String] = []

        for component in components {
            guard remaining > 0 else { break }

            let value: Int
            switch component.unit {
            case .year:
                value = remaining / (365 * 24 * 3600)
            case .month:
                value = remaining / (30 * 24 * 3600)
            case .weekOfYear:
                value = remaining / (7 * 24 * 3600)
            case .day:
                value = remaining / (24 * 3600)
            case .hour:
                value = remaining / 3600
            case .minute:
                value = remaining / 60
            case .second:
                value = remaining
            default:
                value = 0
            }

            if value > 0 {
                parts.append("\(value)\(component.label)")
                remaining -= value * seconds(for: component.unit)
            }

            if parts.count == 2 {
                break
            }
        }

        return parts.isEmpty ? "0m" : parts.joined(separator: " ")
    }

    private func seconds(for component: Calendar.Component) -> Int {
        switch component {
        case .year:
            return 365 * 24 * 3600
        case .month:
            return 30 * 24 * 3600
        case .weekOfYear:
            return 7 * 24 * 3600
        case .day:
            return 24 * 3600
        case .hour:
            return 3600
        case .minute:
            return 60
        case .second:
            return 1
        default:
            return 1
        }
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
        if let kilometers = distanceFromStops(for: trip) {
            return kilometers
        }
        guard let stored = trip.detailDistance else { return nil }
        return parsedDistanceKilometers(from: stored)
    }

    private func distanceFromStops(for trip: Trip) -> Double? {
        let orderedStops = stopsForRide(
            trip.stops,
            originStopID: trip.originStopId,
            destinationStopID: trip.destinationStopId,
            originSequence: trip.originSequence,
            destinationSequence: trip.destinationSequence
        )
        guard orderedStops.count > 1 else {
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
        let resolved = TripTimingResolver().resolve(
            trip: trip,
            delayInfo: LiveDelayStore.shared.info(for: trip.id),
            referenceDate: now
        )
        guard let departure = resolved.adjustedDeparture,
              let arrival = resolved.adjustedArrival else { return nil }
        let duration = arrival.timeIntervalSince(departure)
        return duration > 0 ? duration : nil
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

private struct TerminalStatusDisplay {
    let statusText: String
    let statusColor: Color
    let timeColor: Color
    let showsOriginalTime: Bool
    let originalTimeText: String?
    let platformText: String
}

private struct TerminalInfoView: View {
    let icon: String
    let title: String
    let timeText: String
    let originalTimeText: String?
    let relativeText: String
    let statusText: String
    let statusColor: Color
    let timeColor: Color
    let platformText: String
    let showsNextDayBadge: Bool
    let showsOriginalTime: Bool

    init(
        icon: String,
        title: String,
        timeText: String,
        originalTimeText: String?,
        relativeText: String,
        statusText: String,
        statusColor: Color,
        timeColor: Color,
        platformText: String,
        showsNextDayBadge: Bool = false,
        showsOriginalTime: Bool
    ) {
        self.icon = icon
        self.title = title
        self.timeText = timeText
        self.originalTimeText = originalTimeText
        self.relativeText = relativeText
        self.statusText = statusText
        self.statusColor = statusColor
        self.timeColor = timeColor
        self.platformText = platformText
        self.showsNextDayBadge = showsNextDayBadge
        self.showsOriginalTime = showsOriginalTime
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
                    .foregroundStyle(timeText == "--:--" ? .secondary : timeColor)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                if showsOriginalTime, let original = originalTimeText {
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

private struct InfoTileCard: View {
    let icon: String
    let title: String
    let value: String
    var isPlaceholder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isPlaceholder ? .secondary : .primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color(.systemGray3).opacity(0.9), lineWidth: 1)
        }
    }
}

private struct SeatEditorSheet: View {
    let trip: Trip
    let onSave: (String?, [String]?) -> Void
    let onCancel: () -> Void

    @AppStorage(FormationSettings.key) private var formationServer = FormationSettings.defaultServer
    @State private var coachText: String
    @State private var seatDraft = ""
    @State private var seats: [String]
    @State private var formationCoaches: [String] = []
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case coach, seat }

    init(trip: Trip, onSave: @escaping (String?, [String]?) -> Void, onCancel: @escaping () -> Void) {
        self.trip = trip
        self.onSave = onSave
        self.onCancel = onCancel
        let firstCoach = (trip.seatCar ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",;/"))
            .first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _coachText = State(initialValue: firstCoach)
        _seats = State(initialValue: trip.seatNumbers ?? [])
    }

    private var coachSuggestions: [String] {
        let choices = formationCoaches.isEmpty ? (1...12).map(String.init) : formationCoaches
        let query = coachText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !choices.contains(query) else { return choices }
        return choices.filter { $0.lowercased().hasPrefix(query.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Find your seat")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text("Pick a coach, then add one or more seats.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Label("Coach", systemImage: "train.side.rear.car")
                            .font(.headline)
                        TextField("Coach number", text: $coachText)
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .onChange(of: coachText) { _, value in
                                // A seat booking has one coach; pasted lists keep the first entry.
                                let first = value.components(separatedBy: CharacterSet(charactersIn: ",;/"))
                                    .first ?? ""
                                if first != value { coachText = first }
                            }
                            .submitLabel(.next)
                            .focused($focusedField, equals: .coach)
                            .onSubmit { focusedField = .seat }
                            .padding(14)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))

                        if !coachSuggestions.isEmpty {
                            Text(formationCoaches.isEmpty ? "QUICK PICK" : "COACHES ON THIS TRAIN")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(coachSuggestions, id: \.self) { coach in
                                        Button(coach) { selectCoach(coach) }
                                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                            .foregroundStyle(coachText == coach ? .white : .primary)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 10)
                                            .background(coachText == coach ? Color.blue : Color(.tertiarySystemFill), in: Capsule())
                                    }
                                }
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))

                    VStack(alignment: .leading, spacing: 14) {
                        Label("Seats", systemImage: "airplaneseat")
                            .font(.headline)
                        HStack(spacing: 10) {
                            TextField("Seat number, e.g. 22A", text: $seatDraft)
                                .font(.system(.title3, design: .rounded, weight: .semibold))
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .focused($focusedField, equals: .seat)
                                .onSubmit(addSeats)
                            Button(action: addSeats) {
                                Image(systemName: "plus")
                                    .font(.headline)
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.borderedProminent)
                            .clipShape(Circle())
                            .disabled(parsedSeats(from: seatDraft).isEmpty)
                            .accessibilityLabel("Add seat")
                        }
                        .padding(10)
                        .padding(.leading, 4)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))

                        if !seats.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(seats.indices, id: \.self) { index in
                                        let seat = seats[index]
                                        Button {
                                            seats.remove(at: index)
                                        } label: {
                                            HStack(spacing: 6) {
                                                Text(seat)
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 9)
                                            .background(Color.blue.opacity(0.12), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Remove seat \(seat)")
                                    }
                                }
                            }
                        } else {
                            Text("Add each seat with +, or separate several with commas.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Coach & Seats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: save) {
                    Text("Save seat details")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
            .onAppear { focusedField = .coach }
            .task(id: "\(trip.id)|\(trip.travelDate?.timeIntervalSince1970 ?? 0)|\(formationServer)") {
                await loadFormationCoaches()
            }
        }
    }

    private func selectCoach(_ coach: String) {
        coachText = coach
        focusedField = .seat
    }

    private func parsedSeats(from input: String) -> [String] {
        input.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
    }

    private func addSeats() {
        for seat in parsedSeats(from: seatDraft)
        where !seats.contains(where: { $0.caseInsensitiveCompare(seat) == .orderedSame }) {
            seats.append(seat)
        }
        seatDraft = ""
        focusedField = .seat
    }

    private func save() {
        var allSeats = seats
        for seat in parsedSeats(from: seatDraft)
        where !allSeats.contains(where: { $0.caseInsensitiveCompare(seat) == .orderedSame }) {
            allSeats.append(seat)
        }
        let coach = coachText.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(coach.isEmpty ? nil : coach, allSeats.isEmpty ? nil : allSeats)
    }

    private func loadFormationCoaches() async {
        do {
            let sourceText = [trip.trainIdentifier, trip.sharedJourneyLeg?.service, trip.title]
                .compactMap { $0 }.joined(separator: " ")
            let number = sourceText.split(whereSeparator: { !$0.isASCII || !$0.isNumber })
                .map(String.init).reversed().first(where: { !$0.isEmpty })
            guard let agency = trip.agencyId, !agency.isEmpty, let number else { return }
            let url = try FormationSettings.request(server: formationServer, agency: agency, number: number, date: trip.travelDate)
            let result = try await FormationService.shared.load(url: url)
            try Task.checkCancellation()
            let uic = trip.sharedJourneyLeg?.origin.id ?? GTFSDataSource.shared.stationUIC(for: trip.originStopId)
            let formation = try result.response.formation(
                boardingUIC: uic,
                boardingName: trip.originName,
                operatorName: agency == "11" ? "SBB" : (GTFSDataSource.shared.agencyInfo(for: agency)?.name ?? agency)
            )
            let coaches = formation?.vehicles.compactMap { vehicle -> String? in
                guard vehicle.position.hasPrefix("Car ") else { return nil }
                return String(vehicle.position.dropFirst(4))
            } ?? []
            formationCoaches = Array(Set(coaches)).sorted {
                (Int($0) ?? Int.max, $0) < (Int($1) ?? Int.max, $1)
            }
        } catch is CancellationError {
            return
        } catch {
            formationCoaches = []
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
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color(.separator), lineWidth: 1)
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
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
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
                    dataScanner.stopScanning()
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

private struct OperatorActionButton: View {
    let title: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
