import SwiftUI
import MapKit
import Combine
import BackgroundTasks

final class BlitzAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { @MainActor in
            RevenueCatManager.shared.configure()
        }
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
                .environment(\.calendar, GTFSDataSource.calendar)
                .environment(\.timeZone, GTFSDataSource.calendar.timeZone)
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
        center: CLLocationCoordinate2D(latitude: 46.8182, longitude: 8.2275),
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
    @State private var isImportingSharedJourneys = false
    @State private var sharedImportError: String?
    @State private var liveTrainClock = Date()
    @State private var mockSpeedKPH: Double = 118
    @State private var trackingRefreshRevision = 0
    @State private var mapRouteGeometries: [String: GTFSRouteGeometry] = [:]
    @State private var missedTrainPrompt: MissedTrainPrompt?
    @State private var dismissedMissedTrainPromptIDs: Set<String> = []
    @State private var missedTrainOriginal: Trip?
    @State private var missedTrainAlternatives: [Trip] = []
    @State private var isShowingMissedTrainAlternatives = false
    @State private var missedTrainDiagnosticText: String?
    @State private var usesGlobeMapStyle = false
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
                // Keep recentering available while the train marker is shown
                // too. The user's location can be useful before the first
                // fresh fix switches the map from train to rider tracking.
                showLocationButton: true,
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
            if activeMapTrip != nil {
                mapSpeedCapsule()
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
                onTripAdded: prepareTripAfterAdd,
                onMissedTrainFindAlternatives: findMissedTrainAlternatives,
                onMissedTrainKeepTracking: dismissMissedTrainPrompt,
                onSelectMissedTrainAlternative: selectAlternative
            )
            .alert("Couldn’t add shared journey", isPresented: Binding(
                get: { sharedImportError != nil },
                set: { if !$0 { sharedImportError = nil } }
            )) {
                Button("Retry") { Task { await importSharedJourneys() } }
                Button("Later", role: .cancel) { sharedImportError = nil }
            } message: {
                Text(sharedImportError ?? "The journey remains saved for retry.")
            }
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
            if let trip = newValue, trips.contains(where: { $0.id == trip.id }) {
                refreshLiveDelays(for: [trip])
            }
        }
    }

    private var lifecycleHandlersView: some View {
        stateHandlersView
        .onChange(of: locationProvider.lastLocation?.timestamp) { _, _ in
            updateLocationPhaseDetection(for: selectedTrip)
            evaluateMissedTrainSuggestion(for: selectedTrip)
            refreshRunningLiveActivities()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tripLocationDetectionPreferenceChanged)) { _ in
            updateLocationPhaseDetection(for: selectedTrip)
            updateTrackingState(using: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .revenueCatEntitlementChanged)) { notification in
            guard (notification.object as? Bool) == true else {
                refreshRunningLiveActivities()
                return
            }
            refreshLiveDelays(for: trips)
            LiveActivityManager.shared.scheduleNextAutomaticStart(for: trips)
            LiveActivityManager.shared.startScheduledActivities(for: trips)
            refreshRunningLiveActivities()
        }
        .onAppear {
            locationPhaseDetector.removeExpired()
            MissedTrainPromptStore.prune()
            updateCameraForCurrentState(animated: false)
            updateLocationPhaseDetection(for: selectedTrip)
            evaluateMissedTrainSuggestion(for: selectedTrip)
            // A SwiftUI task may not rerun when the app returns from suspension
            // with the same selected trip, so explicitly restart reconciliation.
            updateTrackingState(using: currentDetailState?.trackingResult)
            refreshLiveDelays(for: trips)
        }
    }

    private var timerHandlersView: some View {
        lifecycleHandlersView
        .onReceive(liveTrainTimer) { value in
            // Keep the speed capsule lively in previews and on devices without
            // a usable GPS fix. Small steps make the simulated speed feel like
            // a real train rather than a rapidly changing random number.
            mockSpeedKPH = min(
                165,
                max(70, mockSpeedKPH + Double.random(in: -3.5...3.5))
            )
            guard selectedTrip != nil else { return }
            withAnimation(.linear(duration: 1)) {
                liveTrainClock = value
            }
            evaluateMissedTrainSuggestion(for: selectedTrip)
        }
        .onReceive(liveActivityRefreshTimer) { _ in
            LiveActivityManager.shared.startScheduledActivities(for: trips)
            refreshRunningLiveActivities()
            refreshLiveDelays(for: trips)
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
            Task { await importSharedJourneys() }
            updateLocationPhaseDetection(for: selectedTrip)
            evaluateMissedTrainSuggestion(for: selectedTrip)
            // Reconcile the persisted last fix and resume future location fixes
            // even when the selected trip itself did not change.
            updateTrackingState(using: currentDetailState?.trackingResult)
            LiveActivityManager.shared.startScheduledActivities()
            LiveActivityManager.shared.scheduleNextAutomaticStart()
            refreshRunningLiveActivities()
            refreshLiveDelays(for: trips)
        }
    }

    private var eventHandlersView: some View {
        timerHandlersView
        .task { await importSharedJourneys() }
        .task(id: mapRouteIdentifiers) {
            let identifiers = mapRouteIdentifiers
            let loaded = await Task.detached(priority: .userInitiated) {
                var result: [String: GTFSRouteGeometry] = [:]
                for identifier in identifiers {
                    result[identifier] = GTFSDataSource.shared.routeGeometry(for: identifier)
                }
                return result
            }.value
            guard !Task.isCancelled, identifiers == mapRouteIdentifiers else { return }
            mapRouteGeometries = loaded
            updateCameraForCurrentState(animated: false)
        }
        .onChange(of: trips) { _, newValue in
            TripStorage.shared.saveTrips(newValue)
            LiveActivityManager.shared.scheduleNextAutomaticStart(for: newValue)
            refreshRunningLiveActivities()
            refreshLiveDelays(for: newValue)
            updateCameraForCurrentState()
        }
        .onChange(of: trips) { oldValue, newValue in
            let activeIDs = Set(newValue.map(\.id))
            let removedIDs = Set(oldValue.map(\.id)).subtracting(activeIDs)
            locationPhaseDetector.remove(tripIDs: removedIDs)
            TripDelayFusionStore.shared.remove(tripIDs: removedIDs)
            oldValue
                .filter { oldTrip in
                    !activeIDs.contains(oldTrip.id) &&
                    (oldTrip.sharedJourneyID == nil || !newValue.contains(where: {
                        $0.sharedJourneyID == oldTrip.sharedJourneyID
                    }))
                }
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
        true
    }

    private func mapSpeedCapsule() -> some View {
        Button(action: {}) {
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
        .accessibilityLabel(showsSpeedCapsuleDetails ? "Current speed" : "Show current speed")
        .accessibilityValue(showsSpeedCapsuleDetails ? (hasCurrentSpeedFix ? "\(mapSpeedDisplayValue) kilometres per hour" : "Acquiring GPS speed") : "Hidden to save battery")
    }

    private var mapSpeedDisplayValue: String {
        String(format: "%.0f", mockSpeedKPH)
    }

    private var hasCurrentSpeedFix: Bool {
        true
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

    private var mapRouteIdentifiers: [String] {
        Set((trips + [selectedTrip].compactMap { $0 }).compactMap(\.gtfsTripId)).sorted()
    }

    private func routeGeometry(for trip: Trip) -> GTFSRouteGeometry? {
        trip.gtfsTripId.flatMap { mapRouteGeometries[$0] }
    }

    private func prepareTripAfterAdd(_ trip: Trip) {
        let result = LiveActivityManager.shared.startOrSchedule(for: trip)
        #if DEBUG
        print("[ContentView] Live Activity auto-start: \(result?.message ?? "scheduled one hour before departure")")
        #endif
        // Capture immutable timetable segments once when the trip is added;
        // subsequent launches can render it without reopening the GTFS route.
        if let identifier = trip.gtfsTripId {
            Task.detached(priority: .utility) {
                _ = GTFSDataSource.shared.segments(for: identifier)
            }
        }
    }

    @MainActor
    private func importSharedJourneys() async {
        guard !isImportingSharedJourneys else { return }
        isImportingSharedJourneys = true
        defer { isImportingSharedJourneys = false }
        do {
            let inbox = try SharedJourneyInbox()
            for file in try inbox.pending() {
                let journey = try inbox.read(file)
                let imported = try await Task.detached(priority: .userInitiated) {
                    try GTFSDataSource.shared.importTrips(from: journey)
                }.value
                var active = trips
                var past = pastTrips
                var addedActive: [Trip] = []
                var addedTrips: [Trip] = []
                for (trip, leg) in zip(imported, journey.legs) {
                    let matchesSavedTrip: (Trip) -> Bool = {
                        $0.id == trip.id || ($0.title == trip.title && $0.travelDate == trip.travelDate &&
                            $0.originStopId == trip.originStopId && $0.destinationStopId == trip.destinationStopId)
                    }
                    if let index = active.firstIndex(where: matchesSavedTrip) {
                        if active[index].sharedJourneyID == nil {
                            active[index].sharedJourneyID = trip.sharedJourneyID
                        }
                        continue
                    }
                    if let index = past.firstIndex(where: matchesSavedTrip) {
                        if past[index].sharedJourneyID == nil {
                            past[index].sharedJourneyID = trip.sharedJourneyID
                        }
                        continue
                    }
                    addedTrips.append(trip)
                    if leg.arrival.addingTimeInterval(20 * 60) < Date() {
                        past.append(trip)
                    } else {
                        active.append(trip)
                        addedActive.append(trip)
                    }
                }
                try TripStorage.shared.persistSharedImport(active: active, past: past)
                addedTrips.forEach(TripDebugLog.added)
                trips = active
                pastTrips = past
                try inbox.acknowledge(file)
                if !addedActive.isEmpty {
                    isAddTripMode = false
                    selectedTrip = addedActive.first
                    addedActive.forEach(prepareTripAfterAdd)
                }
            }
        } catch {
            sharedImportError = error.localizedDescription
        }
    }

    private func refreshRunningLiveActivities() {
        var refreshed = Set<String>()
        for trip in trips where LiveActivityManager.shared.isActivityRunning(for: trip.id) {
            guard refreshed.insert(trip.sharedJourneyID ?? trip.id).inserted else { continue }
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

    private func refreshLiveDelays(for trips: [Trip]) {
        guard RevenueCatManager.cachedIsPro else { return }
        Task { await SBBLiveTripService.shared.refresh(trips: trips) }
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
        // Start collecting a fresh fix during the active trip window even when
        // automatic station detection is disabled. Previously the map showed
        // the interpolated train marker and then disabled Core Location, so it
        // could never obtain the rider location needed to switch markers.
        if let trip = selectedTrip,
           !isAddTripMode,
           !pastTrips.contains(where: { $0.id == trip.id }) {
            let timing = TripTimingResolver().resolve(
                trip: trip,
                delayInfo: LiveDelayStore.shared.info(for: trip.id),
                referenceDate: Date(),
                includeProgressDetails: false
            )
            if let departure = timing.adjustedDeparture,
               let arrival = timing.adjustedArrival,
               Date() >= departure.addingTimeInterval(-10 * 60),
               Date() <= arrival.addingTimeInterval(15 * 60) {
                locationProvider.enableTracking()
                if TripLocationDetectionPreferences.continuousSpeedCapsuleEnabled {
                    locationProvider.enableSpeedTracking()
                } else {
                    locationProvider.stopSpeedTracking()
                }
                return
            }
        }

        if TripLocationDetectionPreferences.isEnabled,
           let trip = selectedTrip,
           !isAddTripMode,
           !pastTrips.contains(where: { $0.id == trip.id }) {
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
        let coordinates = routeCoordinates(for: trip) ?? []
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
        if let geometry = routeGeometry(for: trip), geometry.stops.count > 1 {
            return geometry.coordinates()
        }
        let stops = polylineStops(for: trip)
        if stops.count > 1 {
            return stops.map { $0.coordinate }
        }
        return straightLineCoordinates(for: trip)
    }

    private func userSegmentCoordinates(for trip: Trip) -> [CLLocationCoordinate2D]? {
        let stops = polylineStops(for: trip)
        return segmentCoordinates(for: trip, orderedStops: stops) ?? straightLineCoordinates(for: trip)
    }

    private func polylineStops(for trip: Trip) -> [StoredStop] {
        if let stored = trip.stops, !stored.isEmpty {
            return stored.sorted { $0.sequence < $1.sequence }
        }
        let identifier = trip.gtfsTripId ?? trip.id
        let gtfsStops = GTFSDataSource.shared.polylineStops(for: identifier)
        return gtfsStops.map(StoredStop.init(gtfsStop:)).sorted { $0.sequence < $1.sequence }
    }

    private func stationStops(for trip: Trip) -> [StoredStop] {
        if let stored = trip.stops, !stored.isEmpty {
            return stored.sorted { $0.sequence < $1.sequence }
        }
        let identifier = trip.gtfsTripId ?? trip.id
        let gtfsStops = GTFSDataSource.shared.stops(for: identifier)
        return gtfsStops.map(StoredStop.init(gtfsStop:)).sorted { $0.sequence < $1.sequence }
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

        guard let fallback = interpolatedCoordinate(
            entries: timeline,
            referenceDate: referenceDate,
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
            return LiveTrainCoordinateResult(
                coordinate: fallback,
                mode: .interpolation,
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
                    return LiveTrainCoordinateResult(
                        coordinate: fallback,
                        mode: .interpolation,
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

                return LiveTrainCoordinateResult(
                    coordinate: fallback,
                    mode: .interpolation,
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
            return LiveTrainCoordinateResult(
                coordinate: fallback,
                mode: .interpolation,
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

        let route = polylineStops(for: trip).map(\.coordinate)
        locationPhaseDetector.update(trip: trip, location: location, route: route)
        let liveInfo = LiveDelayStore.shared.info(for: trip.id)
        let timing = TripTimingResolver().resolve(trip: trip, delayInfo: liveInfo, referenceDate: location.timestamp)
        TripDelayFusionStore.shared.update(
            trip: trip,
            progress: locationPhaseDetector.progress(for: trip),
            timing: timing,
            liveInfo: liveInfo,
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

        // Schedule time alone cannot prove the train has left while the rider
        // is still at the origin, so keep the suggestion suppressed there.
        if isFreshlyAtOrigin(trip) {
#if DEBUG
            missedTrainDiagnosticText = "Missed train: train still appears to be at origin"
#endif
            return
        }

        // A rider away from the origin can be prompted once the adjusted
        // departure has passed.
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
        if isFreshlyAtOrigin(trip) {
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
        TripDebugLog.added(selected)
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
        let baseDate = GTFSDataSource.calendar.startOfDay(for: referenceDate)

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
        referenceDate: Date
    ) -> CLLocationCoordinate2D? {
        guard let first = entries.first, let last = entries.last else { return nil }

        if referenceDate <= first.startDate {
            return first.startCoordinate
        }

        if referenceDate >= last.endDate {
            return last.endCoordinate
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

    private func segmentCoordinates(for trip: Trip, orderedStops: [StoredStop]) -> [CLLocationCoordinate2D]? {
        guard let range = highlightedRange(for: trip, orderedStops: orderedStops) else { return nil }
        let segmentSlice = orderedStops[range]
        guard segmentSlice.count > 1 else { return nil }
        if let geometry = routeGeometry(for: trip),
           let first = segmentSlice.first, let last = segmentSlice.last {
            let coordinates = geometry.coordinates(fromSequence: first.sequence, toSequence: last.sequence)
            if coordinates.count > 1 { return coordinates }
        }
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
        if let sequence, let index = stops.firstIndex(where: { $0.sequence == sequence && (id == nil || $0.id == id) }) {
            return index
        }
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

    nonisolated init?(categoryCode: String) {
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
    let sharedJourneyLeg: SharedJourney.Leg?
    var sharedJourneyID: String?
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

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case agencyId
        case detailDate
        case detailRoute
        case gtfsTripId
        case travelDate
        case sharedJourneyLeg
        case sharedJourneyID
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
    }

    nonisolated init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String,
        agencyId: String? = nil,
        detailDate: String? = nil,
        detailRoute: String? = nil,
        gtfsTripId: String? = nil,
        travelDate: Date? = nil,
        sharedJourneyLeg: SharedJourney.Leg? = nil,
        sharedJourneyID: String? = nil,
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
        trainPower: TrainPowerType? = nil
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
            sharedJourneyLeg: sharedJourneyLeg,
            sharedJourneyID: sharedJourneyID,
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
            trainPower: trainPower
        )
    }

    nonisolated init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String,
        agencyId: String? = nil,
        detailDate: String? = nil,
        detailRoute: String? = nil,
        gtfsTripId: String? = nil,
        travelDate: Date? = nil,
        sharedJourneyLeg: SharedJourney.Leg? = nil,
        sharedJourneyID: String? = nil,
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
        trainPower: TrainPowerType? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.agencyId = agencyId
        self.detailDate = detailDate
        self.detailRoute = detailRoute
        self.gtfsTripId = gtfsTripId
        self.travelDate = travelDate
        self.sharedJourneyLeg = sharedJourneyLeg
        self.sharedJourneyID = sharedJourneyID
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
        sharedJourneyLeg = try container.decodeIfPresent(SharedJourney.Leg.self, forKey: .sharedJourneyLeg)
        sharedJourneyID = try container.decodeIfPresent(String.self, forKey: .sharedJourneyID)
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
        try container.encodeIfPresent(sharedJourneyLeg, forKey: .sharedJourneyLeg)
        try container.encodeIfPresent(sharedJourneyID, forKey: .sharedJourneyID)
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

    nonisolated init(
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

extension StoredStop {
    nonisolated init(gtfsStop: GTFSStop) {
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
            sharedJourneyLeg: sharedJourneyLeg,
            sharedJourneyID: sharedJourneyID,
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
            trainPower: trainPower
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
            sharedJourneyLeg: sharedJourneyLeg,
            sharedJourneyID: sharedJourneyID,
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
            trainPower: trainPower
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
            sharedJourneyLeg: sharedJourneyLeg,
            sharedJourneyID: sharedJourneyID,
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
            trainPower: trainPower
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
            sharedJourneyLeg: sharedJourneyLeg,
            sharedJourneyID: sharedJourneyID,
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
            trainPower: trainPower
        )
    }




}

struct BlitzAppPreview: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
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
                        description: Text("No alternative trains were found for this journey.")
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
