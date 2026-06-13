import SwiftUI
import MapKit
import Combine

@main
struct BlitzApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
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
    @State private var usesGlobeMapStyle = false
    @StateObject private var locationProvider = DeviceLocationProvider()
    private let liveTrainTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let liveActivityRefreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        let detailState: DetailMapState? = {
            guard let trip = selectedTrip, !isAddTripMode else { return nil }
            return detailMapState(for: trip)
        }()
        let shouldShowUserLocation = shouldDisplayUserLocationDot(for: detailState)
        let shouldShowLiveTrainMarker = shouldDisplayLiveTrainMarker(
            for: detailState,
            userLocationVisible: shouldShowUserLocation
        )


        Map(position: $mapPosition) {
            if shouldShowUserLocation {
                UserAnnotation()
            }
            if let state = detailState {
                detailMapContent(state: state, showLiveTrainMarker: shouldShowLiveTrainMarker)
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
                showLocationButton: shouldShowUserLocation,
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
        .safeAreaInset(edge: .top, alignment: .center) {
            Color.clear
                .frame(height: 20)
        }
        .ignoresSafeArea()
        .sheet(isPresented: $isSheetPresented) {
            SheetContent(
                trips: $trips,
                selectedTrip: $selectedTrip,
                isAddTripMode: addTripModeBinding,
                trainSearchQuery: $trainSearchQuery,
                pastTrips: $pastTrips,
                onTripAdded: syncTripAfterAdd
            )
            .presentationDetents(detents, selection: $selectedDetent)
            .presentationBackground(Color(.systemBackground))
            .presentationBackgroundInteraction(.enabled)
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(true)
        }
        .onChange(of: isAddTripMode) { _, newValue in
            if !newValue {
                DispatchQueue.main.async {
                    selectedDetent = .medium
                }
            }
            if newValue {
                locationProvider.disableTracking()
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
            updateCameraForCurrentState()
        }
        .onAppear {
            updateCameraForCurrentState(animated: false)
            syncTripsOnLaunchIfNeeded()
        }
        .onReceive(liveTrainTimer) { value in
            withAnimation(.linear(duration: 1)) {
                liveTrainClock = value
            }
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
            refreshRunningLiveActivities()
        }
        .onChange(of: trips) { _, newValue in
            TripStorage.shared.saveTrips(newValue)
            updateCameraForCurrentState()
        }
        .onChange(of: trips) { oldValue, newValue in
            let activeIDs = Set(newValue.map(\.id))
            oldValue
                .filter { !activeIDs.contains($0.id) }
                .forEach { LiveActivityManager.shared.endActivity(for: $0.id) }
        }
        .onChange(of: pastTrips) { _, newValue in
            TripStorage.shared.savePastTrips(newValue)
        }
        // Run tracking side effect when the selected trip or user-location visibility changes.
        .task(id: trackingTaskKey(for: detailState)) {
            updateTrackingState(using: detailState?.trackingResult)
        }
    }

    private var detents: Set<PresentationDetent> {
        isAddTripMode ? [.large] : [.fraction(0.3), .medium, .large]
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
        return "\(tripID)-\(showsUser)"
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
        let result = LiveActivityManager.shared.startActivity(for: trip)
        #if DEBUG
        print("[ContentView] Live Activity auto-start: \(result.message)")
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
        guard let trainNumber = resolvedTrainNumber(for: trip) else { return }
        await InfoFerSessionManager.shared.refreshSession(for: trainNumber)
        var info = await InfoFerScraper.shared.fetchDelay(
            for: trainNumber,
            travelDate: trip.travelDate
        )
        let mapInfo = shouldFetchMapInfo
            ? await fetchMapInfo(for: trainNumber, trip: trip)
            : InfoFerMapInfo(routePolylines: [], liveCoordinate: nil, gpsPermanentlyUnavailable: false)
        if let liveCoordinate = mapInfo.liveCoordinate {
            info = info.updatingLiveCoordinate(liveCoordinate)
        }

        await MainActor.run {
            LiveDelayStore.shared.save(info: info, for: trip.id)
            applyLaunchSync(info: info, mapInfo: mapInfo, to: trip.id)
            let updatedTrip = trips.first(where: { $0.id == trip.id }) ?? trip
            LiveActivityManager.shared.updateActivity(for: updatedTrip, delayInfo: info)
        }
    }

    private func fetchMapInfo(for trainNumber: String, trip: Trip) async -> InfoFerMapInfo {
        guard let departureTime = scheduledDepartureTimeString(for: trip) else {
            return InfoFerMapInfo(routePolylines: [], liveCoordinate: nil, gpsPermanentlyUnavailable: false)
        }
        return await InfoFerScraper.shared.fetchMapInfo(
            for: trainNumber,
            travelDate: trip.travelDate,
            departureTime: departureTime
        )
    }

    private func scheduledDepartureTimeString(for trip: Trip) -> String? {
        serviceDepartureDate(for: trip).map { Self.mapDepartureTimeFormatter.string(from: $0) }
    }

    private func serviceDepartureDate(for trip: Trip) -> Date? {
        guard let travelDate = trip.travelDate else { return nil }
        let identifier = trip.gtfsTripId ?? trip.id
        let segments = GTFSDataSource.shared.segments(for: identifier)
        let firstSegment = segments.min {
            ($0.departureSeconds ?? $0.arrivalSeconds ?? Int.max) < ($1.departureSeconds ?? $1.arrivalSeconds ?? Int.max)
        }
        guard let departureSeconds = firstSegment?.departureSeconds ?? firstSegment?.arrivalSeconds else { return nil }
        return Calendar.current.startOfDay(for: travelDate).addingTimeInterval(TimeInterval(departureSeconds))
    }

    private func resolvedTrainNumber(for trip: Trip) -> String? {
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

    private func applyLaunchSync(info: DelayInfo, mapInfo: InfoFerMapInfo, to tripID: String) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }

        var updatedTrip = trips[index]
        var hasChanges = false

        if let updatedStops = stopsByApplying(info: info, to: updatedTrip) {
            updatedTrip = updatedTrip.updatingStops(updatedStops)
            hasChanges = true
        }

        if !mapInfo.routePolylines.isEmpty, updatedTrip.routePolylines != mapInfo.routePolylines {
            updatedTrip = updatedTrip.updatingRoutePolylines(mapInfo.routePolylines)
            hasChanges = true
        }

        if mapInfo.gpsPermanentlyUnavailable, !updatedTrip.infoFerGPSUnavailable {
            updatedTrip = updatedTrip.updatingInfoFerGPSUnavailable(true)
            hasChanges = true
        } else if mapInfo.liveCoordinate != nil, updatedTrip.infoFerGPSUnavailable {
            updatedTrip = updatedTrip.updatingInfoFerGPSUnavailable(false)
            hasChanges = true
        }

        guard hasChanges else { return }
        trips[index] = updatedTrip

        if selectedTrip?.id == tripID {
            selectedTrip = updatedTrip
        }
    }

    private func stopsByApplying(info: DelayInfo, to trip: Trip) -> [StoredStop]? {
        guard let storedStops = trip.stops, !storedStops.isEmpty else { return nil }

        var lookup: [String: StationDelay] = [:]
        for detail in info.stationDelays {
            lookup[normalizedStationName(detail.stationName)] = detail
        }

        var updatedStops = storedStops
        var hasChanges = false

        for index in updatedStops.indices {
            let key = normalizedStationName(updatedStops[index].name)
            guard let detail = lookup[key] else { continue }

            if updatedStops[index].arrivalDelayMinutes != detail.arrivalDelayMinutes {
                updatedStops[index].arrivalDelayMinutes = detail.arrivalDelayMinutes
                hasChanges = true
            }

            if updatedStops[index].departureDelayMinutes != detail.departureDelayMinutes {
                updatedStops[index].departureDelayMinutes = detail.departureDelayMinutes
                hasChanges = true
            }

            if updatedStops[index].platform != detail.platform {
                updatedStops[index].platform = detail.platform
                hasChanges = true
            }
        }

        return hasChanges ? updatedStops : nil
    }

    private func normalizedStationName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let mapDepartureTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
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
        let orderedStops = polylineStops(for: trip)
        let stoppingStops = stationStops(for: trip)
        let trackingResult = liveTrainCoordinate(
            for: trip,
            orderedStops: orderedStops,
            stoppingStops: stoppingStops,
            referenceDate: liveTrainClock,
            deviceCoordinate: locationProvider.coordinate
        )

        return DetailMapState(
            trip: trip,
            orderedStops: orderedStops,
            stoppingStops: stoppingStops,
            trackingResult: trackingResult
        )
    }

    private func updateTrackingState(using result: LiveTrainCoordinateResult?) {
        if result?.showsUserLocation == true {
            locationProvider.enableTracking()
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

        let timeline = buildSegmentEntries(
            segments: segments,
            trip: trip,
            stopLookup: stopLookup
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
              let destinationArrival = arrivalDate(for: destinationStopId, in: timeline) else {
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
        let referenceDate = trip.travelDate ?? Date()
        let baseDate = Calendar.current.startOfDay(for: referenceDate)

        let delaySeconds = TimeInterval((LiveDelayStore.shared.info(for: trip.id)?.delayMinutes ?? trip.delayMinutes ?? 0) * 60)

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
