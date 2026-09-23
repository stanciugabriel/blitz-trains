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
    @State private var isSyncingDelay = false
    @State private var liveDelayInfo: DelayInfo?
    @State private var syncStatusText: String?
    @State private var shouldSkipNextSync = false
    @State private var hasTriggeredSyncLongPress = false
    @State private var isPresentingSeatEditor = false
    @State private var seatEditorCar = ""
    @State private var seatEditorSeats = ""
    @State private var seatEditorTrainIdentifier = ""
    @State private var seatEditorTrainPower: TrainPowerType?
    @State private var ticketCode: String?
    @State private var isPresentingTicketSheet = false
    @State private var isShowingStationDelaySheet = false
    @State private var segments: [GTFSSegment] = []
    @StateObject private var locationProvider = DeviceLocationProvider()
    @State private var isShowingSpeedPage = false
    @State private var isSpeedPageLoading = false
    @State private var isLiveActivityRunning = false
    @State private var liveActivityStatusText: String?
    @State private var liveActivityDiagnosticText: String?

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
            if !isPastTrip {
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
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.6)
                            .onChanged { _ in
                                guard !hasTriggeredSyncLongPress else { return }
                                hasTriggeredSyncLongPress = true
                                shouldSkipNextSync = true
                                forgetDelay()
                            }
                            .onEnded { _ in
                                hasTriggeredSyncLongPress = false
                            }
                    )
                    .disabled(isSyncingDelay)
                }
            }

            ToolbarItem(placement: .bottomBar) {
                Button(action: toggleLiveActivity) {
                    Label(
                        isLiveActivityRunning ? "Stop Live" : "Live",
                        systemImage: isLiveActivityRunning ? "bell.slash.fill" : "bell.badge.fill"
                    )
                }
                .disabled(isPastTrip)
            }

            ToolbarItem(placement: .bottomBar) {
                Button(action: {
                    isShowingStationDelaySheet = true
                }) {
                    Label("Delays", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .task(id: trip.id) {
            await loadTiming()
            await loadSegments()
            refreshLiveActivityState()
            await loadDestinationWeather()
        }
        .onReceive(secondTimer) { value in
            now = value
            refreshLiveActivityState()
        }
        .sheet(isPresented: $isPresentingSeatEditor) {
            SeatEditorSheet(
                carText: $seatEditorCar,
                seatsText: $seatEditorSeats,
                trainIdentifierText: $seatEditorTrainIdentifier,
                trainPower: $seatEditorTrainPower,
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
        .background(Color(.systemBackground))
        .sheet(isPresented: $isShowingStationDelaySheet) {
            WebcamBoardSheet(trip: trip, station: "BucurestiNord", onDismiss: {
                isShowingStationDelaySheet = false
            }, onUpdateTrip: { updatedTrip in
                onUpdateTrip?(updatedTrip)
            })
            .presentationDetents([.fraction(0.72), .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: trip.ticketQRCode ?? "") { _ in
            ticketCode = trip.ticketQRCode
        }
        .onChange(of: trip.id) { _ in
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
                        if !isPastTrip {
                            syncFreshnessIndicator
                        }
#if DEBUG
                        // Keep operational detail available while developing. The
                        // release UI communicates freshness through the indicator.
                        if !isPastTrip, let syncStatusText {
                            Text(syncStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !isPastTrip, let liveActivityStatusText {
                            Text(liveActivityStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !isPastTrip, let liveActivityDiagnosticText {
                            Text(liveActivityDiagnosticText)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                        if !isPastTrip, let freshness = liveDelayInfo?.freshnessText {
                            Text("Live data: \(freshness)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
#endif
                        if !isPastTrip, let candidate = locationPhaseDetector.earlyExitCandidate(for: trip) {
                            earlyExitConfirmationCard(candidate: candidate)
                        }
                        if !isPastTrip, let prediction = TripDelayFusionStore.shared.prediction(for: trip) {
                            delayPredictionCard(prediction)
                        }
                        if !isPastTrip, let bannerText = scraperStatusText {
                            ScraperStatusBanner(text: bannerText, isDelayed: scraperStatusIsDelayed)
                                .padding(.horizontal, -16)
                        }
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

    private func earlyExitConfirmationCard(candidate: TripEarlyExitCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Possible early exit", systemImage: "figure.walk.departure")
                .font(.headline)
            Text("Your location has stayed near \(candidate.stationName) beyond the expected stop. Did you get off here?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Keep tracking") {
                    locationPhaseDetector.dismissEarlyExit(for: trip)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("I got off here") {
                    locationPhaseDetector.confirmEarlyExit(for: trip)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private func delayPredictionCard(_ prediction: TripDelayPrediction) -> some View {
        let delayText: String = {
            guard let delay = prediction.delayMinutes else { return "No estimate yet" }
            if delay == 0 { return "Estimated on time" }
            return delay > 0 ? "Estimated +\(delay)m" : "Estimated \(abs(delay))m early"
        }()
        return HStack(spacing: 10) {
            Image(systemName: "location.north.line")
                .foregroundStyle(prediction.source == .infoFerConfirmed ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Arrival forecast")
                    .font(.subheadline.weight(.semibold))
                Text("\(delayText) • \(prediction.source.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var speedDashboard: some View {
        ScrollView {
            VStack(spacing: 24) {
                if isSpeedPageLoading {
                    speedLoadingCard
                } else {
                    currentSpeedCard
                    speedLimitCard
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

    private var speedLimitCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Track Speed Limit")
                .font(.headline)

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(maxSpeedDisplayValue)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("km/h")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let label = speedLimitSegmentLabel {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            if let comparison = speedComparisonDetailText {
                Text(comparison)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    private var syncFreshnessIndicator: some View {
        Circle()
            .fill(syncFreshnessColor)
            .frame(width: 8, height: 8)
            .accessibilityLabel(syncFreshnessAccessibilityLabel)
    }

    private var syncFreshnessColor: Color {
        guard let fetchedAt = liveDelayInfo?.fetchedAt else { return .gray }
        let age = Date().timeIntervalSince(fetchedAt)
        if age < 5 * 60 { return .green }
        if age < 20 * 60 { return .orange }
        return .red
    }

    private var syncFreshnessAccessibilityLabel: String {
        guard let fetchedAt = liveDelayInfo?.fetchedAt else { return "Live data unavailable" }
        let age = Date().timeIntervalSince(fetchedAt)
        if age < 5 * 60 { return "Live data is fresh" }
        if age < 20 * 60 { return "Live data may be getting old" }
        return "Live data is stale"
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

    private var referenceSpeedSegment: GTFSSegment? {
        currentSegmentContext?.segment ?? segments.first
    }

    private var maxSegmentSpeedValue: Int {
        referenceSpeedSegment?.maxSpeed ?? 0
    }

    private var maxSpeedDisplayValue: String {
        maxSegmentSpeedValue > 0 ? "\(maxSegmentSpeedValue)" : "--"
    }

    private var speedLimitSegmentLabel: String? {
        guard let segment = referenceSpeedSegment else { return nil }
        return segmentLabel(for: segment)
    }

    private var speedComparisonDetailText: String? {
        guard let current = currentSpeedKPH, maxSegmentSpeedValue > 0 else { return nil }
        let delta = Int(round(Double(maxSegmentSpeedValue) - current))
        if delta >= 0 {
            return "≈ \(delta) km/h below the limit"
        }
        return "≈ \(abs(delta)) km/h above the limit"
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
            return "Location is turned off for Raily. Enable it in Settings to track speed."
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
            operatorSection
            arrivalForecastSection
//            trackSpeedSection
            trainInfoSection
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

    private var scraperStatusText: String? {
        liveDelayInfo?.statusText
    }

    private var scraperStatusIsDelayed: Bool {
        (liveDelayInfo?.delayMinutes ?? trip.delayMinutes ?? 0) > 0
    }

    private var syncTravelDate: Date {
        trip.travelDate ?? timing.scheduledDeparture ?? Date()
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
        return !Calendar.current.isDate(arrival, inSameDayAs: departure)
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
        timing = await Task.detached(priority: .userInitiated) {
            TripTimingResolver().resolve(
                trip: trip,
                delayInfo: delayInfo,
                referenceDate: referenceDate
            )
        }.value
    }

    private func loadSegments() async {
        let identifier = tripIdentifier
        segments = await Task.detached(priority: .userInitiated) {
            dataSource.segments(for: identifier)
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
        if let serviceDepartureDate, Date() < serviceDepartureDate.addingTimeInterval(-30 * 60) {
            syncStatusText = "The train does not have data from its trip yet."
            return
        }

        isSyncingDelay = true
        syncStatusText = "Refreshing session…"

        Task {
            print("[TripDetailSheet] Starting InfoFer sync for \(trainNumber)")
            guard let result = await TripSyncService.shared.sync(trip: trip, shouldFetchMapInfo: true) else { return }
            let info = result.info
            print("[TripDetailSheet] Sync completed delay=\(info.delayMinutes ?? -1) platform=\(info.platform ?? "n/a")")

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.35)) {
                    liveDelayInfo = info
                }
                onUpdateTrip?(result.trip)
                isSyncingDelay = false
                syncStatusText = result.status.detailText
            }
        }
    }

    private var serviceDepartureDate: Date? {
        let baseDate = Calendar.current.startOfDay(for: syncTravelDate)
        let segments = dataSource.segments(for: tripIdentifier)
        guard let firstSegment = segments.min(by: {
            ($0.departureSeconds ?? $0.arrivalSeconds ?? Int.max) < ($1.departureSeconds ?? $1.arrivalSeconds ?? Int.max)
        }) else {
            return nil
        }
        guard let departureSeconds = firstSegment.departureSeconds ?? firstSegment.arrivalSeconds else { return nil }
        return baseDate.addingTimeInterval(TimeInterval(departureSeconds))
    }

    private func forgetDelay() {
        withAnimation(.easeInOut(duration: 0.35)) {
            liveDelayInfo = nil
        }
        LiveDelayStore.shared.clear(tripID: trip.id)
        LiveActivityManager.shared.updateActivity(for: trip)
        syncStatusText = "Delay cleared"
    }

    private func toggleLiveActivity() {
        if isLiveActivityRunning {
            LiveActivityManager.shared.endActivity(for: trip.id)
            isLiveActivityRunning = false
            liveActivityStatusText = "Live Activity stopped"
            refreshLiveActivityState()
            return
        }

        let result = LiveActivityManager.shared.startActivity(for: trip, delayInfo: liveDelayInfo)
        liveActivityStatusText = result.message
        refreshLiveActivityState()
    }

    private func refreshLiveActivityState() {
        isLiveActivityRunning = LiveActivityManager.shared.isActivityRunning(for: trip.id)
        liveActivityDiagnosticText = LiveActivityManager.shared.diagnosticSummary(for: trip.id)
    }

    private var resolvedTrainNumber: String? {
        trip.resolvedTrainNumber
    }
}

private extension TripDetailSheet {
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

    private var departureTerminalDisplay: TerminalStatusDisplay {
        terminalStatusDisplay(for: .departure, scheduledDate: timing.scheduledDeparture)
    }

    private var arrivalTerminalDisplay: TerminalStatusDisplay {
        terminalStatusDisplay(for: .arrival, scheduledDate: timing.scheduledArrival)
    }

    private var isWaitingAtOriginForDeparture: Bool {
        guard !isPastTrip,
              let departure = timing.adjustedDeparture,
              now >= departure,
              locationPhaseDetector.phase(for: trip) != .boarded,
              !hasFreshInfoFerTrainDeparture,
              let location = locationProvider.lastLocation,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 150,
              abs(location.timestamp.timeIntervalSinceNow) <= 15 * 60,
              let origin = coordinate(for: trip.originStopId, sequence: trip.originSequence, in: trip) else {
            return false
        }
        let radius = max(250, location.horizontalAccuracy * 1.5)
        return location.distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude)) <= radius
    }

    private var hasFreshInfoFerTrainDeparture: Bool {
        guard let info = liveDelayInfo,
              let liveCoordinate = info.liveCoordinate,
              let fetchedAt = info.fetchedAt,
              Date().timeIntervalSince(fetchedAt) <= 15 * 60,
              let origin = coordinate(for: trip.originStopId, sequence: trip.originSequence, in: trip) else {
            return false
        }
        let trainDistance = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: liveCoordinate.latitude, longitude: liveCoordinate.longitude))
        return trainDistance > 750
    }

    private var stationDelayEntries: [StationDelayEntry] {
        let stops = segmentStops
        guard !stops.isEmpty else { return [] }

        return stops.enumerated().map { index, stop in
            StationDelayEntry(
                id: stop.id,
                name: stop.name,
                platform: stop.platform,
                arrivalDelay: stop.arrivalDelayMinutes,
                departureDelay: stop.departureDelayMinutes,
                isOrigin: isOriginStop(stop),
                isDestination: isDestinationStop(stop),
                isFirst: index == 0,
                isLast: index == stops.count - 1
            )
        }
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

            OperatorActionButton(title: "Send a report") {}
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color(.systemGray3).opacity(0.9), lineWidth: 1)
        )
    }

    @ViewBuilder
    var arrivalForecastSection: some View {
        let history = dataSource.delayHistory(for: resolvedTrainNumber ?? trip.id)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Arrival Forecast")
                    .font(.system(size: 20, weight: .semibold))
                Text(arrivalForecastSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 50) {
                ForecastStatView(title: "Late", icon: "clock", value: history.map { "\(roundedPercent($0.delayedTrips, of: $0.observedTrips))%" } ?? "--")
                ForecastStatView(title: "Avg. delay", icon: "stopwatch", value: history.map { formattedAverageDelay($0.averageDelayMinutes) } ?? "--")
                ForecastStatView(title: "Observed", icon: "binoculars", value: history.map { "\($0.observedTrips)" } ?? "--")
            }

            VStack(spacing: 10) {
                ForEach(arrivalDistribution, id: \.label) { entry in
                    HStack(spacing: 12) {
                        Text(entry.label)
                            .font(.system(size: 13, weight: .regular))
                            .frame(width: 65, alignment: .leading)

                        ArrivalBarView(percent: entry.percent, barColor: entry.color)

                        Text("\(entry.percent)%")
                            .font(.system(size: 13, weight: .regular))
                            .frame(width: 30, alignment: .trailing)
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

    private var arrivalDistribution: [(label: String, percent: Int, color: Color)] {
        guard let history = dataSource.delayHistory(for: resolvedTrainNumber ?? trip.id) else {
            return []
        }
        return [
            ("On time", percentValue(history.percentOnTime), Color.green.opacity(0.8)),
            ("15m late", percentValue(history.percentDelay15Minutes), Color.yellow.opacity(0.8)),
            ("30m late", percentValue(history.percentDelay30Minutes), Color.orange.opacity(0.85)),
            ("45m+ late", percentValue(history.percentDelay45MinutesPlus), Color.orange.opacity(0.6))
        ]
    }

    private var arrivalForecastSubtitle: String {
        "\(trainDisplayName) performance over the last 60 days"
    }

    private func percentValue(_ value: Double) -> Int {
        Int(value.rounded())
    }

    private func roundedPercent(_ count: Int, of total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(count) / Double(total) * 100).rounded())
    }

    private func formattedAverageDelay(_ value: Double) -> String {
        let minutes = Int(value.rounded())
        if minutes == 0 { return "0m" }
        return minutes > 0 ? "+\(minutes)m" : "\(minutes)m"
    }

    private var trainDisplayName: String {
        let title = trip.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstComponent = title.split(separator: "•").first {
            return String(firstComponent).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
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

    @ViewBuilder
    private var trainInfoSection: some View {
        Button(action: openSeatEditor) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("About the Train")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Tap to edit seats, license & traction")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    trainPowerChip
                    Image(systemName: "chevron.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if trip.agencyId == "236025" {
                    HStack() {
                        Spacer()
                        Image("train")
                            .resizable()
                            .scaledToFill()
                            .clipped()
                            .frame(alignment: .leading)
                            .padding(.trailing, -16)
                    }
                }

                trainFactRow(
                    title: "Type",
                    value: trainTypeFact.text,
                    isPlaceholder: trainTypeFact.isPlaceholder
                )

                Divider()

                trainFactRow(
                    title: "Registration",
                    value: trainIdentifierFact.text,
                    isPlaceholder: trainIdentifierFact.isPlaceholder
                )

                Divider()

                trainFactRow(
                    title: "Length",
                    value: trainLengthFact.text,
                    isPlaceholder: trainLengthFact.isPlaceholder
                )

                Divider()

                trainFactRow(
                    title: "Tonnage",
                    value: trainTonnageFact.text,
                    isPlaceholder: trainTonnageFact.isPlaceholder
                )

                Divider()

                trainFactRow(
                    title: "Voltage & Frequency",
                    value: trainElectrificationFact.text,
                    isPlaceholder: trainElectrificationFact.isPlaceholder
                )

                Divider()

                trainFactRow(
                    title: "Track Gauge",
                    value: trainTrackGaugeFact.text,
                    isPlaceholder: trainTrackGaugeFact.isPlaceholder
                )
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color(.systemGray3).opacity(0.9), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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

    private var resolvedTrainType: TrainType? {
        if let stored = trip.trainType {
            return stored
        }
        return TrainType.inferred(fromTitle: trip.title)
    }

    private var trainTypeFact: (text: String, isPlaceholder: Bool) {
        if let type = resolvedTrainType {
            return (type.displayLabel, false)
        }
        return ("Add train type", true)
    }

    private var trainIdentifierFact: (text: String, isPlaceholder: Bool) {
        guard let identifier = trip.trainIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty else {
            return ("Add train license", true)
        }
        return (identifier, false)
    }

    private var trainLengthFact: (text: String, isPlaceholder: Bool) {
        if let stored = trip.trainLength?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return (stored, false)
        }
        if let derived = derivedTrainLengthText {
            return (derived, false)
        }
        return ("Add train length", true)
    }

    private var trainTonnageFact: (text: String, isPlaceholder: Bool) {
        if let stored = trip.trainTonnage?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return (stored, false)
        }
        if let derived = derivedTrainTonnageText {
            return (derived, false)
        }
        return ("Add tonnage", true)
    }

    private var trainElectrificationFact: (text: String, isPlaceholder: Bool) {
        ("25kV @ 50Hz", false)
    }

    private var trainTrackGaugeFact: (text: String, isPlaceholder: Bool) {
        ("1435mm standard", false)
    }

    private var derivedTrainLengthText: String? {
        guard let meters = segments.first?.trainLengthMeters, meters > 0 else { return nil }
        return "\(meters) m"
    }

    private var derivedTrainTonnageText: String? {
        guard let tons = segments.first?.trainTonnage, tons > 0 else { return nil }
        return "\(tons) t"
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
        operatorLocationText ?? operatorWebsiteHost ?? "Romania"
    }

    private var operatorLocationText: String? {
        OperatorBrandingCatalog.city(for: trip.agencyId)
            ?? inferredLocationFromTimezone
            ?? operatorWebsiteHost
    }

    private var inferredLocationFromTimezone: String? {
        guard let timezone = operatorAgencyInfo?.timezone else { return nil }
        guard let component = timezone.split(separator: "/").last else { return nil }
        let city = component.replacingOccurrences(of: "_", with: " ")
        return city.isEmpty ? nil : city
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

    @ViewBuilder
    private func trainFactRow(title: String, value: String, isPlaceholder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var trainPowerChip: some View {
        if let power = trip.trainPower {
            Label(power.displayName, systemImage: power.systemImage)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(power == .electric ? Color.blue : Color.orange)
                .background((power == .electric ? Color.blue : Color.orange).opacity(0.15))
                .clipShape(Capsule())
        } else {
            Text("Set traction")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(.secondary)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
        }
    }

    private func openSeatEditor() {
        seatEditorCar = trip.seatCar ?? ""
        seatEditorSeats = trip.seatNumbers?.joined(separator: ", ") ?? ""
        seatEditorTrainIdentifier = trip.trainIdentifier ?? ""
        seatEditorTrainPower = trip.trainPower
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

    private func saveSeatEditor() {
        let trimmedCar = seatEditorCar.trimmingCharacters(in: .whitespacesAndNewlines)
        let carValue = trimmedCar.isEmpty ? nil : trimmedCar

        let seatTokens = seatEditorSeats
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let seatsValue = seatTokens.isEmpty ? nil : seatTokens

        let trimmedIdentifier = seatEditorTrainIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trainIdentifierValue = trimmedIdentifier.isEmpty ? nil : trimmedIdentifier

        guard let onUpdateTrip else {
            isPresentingSeatEditor = false
            return
        }

        let updatedTrip = trip.updatingSeatInfo(
            car: carValue,
            seats: seatsValue,
            trainType: trip.trainType ?? resolvedTrainType,
            trainLength: trip.trainLength ?? derivedTrainLengthText,
            trainTonnage: trip.trainTonnage ?? derivedTrainTonnageText,
            trainIdentifier: trainIdentifierValue,
            trainPower: seatEditorTrainPower
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

private struct SegmentTimelineEntry {
    let segment: GTFSSegment
    let startDate: Date
    let endDate: Date
}

private struct SegmentSpeedContext {
    enum State {
        case upcoming
        case active
        case complete
    }

    let segment: GTFSSegment
    let startDate: Date
    let endDate: Date
    let state: State

    init(entry: SegmentTimelineEntry, state: State) {
        segment = entry.segment
        startDate = entry.startDate
        endDate = entry.endDate
        self.state = state
    }
}

private enum SegmentClockEvent {
    case departure
    case arrival
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

private struct StationDelayEntry: Identifiable {
    let id: String
    let name: String
    let platform: String?
    let arrivalDelay: Int?
    let departureDelay: Int?
    let isOrigin: Bool
    let isDestination: Bool
    let isFirst: Bool
    let isLast: Bool

    var platformLabel: String {
        guard let platform, !platform.isEmpty, platform != "-" else { return "—" }
        return "Linia \(platform)"
    }
}

private struct StationDelaysSheet: View {
    let entries: [StationDelayEntry]
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                StationDelayTimelineView(entries: entries)
                    .padding()
            }
            .navigationTitle("Station Delays")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss?() }
                }
            }
        }
    }
}

private struct WebcamBoardSheet: View {
    let trip: Trip
    let station: String
    var onDismiss: (() -> Void)? = nil
    var onUpdateTrip: ((Trip) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var currentImage: UIImage?
    @State private var platformText: String?
    @State private var statusText: String = "Waiting for the first webcam refresh…"
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerCard

                    if isLoading && currentImage == nil {
                        loadingCard
                    } else {
                        if let loadError {
                            errorCard(text: loadError)
                        }
                        platformCard
                        webcamImageCard
                    }
                }
                .padding()
            }
            .navigationTitle("Platform OCR")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        loadTask?.cancel()
                        dismiss()
                        onDismiss?()
                    }
                }
            }
        }
        .onAppear {
            guard loadTask == nil else { return }
            loadTask = Task { await runRefreshLoop() }
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bucharest North platform")
                    .font(.system(size: 22, weight: .semibold))
                Spacer(minLength: 12)
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            Text("Live board OCR for \(station)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.7), lineWidth: 1)
        )
    }

    private var loadingCard: some View {
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.2)
            Text("Reading the board…")
                .font(.headline)
            Text("Fetching the JPG and checking the train row.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.7), lineWidth: 1)
        )
    }

    private var platformCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Platform")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(platformText ?? "—")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(platformText == nil ? "not there yet" : "confirmed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.7), lineWidth: 1)
        )
    }

    private func errorCard(text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Could not load board")
                .font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var webcamImageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Webcam JPG")
                .font(.system(size: 20, weight: .semibold))
            Text("The raw image fetched from the CFR webcam page.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let currentImage {
                Image(uiImage: currentImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color(.separator).opacity(0.7), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.quaternary.opacity(0.35))
                    .frame(height: 220)
                    .overlay {
                        ProgressView()
                    }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.7), lineWidth: 1)
        )
    }

    private func runRefreshLoop() async {
        await refreshOnce()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                break
            }
            guard !Task.isCancelled else { break }
            await refreshOnce()
        }
    }

    private func refreshOnce() async {
        await MainActor.run {
            isLoading = true
            loadError = nil
        }

        let observation = await InfoFerScraper.shared.fetchBoardObservation(for: trip, station: station)

        guard !Task.isCancelled else { return }

        await MainActor.run {
            guard !Task.isCancelled else { return }
            isLoading = false
            guard let observation else {
                loadError = "Unable to fetch or read the webcam board."
                statusText = "Unable to fetch or read the webcam board."
                return
            }

            currentImage = observation.image
            platformText = observation.platformText
            statusText = observation.statusText
            loadError = nil

            if let updatedTrip = observation.updatedTrip {
                onUpdateTrip?(updatedTrip)
            }
        }
    }
}

private extension TripDetailSheet {
    @ViewBuilder
    var trackSpeedSection: some View {
        if let context = currentSegmentContext {
            VStack(alignment: .leading, spacing: 16) {
                Text("Track Speed Limit")
                    .font(.system(size: 20, weight: .semibold))

                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(speedDisplayValue(for: context.segment.maxSpeed))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if context.segment.maxSpeed > 0 {
                        Text("km/h")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: context.segment.id)

                VStack(alignment: .leading, spacing: 4) {
                    Text(segmentLabel(for: context.segment))
                        .font(.headline)
                    Text(segmentStateDescription(for: context))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(segmentWindowDescription(for: context))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color(.systemGray3).opacity(0.9), lineWidth: 1)
            )
        }
    }

    private func speedDisplayValue(for speed: Int) -> String {
        speed > 0 ? "\(speed)" : "-"
    }

    private func segmentLabel(for segment: GTFSSegment) -> String {
        let origin = segmentStationName(segment.startName, fallback: segment.startId)
        let destination = segmentStationName(segment.endName, fallback: segment.endId)
        return "\(origin) → \(destination)"
    }

    private func segmentStateDescription(for context: SegmentSpeedContext) -> String {
        switch context.state {
        case .active:
            return "Segment in progress"
        case .upcoming:
            return "Segment scheduled next"
        case .complete:
            return "Segment completed"
        }
    }

    private func segmentWindowDescription(for context: SegmentSpeedContext) -> String {
        let startText = segmentTimeLabel(for: context.startDate)
        let endText = segmentTimeLabel(for: context.endDate)
        switch context.state {
        case .active:
            return "Live window: \(startText) – \(endText)"
        case .upcoming:
            return "Begins around \(startText)"
        case .complete:
            return "Ended around \(endText)"
        }
    }

    private func segmentStationName(_ name: String?, fallback: String) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return fallback
    }

    private func segmentTimeLabel(for date: Date) -> String {
        TripDetailSheet.timeFormatter.string(from: date)
    }

    private var currentSegmentContext: SegmentSpeedContext? {
        let entries = segmentTimelineEntries
        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.startDate < $1.startDate }
        let reference = now

        if let active = sorted.first(where: { reference >= $0.startDate && reference <= $0.endDate }) {
            return SegmentSpeedContext(entry: active, state: .active)
        }

        if reference < sorted.first!.startDate {
            let upcoming = sorted.first(where: { reference <= $0.startDate }) ?? sorted.first!
            return SegmentSpeedContext(entry: upcoming, state: .upcoming)
        }

        if reference > sorted.last!.endDate {
            let last = sorted.last!
            return SegmentSpeedContext(entry: last, state: .complete)
        }

        if let upcoming = sorted.first(where: { reference <= $0.startDate }) {
            return SegmentSpeedContext(entry: upcoming, state: .upcoming)
        }

        return nil
    }

    private var segmentTimelineEntries: [SegmentTimelineEntry] {
        guard !segments.isEmpty else { return [] }
        let baseDate = segmentBaseDate
        var lastReference: Date?
        let entries: [SegmentTimelineEntry] = segments.compactMap { segment in
            guard
                var startDate = adjustedSegmentDate(seconds: segment.departureSeconds, stopId: segment.startId, stationName: segment.startName, event: .departure, baseDate: baseDate),
                var endDate = adjustedSegmentDate(seconds: segment.arrivalSeconds, stopId: segment.endId, stationName: segment.endName, event: .arrival, baseDate: baseDate)
            else {
                return nil
            }

            if let arrivalNormalized = ScheduleDateUtils.normalizedArrival(endDate, relativeTo: startDate) {
                endDate = arrivalNormalized
            }

            startDate = ScheduleDateUtils.shiftedForward(startDate, after: lastReference)
            endDate = ScheduleDateUtils.shiftedForward(endDate, after: startDate)
            lastReference = endDate

            return SegmentTimelineEntry(segment: segment, startDate: startDate, endDate: endDate)
        }
        return entries
    }

    private var segmentBaseDate: Date {
        let reference = timing.scheduledDeparture ?? trip.travelDate ?? syncTravelDate
        var candidate = Calendar.current.startOfDay(for: reference)
        if reference < now,
           let firstSeconds = segments.first?.departureSeconds {
            let firstStart = candidate.addingTimeInterval(TimeInterval(firstSeconds))
            if now < firstStart {
                candidate = candidate.addingTimeInterval(-ScheduleDateUtils.dayInterval)
            }
        }
        return candidate
    }

    private func adjustedSegmentDate(
        seconds: Int?,
        stopId: String,
        stationName: String?,
        event: SegmentClockEvent,
        baseDate: Date
    ) -> Date? {
        guard let seconds else { return nil }
        var date = baseDate.addingTimeInterval(TimeInterval(seconds))
        if let delay = segmentDelayMinutes(for: stopId, stationName: stationName, event: event) ?? activeDelayMinutes,
           delay != 0 {
            date = date.addingTimeInterval(TimeInterval(delay * 60))
        }
        return date
    }

    private func segmentDelayMinutes(
        for stopId: String,
        stationName: String?,
        event: SegmentClockEvent
    ) -> Int? {
        if let stop = trip.stops?.first(where: { $0.id == stopId }) {
            return event == .departure ? stop.departureDelayMinutes : stop.arrivalDelayMinutes
        }

        guard let stationName else { return nil }
        let normalized = normalizeStationName(stationName)
        if let info = liveDelayInfo,
           let entry = info.stationDelays.first(where: { normalizeStationName($0.stationName) == normalized }) {
            switch event {
            case .departure:
                return entry.departureDelayMinutes
            case .arrival:
                return entry.arrivalDelayMinutes
            }
        }

        return nil
    }
}

private struct StationDelayTimelineView: View {
    let entries: [StationDelayEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Station Delays")
                .font(.system(size: 18, weight: .semibold))

            if entries.isEmpty {
                Text("No station-level delay data yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(entries.indices, id: \.self) { index in
                        StationDelayRow(entry: entries[index])
                        if index < entries.count - 1 {
                            Divider().opacity(0.2)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(.separator), lineWidth: 1)
        )
    }
}

private struct StationDelayRow: View {
    let entry: StationDelayEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimelineIndicator(isFirst: entry.isFirst, isLast: entry.isLast, isHighlighted: entry.isOrigin || entry.isDestination)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .fontWeight(entry.isOrigin || entry.isDestination ? .semibold : .regular)
                    if entry.isOrigin {
                        tagView("Origin")
                    }
                    if entry.isDestination {
                        tagView("Destination")
                    }
                }

                HStack(spacing: 8) {
                    DelayBadge(label: "Arr", value: entry.arrivalDelay)
                    DelayBadge(label: "Dep", value: entry.departureDelay)
                }
            }

            Spacer(minLength: 0)

            Text(entry.platformLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func tagView(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())
    }
}

private struct TimelineIndicator: View {
    let isFirst: Bool
    let isLast: Bool
    let isHighlighted: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 2, height: isFirst ? 0 : 12)
            Circle()
                .fill(isHighlighted ? Color.orange : Color(.label))
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(Color(.separator), lineWidth: 1)
                )
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 2, height: isLast ? 0 : 12)
        }
        .frame(width: 12)
    }
}

private struct DelayBadge: View {
    let label: String
    let value: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(displayText)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var displayText: String {
        guard let value else { return "--" }
        if value > 0 { return "+\(value)m" }
        if value < 0 { return "−\(abs(value))m" }
        return "0m"
    }

    private var color: Color {
        guard let value else { return .secondary }
        if value > 0 { return .orange }
        if value < 0 { return .green }
        return .secondary
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
    var isPlaceholder: Bool = false

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
                    .foregroundStyle(isPlaceholder ? .secondary : .primary)
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
    @Binding var trainIdentifierText: String
    @Binding var trainPower: TrainPowerType?
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Coach") {
                    TextField("e.g. 12", text: $carText)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                }

                Section("Seats") {
                    TextField("e.g. 22A, 22B", text: $seatsText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }

                Section("Train License") {
                    TextField("e.g. 90 53 0481 001-2", text: $trainIdentifierText)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                }

                Section("Traction") {
                    Picker("Power", selection: $trainPower) {
                        Text("Not set").tag(nil as TrainPowerType?)
                        ForEach(TrainPowerType.allCases) { power in
                            Text(power.displayName).tag(power as TrainPowerType?)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("Seat & Train Details")
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

private struct ScraperStatusBanner: View {
    let text: String
    let isDelayed: Bool

    private var accentColor: Color {
        isDelayed ? .red : .green
    }

    private var backgroundColor: Color {
        accentColor.opacity(0.12)
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(accentColor)
                .frame(height: 1)

            Text(text)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .foregroundStyle(accentColor)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .background(backgroundColor)

            Rectangle()
                .fill(accentColor)
                .frame(height: 1)
        }
    }
}

private struct ForecastStatView: View {
    let title: String
    let icon: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.headline)
                Text(value)
                    .font(.system(size: 16, weight: .semibold))
            }
        }
    }
}

private struct ArrivalBarView: View {
    let percent: Int
    let barColor: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(.systemGray5))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(barColor)
                    .frame(width: max(0, CGFloat(percent) / 100.0 * proxy.size.width))
            }
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity)
    }
}
