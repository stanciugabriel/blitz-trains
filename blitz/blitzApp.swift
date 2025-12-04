import SwiftUI
import MapKit

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

    var body: some View {
        Map(position: $mapPosition) {
            if let focusedTrip = selectedTrip, let stops = focusedTrip.stops, !isAddTripMode {
                detailMapContent(for: focusedTrip, stops: stops)
            } else {
                dashboardMapContent()
            }
        }
        .mapStyle(.standard(elevation: .automatic))
        .mapControls {
            MapUserLocationButton()
                .mapControlVisibility(.visible)
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
            .presentationBackground(Color.white)
            .presentationBackgroundInteraction(.enabled)
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(true)
        }
        .onChange(of: isAddTripMode) { _, newValue in
            DispatchQueue.main.async {
                selectedDetent = newValue ? .large : .medium
            }
            updateCameraForCurrentState()
        }
        .onChange(of: selectedTrip) { _, _ in
            updateCameraForCurrentState()
        }
        .onAppear {
            updateCameraForCurrentState(animated: false)
        }
        .onChange(of: trips) { _, newValue in
            TripStorage.shared.saveTrips(newValue)
            updateCameraForCurrentState()
        }
        .onChange(of: pastTrips) { _, newValue in
            TripStorage.shared.savePastTrips(newValue)
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
            if let line = straightLineCoordinates(for: trip) {
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

    @MapContentBuilder
    private func detailMapContent(for trip: Trip, stops: [StoredStop]) -> some MapContent {
        let ordered = stops.sorted { $0.sequence < $1.sequence }
        let coordinates = ordered.map { $0.coordinate }
        if coordinates.count > 1 {
            MapPolyline(coordinates: coordinates)
                .stroke(
                    .gray.opacity(0.5),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 6])
                )

            if let segment = segmentCoordinates(for: trip, orderedStops: ordered) {
                MapPolyline(coordinates: segment)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
        }

        ForEach(ordered) { stop in
            Annotation("", coordinate: stop.coordinate) {
                MapDot(color: isStopWithinSegment(stop, trip: trip) ? .blue : .gray)
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
        guard let startSeq = trip.originSequence, let endSeq = trip.destinationSequence else { return nil }
        let segment = orderedStops.filter { $0.sequence >= startSeq && $0.sequence <= endSeq }
        guard segment.count > 1 else { return nil }
        return segment.map { $0.coordinate }
    }

    private func isStopWithinSegment(_ stop: StoredStop, trip: Trip) -> Bool {
        guard let startSeq = trip.originSequence, let endSeq = trip.destinationSequence else { return false }
        return stop.sequence >= startSeq && stop.sequence <= endSeq
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
        let coordinates = trips.compactMap { straightLineCoordinates(for: $0) }.flatMap { $0 }
        if let region = region(containing: coordinates) {
            setMapRegion(region, animated: animated)
        } else {
            setMapRegion(Self.defaultRegion, animated: animated)
        }
    }

    private func coordinatesForTrip(_ trip: Trip) -> [CLLocationCoordinate2D]? {
        if let stops = trip.stops, !stops.isEmpty {
            let ordered = stops.sorted { $0.sequence < $1.sequence }
            return ordered.map { $0.coordinate }
        }
        return straightLineCoordinates(for: trip)
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
        adjusted.center.latitude += region.span.latitudeDelta * -1
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
        seatNumbers: [String]? = nil
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
            ticketQRCode: nil
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
        ticketQRCode: String?
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

    init(
        id: String,
        name: String,
        latitude: Double,
        longitude: Double,
        sequence: Int,
        arrivalDelayMinutes: Int? = nil,
        departureDelayMinutes: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.sequence = sequence
        self.arrivalDelayMinutes = arrivalDelayMinutes
        self.departureDelayMinutes = departureDelayMinutes
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension Trip {
    func updatingSeatInfo(car: String?, seats: [String]?) -> Trip {
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
            ticketQRCode: ticketQRCode
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
            ticketQRCode: code
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
            ticketQRCode: ticketQRCode
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
            ticketQRCode: ticketQRCode
        )
    }
}

#Preview {
    ContentView()
}
