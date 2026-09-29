import CoreLocation
import Combine

final class DeviceLocationProvider: NSObject, ObservableObject {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var currentSpeed: CLLocationSpeed?
    @Published private(set) var lastLocation: CLLocation?

    private let manager = CLLocationManager()
    private var isTracking = false
    private var isSpeedTracking = false
    private let lastLocationKey = "raily.location.lastReliableSample"

    private struct PersistedLocation: Codable {
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let horizontalAccuracy: Double
        let verticalAccuracy: Double
        let course: Double
        let speed: Double
        let timestamp: Date
    }

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.activityType = .otherNavigation
        if let data = UserDefaults.standard.data(forKey: lastLocationKey),
           let saved = try? JSONDecoder().decode(PersistedLocation.self, from: data) {
            let restored = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: saved.latitude, longitude: saved.longitude),
                altitude: saved.altitude,
                horizontalAccuracy: saved.horizontalAccuracy,
                verticalAccuracy: saved.verticalAccuracy,
                course: saved.course,
                speed: saved.speed,
                timestamp: saved.timestamp
            )
            coordinate = restored.coordinate
            currentSpeed = restored.speed >= 0 ? restored.speed : nil
            lastLocation = restored
        }
    }

    func enableTracking() {
        guard authorizationStatus != .denied, authorizationStatus != .restricted else { return }
        if authorizationStatus == .notDetermined {
            manager.requestAlwaysAuthorization()
        } else if authorizationStatus == .authorizedWhenInUse {
            // Automatic trip detection is explicitly an Always-location
            // feature. Ask iOS to upgrade the permission when the user has
            // previously granted only foreground access.
            manager.requestAlwaysAuthorization()
        }
        configureLocationService()
        isTracking = true
    }

    func disableTracking() {
        guard isTracking else { return }
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        isTracking = false
        isSpeedTracking = false
    }

    func enableSpeedTracking() {
        guard authorizationStatus != .denied, authorizationStatus != .restricted else { return }
        if authorizationStatus == .notDetermined {
            manager.requestAlwaysAuthorization()
        }
        isTracking = true
        isSpeedTracking = true
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 10
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.stopMonitoringSignificantLocationChanges()
        manager.startUpdatingLocation()
    }

    func stopSpeedTracking() {
        guard isSpeedTracking else { return }
        isSpeedTracking = false
        configureLocationService()
    }

    private func configureLocationService() {
        guard !isSpeedTracking else { return }
        let batterySaving = TripLocationDetectionPreferences.batterySavingEnabled
        manager.desiredAccuracy = batterySaving ? kCLLocationAccuracyKilometer : kCLLocationAccuracyHundredMeters
        manager.distanceFilter = batterySaving ? 250 : 50
        manager.allowsBackgroundLocationUpdates = !batterySaving
        manager.showsBackgroundLocationIndicator = !batterySaving
        manager.pausesLocationUpdatesAutomatically = batterySaving

        if batterySaving {
            manager.stopUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
            manager.startUpdatingLocation()
        }
    }
}

extension DeviceLocationProvider: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if !(manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse) {
            disableTracking()
        } else if isTracking {
            configureLocationService()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        coordinate = latest.coordinate
        currentSpeed = latest.speed >= 0 ? latest.speed : nil
        lastLocation = latest
        let persisted = PersistedLocation(
            latitude: latest.coordinate.latitude,
            longitude: latest.coordinate.longitude,
            altitude: latest.altitude,
            horizontalAccuracy: latest.horizontalAccuracy,
            verticalAccuracy: latest.verticalAccuracy,
            course: latest.course,
            speed: latest.speed,
            timestamp: latest.timestamp
        )
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: lastLocationKey)
        }
    }
}

enum TripDetectedPhase: String, Codable {
    case unknown
    case atOrigin
    case boarded
    case arrived
    case exitedEarly
}

struct TripGPSProgress: Equatable, Codable {
    let fraction: Double
    let recordedAt: Date
}

enum TripLocationDetectionPreferences {
    private static let enabledKey = "raily.automaticStationDetection"
    private static let batterySavingKey = "raily.automaticStationDetection.batterySaving"
    private static let highConfidenceArrivalKey = "raily.automaticStationDetection.highConfidenceArrival"
    private static let missedTrainSuggestionsKey = "raily.automaticStationDetection.missedTrainSuggestions"
    private static let continuousSpeedCapsuleKey = "raily.speedCapsule.continuous"
    private static let missedTrainDebugUIKey = "raily.missedTrain.debugUI"
    private static let missedTrainSimulationKey = "raily.missedTrain.simulation"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: .tripLocationDetectionPreferenceChanged, object: nil)
        }
    }

    static var batterySavingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: batterySavingKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: batterySavingKey)
            NotificationCenter.default.post(name: .tripLocationDetectionPreferenceChanged, object: nil)
        }
    }

    static var highConfidenceArrivalEnabled: Bool {
        get { UserDefaults.standard.object(forKey: highConfidenceArrivalKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: highConfidenceArrivalKey); postChange() }
    }

    static var missedTrainSuggestionsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: missedTrainSuggestionsKey) }
        set { UserDefaults.standard.set(newValue, forKey: missedTrainSuggestionsKey); postChange() }
    }

    static var continuousSpeedCapsuleEnabled: Bool {
        get { UserDefaults.standard.object(forKey: continuousSpeedCapsuleKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: continuousSpeedCapsuleKey); postChange() }
    }

    static var missedTrainDebugUIEnabled: Bool {
        get { UserDefaults.standard.object(forKey: missedTrainDebugUIKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: missedTrainDebugUIKey); postChange() }
    }

    static var missedTrainSimulationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: missedTrainSimulationKey) }
        set { UserDefaults.standard.set(newValue, forKey: missedTrainSimulationKey); postChange() }
    }


    private static func postChange() {
        NotificationCenter.default.post(name: .tripLocationDetectionPreferenceChanged, object: nil)
    }
}

extension Notification.Name {
    static let tripLocationDetectionPreferenceChanged = Notification.Name("tripLocationDetectionPreferenceChanged")
}

final class TripLocationPhaseDetector: ObservableObject {
    @Published private(set) var phases: [String: TripDetectedPhase] = [:]
    @Published private(set) var holdingStations: [String: String] = [:]
    @Published private(set) var gpsProgress: [String: TripGPSProgress] = [:]

    private let phaseKey = "raily.tripDetection.phases"
    private let observationKey = "raily.tripDetection.observations"
    private let stationKey = "raily.tripDetection.holdingStations"
    private let arrivalEvidenceKey = "raily.tripDetection.arrivalEvidence"
    private let holdingGrace: TimeInterval = 3 * 60

    private struct Observation: Codable {
        let progress: CLLocationDistance
        let latitude: CLLocationDegrees
        let longitude: CLLocationDegrees
        let timestamp: Date

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private var observations: [String: Observation] = [:]
    private var stationSchedules: [String: [String: StationSchedule]] = [:]
    private var arrivalEvidence: [String: ArrivalEvidence] = [:]

    private struct StationSchedule: Codable {
        let arrival: Date?
        let departure: Date?
    }

    private struct ArrivalEvidence: Codable {
        var count: Int
        var lastTimestamp: Date
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: phaseKey),
           let stored = try? JSONDecoder().decode([String: TripDetectedPhase].self, from: data) {
            phases = stored
        }
        if let data = UserDefaults.standard.data(forKey: observationKey),
           let stored = try? JSONDecoder().decode([String: Observation].self, from: data) {
            observations = stored
        }
        if let data = UserDefaults.standard.data(forKey: stationKey),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            holdingStations = stored
        }
        if let data = UserDefaults.standard.data(forKey: arrivalEvidenceKey),
           let stored = try? JSONDecoder().decode([String: ArrivalEvidence].self, from: data) {
            arrivalEvidence = stored
        }
    }

    func phase(for trip: Trip) -> TripDetectedPhase {
        phases[stateKey(for: trip)] ?? .unknown
    }

    static func persistedPhase(for trip: Trip) -> TripDetectedPhase {
        guard let data = UserDefaults.standard.data(forKey: "raily.tripDetection.phases"),
              let phases = try? JSONDecoder().decode([String: TripDetectedPhase].self, from: data) else {
            return .unknown
        }
        let day = trip.travelDate.map { ISO8601DateFormatter().string(from: $0) } ?? "undated"
        return phases["\(trip.id)|\(day.prefix(10))"] ?? .unknown
    }

    func progress(for trip: Trip) -> TripGPSProgress? {
        gpsProgress[stateKey(for: trip)]
    }

    func update(
        trip: Trip,
        location: CLLocation,
        route: [CLLocationCoordinate2D]
    ) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 150,
              abs(location.timestamp.timeIntervalSinceNow) <= 15 * 60,
              route.count > 1 else { return }

        let key = stateKey(for: trip)
        let currentPhase = phase(for: trip)
        guard currentPhase != .arrived, currentPhase != .exitedEarly else { return }

        let origin = coordinate(for: trip.originStopId, sequence: trip.originSequence, in: trip)
        let destination = coordinate(for: trip.destinationStopId, sequence: trip.destinationSequence, in: trip)
        guard let origin, let destination else { return }

        let routeProjection = Self.projection(of: location.coordinate, on: route)
        let originProjection = Self.projection(of: origin, on: route)
        let destinationProjection = Self.projection(of: destination, on: route)
        let routeLength = max(destinationProjection.progress - originProjection.progress, 1)
        let fraction = min(1, max(0, (routeProjection.progress - originProjection.progress) / routeLength))
        gpsProgress[key] = TripGPSProgress(fraction: fraction, recordedAt: location.timestamp)
        let previous = observations[key]
        observations[key] = Observation(
            progress: routeProjection.progress,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp
        )
        persistObservations()

        updateIntermediateStationHold(
            trip: trip,
            location: location,
            routeProjection: routeProjection,
            originProjection: originProjection,
            destinationProjection: destinationProjection,
            key: key
        )
        let originRadius = max(250, location.horizontalAccuracy * 1.5)
        let destinationRadius = max(250, location.horizontalAccuracy * 1.5)
        let distanceToOrigin = location.distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude))
        let distanceToDestination = location.distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))

        if currentPhase == .unknown, distanceToOrigin <= originRadius {
            setPhase(.atOrigin, for: key)
            return
        }

        let routeMatch = routeProjection.distance <= max(500, location.horizontalAccuracy * 3)
        let progressed = routeProjection.progress > originProjection.progress + 250
        let movedSinceLastUpdate: Bool = {
            guard let previous else { return false }
            let old = CLLocation(latitude: previous.coordinate.latitude, longitude: previous.coordinate.longitude)
            return location.distance(from: old) > 100 || routeProjection.progress > previous.progress + 150
        }()
        let moving = location.speed >= 1 || movedSinceLastUpdate

        if (currentPhase == .atOrigin || currentPhase == .unknown), routeMatch, progressed, moving {
            setPhase(.boarded, for: key)
            return
        }

        if currentPhase == .boarded,
           routeMatch,
           distanceToDestination <= destinationRadius,
           routeProjection.progress >= destinationProjection.progress - 350 {
            guard TripLocationDetectionPreferences.highConfidenceArrivalEnabled else {
                setPhase(.arrived, for: key)
                return
            }

            let previousEvidence = arrivalEvidence[key]
            let isSeparateFix = previousEvidence.map {
                location.timestamp.timeIntervalSince($0.lastTimestamp) >= 10
            } ?? true
            let count = isSeparateFix ? (previousEvidence?.count ?? 0) + 1 : (previousEvidence?.count ?? 0)
            arrivalEvidence[key] = ArrivalEvidence(count: count, lastTimestamp: location.timestamp)
            persistArrivalEvidence()
            if count >= 2 {
                setPhase(.arrived, for: key)
                arrivalEvidence.removeValue(forKey: key)
                persistArrivalEvidence()
            }
        } else {
            arrivalEvidence.removeValue(forKey: key)
            persistArrivalEvidence()
        }
    }

    private func setPhase(_ phase: TripDetectedPhase, for tripID: String) {
        phases[tripID] = phase
        if let data = try? JSONEncoder().encode(phases) {
            UserDefaults.standard.set(data, forKey: phaseKey)
        }
    }

    private func persistArrivalEvidence() {
        if let data = try? JSONEncoder().encode(arrivalEvidence) {
            UserDefaults.standard.set(data, forKey: arrivalEvidenceKey)
        }
    }

    private func stateKey(for trip: Trip) -> String {
        let day = trip.travelDate.map { ISO8601DateFormatter().string(from: $0) } ?? "undated"
        return "\(trip.id)|\(day.prefix(10))"
    }

    private func persistObservations() {
        if let data = try? JSONEncoder().encode(observations) {
            UserDefaults.standard.set(data, forKey: observationKey)
        }
    }

    private func updateIntermediateStationHold(
        trip: Trip,
        location: CLLocation,
        routeProjection: (progress: CLLocationDistance, distance: CLLocationDistance),
        originProjection: (progress: CLLocationDistance, distance: CLLocationDistance),
        destinationProjection: (progress: CLLocationDistance, distance: CLLocationDistance),
        key: String
    ) {
        guard routeProjection.distance <= max(500, location.horizontalAccuracy * 3),
              routeProjection.progress > originProjection.progress + 250,
              routeProjection.progress < destinationProjection.progress - 350,
              let travelDate = trip.travelDate else {
            holdingStations.removeValue(forKey: key)
            persistHoldingStations()
            return
        }

        let tripIdentifier = trip.gtfsTripId ?? trip.id
        let schedules = stationSchedulesForTrip(trip: trip, identifier: tripIdentifier, baseDate: travelDate)
        let sourceStops = GTFSDataSource.shared.stops(for: tripIdentifier)
        let stops: [StoredStop] = (sourceStops.isEmpty ? (trip.stops ?? []) : sourceStops.map(StoredStop.init(gtfsStop:)))
            .sorted { $0.sequence < $1.sequence }
        let originIndex = stops.firstIndex { $0.id == trip.originStopId || $0.sequence == trip.originSequence } ?? 0
        let destinationIndex = stops.lastIndex { $0.id == trip.destinationStopId || $0.sequence == trip.destinationSequence } ?? stops.count - 1
        guard originIndex < destinationIndex else { return }
        let intermediate = stops[(originIndex + 1)..<destinationIndex]
        guard let station = intermediate.min(by: {
            let lhs = location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
            let rhs = location.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
            return lhs < rhs
        }), let schedule = schedules[station.id], let departure = schedule.departure else {
            holdingStations.removeValue(forKey: key)
            persistHoldingStations()
            return
        }

        let stationDistance = location.distance(from: CLLocation(latitude: station.latitude, longitude: station.longitude))
        guard stationDistance <= max(250, location.horizontalAccuracy * 1.5),
              location.timestamp > departure.addingTimeInterval(holdingGrace) else {
            holdingStations.removeValue(forKey: key)
            persistHoldingStations()
            return
        }

        holdingStations[key] = station.name
        persistHoldingStations()
    }

    private func stationSchedulesForTrip(trip: Trip, identifier: String, baseDate: Date) -> [String: StationSchedule] {
        let key = stateKey(for: trip)
        if let cached = stationSchedules[key] { return cached }
        let sourceStops = GTFSDataSource.shared.stops(for: identifier)
        let stops = (sourceStops.isEmpty ? (trip.stops ?? []).map { GTFSStop(id: $0.id, name: $0.name, sequence: $0.sequence, latitude: $0.latitude, longitude: $0.longitude) } : sourceStops)
            .sorted { $0.sequence < $1.sequence }
        var result: [String: StationSchedule] = [:]
        for stop in stops {
            guard let schedule = GTFSDataSource.shared.stopSchedule(for: identifier, stopId: stop.id) else { continue }
            result[stop.id] = StationSchedule(
                arrival: schedule.arrivalDate(on: baseDate),
                departure: schedule.departureDate(on: baseDate)
            )
        }
        stationSchedules[key] = result
        return result
    }

    private func persistHoldingStations() {
        if let data = try? JSONEncoder().encode(holdingStations) {
            UserDefaults.standard.set(data, forKey: stationKey)
        }
    }

    func remove(tripIDs: Set<String>) {
        let prefixes = tripIDs.map { "\($0)|" }
        phases = phases.filter { entry in !prefixes.contains(where: { entry.key.hasPrefix($0) }) }
        observations = observations.filter { entry in !prefixes.contains(where: { entry.key.hasPrefix($0) }) }
        holdingStations = holdingStations.filter { entry in !prefixes.contains(where: { entry.key.hasPrefix($0) }) }
        gpsProgress = gpsProgress.filter { entry in !prefixes.contains(where: { entry.key.hasPrefix($0) }) }
        arrivalEvidence = arrivalEvidence.filter { entry in !prefixes.contains(where: { entry.key.hasPrefix($0) }) }
        stationSchedules = stationSchedules.filter { entry in !prefixes.contains(where: { entry.key.hasPrefix($0) }) }
        if let data = try? JSONEncoder().encode(phases) { UserDefaults.standard.set(data, forKey: phaseKey) }
        persistObservations()
        persistHoldingStations()
        persistArrivalEvidence()
    }

    func removeExpired(before date: Date = Date()) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -2, to: date) ?? date
        let formatter = ISO8601DateFormatter()
        let cutoffDay = formatter.string(from: cutoff).prefix(10)
        let keep: (String) -> Bool = { key in
            guard let separator = key.firstIndex(of: "|") else { return false }
            let day = key[key.index(after: separator)...]
            return day >= cutoffDay
        }
        phases = phases.filter { keep($0.key) }
        observations = observations.filter { keep($0.key) }
        holdingStations = holdingStations.filter { keep($0.key) }
        gpsProgress = gpsProgress.filter { keep($0.key) }
        arrivalEvidence = arrivalEvidence.filter { keep($0.key) }
        stationSchedules = stationSchedules.filter { keep($0.key) }
        if let data = try? JSONEncoder().encode(phases) { UserDefaults.standard.set(data, forKey: phaseKey) }
        persistObservations()
        persistHoldingStations()
        persistArrivalEvidence()
    }

    func clearAll() {
        phases.removeAll()
        observations.removeAll()
        holdingStations.removeAll()
        gpsProgress.removeAll()
        arrivalEvidence.removeAll()
        stationSchedules.removeAll()
        UserDefaults.standard.removeObject(forKey: phaseKey)
        UserDefaults.standard.removeObject(forKey: observationKey)
        UserDefaults.standard.removeObject(forKey: stationKey)
        UserDefaults.standard.removeObject(forKey: arrivalEvidenceKey)
    }

    private func coordinate(for id: String?, sequence: Int?, in trip: Trip) -> CLLocationCoordinate2D? {
        let stops = trip.stops?.sorted { $0.sequence < $1.sequence } ?? []
        if let id, let stop = stops.first(where: { $0.id == id }) { return stop.coordinate }
        if let sequence, let stop = stops.first(where: { $0.sequence == sequence }) { return stop.coordinate }
        return nil
    }

    private static func projection(
        of coordinate: CLLocationCoordinate2D,
        on route: [CLLocationCoordinate2D]
    ) -> (progress: CLLocationDistance, distance: CLLocationDistance) {
        var progress: CLLocationDistance = 0
        var bestProgress: CLLocationDistance = 0
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude

        for pair in zip(route, route.dropFirst()) {
            let start = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let end = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
            let point = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let segmentLength = start.distance(from: end)
            guard segmentLength > 0 else { continue }

            let latitudeScale = cos((pair.0.latitude + pair.1.latitude) * .pi / 360)
            let dx = (pair.1.longitude - pair.0.longitude) * latitudeScale
            let dy = pair.1.latitude - pair.0.latitude
            let px = (coordinate.longitude - pair.0.longitude) * latitudeScale
            let py = coordinate.latitude - pair.0.latitude
            let denominator = dx * dx + dy * dy
            let fraction = denominator > 0
                ? min(1, max(0, (px * dx + py * dy) / denominator))
                : 0
            let projected = CLLocationCoordinate2D(
                latitude: pair.0.latitude + (pair.1.latitude - pair.0.latitude) * fraction,
                longitude: pair.0.longitude + (pair.1.longitude - pair.0.longitude) * fraction
            )
            let distance = point.distance(from: CLLocation(latitude: projected.latitude, longitude: projected.longitude))
            if distance < bestDistance {
                bestDistance = distance
                bestProgress = progress + segmentLength * fraction
            }
            progress += segmentLength
        }
        return (bestProgress, bestDistance)
    }
}
