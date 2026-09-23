import SwiftUI
import MapKit
import Combine
import BackgroundTasks

final class BlitzAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: automaticLiveActivityTaskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            task.expirationHandler = { }
            Task { @MainActor in
                LiveActivityManager.shared.startScheduledActivities()
                LiveActivityManager.shared.scheduleNextAutomaticStart()
                task.setTaskCompleted(success: true)
            }
        }
        LiveActivityManager.shared.scheduleNextAutomaticStart()
        return true
    }
}

@main
struct BlitzApp: App {
    @UIApplicationDelegateAdaptor(BlitzAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct MissedTrainPrompt: Identifiable {
    let id: String
    let trainTitle: String
    let originStopID: String
    let destinationStopID: String?
    let trainID: String?
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 45.9432, longitude: 24.9668),
        span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)
    )

    @State private var mapPosition: MapCameraPosition = .region(defaultRegion)
    @State private var selectedDetent: PresentationDetent = .medium
    @State private var isSheetPresented: Bool = true
    @State private var selectedTrip: Trip? = nil
    @State private var isAddTripMode: Bool = false
    @State private var trainSearchQuery: String = ""
    @State private var trips: [Trip] = TripStorage.shared.loadTrips()
    @State private var pastTrips: [Trip] = TripStorage.shared.loadPastTrips()
    @State private var liveTrainClock = Date()
    @State private var trackingRefreshRevision = 0
    @State private var hasSyncedTripsOnLaunch = false
    @State private var missedTrainPrompt: MissedTrainPrompt?
    @State private var dismissedMissedTrainPromptIDs: Set<String> = []
    @State private var missedTrainOriginal: Trip?
    @State private var missedTrainAlternatives: [Trip] = []
    @State private var isShowingMissedTrainAlternatives = false
    @State private var missedTrainDiagnosticText: String?
    @State private var usesGlobeMapStyle = false
    @State private var isSpeedCapsuleRevealed = false
    @State private var speedCapsuleHideTask: Task<Void, Never>?
    @State private var speedLimitSegments: [GTFSSegment] = []
    @StateObject private var locationProvider = DeviceLocationProvider()
    @StateObject private var locationPhaseDetector = TripLocationPhaseDetector()
    // The detail sheet owns its own one-second countdown timeline. The map
    // only needs a lower-frequency clock for interpolation and missed-train
    // checks, which avoids rebuilding the full Map every second.
    private let liveTrainTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let liveActivityRefreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var currentDetailState: DetailMapState? {
        guard let trip = selectedTrip, !isAddTripMode else { return nil }
        return detailMapState(for: trip)
    }

    private var shouldShowUserLocation: Bool {
        shouldDisplayUserLocationDot(for: currentDetailState)
    }

    private var shouldShowLiveTrainMarker: Bool {
        shouldDisplayLiveTrainMarker(
            for: currentDetailState,
            userLocationVisible: shouldShowUserLocation
        )
    }

    private var mapView: some View {
        let detailState = currentDetailState
        let showUserLocation = shouldDisplayUserLocationDot(for: detailState)
        let showTrainMarker = shouldDisplayLiveTrainMarker(
            for: detailState,
            userLocationVisible: showUserLocation
        )

        return Map(position: $mapPosition) {
            if showUserLocation {
                UserAnnotation()
            }
            if let detailState {
                detailMapContent(state: detailState, showLiveTrainMarker: showTrainMarker)
            } else {
                dashboardMapContent()
            }
        }
        .mapStyle(usesGlobeMapStyle ? .hybrid(elevation: .realistic) : .standard(elevation: .automatic))
        .mapControlVisibility(.hidden)
        .animation(.linear(duration: 1), value: liveTrainClock)
        .animation(.easeInOut(duration: 1.2), value: trackingRefreshRevision)
        .overlay(alignment: .topTrailing) {
            MapToolbarButtons(
                isGlobeStyle: usesGlobeMapStyle,
                showLocationButton: showUserLocation,
                onToggleStyle: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        usesGlobeMapStyle.toggle()
                    }
                },
                onCenterOnUser: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        mapPosition = .userLocation(fallback: .automatic)
                    }
                }
            )
            .padding(.top, 52)
            .padding(.trailing, 16)
        }
        .overlay(alignment: .top) {
            if let trip = activeMapTrip {
                mapSpeedCapsule(for: trip)
                    .padding(.top, 52)
                    .padding(.horizontal, 76)
            }
        }
#if DEBUG
        .overlay(alignment: .topLeading) {
            if TripLocationDetectionPreferences.missedTrainDebugUIEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    if let diagnostic = missedTrainDiagnosticText {
                        Text(diagnostic)
                    }
                    if TripLocationDetectionPreferences.missedTrainSimulationEnabled,
                       let trip = activeMapTrip {
                        Button("Simulate missed train") {
                            simulateMissedTrain(for: trip)
                        }
                        .font(.caption2.weight(.semibold))
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1) }
                .padding(.top, 104)
                .padding(.leading, 16)
            }
        }
#endif
        .safeAreaInset(edge: .top, alignment: .center) {
            Color.clear
                .frame(height: 20)
        }
        .ignoresSafeArea()
    }

    var body: some View {
        eventHandlersView
    }

    private var mapWithSheet: some View {
        mapView
        .sheet(isPresented: $isSheetPresented) {
            SheetContent(
                trips: $trips,
                selectedTrip: $selectedTrip,
                isAddTripMode: addTripModeBinding,
                trainSearchQuery: $trainSearchQuery,
                pastTrips: $pastTrips,
                missedTrainPrompt: $missedTrainPrompt,
                isShowingMissedTrainAlternatives: $isShowingMissedTrainAlternatives,
                missedTrainAlternatives: missedTrainAlternatives,
                locationPhaseDetector: locationPhaseDetector,
                onTripAdded: syncTripAfterAdd,
                onMissedTrainFindAlternatives: findMissedTrainAlternatives,
                onMissedTrainKeepTracking: dismissMissedTrainPrompt,
                onSelectMissedTrainAlternative: selectAlternative
            )
            .presentationDetents(detents, selection: $selectedDetent)
            .presentationBackground(Color(.systemBackground))
            .presentationBackgroundInteraction(.enabled)
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(true)
        }
    }

    private var stateHandlersView: some View {
        mapWithSheet
        .onChange(of: isAddTripMode) { _, newValue in
            if !newValue {
                DispatchQueue.main.async {
                    selectedDetent = .medium
                }
            }
            if newValue {
                locationProvider.disableTracking()
            } else {
                updateLocationPhaseDetection(for: selectedTrip)
                updateTrackingState(using: currentDetailState?.trackingResult)
            }
            updateCameraForCurrentState()
        }
        .onChange(of: selectedTrip) { _, newValue in
            isSpeedCapsuleRevealed = false
            speedCapsuleHideTask?.cancel()
            speedLimitSegments = []
            preloadRouteData(for: newValue)
            if newValue != nil {
                DispatchQueue.main.async {
                    selectedDetent = .medium
                }
            } else {
                DispatchQueue.main.async {
                    selectedDetent = .medium
                }
                locationProvider.disableTracking()
            }
            updateLocationPhaseDetection(for: newValue)
            updateTrackingState(using: currentDetailState?.trackingResult)
            updateCameraForCurrentState()
        }
    }

    private var lifecycleHandlersView: some View {
        stateHandlersView
        .onChange(of: locationProvider.lastLocation?.timestamp) { _, _ in
            updateLocationPhaseDetection(for: selectedTrip)
            evaluateMissedTrainSuggestion(for: selectedTrip)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tripLocationDetectionPreferenceChanged)) { _ in
            updateLocationPhaseDetection(for: selectedTrip)
            updateTrackingState(using: nil)
        }
        .onAppear {
            locationPhaseDetector.removeExpired()
            MissedTrainPromptStore.prune()
            updateCameraForCurrentState(animated: false)
            preloadRouteData(for: selectedTrip)
            updateLocationPhaseDetection(for: selectedTrip)
            evaluateMissedTrainSuggestion(for: selectedTrip)
            // A SwiftUI task may not rerun when the app returns from suspension
            // with the same selected trip, so explicitly restart reconciliation.
            updateTrackingState(using: currentDetailState?.trackingResult)
            syncTripsOnLaunchIfNeeded()
        }
    }

    private var timerHandlersView: some View {
        lifecycleHandlersView
        .onReceive(liveTrainTimer) { value in
            guard selectedTrip != nil else { return }
            withAnimation(.linear(duration: 1)) {
                liveTrainClock = value
            }
            evaluateMissedTrainSuggestion(for: selectedTrip)
        }
        .onReceive(liveActivityRefreshTimer) { _ in
            refreshRunningLiveActivities()
        }
        .onReceive(NotificationCenter.default.publisher(for: .liveDelayInfoUpdated)) { notification in
            guard let tripID = notification.object as? String else { return }
            withAnimation(.easeInOut(duration: 1.2)) {
                liveTrainClock = Date()
                trackingRefreshRevision += 1
            }
            refreshLiveActivity(for: tripID)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            updateLocationPhaseDetection(for: selectedTrip)
            evaluateMissedTrainSuggestion(for: selectedTrip)
            // Reconcile the persisted last fix and resume future location fixes
            // even when the selected trip itself did not change.
            updateTrackingState(using: currentDetailState?.trackingResult)
            LiveActivityManager.shared.startScheduledActivities()
            LiveActivityManager.shared.scheduleNextAutomaticStart()
            refreshRunningLiveActivities()
        }
    }

    private var eventHandlersView: some View {
        timerHandlersView
        .onChange(of: trips) { _, newValue in
            TripStorage.shared.saveTrips(newValue)
            updateCameraForCurrentState()
        }
        .onChange(of: trips) { oldValue, newValue in
            let activeIDs = Set(newValue.map(\.id))
            let removedIDs = Set(oldValue.map(\.id)).subtracting(activeIDs)
            locationPhaseDetector.remove(tripIDs: removedIDs)
            TripDelayFusionStore.shared.remove(tripIDs: removedIDs)
            oldValue
                .filter { !activeIDs.contains($0.id) }
                .forEach { LiveActivityManager.shared.endActivity(for: $0.id) }
        }
        .onChange(of: pastTrips) { _, newValue in
            TripStorage.shared.savePastTrips(newValue)
        }
        // Run tracking side effect when the selected trip or user-location visibility changes.
        .task(id: trackingTaskKey(for: currentDetailState)) {
            updateTrackingState(using: currentDetailState?.trackingResult)
        }
    }

    private var detents: Set<PresentationDetent> {
        isAddTripMode ? [.large] : [.fraction(0.3), .medium, .large]
    }

    private var activeMapTrip: Trip? {
        guard let selectedTrip else { return nil }
        return trips.first(where: { $0.id == selectedTrip.id })
    }

    private var showsSpeedCapsuleDetails: Bool {
        TripLocationDetectionPreferences.continuousSpeedCapsuleEnabled || isSpeedCapsuleRevealed
    }

    private func mapSpeedCapsule(for trip: Trip) -> some View {
        let speedLimit = mapSpeedLimitValue(for: trip)
        return Button(action: revealSpeedCapsule) {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                if showsSpeedCapsuleDetails {
                    if hasCurrentSpeedFix {
                        Text("\(mapSpeedDisplayValue) km/h")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.25), value: mapSpeedDisplayValue)
                    } else {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("GPS…")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    Text("•")
                        .foregroundStyle(.secondary)
                        Text("Limit \(speedLimit) km/h")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.25), value: speedLimit)
                } else {
                    Text("Speed")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "hand.tap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(Color.white.opacity(0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsSpeedCapsuleDetails ? "Current speed and speed limit" : "Show current speed and speed limit")
        .accessibilityValue(showsSpeedCapsuleDetails ? (hasCurrentSpeedFix ? "\(mapSpeedDisplayValue) kilometres per hour, limit \(speedLimit)" : "Acquiring GPS speed, limit \(speedLimit)") : "Hidden to save battery")
        .task(id: trip.id) {
            let identifier = trip.gtfsTripId ?? trip.id
            let loaded = await Task.detached(priority: .utility) {
                GTFSDataSource.shared.segments(for: identifier)
            }.value
            guard activeMapTrip?.id == trip.id else { return }
            speedLimitSegments = loaded
        }
    }

    private var mapSpeedDisplayValue: String {
        guard let speed = locationProvider.currentSpeed, speed >= 0 else { return "--" }
        return String(format: "%.0f", speed * 3.6)
    }

    private var hasCurrentSpeedFix: Bool {
        guard let speed = locationProvider.currentSpeed else { return false }
        return speed >= 0 && speed.isFinite
    }

    private func mapSpeedLimitValue(for trip: Trip) -> String {
        let segments = speedLimitSegments
        guard !segments.isEmpty else { return "--" }
        guard let travelDate = trip.travelDate else {
            return segments.first(where: { $0.maxSpeed > 0 }).map { String($0.maxSpeed) } ?? "--"
        }
        let dayStart = Calendar.current.startOfDay(for: travelDate)
        let active = segments.first { segment in
            guard let start = segment.departureSeconds ?? segment.arrivalSeconds,
                  let end = segment.arrivalSeconds ?? segment.departureSeconds else { return false }
            let startDate = dayStart.addingTimeInterval(TimeInterval(start))
            let normalizedEnd = end < start ? end + Int(ScheduleDateUtils.dayInterval) : end
            let endDate = dayStart.addingTimeInterval(TimeInterval(normalizedEnd))
            return liveTrainClock >= startDate && liveTrainClock <= endDate
        }
        let fallback = active ?? segments.first(where: { $0.maxSpeed > 0 })
        guard let speed = fallback?.maxSpeed, speed > 0 else { return "--" }
        return String(speed)
    }

    private func revealSpeedCapsule() {
        guard !TripLocationDetectionPreferences.continuousSpeedCapsuleEnabled else { return }
        speedCapsuleHideTask?.cancel()
        isSpeedCapsuleRevealed = true
        locationProvider.enableSpeedTracking()
        speedCapsuleHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            isSpeedCapsuleRevealed = false
            locationProvider.stopSpeedTracking()
        }
    }

    private var addTripModeBinding: Binding<Bool> {
        Binding(
            get: { isAddTripMode },
            set: { newValue in
                if newValue {
                    selectedDetent = .large
                    isAddTripMode = true
                } else {
                    isAddTripMode = false
                }
            }
        )
    }

    private func trackingTaskKey(for state: DetailMapState?) -> String {
        let tripID = state?.trip.id ?? "dashboard"
        let showsUser = state?.trackingResult?.showsUserLocation == true
        let detectedPhase = state.map { locationPhaseDetector.phase(for: $0.trip).rawValue } ?? "none"
        return "\(tripID)-\(showsUser)-\(detectedPhase)"
    }

    private func preloadRouteData(for trip: Trip?) {
        guard let trip else { return }
        let identifier = trip.gtfsTripId ?? trip.id
        Task.detached(priority: .utility) {
            GTFSDataSource.shared.preloadRouteData(for: identifier)
        }
    }

    private func syncTripsOnLaunchIfNeeded() {
        guard !hasSyncedTripsOnLaunch else { return }
        hasSyncedTripsOnLaunch = true

        let launchTrips = trips
        guard !launchTrips.isEmpty else { return }

        Task {
            for trip in launchTrips {
                await syncTrip(trip, shouldFetchMapInfo: false)
            }
        }
    }

    private func syncTripAfterAdd(_ trip: Trip) {
        let result = LiveActivityManager.shared.startOrSchedule(for: trip)
        #if DEBUG
        print("[ContentView] Live Activity auto-start: \(result?.message ?? "scheduled one hour before departure")")
        #endif
        Task {
            await syncTrip(trip, shouldFetchMapInfo: true)
        }
    }

    private func refreshRunningLiveActivities() {
        for trip in trips where LiveActivityManager.shared.isActivityRunning(for: trip.id) {
            LiveActivityManager.shared.updateActivity(
                for: trip,
                delayInfo: LiveDelayStore.shared.info(for: trip.id)
            )
        }
    }

    private func refreshLiveActivity(for tripID: String) {
        guard let trip = trips.first(where: { $0.id == tripID }) else { return }
        guard LiveActivityManager.shared.isActivityRunning(for: tripID) else { return }
        LiveActivityManager.shared.updateActivity(
            for: trip,
            delayInfo: LiveDelayStore.shared.info(for: tripID)
        )
    }

    private func syncTrip(_ trip: Trip, shouldFetchMapInfo: Bool) async {
        guard let result = await TripSyncService.shared.sync(
            trip: trip,
            shouldFetchMapInfo: shouldFetchMapInfo
        ) else { return }

        if let index = trips.firstIndex(where: { $0.id == trip.id }) {
            trips[index] = result.trip
        }
        if selectedTrip?.id == trip.id {
            selectedTrip = result.trip
        }
    }

}

extension ContentView {
    @MapContentBuilder
    private func dashboardMapContent() -> some MapContent {
        ForEach(trips) { trip in
            if let line = userSegmentCoordinates(for: trip) {
                MapPolyline(coordinates: line)
                    .stroke(.blue.opacity(0.6), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                if let start = line.first {
                    Annotation("", coordinate: start) {
                        MapDot(color: .blue)
                    }
                }
                if let end = line.last {
                    Annotation("", coordinate: end) {
                        MapDot(color: .orange)
                    }
                }
            }
        }
    }

    private func detailMapState(for trip: Trip) -> DetailMapState {
#if DEBUG
        let startedAt = Date()
        defer {
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed >= 0.05 {
                print("[ContentView] slow map state for \(trip.id): \(Int(elapsed * 1000))ms")
            }
        }
#endif
        let orderedStops = polylineStops(for: trip)
        let stoppingStops = stationStops(for: trip)
        let deviceCoordinate = locationProvider.lastLocation.flatMap { location in
            abs(location.timestamp.timeIntervalSinceNow) <= 15 * 60 ? location.coordinate : nil
        }
        let trackingResult = liveTrainCoordinate(
            for: trip,
            orderedStops: orderedStops,
            stoppingStops: stoppingStops,
            referenceDate: liveTrainClock,
            deviceCoordinate: deviceCoordinate
        )

        return DetailMapState(
            trip: trip,
            orderedStops: orderedStops,
            stoppingStops: stoppingStops,
            trackingResult: trackingResult
        )
    }

    private func updateTrackingState(using result: LiveTrainCoordinateResult?) {
        if TripLocationDetectionPreferences.isEnabled,
           let trip = selectedTrip,
           !isAddTripMode,
           !isSelectedTripPast {
            let phase = locationPhaseDetector.phase(for: trip)
            if phase == .arrived || phase == .exitedEarly {
                locationProvider.disableTracking()
            } else {
                locationProvider.enableTracking()
                if TripLocationDetectionPreferences.continuousSpeedCapsuleEnabled {
                    locationProvider.enableSpeedTracking()
                } else {
                    locationProvider.stopSpeedTracking()
                }
            }
            return
        }
        if result?.showsUserLocation == true {
            locationProvider.enableTracking()
            if TripLocationDetectionPreferences.continuousSpeedCapsuleEnabled {
                locationProvider.enableSpeedTracking()
            } else {
                locationProvider.stopSpeedTracking()
            }
        } else {
            locationProvider.disableTracking()
        }
    }

    private func shouldDisplayUserLocationDot(for state: DetailMapState?) -> Bool {
        return state?.trackingResult?.showsUserLocation ?? false
    }

    private func shouldDisplayLiveTrainMarker(
        for state: DetailMapState?,
        userLocationVisible: Bool
    ) -> Bool {
        guard !userLocationVisible else { return false }
        guard state?.trackingResult?.showsLiveTrainMarker == true else { return false }
        return state?.trackingResult?.coordinate != nil
    }

    @MapContentBuilder
    private func detailMapContent(state: DetailMapState, showLiveTrainMarker: Bool) -> some MapContent {
        let trip = state.trip
        let orderedStops = state.orderedStops
        let stoppingStops = state.stoppingStops
        let scrapedRouteSegments = routePolylineSegments(for: trip)
        if !scrapedRouteSegments.isEmpty {
            ForEach(Array(scrapedRouteSegments.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment)
                    .stroke(
                        .gray.opacity(0.5),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 6])
                    )
            }

            if let segment = preciseUserSegmentCoordinates(for: trip) {
                MapPolyline(coordinates: segment)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
        } else {
            let coordinates = orderedStops.map { $0.coordinate }
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(
                        .gray.opacity(0.5),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 6])
                    )

                if let segment = segmentCoordinates(for: trip, orderedStops: orderedStops) {
                    MapPolyline(coordinates: segment)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
            }
        }

        if !stoppingStops.isEmpty {
            if let range = highlightedRange(for: trip, orderedStops: stoppingStops) {
                ForEach(Array(stoppingStops.enumerated()), id: \.offset) { index, stop in
                    Annotation("", coordinate: stop.coordinate) {
                        MapDot(color: range.contains(index) ? .blue : .gray)
                    }
                }
            } else {
                ForEach(stoppingStops) { stop in
                    Annotation("", coordinate: stop.coordinate) {
                        MapDot(color: .gray)
                    }
                }
            }
        }

        if showLiveTrainMarker, let liveCoordinate = state.trackingResult?.coordinate {
            Annotation("", coordinate: liveCoordinate) {
                LiveTrainMarkerView(isGPSBased: state.trackingResult?.mode == .gps)
            }
        }
    }

    private func straightLineCoordinates(for trip: Trip) -> [CLLocationCoordinate2D]? {
        guard
            let start = coordinate(for: trip.originStopId, sequence: trip.originSequence, in: trip),
            let end = coordinate(for: trip.destinationStopId, sequence: trip.destinationSequence, in: trip)
        else { return nil }
        return [start, end]
    }

    private func routeCoordinates(for trip: Trip) -> [CLLocationCoordinate2D]? {
        if let coordinates = flattenedRoutePolylineCoordinates(for: trip), coordinates.count > 1 {
            return coordinates
        }
        let stops = polylineStops(for: trip)
        if stops.count > 1 {
            return stops.map { $0.coordinate }
        }
        return straightLineCoordinates(for: trip)
    }

    private func userSegmentCoordinates(for trip: Trip) -> [CLLocationCoordinate2D]? {
        if let preciseSegment = preciseUserSegmentCoordinates(for: trip) {
            return preciseSegment
        }
        let stops = polylineStops(for: trip)
        let segmentStops = userSegmentStops(for: trip, stops: stops)
        if segmentStops.count > 1 {
            return segmentStops.map { $0.coordinate }
        }
        return straightLineCoordinates(for: trip)
    }

    private func userSegmentStops(for trip: Trip, stops: [StoredStop]) -> [StoredStop] {
        guard !stops.isEmpty else { return [] }
        guard let range = highlightedRange(for: trip, orderedStops: stops) else { return stops }
        let lower = max(range.lowerBound, 0)
        let upper = min(range.upperBound, stops.count - 1)
        guard lower <= upper else { return stops }
        return Array(stops[lower...upper])
    }

    private func polylineStops(for trip: Trip) -> [StoredStop] {
        let identifier = trip.gtfsTripId ?? trip.id
        let gtfsStops = GTFSDataSource.shared.polylineStops(for: identifier)
        let baseStops: [StoredStop]
        if !gtfsStops.isEmpty {
            baseStops = gtfsStops.map(StoredStop.init(gtfsStop:))
        } else if let stored = trip.stops {
            baseStops = stored
        } else {
            baseStops = []
        }
        return baseStops.sorted { $0.sequence < $1.sequence }
    }

    private func stationStops(for trip: Trip) -> [StoredStop] {
        let identifier = trip.gtfsTripId ?? trip.id
        let gtfsStops = GTFSDataSource.shared.stops(for: identifier)
        let baseStops: [StoredStop]
        if !gtfsStops.isEmpty {
            baseStops = gtfsStops.map(StoredStop.init(gtfsStop:))
        } else if let stored = trip.stops {
            baseStops = stored
        } else {
            baseStops = []
        }
        return baseStops.sorted { $0.sequence < $1.sequence }
    }

    private func liveTrainCoordinate(
        for trip: Trip,
        orderedStops: [StoredStop],
        stoppingStops: [StoredStop],
        referenceDate: Date,
        deviceCoordinate: CLLocationCoordinate2D?
    ) -> LiveTrainCoordinateResult? {
        let segments = GTFSDataSource.shared.segments(for: trip.gtfsTripId ?? trip.id)
        guard !segments.isEmpty else { return nil }

        var stopLookup: [String: StoredStop] = [:]
        for stop in orderedStops {
            stopLookup[stop.id] = stop
        }
        for stop in stoppingStops {
            stopLookup[stop.id] = stop
        }
        guard !stopLookup.isEmpty else { return nil }

        let timeline = cachedSegmentEntries(
            segments: segments,
            trip: trip,
            stopLookup: stopLookup
        )

        let resolvedTiming = TripTimingResolver().resolve(
            trip: trip,
            delayInfo: LiveDelayStore.shared.info(for: trip.id),
            referenceDate: referenceDate,
            includeProgressDetails: false
        )

        guard !timeline.isEmpty else { return nil }

        let routeCoordinates = flattenedRoutePolylineCoordinates(for: trip)
        let trackingRouteCoordinates = routeCoordinates ?? timelineRouteCoordinates(from: timeline)
        guard let fallback = interpolatedCoordinate(
            entries: timeline,
            referenceDate: referenceDate,
            routeCoordinates: routeCoordinates
        ) else {
            return nil
        }

        let resolvedStops = resolvedStopIdentifiers(
            for: trip,
            orderedStops: orderedStops,
            stoppingStops: stoppingStops
        )

        guard let originStopId = resolvedStops.origin,
              let destinationStopId = resolvedStops.destination,
              let serviceDeparture = timeline.first?.startDate,
              let serviceArrival = timeline.last?.endDate else {
            return LiveTrainCoordinateResult(
                coordinate: fallback,
                mode: .interpolation,
                showsUserLocation: false,
                showsLiveTrainMarker: false
            )
        }

        guard let boardingDate = boardingDate(for: originStopId, in: timeline),
              let destinationArrival = resolvedTiming.adjustedArrival
                ?? arrivalDate(for: destinationStopId, in: timeline) else {
            if TripLocationDetectionPreferences.isEnabled, let deviceCoordinate {
                return LiveTrainCoordinateResult(
                    coordinate: deviceCoordinate,
                    mode: .device,
                    showsUserLocation: true,
                    showsLiveTrainMarker: false
                )
            }
            let showsTrainMarker = referenceDate >= serviceDeparture && referenceDate <= serviceArrival
            let gpsCoordinate = showsTrainMarker ? gpsAnchoredLiveTrainCoordinate(
                for: trip,
                entries: timeline,
                referenceDate: referenceDate,
                routeCoordinates: trackingRouteCoordinates
            ) : nil
            let trainCoordinate = gpsCoordinate ?? fallback
            return LiveTrainCoordinateResult(
                coordinate: trainCoordinate,
                mode: gpsCoordinate == nil ? .interpolation : .gps,
                showsUserLocation: false,
                showsLiveTrainMarker: showsTrainMarker
            )
        }

        if TripLocationDetectionPreferences.isEnabled {
            switch locationPhaseDetector.phase(for: trip) {
            case .boarded:
                return LiveTrainCoordinateResult(
                    coordinate: deviceCoordinate ?? fallback,
                    mode: .device,
                    showsUserLocation: deviceCoordinate != nil,
                    showsLiveTrainMarker: deviceCoordinate == nil
                )
            case .arrived:
                return LiveTrainCoordinateResult(
                    coordinate: coordinate(for: destinationStopId, sequence: trip.destinationSequence, in: trip) ?? fallback,
                    mode: .interpolation,
                    showsUserLocation: false,
                    showsLiveTrainMarker: false
                )
            case .exitedEarly:
                return LiveTrainCoordinateResult(
                    coordinate: deviceCoordinate ?? fallback,
                    mode: .device,
                    showsUserLocation: deviceCoordinate != nil,
                    showsLiveTrainMarker: false
                )
            case .unknown, .atOrigin:
                // Until the train reaches the selected origin, show its
                // predicted position. This keeps the train visible while the
                // rider is still travelling to the station and avoids using
                // the rider's phone location as a proxy for the train.
                if referenceDate < boardingDate {
                    let gpsCoordinate = referenceDate >= serviceDeparture ? gpsAnchoredLiveTrainCoordinate(
                        for: trip,
                        entries: timeline,
                        referenceDate: referenceDate,
                        routeCoordinates: trackingRouteCoordinates
                    ) : nil
                    return LiveTrainCoordinateResult(
                        coordinate: gpsCoordinate ?? fallback,
                        mode: gpsCoordinate == nil ? .interpolation : .gps,
                        showsUserLocation: false,
                        showsLiveTrainMarker: true
                    )
                }

                // Once the train has reached the user's origin, the phone
                // position is the rider signal and remains distinct from the
                // train marker.
                if let deviceCoordinate {
                    return LiveTrainCoordinateResult(
                        coordinate: deviceCoordinate,
                        mode: .device,
                        showsUserLocation: true,
                        showsLiveTrainMarker: false
                    )
                }

                // If there is no device fix yet, retain the train marker as
                // secondary context until the next location callback.

                let gpsCoordinate = referenceDate >= serviceDeparture ? gpsAnchoredLiveTrainCoordinate(
                    for: trip,
                    entries: timeline,
                    referenceDate: referenceDate,
                    routeCoordinates: trackingRouteCoordinates
                ) : nil
                return LiveTrainCoordinateResult(
                    coordinate: gpsCoordinate ?? fallback,
                    mode: gpsCoordinate == nil ? .interpolation : .gps,
                    showsUserLocation: false,
                    showsLiveTrainMarker: referenceDate <= serviceArrival
                )
            }
        }

        if referenceDate >= boardingDate && referenceDate < destinationArrival {
            let coordinate = deviceCoordinate ?? fallback
            return LiveTrainCoordinateResult(
                coordinate: coordinate,
                mode: .device,
                showsUserLocation: true,
                showsLiveTrainMarker: false
            )
        }

        if referenceDate <= serviceArrival {
            let gpsCoordinate = referenceDate >= serviceDeparture ? gpsAnchoredLiveTrainCoordinate(
                for: trip,
                entries: timeline,
                referenceDate: referenceDate,
                routeCoordinates: trackingRouteCoordinates
            ) : nil
            let trainCoordinate = gpsCoordinate ?? fallback
            return LiveTrainCoordinateResult(
                coordinate: trainCoordinate,
                mode: gpsCoordinate == nil ? .interpolation : .gps,
                showsUserLocation: false,
                showsLiveTrainMarker: true
            )
        }

        return LiveTrainCoordinateResult(
            coordinate: fallback,
            mode: .interpolation,
            showsUserLocation: false,
            showsLiveTrainMarker: false
        )
    }

    private func updateLocationPhaseDetection(for trip: Trip?) {
        guard TripLocationDetectionPreferences.isEnabled,
              !isAddTripMode,
              let trip,
              let location = locationProvider.lastLocation else { return }

        let route = flattenedRoutePolylineCoordinates(for: trip)
            ?? polylineStops(for: trip).map(\.coordinate)
        let trustedTrainCoordinate = LiveDelayStore.shared.info(for: trip.id)?.liveCoordinate.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        locationPhaseDetector.update(
            trip: trip,
            location: location,
            route: route,
            trustedTrainCoordinate: trustedTrainCoordinate
        )
        let infoFer = LiveDelayStore.shared.info(for: trip.id)
        let timing = TripTimingResolver().resolve(trip: trip, delayInfo: infoFer, referenceDate: location.timestamp)
        TripDelayFusionStore.shared.update(
            trip: trip,
            progress: locationPhaseDetector.progress(for: trip),
            timing: timing,
            infoFer: infoFer,
            now: location.timestamp
        )
    }

    private func evaluateMissedTrainSuggestion(for trip: Trip?) {
        updateMissedTrainDiagnostic(for: trip)
        guard TripLocationDetectionPreferences.isEnabled,
              TripLocationDetectionPreferences.missedTrainSuggestionsEnabled,
              !isAddTripMode,
              let trip,
              trips.contains(where: { $0.id == trip.id }),
              missedTrainPrompt == nil,
              !dismissedMissedTrainPromptIDs.contains(trip.id),
              !MissedTrainPromptStore.isDismissed(tripID: trip.id, travelDate: trip.travelDate),
              let location = locationProvider.lastLocation,
              abs(location.timestamp.timeIntervalSinceNow) <= 15 * 60 else { return }

        let phase = locationPhaseDetector.phase(for: trip)
        guard phase == .unknown || phase == .atOrigin else { return }

        let timing = TripTimingResolver().resolve(
            trip: trip,
            delayInfo: LiveDelayStore.shared.info(for: trip.id),
            referenceDate: liveTrainClock
        )
        guard let departure = timing.adjustedDeparture,
              liveTrainClock >= departure else { return }

        // Schedule time alone is not proof that the rider left. If the rider
        // is still at the origin, wait for evidence that the train actually
        // left. Phone GPS is authoritative for the rider; trusted InfoFer GPS
        // is secondary evidence about the train itself and must never be used
        // as a proxy for the rider's location.
        if isFreshlyAtOrigin(trip), !hasConfirmedTrainDeparture(for: trip) {
#if DEBUG
            missedTrainDiagnosticText = "Missed train: train still appears to be at origin"
#endif
            return
        }

        // A rider away from the origin can be prompted as soon as the
        // adjusted departure has passed, even if InfoFer has not refreshed.
        missedTrainPrompt = MissedTrainPrompt(
            id: trip.id,
            trainTitle: trip.title,
            originStopID: trip.originStopId ?? "",
            destinationStopID: trip.destinationStopId,
            trainID: trip.gtfsTripId
        )
        missedTrainOriginal = trip
    }

    private func isFreshlyAtOrigin(_ trip: Trip) -> Bool {
        guard let location = locationProvider.lastLocation,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 150,
              abs(location.timestamp.timeIntervalSinceNow) <= 15 * 60,
              let origin = coordinate(for: trip.originStopId, sequence: trip.originSequence, in: trip) else {
            return false
        }
        let radius = max(250, location.horizontalAccuracy * 1.5)
        return location.distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude)) <= radius
    }

    private func hasConfirmedTrainDeparture(for trip: Trip) -> Bool {
        if locationPhaseDetector.phase(for: trip) == .boarded {
            return true
        }

        guard let info = LiveDelayStore.shared.info(for: trip.id),
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

    private func findMissedTrainAlternatives(for prompt: MissedTrainPrompt) {
        dismissedMissedTrainPromptIDs.insert(prompt.id)
        if let trip = trips.first(where: { $0.id == prompt.id }) {
            MissedTrainPromptStore.dismiss(tripID: trip.id, travelDate: trip.travelDate)
        }
        missedTrainPrompt = nil
        // Let the confirmation alert finish dismissing before presenting the
        // alternatives sheet. Presenting both in the same update cycle causes
        // SwiftUI to discard the second presentation request.
        missedTrainAlternatives = dataSource.departures(
            from: prompt.originStopID,
            after: liveTrainClock,
            excluding: prompt.trainID,
            destinationStationID: prompt.destinationStopID
        )
        selectedDetent = .large
        DispatchQueue.main.async {
            isShowingMissedTrainAlternatives = true
        }
    }

    private func dismissMissedTrainPrompt(_ prompt: MissedTrainPrompt) {
        dismissedMissedTrainPromptIDs.insert(prompt.id)
        if let trip = trips.first(where: { $0.id == prompt.id }) {
            MissedTrainPromptStore.dismiss(tripID: trip.id, travelDate: trip.travelDate)
        }
        missedTrainPrompt = nil
    }

    private func updateMissedTrainDiagnostic(for trip: Trip?) {
#if DEBUG
        guard TripLocationDetectionPreferences.isEnabled,
              TripLocationDetectionPreferences.missedTrainSuggestionsEnabled else {
            missedTrainDiagnosticText = "Missed train: enable detection + suggestions"
            return
        }
        guard let trip else {
            missedTrainDiagnosticText = "Missed train: no selected trip"
            return
        }
        if dismissedMissedTrainPromptIDs.contains(trip.id)
            || MissedTrainPromptStore.isDismissed(tripID: trip.id, travelDate: trip.travelDate) {
            missedTrainDiagnosticText = "Missed train: prompt dismissed for this trip"
            return
        }
        guard let location = locationProvider.lastLocation else {
            missedTrainDiagnosticText = "Missed train: waiting for GPS fix"
            return
        }
        let age = abs(location.timestamp.timeIntervalSinceNow)
        guard age <= 15 * 60 else {
            missedTrainDiagnosticText = "Missed train: GPS is \(Int(age / 60))m old"
            return
        }
        let phase = locationPhaseDetector.phase(for: trip)
        guard phase == .unknown || phase == .atOrigin else {
            missedTrainDiagnosticText = "Missed train: phase is \(phase.rawValue)"
            return
        }
        let timing = TripTimingResolver().resolve(
            trip: trip,
            delayInfo: LiveDelayStore.shared.info(for: trip.id),
            referenceDate: liveTrainClock
        )
        guard let departure = timing.adjustedDeparture else {
            missedTrainDiagnosticText = "Missed train: departure unavailable"
            return
        }
        guard liveTrainClock >= departure else {
            missedTrainDiagnosticText = "Missed train: waiting for departure"
            return
        }
        if isFreshlyAtOrigin(trip), !hasConfirmedTrainDeparture(for: trip) {
            missedTrainDiagnosticText = "Missed train: train still appears to be at origin"
            return
        }
        missedTrainDiagnosticText = "Missed train: ready to prompt"
#endif
    }

    private func simulateMissedTrain(for trip: Trip) {
#if DEBUG
        dismissedMissedTrainPromptIDs.remove(trip.id)
        MissedTrainPromptStore.clear(tripID: trip.id, travelDate: trip.travelDate)
        missedTrainOriginal = trip
        missedTrainPrompt = MissedTrainPrompt(
            id: trip.id,
            trainTitle: trip.title,
            originStopID: trip.originStopId ?? "",
            destinationStopID: trip.destinationStopId,
            trainID: trip.gtfsTripId
        )
#endif
    }

    private var dataSource: GTFSDataSource { GTFSDataSource.shared }

    private func selectAlternative(_ alternative: Trip) {
        guard let original = missedTrainOriginal,
              let originID = original.originStopId else { return }

        let stops = alternative.stops ?? []
        let destination = original.destinationStopId.flatMap { id in stops.first(where: { $0.id == id }) }
            ?? stops.last
        let origin = stops.first(where: { $0.id == originID })
        let route = "\(origin?.name ?? original.originName ?? "Origin") → \(destination?.name ?? original.destinationName ?? "Destination")"
        let selected = Trip(
            id: UUID().uuidString,
            title: alternative.title,
            subtitle: route,
            agencyId: alternative.agencyId,
            detailRoute: route,
            gtfsTripId: alternative.gtfsTripId,
            travelDate: alternative.travelDate,
            originStopId: origin?.id ?? originID,
            originName: origin?.name ?? original.originName,
            destinationStopId: destination?.id,
            destinationName: destination?.name ?? original.destinationName,
            stops: stops,
            originSequence: origin?.sequence,
            destinationSequence: destination?.sequence,
            trainType: alternative.trainType,
            trainLength: alternative.trainLength,
            trainTonnage: alternative.trainTonnage
        )
        trips.append(selected)
        selectedTrip = selected
        isShowingMissedTrainAlternatives = false
        missedTrainPrompt = nil
        missedTrainOriginal = nil
        LiveActivityManager.shared.startOrSchedule(for: selected)
    }

    private func boardingDate(for stopId: String, in timeline: [MapSegmentEntry]) -> Date? {
        if let arrival = timeline.first(where: { $0.endStopId == stopId })?.endDate {
            return arrival
        }
        return timeline.first(where: { $0.startStopId == stopId })?.startDate
    }

    private func arrivalDate(for stopId: String, in timeline: [MapSegmentEntry]) -> Date? {
        if let arrival = timeline.first(where: { $0.endStopId == stopId })?.endDate {
            return arrival
        }
        return timeline.first(where: { $0.startStopId == stopId })?.startDate
    }

    private func resolvedStopIdentifiers(
        for trip: Trip,
        orderedStops: [StoredStop],
        stoppingStops: [StoredStop]
    ) -> (origin: String?, destination: String?) {
        let referenceStops = stoppingStops.isEmpty ? orderedStops : stoppingStops
        guard !referenceStops.isEmpty else {
            return (trip.originStopId, trip.destinationStopId)
        }

        let originIndex = indexForStop(
            id: trip.originStopId,
            sequence: trip.originSequence,
            in: referenceStops,
            fallback: 0
        )
        let destinationIndex = indexForStop(
            id: trip.destinationStopId,
            sequence: trip.destinationSequence,
            in: referenceStops,
            fallback: max(referenceStops.count - 1, 0)
        )

        let originStopId = referenceStops.indices.contains(originIndex)
            ? referenceStops[originIndex].id
            : trip.originStopId
        let destinationStopId = referenceStops.indices.contains(destinationIndex)
            ? referenceStops[destinationIndex].id
            : trip.destinationStopId

        return (originStopId, destinationStopId)
    }

    private func buildSegmentEntries(
        segments: [GTFSSegment],
        trip: Trip,
        stopLookup: [String: StoredStop]
    ) -> [MapSegmentEntry] {
        let resolvedTiming = TripTimingResolver().resolve(
            trip: trip,
            delayInfo: LiveDelayStore.shared.info(for: trip.id),
            referenceDate: Date(),
            includeProgressDetails: false
        )
        let referenceDate = resolvedTiming.scheduledDeparture ?? trip.travelDate ?? Date()
        let baseDate = Calendar.current.startOfDay(for: referenceDate)

        let delaySeconds = TimeInterval((resolvedTiming.headerDelayMinutes ?? 0) * 60)

        var lastReference: Date?
        var entries: [MapSegmentEntry] = []

        for segment in segments {
            guard
                let startStop = stopLookup[segment.startId],
                let endStop = stopLookup[segment.endId]
            else {
                continue
            }

            guard
                let departureSeconds = segment.departureSeconds ?? segment.arrivalSeconds,
                let arrivalSeconds = segment.arrivalSeconds ?? segment.departureSeconds
            else {
                continue
            }

            var startDate = baseDate.addingTimeInterval(TimeInterval(departureSeconds))
            var endDate = baseDate.addingTimeInterval(TimeInterval(arrivalSeconds))

            if let normalized = ScheduleDateUtils.normalizedArrival(endDate, relativeTo: startDate) {
                endDate = normalized
            }

            if let previous = lastReference {
                startDate = ScheduleDateUtils.shiftedForward(startDate, after: previous)
            }

            endDate = ScheduleDateUtils.shiftedForward(endDate, after: startDate)
            lastReference = endDate

            startDate = startDate.addingTimeInterval(delaySeconds)
            endDate = endDate.addingTimeInterval(delaySeconds)

            entries.append(
                MapSegmentEntry(
                    startStopId: segment.startId,
                    endStopId: segment.endId,
                    startCoordinate: startStop.coordinate,
                    endCoordinate: endStop.coordinate,
                    startDate: startDate,
                    endDate: endDate
                )
            )
        }

        return entries
    }

    private func cachedSegmentEntries(
        segments: [GTFSSegment],
        trip: Trip,
        stopLookup: [String: StoredStop]
    ) -> [MapSegmentEntry] {
        let delayInfo = LiveDelayStore.shared.info(for: trip.id)
        let key = MapSegmentTimelineCache.key(for: trip, delayInfo: delayInfo)
        if let cached = MapSegmentTimelineCache.entries[key] {
            return cached
        }

        let entries = buildSegmentEntries(
            segments: segments,
            trip: trip,
            stopLookup: stopLookup
        )
        MapSegmentTimelineCache.store(entries, for: key)
        return entries
    }

    private func interpolatedCoordinate(
        entries: [MapSegmentEntry],
        referenceDate: Date,
        routeCoordinates: [CLLocationCoordinate2D]? = nil
    ) -> CLLocationCoordinate2D? {
        guard let first = entries.first, let last = entries.last else { return nil }

        if referenceDate <= first.startDate {
            return routeCoordinates?.first ?? first.startCoordinate
        }

        if referenceDate >= last.endDate {
            return routeCoordinates?.last ?? last.endCoordinate
        }

        if let routeCoordinates, routeCoordinates.count > 1 {
            let totalDuration = last.endDate.timeIntervalSince(first.startDate)
            if totalDuration > 0 {
                let elapsed = referenceDate.timeIntervalSince(first.startDate)
                let progress = max(0, min(elapsed / totalDuration, 1))
                return coordinateAlongPolyline(routeCoordinates, progress: progress)
            }
        }

        for entry in entries {
            if referenceDate <= entry.startDate {
                return entry.startCoordinate
            }

            if referenceDate >= entry.startDate && referenceDate <= entry.endDate {
                let duration = entry.endDate.timeIntervalSince(entry.startDate)
                guard duration > 0 else { return entry.endCoordinate }
                let elapsed = referenceDate.timeIntervalSince(entry.startDate)
                let progress = max(0, min(elapsed / duration, 1))
                return interpolateCoordinate(
                    from: entry.startCoordinate,
                    to: entry.endCoordinate,
                    progress: progress
                )
            }
        }

        return last.endCoordinate
    }

    private func gpsAnchoredLiveTrainCoordinate(
        for trip: Trip,
        entries: [MapSegmentEntry],
        referenceDate: Date,
        routeCoordinates: [CLLocationCoordinate2D]?
    ) -> CLLocationCoordinate2D? {
        guard let liveCoordinate = LiveDelayStore.shared.info(for: trip.id)?.liveCoordinate else { return nil }
        let gpsCoordinate = CLLocationCoordinate2D(
            latitude: liveCoordinate.latitude,
            longitude: liveCoordinate.longitude
        )
        guard
            let fetchedAt = liveCoordinate.fetchedAt,
            let first = entries.first,
            let last = entries.last,
            let routeCoordinates,
            routeCoordinates.count > 1
        else {
            return gpsCoordinate
        }

        let totalDuration = last.endDate.timeIntervalSince(first.startDate)
        guard totalDuration > 0 else { return gpsCoordinate }

        let anchoredProgress = progressAlongPolyline(routeCoordinates, nearestTo: gpsCoordinate)
        let elapsedProgress = referenceDate.timeIntervalSince(fetchedAt) / totalDuration
        return coordinateAlongPolyline(
            routeCoordinates,
            progress: anchoredProgress + elapsedProgress
        ) ?? gpsCoordinate
    }

    private func timelineRouteCoordinates(from entries: [MapSegmentEntry]) -> [CLLocationCoordinate2D]? {
        guard let first = entries.first else { return nil }
        var coordinates = [first.startCoordinate]
        coordinates.append(contentsOf: entries.map(\.endCoordinate))
        return coordinates.count > 1 ? coordinates : nil
    }

    private func progressAlongPolyline(
        _ coordinates: [CLLocationCoordinate2D],
        nearestTo coordinate: CLLocationCoordinate2D
    ) -> Double {
        guard coordinates.count > 1 else { return 0 }

        let origin = coordinates[0]
        let targetPoint = mapPoint(coordinate, relativeTo: origin)
        var totalLength: CLLocationDistance = 0
        var nearestDistance = Double.greatestFiniteMagnitude
        var nearestLengthAlongRoute: CLLocationDistance = 0

        for index in 1..<coordinates.count {
            let start = mapPoint(coordinates[index - 1], relativeTo: origin)
            let end = mapPoint(coordinates[index], relativeTo: origin)
            let segment = CGPoint(x: end.x - start.x, y: end.y - start.y)
            let segmentLength = hypot(segment.x, segment.y)
            guard segmentLength > 0 else { continue }

            let target = CGPoint(x: targetPoint.x - start.x, y: targetPoint.y - start.y)
            let projection = max(0, min((target.x * segment.x + target.y * segment.y) / (segmentLength * segmentLength), 1))
            let projectedPoint = CGPoint(
                x: start.x + segment.x * projection,
                y: start.y + segment.y * projection
            )
            let distanceToProjection = hypot(targetPoint.x - projectedPoint.x, targetPoint.y - projectedPoint.y)
            if distanceToProjection < nearestDistance {
                nearestDistance = distanceToProjection
                nearestLengthAlongRoute = totalLength + segmentLength * projection
            }

            totalLength += segmentLength
        }

        guard totalLength > 0 else { return 0 }
        return max(0, min(nearestLengthAlongRoute / totalLength, 1))
    }

    private func mapPoint(
        _ coordinate: CLLocationCoordinate2D,
        relativeTo origin: CLLocationCoordinate2D
    ) -> CGPoint {
        let originPoint = MKMapPoint(origin)
        let point = MKMapPoint(coordinate)
        return CGPoint(x: point.x - originPoint.x, y: point.y - originPoint.y)
    }

    private func coordinateAlongPolyline(
        _ coordinates: [CLLocationCoordinate2D],
        progress: Double
    ) -> CLLocationCoordinate2D? {
        guard let first = coordinates.first, let last = coordinates.last else { return nil }
        guard coordinates.count > 1 else { return first }

        let clamped = max(0, min(progress, 1))
        if clamped <= 0 { return first }
        if clamped >= 1 { return last }

        var segmentLengths: [CLLocationDistance] = []
        var totalLength: CLLocationDistance = 0

        for index in 1..<coordinates.count {
            let length = distanceBetween(coordinates[index - 1], coordinates[index])
            segmentLengths.append(length)
            totalLength += length
        }

        guard totalLength > 0 else { return first }

        let targetLength = totalLength * clamped
        var coveredLength: CLLocationDistance = 0

        for index in segmentLengths.indices {
            let segmentLength = segmentLengths[index]
            let nextCoveredLength = coveredLength + segmentLength
            if targetLength <= nextCoveredLength {
                let segmentProgress = segmentLength > 0 ? (targetLength - coveredLength) / segmentLength : 0
                return interpolateCoordinate(
                    from: coordinates[index],
                    to: coordinates[index + 1],
                    progress: segmentProgress
                )
            }
            coveredLength = nextCoveredLength
        }

        return last
    }

    private func distanceBetween(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }

    private func interpolateCoordinate(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        progress: Double
    ) -> CLLocationCoordinate2D {
        let clamped = max(0, min(progress, 1))
        let latitude = start.latitude + (end.latitude - start.latitude) * clamped
        let longitude = start.longitude + (end.longitude - start.longitude) * clamped
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }


    private func coordinate(for stopId: String?, sequence: Int?, in trip: Trip) -> CLLocationCoordinate2D? {
        if let id = stopId, let stop = trip.stops?.first(where: { $0.id == id }) {
            return stop.coordinate
        }
        if let seq = sequence, let stop = trip.stops?.first(where: { $0.sequence == seq }) {
            return stop.coordinate
        }
        return trip.stops?.sorted(by: { $0.sequence < $1.sequence }).first?.coordinate
    }

    private func routePolylineSegments(for trip: Trip) -> [[CLLocationCoordinate2D]] {
        trip.routePolylines?
            .map(\.coordinates)
            .filter { $0.count > 1 } ?? []
    }

    private func flattenedRoutePolylineCoordinates(for trip: Trip) -> [CLLocationCoordinate2D]? {
        let segments = routePolylineSegments(for: trip)
        guard !segments.isEmpty else { return nil }
        return segments.flatMap { $0 }
    }

    private func preciseUserSegmentCoordinates(for trip: Trip) -> [CLLocationCoordinate2D]? {
        guard let coordinates = flattenedRoutePolylineCoordinates(for: trip), coordinates.count > 1 else { return nil }
        guard
            let origin = coordinate(for: trip.originStopId, sequence: trip.originSequence, in: trip),
            let destination = coordinate(for: trip.destinationStopId, sequence: trip.destinationSequence, in: trip)
        else { return nil }

        let originIndex = nearestCoordinateIndex(to: origin, in: coordinates)
        let destinationIndex = nearestCoordinateIndex(to: destination, in: coordinates)
        let lower = min(originIndex, destinationIndex)
        let upper = max(originIndex, destinationIndex)
        guard lower < upper else { return nil }
        return Array(coordinates[lower...upper])
    }

    private func nearestCoordinateIndex(
        to target: CLLocationCoordinate2D,
        in coordinates: [CLLocationCoordinate2D]
    ) -> Int {
        coordinates.indices.min { lhs, rhs in
            coordinateDistanceSquared(coordinates[lhs], target) < coordinateDistanceSquared(coordinates[rhs], target)
        } ?? 0
    }

    private func coordinateDistanceSquared(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Double {
        let latitudeDelta = lhs.latitude - rhs.latitude
        let longitudeDelta = lhs.longitude - rhs.longitude
        return latitudeDelta * latitudeDelta + longitudeDelta * longitudeDelta
    }

    private func segmentCoordinates(for trip: Trip, orderedStops: [StoredStop]) -> [CLLocationCoordinate2D]? {
        guard let range = highlightedRange(for: trip, orderedStops: orderedStops) else { return nil }
        let segmentSlice = orderedStops[range]
        guard segmentSlice.count > 1 else { return nil }
        return segmentSlice.map { $0.coordinate }
    }

    private func highlightedRange(for trip: Trip, orderedStops: [StoredStop]) -> ClosedRange<Int>? {
        guard !orderedStops.isEmpty else { return nil }
        let originIndex = indexForStop(id: trip.originStopId, sequence: trip.originSequence, in: orderedStops, fallback: 0)
        let destinationIndex = indexForStop(id: trip.destinationStopId, sequence: trip.destinationSequence, in: orderedStops, fallback: orderedStops.count - 1)
        guard originIndex < orderedStops.count, destinationIndex < orderedStops.count else { return nil }
        let lower = min(originIndex, destinationIndex)
        let upper = max(originIndex, destinationIndex)
        return lower...upper
    }

    private func indexForStop(id: String?, sequence: Int?, in stops: [StoredStop], fallback: Int) -> Int {
        if let id, let index = stops.firstIndex(where: { $0.id == id }) {
            return index
        }
        if let sequence, let index = stops.firstIndex(where: { $0.sequence == sequence }) {
            return index
        }
        return min(max(fallback, 0), max(stops.count - 1, 0))
    }

    private func updateCameraForCurrentState(animated: Bool = true) {
        if let trip = selectedTrip, !isAddTripMode {
            focusOnTrip(trip, animated: animated)
        } else {
            focusOnAllTrips(animated: animated)
        }
    }

    private func focusOnTrip(_ trip: Trip, animated: Bool = true) {
        guard let coordinates = coordinatesForTrip(trip), let region = region(containing: coordinates) else {
            return
        }
        setMapRegion(region, animated: animated)
    }

    private func focusOnAllTrips(animated: Bool = true) {
        let coordinates = trips.compactMap { userSegmentCoordinates(for: $0) }.flatMap { $0 }
        if let region = region(containing: coordinates) {
            setMapRegion(region, animated: animated)
        } else {
            setMapRegion(Self.defaultRegion, animated: animated)
        }
    }

    private func coordinatesForTrip(_ trip: Trip) -> [CLLocationCoordinate2D]? {
        return routeCoordinates(for: trip)
    }

    private func region(containing coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }
        guard coordinates.count > 1 else {
            let coordinate = coordinates[0]
            let span = MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
            return MKCoordinateRegion(center: coordinate, span: span)
        }

        let lats = coordinates.map { $0.latitude }
        let lons = coordinates.map { $0.longitude }

        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else {
            return nil
        }

        var latDelta = max(maxLat - minLat, 0.2)
        var lonDelta = max(maxLon - minLon, 0.2)
        latDelta *= 1.4
        lonDelta *= 1.4

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    private func setMapRegion(_ region: MKCoordinateRegion, animated: Bool) {
        let adjustedRegion = offsetRegion(for: region)
        let position = MapCameraPosition.region(adjustedRegion)
        if animated {
            withAnimation {
                mapPosition = position
            }
        } else {
            mapPosition = position
        }
    }

    private func offsetRegion(for region: MKCoordinateRegion) -> MKCoordinateRegion {
        var adjusted = region
        adjusted.center.latitude += region.span.latitudeDelta * -0.6
        //-.5 for frac and
        return adjusted
    }
}

private struct MapDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .shadow(color: color.opacity(0.4), radius: 4, x: 0, y: 2)
    }
}

enum TrainType: String, Codable, CaseIterable, Identifiable, Hashable {
    case intercity = "IC"
    case interregio = "IR"
    case interregioNight = "IR-N"
    case regioExpress = "R-E"
    case regio = "R"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .intercity:
            return "InterCity"
        case .interregio:
            return "InterRegio"
        case .interregioNight:
            return "InterRegio Night"
        case .regioExpress:
            return "Regio Express"
        case .regio:
            return "Regio"
        }
    }

    var displayLabel: String {
        "\(rawValue) • \(name)"
    }

    init?(categoryCode: String) {
        let normalized = categoryCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        switch normalized {
        case Self.intercity.rawValue:
            self = .intercity
        case Self.interregio.rawValue:
            self = .interregio
        case "IRN", "IR-N", "IR N":
            self = .interregioNight
        case "RE", Self.regioExpress.rawValue:
            self = .regioExpress
        case "R", "REGIO":
            self = .regio
        default:
            return nil
        }
    }

    static func inferred(fromTitle title: String) -> TrainType? {
        guard let prefix = title.split(separator: " ").first else { return nil }
        return TrainType(categoryCode: String(prefix))
    }
}

enum TrainPowerType: String, Codable, CaseIterable, Identifiable, Hashable {
    case electric
    case diesel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .electric:
            return "Electric"
        case .diesel:
            return "Diesel"
        }
    }

    var systemImage: String {
        switch self {
        case .electric:
            return "bolt.fill"
        case .diesel:
            return "fuelpump.fill"
        }
    }
}

struct Trip: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let agencyId: String?
    let detailDate: String?
    let detailRoute: String?
    let gtfsTripId: String?
    let travelDate: Date?
    let originStopId: String?
    let originName: String?
    let destinationStopId: String?
    let destinationName: String?
    let originPlatform: String?
    let destinationPlatform: String?
    let delayMinutes: Int?
    let detailDistance: String?
    let stops: [StoredStop]?
    let originSequence: Int?
    let destinationSequence: Int?
    let seatCar: String?
    let seatNumbers: [String]?
    let ticketQRCode: String?
    let trainType: TrainType?
    let trainLength: String?
    let trainTonnage: String?
    let trainIdentifier: String?
    let trainPower: TrainPowerType?
    let routePolylines: [StoredRoutePolyline]?
    let infoFerGPSUnavailable: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case agencyId
        case detailDate
        case detailRoute
        case gtfsTripId
        case travelDate
        case originStopId
        case originName
        case destinationStopId
        case destinationName
        case originPlatform
        case destinationPlatform
        case delayMinutes
        case detailDistance
        case stops
        case originSequence
        case destinationSequence
        case seatCar
        case seatNumbers
        case ticketQRCode
        case trainType
        case trainLength
        case trainTonnage
        case trainIdentifier
        case trainPower
        case routePolylines
        case infoFerGPSUnavailable
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String,
        agencyId: String? = nil,
        detailDate: String? = nil,
        detailRoute: String? = nil,
        gtfsTripId: String? = nil,
        travelDate: Date? = nil,
        originStopId: String? = nil,
        originName: String? = nil,
        destinationStopId: String? = nil,
        destinationName: String? = nil,
        originPlatform: String? = nil,
        destinationPlatform: String? = nil,
        delayMinutes: Int? = nil,
        detailDistance: String? = nil,
        stops: [StoredStop]? = nil,
        originSequence: Int? = nil,
        destinationSequence: Int? = nil,
        seatCar: String? = nil,
        seatNumbers: [String]? = nil,
        trainType: TrainType? = nil,
        trainLength: String? = nil,
        trainTonnage: String? = nil,
        trainIdentifier: String? = nil,
        trainPower: TrainPowerType? = nil,
        routePolylines: [StoredRoutePolyline]? = nil,
        infoFerGPSUnavailable: Bool = false
    ) {
        self.init(
            id: id,
            title: title,
            subtitle: subtitle,
            agencyId: agencyId,
            detailDate: detailDate,
            detailRoute: detailRoute,
            gtfsTripId: gtfsTripId,
            travelDate: travelDate,
            originStopId: originStopId,
            originName: originName,
            destinationStopId: destinationStopId,
            destinationName: destinationName,
            originPlatform: originPlatform,
            destinationPlatform: destinationPlatform,
            delayMinutes: delayMinutes,
            detailDistance: detailDistance,
            stops: stops,
            originSequence: originSequence,
            destinationSequence: destinationSequence,
            seatCar: seatCar,
            seatNumbers: seatNumbers,
            ticketQRCode: nil,
            trainType: trainType,
            trainLength: trainLength,
            trainTonnage: trainTonnage,
            trainIdentifier: trainIdentifier,
            trainPower: trainPower,
            routePolylines: routePolylines,
            infoFerGPSUnavailable: infoFerGPSUnavailable
        )
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String,
        agencyId: String? = nil,
        detailDate: String? = nil,
        detailRoute: String? = nil,
        gtfsTripId: String? = nil,
        travelDate: Date? = nil,
        originStopId: String? = nil,
        originName: String? = nil,
        destinationStopId: String? = nil,
        destinationName: String? = nil,
        originPlatform: String? = nil,
        destinationPlatform: String? = nil,
        delayMinutes: Int? = nil,
        detailDistance: String? = nil,
        stops: [StoredStop]? = nil,
        originSequence: Int? = nil,
        destinationSequence: Int? = nil,
        seatCar: String? = nil,
        seatNumbers: [String]? = nil,
        ticketQRCode: String?,
        trainType: TrainType? = nil,
        trainLength: String? = nil,
        trainTonnage: String? = nil,
        trainIdentifier: String? = nil,
        trainPower: TrainPowerType? = nil,
        routePolylines: [StoredRoutePolyline]? = nil,
        infoFerGPSUnavailable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.agencyId = agencyId
        self.detailDate = detailDate
        self.detailRoute = detailRoute
        self.gtfsTripId = gtfsTripId
        self.travelDate = travelDate
        self.originStopId = originStopId
        self.originName = originName
        self.destinationStopId = destinationStopId
        self.destinationName = destinationName
        self.originPlatform = originPlatform
        self.destinationPlatform = destinationPlatform
        self.delayMinutes = delayMinutes
        self.detailDistance = detailDistance
        self.stops = stops
        self.originSequence = originSequence
        self.destinationSequence = destinationSequence
        self.seatCar = seatCar
        self.seatNumbers = seatNumbers
        self.ticketQRCode = ticketQRCode
        self.trainType = trainType
        self.trainLength = trainLength
        self.trainTonnage = trainTonnage
        self.trainIdentifier = trainIdentifier
        self.trainPower = trainPower
        self.routePolylines = routePolylines
        self.infoFerGPSUnavailable = infoFerGPSUnavailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        agencyId = try container.decodeIfPresent(String.self, forKey: .agencyId)
        detailDate = try container.decodeIfPresent(String.self, forKey: .detailDate)
        detailRoute = try container.decodeIfPresent(String.self, forKey: .detailRoute)
        gtfsTripId = try container.decodeIfPresent(String.self, forKey: .gtfsTripId)
        travelDate = try container.decodeIfPresent(Date.self, forKey: .travelDate)
        originStopId = try container.decodeIfPresent(String.self, forKey: .originStopId)
        originName = try container.decodeIfPresent(String.self, forKey: .originName)
        destinationStopId = try container.decodeIfPresent(String.self, forKey: .destinationStopId)
        destinationName = try container.decodeIfPresent(String.self, forKey: .destinationName)
        originPlatform = try container.decodeIfPresent(String.self, forKey: .originPlatform)
        destinationPlatform = try container.decodeIfPresent(String.self, forKey: .destinationPlatform)
        delayMinutes = try container.decodeIfPresent(Int.self, forKey: .delayMinutes)
        detailDistance = try container.decodeIfPresent(String.self, forKey: .detailDistance)
        stops = try container.decodeIfPresent([StoredStop].self, forKey: .stops)
        originSequence = try container.decodeIfPresent(Int.self, forKey: .originSequence)
        destinationSequence = try container.decodeIfPresent(Int.self, forKey: .destinationSequence)
        seatCar = try container.decodeIfPresent(String.self, forKey: .seatCar)
        seatNumbers = try container.decodeIfPresent([String].self, forKey: .seatNumbers)
        ticketQRCode = try container.decodeIfPresent(String.self, forKey: .ticketQRCode)
        trainType = try container.decodeIfPresent(TrainType.self, forKey: .trainType)
        trainLength = try container.decodeIfPresent(String.self, forKey: .trainLength)
        trainTonnage = try container.decodeIfPresent(String.self, forKey: .trainTonnage)
        trainIdentifier = try container.decodeIfPresent(String.self, forKey: .trainIdentifier)
        trainPower = try container.decodeIfPresent(TrainPowerType.self, forKey: .trainPower)
        routePolylines = try container.decodeIfPresent([StoredRoutePolyline].self, forKey: .routePolylines)
        infoFerGPSUnavailable = try container.decodeIfPresent(Bool.self, forKey: .infoFerGPSUnavailable) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(agencyId, forKey: .agencyId)
        try container.encodeIfPresent(detailDate, forKey: .detailDate)
        try container.encodeIfPresent(detailRoute, forKey: .detailRoute)
        try container.encodeIfPresent(gtfsTripId, forKey: .gtfsTripId)
        try container.encodeIfPresent(travelDate, forKey: .travelDate)
        try container.encodeIfPresent(originStopId, forKey: .originStopId)
        try container.encodeIfPresent(originName, forKey: .originName)
        try container.encodeIfPresent(destinationStopId, forKey: .destinationStopId)
        try container.encodeIfPresent(destinationName, forKey: .destinationName)
        try container.encodeIfPresent(originPlatform, forKey: .originPlatform)
        try container.encodeIfPresent(destinationPlatform, forKey: .destinationPlatform)
        try container.encodeIfPresent(delayMinutes, forKey: .delayMinutes)
        try container.encodeIfPresent(detailDistance, forKey: .detailDistance)
        try container.encodeIfPresent(stops, forKey: .stops)
        try container.encodeIfPresent(originSequence, forKey: .originSequence)
        try container.encodeIfPresent(destinationSequence, forKey: .destinationSequence)
        try container.encodeIfPresent(seatCar, forKey: .seatCar)
        try container.encodeIfPresent(seatNumbers, forKey: .seatNumbers)
        try container.encodeIfPresent(ticketQRCode, forKey: .ticketQRCode)
        try container.encodeIfPresent(trainType, forKey: .trainType)
        try container.encodeIfPresent(trainLength, forKey: .trainLength)
        try container.encodeIfPresent(trainTonnage, forKey: .trainTonnage)
        try container.encodeIfPresent(trainIdentifier, forKey: .trainIdentifier)
        try container.encodeIfPresent(trainPower, forKey: .trainPower)
        try container.encodeIfPresent(routePolylines, forKey: .routePolylines)
        try container.encode(infoFerGPSUnavailable, forKey: .infoFerGPSUnavailable)
    }
}

struct StoredStop: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let sequence: Int
    var arrivalDelayMinutes: Int?
    var departureDelayMinutes: Int?
    var platform: String?

    init(
        id: String,
        name: String,
        latitude: Double,
        longitude: Double,
        sequence: Int,
        arrivalDelayMinutes: Int? = nil,
        departureDelayMinutes: Int? = nil,
        platform: String? = nil
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.sequence = sequence
        self.arrivalDelayMinutes = arrivalDelayMinutes
        self.departureDelayMinutes = departureDelayMinutes
        self.platform = platform
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Returns only the stops between the user's boarding and destination stations.
/// Older saved trips may have a stored distance for the whole train route, so
/// callers should prefer this slice whenever stored stops are available.
func stopsForRide(
    _ stops: [StoredStop]?,
    originStopID: String?,
    destinationStopID: String?,
    originSequence: Int?,
    destinationSequence: Int?
) -> [StoredStop] {
    let orderedStops = (stops ?? []).sorted { $0.sequence < $1.sequence }
    guard !orderedStops.isEmpty else { return [] }

    let originIndex = orderedStops.firstIndex {
        if let originStopID { return $0.id == originStopID }
        if let originSequence { return $0.sequence == originSequence }
        return false
    }
    let destinationIndex = orderedStops.firstIndex {
        if let destinationStopID { return $0.id == destinationStopID }
        if let destinationSequence { return $0.sequence == destinationSequence }
        return false
    }

    guard let originIndex, let destinationIndex, originIndex <= destinationIndex else {
        return orderedStops
    }
    return Array(orderedStops[originIndex...destinationIndex])
}

struct StoredRoutePoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct StoredRoutePolyline: Identifiable, Codable, Equatable {
    let id: UUID
    let points: [StoredRoutePoint]

    init(id: UUID = UUID(), points: [StoredRoutePoint]) {
        self.id = id
        self.points = points
    }

    var coordinates: [CLLocationCoordinate2D] {
        points.map(\.coordinate)
    }
}

extension StoredStop {
    init(gtfsStop: GTFSStop) {
        self.init(
            id: gtfsStop.id,
            name: gtfsStop.name,
            latitude: gtfsStop.latitude,
            longitude: gtfsStop.longitude,
            sequence: gtfsStop.sequence
        )
    }
}

extension Trip {
    var resolvedTrainNumber: String? {
        let titleComponents = title.split(separator: " ")
        if let last = titleComponents.last {
            let digits = last.filter(\.isNumber)
            if !digits.isEmpty {
                return String(digits)
            }
        }

        if let code = gtfsTripId, !code.isEmpty {
            return code
        }

        return nil
    }

    var webcamBoardSideHint: CFRWebcamBoardSide {
        let destinationText = [destinationName, subtitle, detailRoute]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if destinationText.contains("bucharest") || destinationText.contains("bucuresti") {
            return .arrivals
        }

        return .departures
    }

    func updatingPlatform(_ platform: String?, for side: CFRWebcamBoardSide) -> Trip {
        switch side {
        case .arrivals:
            return Trip(
                id: id,
                title: title,
                subtitle: subtitle,
                agencyId: agencyId,
                detailDate: detailDate,
                detailRoute: detailRoute,
                gtfsTripId: gtfsTripId,
                travelDate: travelDate,
                originStopId: originStopId,
                originName: originName,
                destinationStopId: destinationStopId,
                destinationName: destinationName,
                originPlatform: originPlatform,
                destinationPlatform: sanitizedPlatform(platform),
                delayMinutes: delayMinutes,
                detailDistance: detailDistance,
                stops: stops,
                originSequence: originSequence,
                destinationSequence: destinationSequence,
                seatCar: seatCar,
                seatNumbers: seatNumbers,
                ticketQRCode: ticketQRCode,
                trainType: trainType,
                trainLength: trainLength,
                trainTonnage: trainTonnage,
                trainIdentifier: trainIdentifier,
                trainPower: trainPower,
                routePolylines: routePolylines,
                infoFerGPSUnavailable: infoFerGPSUnavailable
            )
        case .departures:
            return Trip(
                id: id,
                title: title,
                subtitle: subtitle,
                agencyId: agencyId,
                detailDate: detailDate,
                detailRoute: detailRoute,
                gtfsTripId: gtfsTripId,
                travelDate: travelDate,
                originStopId: originStopId,
                originName: originName,
                destinationStopId: destinationStopId,
                destinationName: destinationName,
                originPlatform: sanitizedPlatform(platform),
                destinationPlatform: destinationPlatform,
                delayMinutes: delayMinutes,
                detailDistance: detailDistance,
                stops: stops,
                originSequence: originSequence,
                destinationSequence: destinationSequence,
                seatCar: seatCar,
                seatNumbers: seatNumbers,
                ticketQRCode: ticketQRCode,
                trainType: trainType,
                trainLength: trainLength,
                trainTonnage: trainTonnage,
                trainIdentifier: trainIdentifier,
                trainPower: trainPower,
                routePolylines: routePolylines,
                infoFerGPSUnavailable: infoFerGPSUnavailable
            )
        }
    }

    private func sanitizedPlatform(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, trimmed != "-" else { return nil }
        return trimmed
    }
}

extension Trip {
    func updatingSeatInfo(
        car: String?,
        seats: [String]?,
        trainType: TrainType?,
        trainLength: String?,
        trainTonnage: String?,
        trainIdentifier: String?,
        trainPower: TrainPowerType?
    ) -> Trip {
        Trip(
            id: id,
            title: title,
            subtitle: subtitle,
            agencyId: agencyId,
            detailDate: detailDate,
            detailRoute: detailRoute,
            gtfsTripId: gtfsTripId,
            travelDate: travelDate,
            originStopId: originStopId,
            originName: originName,
            destinationStopId: destinationStopId,
            destinationName: destinationName,
            originPlatform: originPlatform,
            destinationPlatform: destinationPlatform,
            delayMinutes: delayMinutes,
            detailDistance: detailDistance,
            stops: stops,
            originSequence: originSequence,
            destinationSequence: destinationSequence,
            seatCar: car,
            seatNumbers: seats,
            ticketQRCode: ticketQRCode,
            trainType: trainType,
            trainLength: trainLength,
            trainTonnage: trainTonnage,
            trainIdentifier: trainIdentifier,
            trainPower: trainPower,
            routePolylines: routePolylines,
            infoFerGPSUnavailable: infoFerGPSUnavailable
        )
    }

    func updatingTicketQRCode(_ code: String?) -> Trip {
        Trip(
            id: id,
            title: title,
            subtitle: subtitle,
            agencyId: agencyId,
            detailDate: detailDate,
            detailRoute: detailRoute,
            gtfsTripId: gtfsTripId,
            travelDate: travelDate,
            originStopId: originStopId,
            originName: originName,
            destinationStopId: destinationStopId,
            destinationName: destinationName,
            originPlatform: originPlatform,
            destinationPlatform: destinationPlatform,
            delayMinutes: delayMinutes,
            detailDistance: detailDistance,
            stops: stops,
            originSequence: originSequence,
            destinationSequence: destinationSequence,
            seatCar: seatCar,
            seatNumbers: seatNumbers,
            ticketQRCode: code,
            trainType: trainType,
            trainLength: trainLength,
            trainTonnage: trainTonnage,
            trainIdentifier: trainIdentifier,
            trainPower: trainPower,
            routePolylines: routePolylines,
            infoFerGPSUnavailable: infoFerGPSUnavailable
        )
    }

    func updatingStops(_ updatedStops: [StoredStop]) -> Trip {
        Trip(
            id: id,
            title: title,
            subtitle: subtitle,
            agencyId: agencyId,
            detailDate: detailDate,
            detailRoute: detailRoute,
            gtfsTripId: gtfsTripId,
            travelDate: travelDate,
            originStopId: originStopId,
            originName: originName,
            destinationStopId: destinationStopId,
            destinationName: destinationName,
            originPlatform: originPlatform,
            destinationPlatform: destinationPlatform,
            delayMinutes: delayMinutes,
            detailDistance: detailDistance,
            stops: updatedStops,
            originSequence: originSequence,
            destinationSequence: destinationSequence,
            seatCar: seatCar,
            seatNumbers: seatNumbers,
            ticketQRCode: ticketQRCode,
            trainType: trainType,
            trainLength: trainLength,
            trainTonnage: trainTonnage,
            trainIdentifier: trainIdentifier,
            trainPower: trainPower,
            routePolylines: routePolylines,
            infoFerGPSUnavailable: infoFerGPSUnavailable
        )
    }

    func updatingStopDelay(
        for stopId: String,
        arrivalDelayMinutes: Int?,
        departureDelayMinutes: Int?
    ) -> Trip {
        guard var stops else { return self }
        guard let index = stops.firstIndex(where: { $0.id == stopId }) else { return self }

        var updatedStop = stops[index]
        updatedStop.arrivalDelayMinutes = arrivalDelayMinutes
        updatedStop.departureDelayMinutes = departureDelayMinutes
        stops[index] = updatedStop

        return Trip(
            id: id,
            title: title,
            subtitle: subtitle,
            agencyId: agencyId,
            detailDate: detailDate,
            detailRoute: detailRoute,
            gtfsTripId: gtfsTripId,
            travelDate: travelDate,
            originStopId: originStopId,
            originName: originName,
            destinationStopId: destinationStopId,
            destinationName: destinationName,
            originPlatform: originPlatform,
            destinationPlatform: destinationPlatform,
            delayMinutes: delayMinutes,
            detailDistance: detailDistance,
            stops: stops,
            originSequence: originSequence,
            destinationSequence: destinationSequence,
            seatCar: seatCar,
            seatNumbers: seatNumbers,
            ticketQRCode: ticketQRCode,
            trainType: trainType,
            trainLength: trainLength,
            trainTonnage: trainTonnage,
            trainIdentifier: trainIdentifier,
            trainPower: trainPower,
            routePolylines: routePolylines,
            infoFerGPSUnavailable: infoFerGPSUnavailable
        )
    }

    func updatingRoutePolylines(_ polylines: [StoredRoutePolyline]) -> Trip {
        Trip(
            id: id,
            title: title,
            subtitle: subtitle,
            agencyId: agencyId,
            detailDate: detailDate,
            detailRoute: detailRoute,
            gtfsTripId: gtfsTripId,
            travelDate: travelDate,
            originStopId: originStopId,
            originName: originName,
            destinationStopId: destinationStopId,
            destinationName: destinationName,
            originPlatform: originPlatform,
            destinationPlatform: destinationPlatform,
            delayMinutes: delayMinutes,
            detailDistance: detailDistance,
            stops: stops,
            originSequence: originSequence,
            destinationSequence: destinationSequence,
            seatCar: seatCar,
            seatNumbers: seatNumbers,
            ticketQRCode: ticketQRCode,
            trainType: trainType,
            trainLength: trainLength,
            trainTonnage: trainTonnage,
            trainIdentifier: trainIdentifier,
            trainPower: trainPower,
            routePolylines: polylines,
            infoFerGPSUnavailable: infoFerGPSUnavailable
        )
    }

    func updatingInfoFerGPSUnavailable(_ unavailable: Bool) -> Trip {
        Trip(
            id: id,
            title: title,
            subtitle: subtitle,
            agencyId: agencyId,
            detailDate: detailDate,
            detailRoute: detailRoute,
            gtfsTripId: gtfsTripId,
            travelDate: travelDate,
            originStopId: originStopId,
            originName: originName,
            destinationStopId: destinationStopId,
            destinationName: destinationName,
            originPlatform: originPlatform,
            destinationPlatform: destinationPlatform,
            delayMinutes: delayMinutes,
            detailDistance: detailDistance,
            stops: stops,
            originSequence: originSequence,
            destinationSequence: destinationSequence,
            seatCar: seatCar,
            seatNumbers: seatNumbers,
            ticketQRCode: ticketQRCode,
            trainType: trainType,
            trainLength: trainLength,
            trainTonnage: trainTonnage,
            trainIdentifier: trainIdentifier,
            trainPower: trainPower,
            routePolylines: routePolylines,
            infoFerGPSUnavailable: unavailable
        )
    }
}

#Preview {
    ContentView()
}

private struct DetailMapState {
    let trip: Trip
    let orderedStops: [StoredStop]
    let stoppingStops: [StoredStop]
    let trackingResult: LiveTrainCoordinateResult?
}

private struct MapSegmentEntry {
    let startStopId: String
    let endStopId: String
    let startCoordinate: CLLocationCoordinate2D
    let endCoordinate: CLLocationCoordinate2D
    let startDate: Date
    let endDate: Date
}

/// Dated segment entries are stable between delay changes, so map clock ticks
/// can interpolate against the existing timeline without rebuilding it.
private enum MapSegmentTimelineCache {
    private static let maximumEntries = 64
    private(set) static var entries: [String: [MapSegmentEntry]] = [:]

    static func key(for trip: Trip, delayInfo: DelayInfo?) -> String {
        let travelDate = trip.travelDate?.timeIntervalSince1970 ?? 0
        let headerDelay = delayInfo?.delayMinutes ?? trip.delayMinutes ?? 0
        return "\(trip.id)|\(travelDate)|\(headerDelay)"
    }

    static func store(_ entries: [MapSegmentEntry], for key: String) {
        self.entries[key] = entries
        if self.entries.count > maximumEntries {
            self.entries.removeValue(forKey: self.entries.keys.first!)
        }
    }
}

private enum LiveTrainTrackingMode {
    case interpolation
    case device
    case gps
}

private struct LiveTrainCoordinateResult {
    let coordinate: CLLocationCoordinate2D?
    let mode: LiveTrainTrackingMode
    let showsUserLocation: Bool
    let showsLiveTrainMarker: Bool
}

private struct MapToolbarButtons: View {
    let isGlobeStyle: Bool
    let showLocationButton: Bool
    let onToggleStyle: () -> Void
    let onCenterOnUser: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggleStyle) {
                Image(systemName: isGlobeStyle ? "map.fill" : "globe.europe.africa.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(.label))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isGlobeStyle ? "Switch to default map" : "Switch to globe map")

            if showLocationButton {
                Button(action: onCenterOnUser) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(.label))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Center on my location")
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: 44)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: showLocationButton)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isGlobeStyle)
    }
}

private struct LiveTrainMarkerView: View {
    let isGPSBased: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill((isGPSBased ? Color.green : Color.blue).opacity(0.9))
            Circle()
                .stroke(Color.white, lineWidth: 2)
            Image(systemName: "tram.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
    }
}

struct MissedTrainAlternativesView: View {
    let alternatives: [Trip]
    let onSelect: (Trip) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if alternatives.isEmpty {
                    ContentUnavailableView(
                        "No alternatives found",
                        systemImage: "tram.fill",
                        description: Text("Try searching again later for departures from the same station.")
                    )
                } else {
                    List(alternatives) { trip in
                        Button {
                            onSelect(trip)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(trip.title)
                                        .font(.headline)
                                    Spacer()
                                    if let departure = trip.travelDate {
                                        Text(departure, style: .time)
                                            .font(.headline.monospacedDigit())
                                    }
                                }
                                Text(trip.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Bundled schedule • live delay unavailable")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Other departures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
