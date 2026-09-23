import Foundation
import SQLite3

struct GTFSStop: Identifiable, Equatable {
    let id: String
    let name: String
    let sequence: Int
    let latitude: Double
    let longitude: Double
}

struct GTFSSegment: Identifiable, Equatable {
    let id: Int
    let startId: String
    let startName: String?
    let endId: String
    let endName: String?
    let departureSeconds: Int?
    let arrivalSeconds: Int?
    let maxSpeed: Int
    let trainLengthMeters: Int?
    let trainTonnage: Int?
}

struct TrainDelayHistory: Equatable {
    let trainNumber: String
    let observedTrips: Int
    let delayedTrips: Int
    let averageDelayMinutes: Double
    let percentEarly: Double
    let percentOnTime: Double
    let percentDelay15Minutes: Double
    let percentDelay30Minutes: Double
    let percentDelay45MinutesPlus: Double
}

extension GTFSDataSource {
    struct AgencyInfo {
        let id: String
        let name: String
        let url: String?
        let timezone: String?
    }
}

extension GTFSDataSource.GTFSStopSchedule {
    func arrivalDate(on baseDate: Date) -> Date? {
        guard let arrivalSeconds else { return nil }
        return baseDate.addingTimeInterval(TimeInterval(arrivalSeconds))
    }

    func departureDate(on baseDate: Date) -> Date? {
        guard let departureSeconds else { return nil }
        return baseDate.addingTimeInterval(TimeInterval(departureSeconds))
    }
}

// Database work must not inherit the app's default MainActor isolation.
// Callers can safely use this source from the background search queue while
// the UI remains responsive.
nonisolated final class GTFSDataSource {
    static let shared = GTFSDataSource()

    private var database: OpaquePointer?
    // Search runs on a separate connection because the rest of the data
    // source uses `database` for map/timing reads on the app's main actor.
    private var searchDatabase: OpaquePointer?
    private let searchQueue = DispatchQueue(label: "ro.openlabs.blitz.gtfs-search")
    private let searchLimit = 25
    private var agenciesById: [String: AgencyInfo] = [:]
    private let cacheLock = NSLock()
    private var stopsCache: [String: [GTFSStop]] = [:]
    private var polylineStopsCache: [String: [GTFSStop]] = [:]
    private var segmentsCache: [String: [GTFSSegment]] = [:]
    private var scheduleCache: [String: GTFSStopSchedule?] = [:]
    private var delayHistoryCache: [String: TrainDelayHistory?] = [:]

    private init() {
        openDatabase()
        openSearchDatabase()
        loadAgencies()
    }

    deinit {
        sqlite3_close(database)
        sqlite3_close(searchDatabase)
    }

    func searchTrips(matching query: String, limit: Int? = nil, travelDate: Date? = nil) -> [Trip] {
        searchQueue.sync {
            searchTripsOnSearchConnection(matching: query, limit: limit, travelDate: travelDate)
        }
    }

    /// Warms the static route cache without requiring a view to perform the
    /// first map lookup synchronously during body evaluation.
    func preloadRouteData(for tripId: String) {
        _ = segments(for: tripId)
        _ = stops(for: tripId)
        _ = polylineStops(for: tripId)
    }

    /// Returns the bundled 60-day delay summary for a train, when the
    /// optional train_delays table is present in the shipped database.
    func delayHistory(for trainNumber: String) -> TrainDelayHistory? {
        cacheLock.lock()
        if let cached = delayHistoryCache[trainNumber] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let result = loadDelayHistory(for: trainNumber)
        cacheLock.lock()
        delayHistoryCache[trainNumber] = result
        cacheLock.unlock()
        return result
    }

    private func loadDelayHistory(for trainNumber: String) -> TrainDelayHistory? {
        guard let database else { return nil }
        let sql = """
        SELECT train_number, observed_trips, delayed_trips,
               avg_delay_minutes, pct_early, pct_on_time,
               pct_delay_15m, pct_delay_30m, pct_delay_45m_plus
        FROM train_delays
        WHERE train_number = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, trainNumber, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let numberPointer = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return TrainDelayHistory(
            trainNumber: String(cString: numberPointer),
            observedTrips: Int(sqlite3_column_int(statement, 1)),
            delayedTrips: Int(sqlite3_column_int(statement, 2)),
            averageDelayMinutes: sqlite3_column_double(statement, 3),
            percentEarly: sqlite3_column_double(statement, 4),
            percentOnTime: sqlite3_column_double(statement, 5),
            percentDelay15Minutes: sqlite3_column_double(statement, 6),
            percentDelay30Minutes: sqlite3_column_double(statement, 7),
            percentDelay45MinutesPlus: sqlite3_column_double(statement, 8)
        )
    }

    /// Returns bundled-schedule departures from a station after the supplied
    /// time. This is intentionally local and synchronous so missed-train
    /// recovery still works without InfoFer connectivity.
    func departures(from stationID: String, after date: Date, excluding trainID: String? = nil, destinationStationID: String? = nil, limit: Int = 8) -> [Trip] {
        guard let database else { return [] }
        let calendar = Calendar.current
        let sql = """
        SELECT DISTINCT first.train_number,
               trains.category,
               trains.operator_id,
               destination.uic_code,
               destination.name,
               first.departure_time
        FROM trip_segments first
        INNER JOIN trains ON trains.train_number = first.train_number
        LEFT JOIN trip_segments last ON last.train_number = first.train_number
            AND last.sequence_id = (
                SELECT MAX(candidate.sequence_id)
                FROM trip_segments candidate
                WHERE candidate.train_number = first.train_number
            )
        LEFT JOIN stations destination ON destination.uic_code = last.uic_end
        WHERE first.uic_start = ?
          AND first.departure_time IS NOT NULL
          \(destinationStationID == nil ? "" : "AND last.uic_end = ?")
        ORDER BY first.departure_time ASC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare departures query")
            return []
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, stationID, -1, transient)
        var limitBindingIndex: Int32 = 2
        if let destinationStationID {
            sqlite3_bind_text(statement, 2, destinationStationID, -1, transient)
            limitBindingIndex = 3
        }
        // Fetch a broad window before applying the time filter below. The
        // query is ordered for the full service day, so a small SQL limit can
        // contain only already-departed trains when the user searches later.
        sqlite3_bind_int(statement, limitBindingIndex, Int32(max(limit * 20, 200)))

        var departures: [Trip] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let numberPointer = sqlite3_column_text(statement, 0) else { continue }
            let trainNumber = String(cString: numberPointer)
            if trainNumber == trainID { continue }
            guard let departureSeconds = sqlite3_column_text(statement, 5).flatMap({
                parseTimeSeconds(String(cString: $0))
            }) else { continue }
            let stops = self.stops(for: trainNumber)

            // A stop after midnight is still part of the previous GTFS
            // service. Compare the normalized wall-clock date, rather than
            // raw seconds after midnight, so a 26:00 stop is not mistaken for
            // the following day's 02:00 service.
            let scheduleTimes = stops.map { stop in
                let schedule = stopSchedule(for: trainNumber, stopId: stop.id)
                return schedule?.departureSeconds ?? schedule?.arrivalSeconds
            }
            let stationIndex = stops.firstIndex(where: { $0.id == stationID }) ?? 0
            let serviceDayOffset = ScheduleDateUtils.serviceDayOffset(for: scheduleTimes, through: stationIndex)
            let serviceDate = ScheduleDateUtils.serviceDate(
                forBoardingDate: date,
                dayOffset: serviceDayOffset,
                calendar: calendar
            )
            let departureDate = serviceDate.addingTimeInterval(TimeInterval(departureSeconds))
            guard departureDate > date else { continue }

            let category = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let agencyID = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let destinationID = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let destinationName = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let originSequence = stops.first(where: { $0.id == stationID })?.sequence
            let destinationSequence = destinationID.flatMap { id in stops.first(where: { $0.id == id })?.sequence }
            let travelDate = serviceDate
            let title = formattedTrainTitle(category: category, number: trainNumber)
            departures.append(Trip(
                id: "\(trainNumber)-\(stationID)-\(Int(date.timeIntervalSince1970))",
                title: title,
                subtitle: routeDescription(origin: stops.first(where: { $0.id == stationID })?.name, destination: destinationName) ?? "Route info unavailable",
                agencyId: agencyID,
                detailRoute: routeDescription(origin: stops.first(where: { $0.id == stationID })?.name, destination: destinationName),
                gtfsTripId: trainNumber,
                travelDate: travelDate,
                originStopId: stationID,
                originName: stops.first(where: { $0.id == stationID })?.name,
                destinationStopId: destinationID,
                destinationName: destinationName,
                stops: stops.map(StoredStop.init(gtfsStop:)),
                originSequence: originSequence,
                destinationSequence: destinationSequence,
                trainType: category.flatMap { TrainType(categoryCode: $0) }
            ))
            if departures.count >= limit { break }
        }
        return departures
    }

    private func searchTripsOnSearchConnection(matching query: String, limit: Int? = nil, travelDate: Date? = nil) -> [Trip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let database = searchDatabase else { return [] }

        let fetchLimit = Int32(limit ?? searchLimit)
        let sql = """
        WITH matched_trains AS (
            SELECT train_number
            FROM trains
            WHERE train_number LIKE ? OR train_number LIKE ?

            UNION

            SELECT DISTINCT ts.train_number
            FROM trip_segments ts
            INNER JOIN stations station ON station.uic_code = ts.uic_start OR station.uic_code = ts.uic_end
            WHERE COALESCE(station.search_index, '') LIKE ?
        ), first_segment AS (
            SELECT ts.train_number, ts.uic_start, ts.train_length_meters, ts.train_tonnage
            FROM trip_segments ts
            INNER JOIN matched_trains matched ON matched.train_number = ts.train_number
            WHERE ts.sequence_id = (
                SELECT MIN(first.sequence_id)
                FROM trip_segments first
                WHERE first.train_number = ts.train_number
            )
        ), last_segment AS (
            SELECT ts.train_number, ts.uic_end
            FROM trip_segments ts
            INNER JOIN matched_trains matched ON matched.train_number = ts.train_number
            WHERE ts.sequence_id = (
                SELECT MAX(last.sequence_id)
                FROM trip_segments last
                WHERE last.train_number = ts.train_number
            )
        )
        SELECT DISTINCT t.train_number,
               t.category,
               t.operator_id,
               origin.name AS origin_name,
               destination.name AS destination_name,
               fs.train_length_meters,
               fs.train_tonnage
        FROM trains t
        LEFT JOIN first_segment fs ON fs.train_number = t.train_number
        LEFT JOIN stations origin ON origin.uic_code = fs.uic_start
        LEFT JOIN last_segment ls ON ls.train_number = t.train_number
        LEFT JOIN stations destination ON destination.uic_code = ls.uic_end
        INNER JOIN matched_trains matched ON matched.train_number = t.train_number
        ORDER BY t.train_number ASC
        LIMIT ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare statement")
            return []
        }
        defer { sqlite3_finalize(statement) }

        // A prefix search uses the train-number index while the user is typing.
        // Keep the contains pattern as a fallback for station/name searches and
        // for numbers that are not stored with the exact formatting entered.
        let pattern = "%\(trimmed)%"
        let numericQuery = trimmed.filter { $0.isNumber }
        let numericPattern = numericQuery.isEmpty ? pattern : "\(numericQuery)%"
        var normalizedQuery = normalizedSearchQuery(trimmed)
        if normalizedQuery.isEmpty {
            normalizedQuery = trimmed.lowercased()
        }
        let normalizedPattern = "%\(normalizedQuery)%"
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, numericPattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, normalizedPattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 4, fetchLimit)

        var trips: [Trip] = []
        var seenTrainNumbers = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let numberPointer = sqlite3_column_text(statement, 0) else { continue }
            let trainNumber = String(cString: numberPointer)
            // A train number can have multiple segment chains in the static
            // data. Trip currently uses the train number as its identity, so
            // return one representative result per number to keep SwiftUI IDs
            // stable.
            guard seenTrainNumbers.insert(trainNumber).inserted else { continue }
            let category: String?
            if let categoryPointer = sqlite3_column_text(statement, 1) {
                let raw = String(cString: categoryPointer).trimmingCharacters(in: .whitespacesAndNewlines)
                category = raw.isEmpty ? nil : raw
            } else {
                category = nil
            }
            let agencyId: String?
            if let agencyPointer = sqlite3_column_text(statement, 2) {
                let raw = String(cString: agencyPointer).trimmingCharacters(in: .whitespacesAndNewlines)
                agencyId = raw.isEmpty ? nil : raw
            } else {
                agencyId = nil
            }
            let originName: String?
            if let originPointer = sqlite3_column_text(statement, 3) {
                let raw = String(cString: originPointer).trimmingCharacters(in: .whitespacesAndNewlines)
                originName = raw.isEmpty ? nil : raw
            } else {
                originName = nil
            }
            let destinationName: String?
            if let destinationPointer = sqlite3_column_text(statement, 4) {
                let raw = String(cString: destinationPointer).trimmingCharacters(in: .whitespacesAndNewlines)
                destinationName = raw.isEmpty ? nil : raw
            } else {
                destinationName = nil
            }
            let lengthMeters: Int?
            if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                lengthMeters = nil
            } else {
                lengthMeters = Int(sqlite3_column_int(statement, 5))
            }

            let tonnageValue: Int?
            if sqlite3_column_type(statement, 6) == SQLITE_NULL {
                tonnageValue = nil
            } else {
                tonnageValue = Int(sqlite3_column_int(statement, 6))
            }

            let routeName = routeDescription(origin: originName, destination: destinationName)
            let subtitle = routeName ?? "Route info unavailable"
            let displayTitle = formattedTrainTitle(category: category, number: trainNumber)
            let trainType = category.flatMap { TrainType(categoryCode: $0) }
            let lengthText = formattedTrainLength(meters: lengthMeters)
            let tonnageText = formattedTrainTonnage(tons: tonnageValue)
            let routeStops = stops(for: trainNumber)
            let originStop = routeStops.first
            let destinationStop = routeStops.last
            let selectedTravelDate = travelDate.map { Calendar.current.startOfDay(for: $0) }
            trips.append(
                Trip(
                    id: trainNumber,
                    title: displayTitle,
                    subtitle: subtitle,
                    agencyId: agencyId,
                    detailRoute: routeName,
                    gtfsTripId: trainNumber,
                    travelDate: selectedTravelDate,
                    originStopId: originStop?.id,
                    originName: originStop?.name ?? originName,
                    destinationStopId: destinationStop?.id,
                    destinationName: destinationStop?.name ?? destinationName,
                    stops: routeStops.map(StoredStop.init(gtfsStop:)),
                    originSequence: originStop?.sequence,
                    destinationSequence: destinationStop?.sequence,
                    trainType: trainType,
                    trainLength: lengthText,
                    trainTonnage: tonnageText
                )
            )
        }

        return trips
    }

    func randomTrip() -> Trip? {
        guard let database else { return nil }
        let sql = """
        WITH first_segment AS (
            SELECT ts.train_number, ts.sequence_id, ts.uic_start, ts.train_length_meters, ts.train_tonnage
            FROM trip_segments ts
            INNER JOIN (
                SELECT train_number, MIN(sequence_id) AS min_sequence
                FROM trip_segments
                GROUP BY train_number
            ) grouped ON grouped.train_number = ts.train_number AND grouped.min_sequence = ts.sequence_id
        ), last_segment AS (
            SELECT ts.train_number, ts.sequence_id, ts.uic_end
            FROM trip_segments ts
            INNER JOIN (
                SELECT train_number, MAX(sequence_id) AS max_sequence
                FROM trip_segments
                GROUP BY train_number
            ) grouped ON grouped.train_number = ts.train_number AND grouped.max_sequence = ts.sequence_id
        )
        SELECT t.train_number,
               t.category,
               t.operator_id,
               origin.name AS origin_name,
               destination.name AS destination_name,
               fs.train_length_meters,
               fs.train_tonnage
        FROM trains t
        LEFT JOIN first_segment fs ON fs.train_number = t.train_number
        LEFT JOIN stations origin ON origin.uic_code = fs.uic_start
        LEFT JOIN last_segment ls ON ls.train_number = t.train_number
        LEFT JOIN stations destination ON destination.uic_code = ls.uic_end
        ORDER BY RANDOM()
        LIMIT 1
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare random trip query")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let trainNumber = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? UUID().uuidString

        let category: String?
        if let pointer = sqlite3_column_text(statement, 1) {
            let raw = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
            category = raw.isEmpty ? nil : raw
        } else {
            category = nil
        }

        let agencyId: String?
        if let pointer = sqlite3_column_text(statement, 2) {
            let raw = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
            agencyId = raw.isEmpty ? nil : raw
        } else {
            agencyId = nil
        }

        let originName: String?
        if let pointer = sqlite3_column_text(statement, 3) {
            let raw = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
            originName = raw.isEmpty ? nil : raw
        } else {
            originName = nil
        }

        let destinationName: String?
        if let pointer = sqlite3_column_text(statement, 4) {
            let raw = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
            destinationName = raw.isEmpty ? nil : raw
        } else {
            destinationName = nil
        }
        let lengthValue = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 5))
        let tonnageValue = sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 6))

        let routeName = routeDescription(origin: originName, destination: destinationName)
        let subtitle = routeName ?? "Route info unavailable"
        let displayTitle = formattedTrainTitle(category: category, number: trainNumber)
        let trainType = category.flatMap { TrainType(categoryCode: $0) }
        let lengthText = formattedTrainLength(meters: lengthValue)
        let tonnageText = formattedTrainTonnage(tons: tonnageValue)

        return Trip(
            id: trainNumber,
            title: displayTitle,
            subtitle: subtitle,
            agencyId: agencyId,
            detailRoute: routeName,
            gtfsTripId: trainNumber,
            trainType: trainType,
            trainLength: lengthText,
            trainTonnage: tonnageText
        )
    }

    func agencyInfo(for id: String?) -> AgencyInfo? {
        guard let id else { return nil }
        if agenciesById.isEmpty {
            loadAgencies()
        }
        return agenciesById[id]
    }

    func stops(for tripId: String) -> [GTFSStop] {
        cacheLock.lock()
        if let cached = stopsCache[tripId] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let startedAt = Date()
        let result = loadStops(for: tripId)
#if DEBUG
        logSlowCacheMiss("stops", tripId: tripId, startedAt: startedAt)
#endif
        cacheLock.lock()
        stopsCache[tripId] = result
        cacheLock.unlock()
        return result
    }

    private func loadStops(for tripId: String) -> [GTFSStop] {
        guard let database else { return [] }
        let sql = """
        SELECT
            trip_segments.sequence_id,
            trip_segments.uic_start,
            trip_segments.uic_end,
            trip_segments.duration_stop_seconds,
            origin.name,
            origin.lat,
            origin.lon,
            destination.name,
            destination.lat,
            destination.lon
        FROM trip_segments
        LEFT JOIN stations origin ON origin.uic_code = trip_segments.uic_start
        LEFT JOIN stations destination ON destination.uic_code = trip_segments.uic_end
        WHERE trip_segments.train_number = ?
        ORDER BY trip_segments.sequence_id ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare stops query")
            return []
        }
        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, tripId, -1, SQLITE_TRANSIENT)

        var stops: [GTFSStop] = []
        var appendedStationIds = Set<String>()
        var sequenceCounter = 1
        var appendedOrigin = false
        var lastDestination: StopInfo?

        while sqlite3_step(statement) == SQLITE_ROW {
            let duration = sqlite3_column_int(statement, 3)
            let originInfo = extractStopInfo(
                from: statement,
                idColumn: 1,
                nameColumn: 4,
                latColumn: 5,
                lonColumn: 6
            )
            let destinationInfo = extractStopInfo(
                from: statement,
                idColumn: 2,
                nameColumn: 7,
                latColumn: 8,
                lonColumn: 9
            )

            if !appendedOrigin, let origin = originInfo {
                append(origin, to: &stops, appendedIds: &appendedStationIds, sequence: &sequenceCounter)
                appendedOrigin = true
            }

            if duration > 0, let origin = originInfo {
                append(origin, to: &stops, appendedIds: &appendedStationIds, sequence: &sequenceCounter)
            }

            if let destinationInfo {
                lastDestination = destinationInfo
            }
        }

        if let finalStop = lastDestination {
            append(finalStop, to: &stops, appendedIds: &appendedStationIds, sequence: &sequenceCounter)
        }

        return stops
    }

    func polylineStops(for tripId: String) -> [GTFSStop] {
        cacheLock.lock()
        if let cached = polylineStopsCache[tripId] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let startedAt = Date()
        let result = loadPolylineStops(for: tripId)
#if DEBUG
        logSlowCacheMiss("polyline stops", tripId: tripId, startedAt: startedAt)
#endif
        cacheLock.lock()
        polylineStopsCache[tripId] = result
        cacheLock.unlock()
        return result
    }

    private func loadPolylineStops(for tripId: String) -> [GTFSStop] {
        guard let database else { return [] }
        let sql = """
        SELECT
            trip_segments.uic_start,
            trip_segments.uic_end,
            origin.name,
            origin.lat,
            origin.lon,
            destination.name,
            destination.lat,
            destination.lon
        FROM trip_segments
        LEFT JOIN stations origin ON origin.uic_code = trip_segments.uic_start
        LEFT JOIN stations destination ON destination.uic_code = trip_segments.uic_end
        WHERE trip_segments.train_number = ?
        ORDER BY trip_segments.sequence_id ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare polyline stops query")
            return []
        }
        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, tripId, -1, SQLITE_TRANSIENT)

        var stops: [GTFSStop] = []
        var appendedStationIds = Set<String>()
        var sequenceCounter = 1

        while sqlite3_step(statement) == SQLITE_ROW {
            if let origin = extractStopInfo(
                from: statement,
                idColumn: 0,
                nameColumn: 2,
                latColumn: 3,
                lonColumn: 4
            ) {
                append(origin, to: &stops, appendedIds: &appendedStationIds, sequence: &sequenceCounter)
            }

            if let destination = extractStopInfo(
                from: statement,
                idColumn: 1,
                nameColumn: 5,
                latColumn: 6,
                lonColumn: 7
            ) {
                append(destination, to: &stops, appendedIds: &appendedStationIds, sequence: &sequenceCounter)
            }
        }

        return stops
    }

    func segments(for tripId: String) -> [GTFSSegment] {
        cacheLock.lock()
        if let cached = segmentsCache[tripId] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let startedAt = Date()
        let result = loadSegments(for: tripId)
#if DEBUG
        logSlowCacheMiss("segments", tripId: tripId, startedAt: startedAt)
#endif
        cacheLock.lock()
        segmentsCache[tripId] = result
        cacheLock.unlock()
        return result
    }

    private func loadSegments(for tripId: String) -> [GTFSSegment] {
        guard let database else { return [] }
        let sql = """
        SELECT
            trip_segments.sequence_id,
            trip_segments.uic_start,
            trip_segments.uic_end,
            trip_segments.departure_time,
            trip_segments.arrival_time,
            trip_segments.max_speed_kmh,
            trip_segments.train_length_meters,
            trip_segments.train_tonnage,
            origin.name,
            destination.name
        FROM trip_segments
        LEFT JOIN stations origin ON origin.uic_code = trip_segments.uic_start
        LEFT JOIN stations destination ON destination.uic_code = trip_segments.uic_end
        WHERE trip_segments.train_number = ?
        ORDER BY trip_segments.sequence_id ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare segments query")
            return []
        }
        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, tripId, -1, SQLITE_TRANSIENT)

        var segments: [GTFSSegment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let sequence = Int(sqlite3_column_int(statement, 0))
            guard
                let startPointer = sqlite3_column_text(statement, 1),
                let endPointer = sqlite3_column_text(statement, 2)
            else { continue }

            let startId = String(cString: startPointer)
            let endId = String(cString: endPointer)
            let departureSeconds = sqlite3_column_text(statement, 3).flatMap { parseTimeSeconds(String(cString: $0)) }
            let arrivalSeconds = sqlite3_column_text(statement, 4).flatMap { parseTimeSeconds(String(cString: $0)) }
            let maxSpeed: Int
            if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                maxSpeed = 0
            } else {
                maxSpeed = Int(sqlite3_column_int(statement, 5))
            }
            let lengthValue: Int?
            if sqlite3_column_type(statement, 6) == SQLITE_NULL {
                lengthValue = nil
            } else {
                lengthValue = Int(sqlite3_column_int(statement, 6))
            }

            let tonnageValue: Int?
            if sqlite3_column_type(statement, 7) == SQLITE_NULL {
                tonnageValue = nil
            } else {
                tonnageValue = Int(sqlite3_column_int(statement, 7))
            }

            let startName = sqlite3_column_text(statement, 8).map { String(cString: $0) }
            let endName = sqlite3_column_text(statement, 9).map { String(cString: $0) }

            let segment = GTFSSegment(
                id: sequence,
                startId: startId,
                startName: startName,
                endId: endId,
                endName: endName,
                departureSeconds: departureSeconds,
                arrivalSeconds: arrivalSeconds,
                maxSpeed: maxSpeed,
                trainLengthMeters: lengthValue,
                trainTonnage: tonnageValue
            )
            segments.append(segment)
        }

        return segments
    }

    struct GTFSStopSchedule {
        let arrivalSeconds: Int?
        let departureSeconds: Int?
    }

    func stopSchedule(for tripId: String, stopId: String) -> GTFSStopSchedule? {
        let key = "\(tripId)|\(stopId)"
        cacheLock.lock()
        if let cached = scheduleCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let startedAt = Date()
        let result = loadStopSchedule(for: tripId, stopId: stopId)
#if DEBUG
        logSlowCacheMiss("schedule \(stopId)", tripId: tripId, startedAt: startedAt)
#endif
        cacheLock.lock()
        scheduleCache[key] = result
        cacheLock.unlock()
        return result
    }

    func stopSchedules(for tripId: String, stopIds: [String]) -> [String: GTFSStopSchedule] {
        let uniqueStopIDs = Array(Set(stopIds))
        guard !uniqueStopIDs.isEmpty, let database else { return [:] }

        var cached: [String: GTFSStopSchedule] = [:]
        var missing: [String] = []
        cacheLock.lock()
        for stopID in uniqueStopIDs {
            let key = "\(tripId)|\(stopID)"
            if let schedule = scheduleCache[key] {
                if let schedule { cached[stopID] = schedule }
            } else {
                missing.append(stopID)
            }
        }
        cacheLock.unlock()
        guard !missing.isEmpty else { return cached }

        let placeholders = Array(repeating: "?", count: missing.count).joined(separator: ",")
        let sql = """
        SELECT stop_id, MIN(arrival_time), MIN(departure_time)
        FROM (
            SELECT uic_end AS stop_id, arrival_time, NULL AS departure_time
            FROM trip_segments
            WHERE train_number = ? AND uic_end IN (\(placeholders))
            UNION ALL
            SELECT uic_start AS stop_id, NULL AS arrival_time, departure_time
            FROM trip_segments
            WHERE train_number = ? AND uic_start IN (\(placeholders))
        )
        GROUP BY stop_id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare bulk stop schedule query")
            return cached
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var index: Int32 = 1
        sqlite3_bind_text(statement, index, tripId, -1, transient)
        index += 1
        for stopID in missing {
            sqlite3_bind_text(statement, index, stopID, -1, transient)
            index += 1
        }
        sqlite3_bind_text(statement, index, tripId, -1, transient)
        index += 1
        for stopID in missing {
            sqlite3_bind_text(statement, index, stopID, -1, transient)
            index += 1
        }

        var loaded: [String: GTFSStopSchedule] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let stopPointer = sqlite3_column_text(statement, 0) else { continue }
            let stopID = String(cString: stopPointer)
            let arrival = sqlite3_column_text(statement, 1).flatMap {
                parseTimeSeconds(String(cString: $0))
            }
            let departure = sqlite3_column_text(statement, 2).flatMap {
                parseTimeSeconds(String(cString: $0))
            }
            guard arrival != nil || departure != nil else { continue }
            loaded[stopID] = GTFSStopSchedule(arrivalSeconds: arrival, departureSeconds: departure)
        }

        cacheLock.lock()
        for stopID in missing {
            let key = "\(tripId)|\(stopID)"
            scheduleCache[key] = loaded[stopID]
        }
        cacheLock.unlock()
        cached.merge(loaded) { _, new in new }
        return cached
    }

    private func loadStopSchedule(for tripId: String, stopId: String) -> GTFSStopSchedule? {
        guard let database else { return nil }
        let sql = """
        SELECT
            (
                SELECT arrival_time
                FROM trip_segments
                WHERE train_number = ? AND uic_end = ?
                ORDER BY sequence_id ASC
                LIMIT 1
            ) AS arrival_time,
            (
                SELECT departure_time
                FROM trip_segments
                WHERE train_number = ? AND uic_start = ?
                ORDER BY sequence_id ASC
                LIMIT 1
            ) AS departure_time
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare stop schedule query")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, tripId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, stopId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, tripId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, stopId, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let arrivalSeconds = sqlite3_column_text(statement, 0).flatMap { parseTimeSeconds(String(cString: $0)) }
        let departureSeconds = sqlite3_column_text(statement, 1).flatMap { parseTimeSeconds(String(cString: $0)) }

        if arrivalSeconds == nil && departureSeconds == nil {
            return nil
        }

        return GTFSStopSchedule(arrivalSeconds: arrivalSeconds, departureSeconds: departureSeconds)
    }

    private func parseTimeSeconds(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var working = trimmed
        var dayComponent: Int = 0

        if let range = working.range(of: "day") ?? working.range(of: "days") {
            let prefix = working[..<range.lowerBound]
            if let days = Int(prefix.trimmingCharacters(in: .whitespaces)) {
                dayComponent = days
            }
            if let commaRange = working.range(of: ",") {
                working = String(working[commaRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                let suffixRange = working.range(of: " ", options: [], range: range.upperBound..<working.endIndex)
                if let suffixRange {
                    working = String(working[suffixRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    working = ""
                }
            }
        }

        let parts = working.split(separator: ":")
        guard parts.count == 3,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]),
              let seconds = Int(parts[2])
        else { return dayComponent > 0 ? dayComponent * 24 * 3600 : nil }

        let baseSeconds = hours * 3600 + minutes * 60 + seconds
        return baseSeconds + dayComponent * 24 * 3600
    }

#if DEBUG
    private func logSlowCacheMiss(_ resource: String, tripId: String, startedAt: Date) {
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed >= 0.05 else { return }
        print("[GTFSDataSource] slow cache miss \(resource) for \(tripId): \(Int(elapsed * 1000))ms")
    }
#endif

    private struct StopInfo {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
    }

    private func extractStopInfo(
        from statement: OpaquePointer?,
        idColumn: Int32,
        nameColumn: Int32,
        latColumn: Int32,
        lonColumn: Int32
    ) -> StopInfo? {
        guard
            let idPointer = sqlite3_column_text(statement, idColumn),
            let namePointer = sqlite3_column_text(statement, nameColumn)
        else { return nil }

        let identifier = String(cString: idPointer).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(cString: namePointer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !name.isEmpty else { return nil }

        guard sqlite3_column_type(statement, latColumn) != SQLITE_NULL,
              sqlite3_column_type(statement, lonColumn) != SQLITE_NULL else { return nil }

        return StopInfo(
            id: identifier,
            name: name,
            latitude: sqlite3_column_double(statement, latColumn),
            longitude: sqlite3_column_double(statement, lonColumn)
        )
    }

    private func append(
        _ info: StopInfo,
        to stops: inout [GTFSStop],
        appendedIds: inout Set<String>,
        sequence: inout Int
    ) {
        guard !appendedIds.contains(info.id) else { return }
        stops.append(
            GTFSStop(
                id: info.id,
                name: info.name,
                sequence: sequence,
                latitude: info.latitude,
                longitude: info.longitude
            )
        )
        appendedIds.insert(info.id)
        sequence += 1
    }

    private func normalizedSearchQuery(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func formattedTrainTitle(category: String?, number: String) -> String {
        guard let category = category?.trimmingCharacters(in: .whitespacesAndNewlines), !category.isEmpty else {
            return number
        }
        return "\(category) \(number)"
    }

    private func formattedTrainLength(meters: Int?) -> String? {
        guard let meters, meters > 0 else { return nil }
        return "\(meters) m"
    }

    private func formattedTrainTonnage(tons: Int?) -> String? {
        guard let tons, tons > 0 else { return nil }
        return "\(tons) t"
    }

    private func routeDescription(origin: String?, destination: String?) -> String? {
        let sanitizedOrigin = sanitizedStationName(origin)
        let sanitizedDestination = sanitizedStationName(destination)

        if let origin = sanitizedOrigin, let destination = sanitizedDestination {
            return "\(origin) → \(destination)"
        }

        return sanitizedOrigin ?? sanitizedDestination
    }

    private func sanitizedStationName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func openDatabase() {
        guard database == nil else { return }
        guard let url = locateDatabaseURL() else {
            logError("Unable to locate static_data.sqlite")
            return
        }

        if sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            logError("Unable to open static_data.sqlite at \(url.path)")
            sqlite3_close(database)
            database = nil
        }
    }

    private func openSearchDatabase() {
        guard searchDatabase == nil, let url = locateDatabaseURL() else { return }

        if sqlite3_open_v2(url.path, &searchDatabase, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            logError("Unable to open search connection for static_data.sqlite at \(url.path)")
            sqlite3_close(searchDatabase)
            searchDatabase = nil
        }
    }

    private func loadAgencies() {
        guard let database, agenciesById.isEmpty else { return }
        let sql = "SELECT agency_id, agency_name, agency_url, agency_timezone FROM agencies"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare agencies query")
            return
        }
        defer { sqlite3_finalize(statement) }

        var lookup: [String: AgencyInfo] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idPointer)
            let name: String
            if let namePointer = sqlite3_column_text(statement, 1) {
                let raw = String(cString: namePointer).trimmingCharacters(in: .whitespacesAndNewlines)
                name = raw.isEmpty ? "Operator" : raw
            } else {
                name = "Operator"
            }
            let rawURL = sqlite3_column_text(statement, 2).map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            let urlString = rawURL?.isEmpty == false ? rawURL : nil
            let rawTimezone = sqlite3_column_text(statement, 3).map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            let timezone = rawTimezone?.isEmpty == false ? rawTimezone : nil
            lookup[id] = AgencyInfo(id: id, name: name, url: urlString, timezone: timezone)
        }

        agenciesById = lookup
    }

    private func locateDatabaseURL() -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "static_data", withExtension: "sqlite") {
            return bundleURL
        }
        #if DEBUG
        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidate = cwd.appendingPathComponent("blitz/static_data.sqlite")
        if fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        #endif
        return nil
    }

    private func logError(_ message: String) {
        #if DEBUG
        print("[GTFSDataSource] \(message)")
        #endif
    }
}
