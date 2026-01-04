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
    @StateObject private var locationProvider = DeviceLocationProvider()
    private let liveTrainTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

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
        .mapStyle(.standard(elevation: .automatic))
        .animation(.easeInOut(duration: 0.8), value: liveTrainClock)
        .mapControls {
            if shouldShowUserLocation {
                MapUserLocationButton()
                    .mapControlVisibility(.visible)
            }
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
                isAddTripMode: $isAddTripMode,
                trainSearchQuery: $trainSearchQuery,
                pastTrips: $pastTrips
            )
            .presentationDetents(detents, selection: $selectedDetent)
            .presentationBackground(Color(.systemBackground))
            .presentationBackgroundInteraction(.enabled)
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(true)
        }
        .onChange(of: isAddTripMode) { _, newValue in
            DispatchQueue.main.async {
                selectedDetent = newValue ? .large : .medium
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
                locationProvider.disableTracking()
            }
            updateCameraForCurrentState()
        }
        .onAppear {
            updateCameraForCurrentState(animated: false)
        }
        .onReceive(liveTrainTimer) { value in
            withAnimation(.easeInOut(duration: 0.8)) {
                liveTrainClock = value
            }
        }
        .onChange(of: trips) { _, newValue in
            TripStorage.shared.saveTrips(newValue)
            updateCameraForCurrentState()
        }
        .onChange(of: pastTrips) { _, newValue in
            TripStorage.shared.savePastTrips(newValue)
        }
        // Run tracking side effect when the user-location visibility changes (and on first render)
        .task(id: detailState?.trackingResult?.showsUserLocation ?? false) {
            updateTrackingState(using: detailState?.trackingResult)
        }
    }

    private var detents: Set<PresentationDetent> {
        isAddTripMode ? [.large] : [.fraction(0.3), .medium, .large]
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
                LiveTrainMarkerView()
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
        let stops = polylineStops(for: trip)
        if stops.count > 1 {
            return stops.map { $0.coordinate }
        }
        return straightLineCoordinates(for: trip)
    }

    private func userSegmentCoordinates(for trip: Trip) -> [CLLocationCoordinate2D]? {
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

        guard let fallback = interpolatedCoordinate(entries: timeline, referenceDate: referenceDate) else {
            return nil
        }

        let resolvedStops = resolvedStopIdentifiers(
            for: trip,
            orderedStops: orderedStops,
            stoppingStops: stoppingStops
        )

        guard
            let originStopId = resolvedStops.origin,
            let destinationStopId = resolvedStops.destination,
            let originDeparture = timeline.first(where: { $0.startStopId == originStopId })?.startDate,
            let destinationArrival = timeline.first(where: { $0.endStopId == destinationStopId })?.endDate
        else {
            return LiveTrainCoordinateResult(
                coordinate: fallback,
                mode: .interpolation,
                showsUserLocation: false,
                showsLiveTrainMarker: false
            )
        }

        let leadTime: TimeInterval = 10 * 60
        let userWindowStart = originDeparture.addingTimeInterval(-leadTime)
        let hasDeparted = referenceDate >= originDeparture
        let hasArrived = referenceDate >= destinationArrival
        let isWithinUserWindow = referenceDate >= userWindowStart && referenceDate <= destinationArrival

        if hasDeparted && !hasArrived {
            let coordinate = deviceCoordinate ?? fallback
            return LiveTrainCoordinateResult(
                coordinate: coordinate,
                mode: .device,
                showsUserLocation: true,
                showsLiveTrainMarker: true
            )
        }

        if isWithinUserWindow {
            return LiveTrainCoordinateResult(
                coordinate: fallback,
                mode: .interpolation,
                showsUserLocation: true,
                showsLiveTrainMarker: false
            )
        }

        if hasDeparted {
            // Train has completed the trip; keep marker but hide GPS/user affordances.
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
        var baseDate = Calendar.current.startOfDay(for: referenceDate)
        if let firstSeconds = segments.first?.departureSeconds,
           baseDate.addingTimeInterval(TimeInterval(firstSeconds)) > referenceDate {
            baseDate = baseDate.addingTimeInterval(-ScheduleDateUtils.dayInterval)
        }

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
}

private struct LiveTrainCoordinateResult {
    let coordinate: CLLocationCoordinate2D?
    let mode: LiveTrainTrackingMode
    let showsUserLocation: Bool
    let showsLiveTrainMarker: Bool
}

private struct LiveTrainMarkerView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.9))
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
