import Foundation

/// Foreground polling for the locally configured SBB GTFS-RT proxy. ActivityKit
/// remote updates require a separate APNs endpoint on the server.
@MainActor
final class SBBLiveTripService {
    static let shared = SBBLiveTripService()

    private let endpoint: URL
    private let load: (URLRequest) async throws -> (Data, URLResponse)
    private let cachedDelay: @MainActor (String) -> DelayInfo?
    private let saveDelay: @MainActor (DelayInfo, String) -> Void
    private var lastAttempt: [String: Date] = [:]
    private var inFlight = Set<String>()
    private let timingResolver = TripTimingResolver()

    init(
        endpoint: URL = URL(string: "http://192.168.0.14:3000")!,
        load: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
        cachedDelay: @escaping @MainActor (String) -> DelayInfo? = { LiveDelayStore.shared.info(for: $0) },
        saveDelay: @escaping @MainActor (DelayInfo, String) -> Void = { LiveDelayStore.shared.save(info: $0, for: $1) }
    ) {
        self.endpoint = endpoint
        self.load = load
        self.cachedDelay = cachedDelay
        self.saveDelay = saveDelay
    }

    func refresh(trips: [Trip], now: Date = Date()) async {
        for trip in trips {
            guard let id = trip.gtfsTripId, !id.isEmpty,
                  let serviceDate = trip.travelDate else { continue }
            let runKey = "\(trip.id)|\(GTFSDataSource.calendar.startOfDay(for: serviceDate).timeIntervalSince1970)"
            guard !inFlight.contains(runKey),
                  now.timeIntervalSince(lastAttempt[runKey] ?? .distantPast) >= 45 else { continue }
            let timing = timingResolver.resolve(trip: trip,
                delayInfo: cachedDelay(trip.id),
                referenceDate: now, includeProgressDetails: false)
            guard let departure = timing.adjustedDeparture ?? timing.scheduledDeparture,
                  let arrival = timing.adjustedArrival ?? timing.scheduledArrival,
                  now >= departure.addingTimeInterval(-45 * 60),
                  now <= arrival.addingTimeInterval(20 * 60) else { continue }

            lastAttempt[runKey] = now
            inFlight.insert(runKey)
            defer { inFlight.remove(runKey) }
            do {
                let url = endpoint.appendingPathComponent("trips").appendingPathComponent(id)
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 8
                let (data, response) = try await load(request)
                // A 404 means this run is absent from the current minute's
                // feed. Retry next minute; it is not a permanent exclusion.
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let live = try? JSONDecoder().decode(SBBRTTripResponse.self, from: data),
                      let observed = live.observedAt,
                      now.timeIntervalSince(observed) <= 5 * 60,
                      observed.timeIntervalSince(now) <= 60,
                      let info = live.delayInfo(for: trip, serviceDate: serviceDate) else { continue }
                let previousInfo = cachedDelay(trip.id)
                if previousInfo == info { continue }
                if let previous = previousInfo?.fetchedAt,
                   let fetched = info.fetchedAt, fetched < previous { continue }
                saveDelay(info, trip.id)
            } catch {
                #if DEBUG
                print("[SBBLiveTripService] \(id): \(error.localizedDescription)")
                #endif
            }
        }
    }
}

struct SBBRTTripResponse: Decodable {
    let tripID: String
    let fetchedAt: String
    let entities: [Entity]
    let header: Header?

    enum CodingKeys: String, CodingKey {
        case tripID = "trip_id", fetchedAt = "fetched_at", entities, header
    }

    struct Header: Decodable {
        let timestamp: EpochSeconds?
    }

    /// Protobuf JSON encodes int64 timestamps as strings.
    struct EpochSeconds: Decodable {
        let value: Int64
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) { value = number; return }
            let text = try container.decode(String.self)
            guard let number = Int64(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid GTFS-RT timestamp")
            }
            value = number
        }
    }

    var observedAt: Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let fetched = parser.date(from: fetchedAt) ?? ISO8601DateFormatter().date(from: fetchedAt) else { return nil }
        guard let timestamp = header?.timestamp else { return fetched }
        return min(fetched, Date(timeIntervalSince1970: TimeInterval(timestamp.value)))
    }

    struct Entity: Decodable {
        let tripUpdate: TripUpdate?
        let isDeleted: Bool?
        enum CodingKeys: String, CodingKey { case tripUpdate = "trip_update", isDeleted = "is_deleted" }
    }

    struct TripUpdate: Decodable {
        let trip: Descriptor
        let stopTimeUpdates: [StopTimeUpdate]?
        let delay: Int?
        enum CodingKeys: String, CodingKey {
            case trip, delay, stopTimeUpdates = "stop_time_update"
        }
    }

    struct Descriptor: Decodable {
        let tripID: String
        let startDate: String?
        let scheduleRelationship: String?
        enum CodingKeys: String, CodingKey {
            case tripID = "trip_id", startDate = "start_date", scheduleRelationship = "schedule_relationship"
        }
    }

    struct StopTimeUpdate: Decodable {
        let sequence: Int?
        let stopID: String?
        let arrival: StopEvent?
        let departure: StopEvent?
        let scheduleRelationship: String?
        enum CodingKeys: String, CodingKey {
            case sequence = "stop_sequence", stopID = "stop_id", arrival, departure,
                 scheduleRelationship = "schedule_relationship"
        }
    }

    struct StopEvent: Decodable {
        let delay: Int?
        let time: EpochSeconds?
    }

    func delayInfo(
        for trip: Trip,
        serviceDate: Date,
        scheduleProvider: TripScheduleProviding = GTFSDataSource.shared
    ) -> DelayInfo? {
        guard trip.gtfsTripId == tripID else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = GTFSDataSource.calendar
        formatter.timeZone = GTFSDataSource.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let serviceDay = formatter.string(from: serviceDate)
        guard let fetched = observedAt,
              let live = entities.filter({ $0.isDeleted != true }).compactMap(\.tripUpdate).last(where: {
                  $0.trip.tripID == tripID &&
                  ($0.trip.startDate ?? formatter.string(from: fetched)) == serviceDay
              }), live.trip.scheduleRelationship != "CANCELED", live.trip.scheduleRelationship != "DELETED" else { return nil }
        let stops = (trip.stops?.isEmpty == false ? trip.stops! : GTFSDataSource.shared.stops(for: tripID).map(StoredStop.init(gtfsStop:)))
            .sorted { $0.sequence < $1.sequence }
        func stop(for update: StopTimeUpdate) -> StoredStop? {
            if let sequence = update.sequence { return stops.first { $0.sequence == sequence } }
            return stops.first { $0.id == update.stopID }
        }
        let updates = (live.stopTimeUpdates ?? []).compactMap { update -> (sequence: Int, update: StopTimeUpdate)? in
            guard update.scheduleRelationship != "SKIPPED",
                  let sequence = update.sequence ?? stop(for: update)?.sequence else { return nil }
            return (sequence, update)
        }.sorted { $0.sequence < $1.sequence }
        let baseDate = GTFSDataSource.calendar.startOfDay(for: serviceDate)
        func seconds(_ event: StopEvent?, for update: StopTimeUpdate, arrival: Bool) -> Int? {
            if let delay = event?.delay { return delay }
            guard let predicted = event?.time, let stop = stop(for: update),
                  let schedule = scheduleProvider.stopSchedule(for: tripID, stopId: stop.id),
                  let scheduled = arrival ? schedule.arrivalSeconds : schedule.departureSeconds else { return nil }
            return Int((TimeInterval(predicted.value) - baseDate.addingTimeInterval(TimeInterval(scheduled)).timeIntervalSince1970).rounded())
        }
        func minutes(_ value: Int?) -> Int? { value.map { Int((Double($0) / 60).rounded()) } }
        var carriedDelay = live.delay
        var updateIndex = 0
        var delaysBySequence: [Int: StationDelay] = [:]
        let stationDelays = stops.compactMap { stop -> StationDelay? in
            // GTFS-RT may omit unchanged stops. Carry an update forward only;
            // a delay later in the route must never rewrite earlier stops.
            while updateIndex < updates.count, updates[updateIndex].sequence < stop.sequence {
                let update = updates[updateIndex].update
                carriedDelay = update.scheduleRelationship == "NO_DATA" ? nil :
                    seconds(update.departure, for: update, arrival: false) ?? seconds(update.arrival, for: update, arrival: true) ?? carriedDelay
                updateIndex += 1
            }
            var arrival = carriedDelay
            var departure = carriedDelay
            if updateIndex < updates.count, updates[updateIndex].sequence == stop.sequence {
                let update = updates[updateIndex].update
                if update.scheduleRelationship == "NO_DATA" {
                    arrival = nil
                    departure = nil
                } else {
                    arrival = seconds(update.arrival, for: update, arrival: true) ?? carriedDelay
                    departure = seconds(update.departure, for: update, arrival: false) ?? arrival
                }
                updateIndex += 1
            }
            carriedDelay = departure
            guard arrival != nil || departure != nil else { return nil }
            let delay = StationDelay(stationName: stop.name, arrivalDelayMinutes: minutes(arrival),
                                     departureDelayMinutes: minutes(departure), platform: nil)
            delaysBySequence[stop.sequence] = delay
            return delay
        }
        let destination = trip.destinationSequence.flatMap { delaysBySequence[$0] }
            ?? stationDelays.first { $0.stationName == trip.destinationName }
        let headline = destination?.arrivalDelayMinutes ?? minutes(live.delay)
        guard headline != nil || !stationDelays.isEmpty else { return nil }
        return DelayInfo(
            delayMinutes: headline,
            platform: nil,
            stationDelays: stationDelays,
            fetchedAt: fetched
        )
    }
}
