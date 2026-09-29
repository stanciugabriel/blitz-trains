import Foundation
import SQLite3
import zlib

nonisolated struct GTFSStop: Identifiable, Equatable, Sendable {
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

// The Swiss feed is read directly; GTFS trip IDs, not train numbers, are identities.
// All SQLite work is serialized, with a separate connection for schedule search.
nonisolated final class GTFSDataSource: @unchecked Sendable {
    static let shared = GTFSDataSource()
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return calendar
    }

    private(set) var hasServiceCalendar = false
    private enum ExceptionMask {
        case missing
        case invalid
        case decoded(start: Date, days: Int, bytes: [UInt8])
    }
    private var exceptionMasks: [String: ExceptionMask] = [:]
    private var calendarTables = Set<String>()
    private var database: OpaquePointer?
    private var searchDatabase: OpaquePointer?
    private let readLock = NSRecursiveLock()
    private let searchQueue = DispatchQueue(label: "app.raily.sbb-search")
    private var routeCache: [String: [StopTime]] = [:]
    private var geometryCache: [String: GTFSRouteGeometry] = [:]
    private var supportsShapes = false
    private var transferTimeCache: [String: Int] = [:]
    private var headsignCache: [String: String] = [:]
    private var agenciesById: [String: AgencyInfo] = [:]

    // Injectable URL also lets tests exercise the actual adapter with a tiny GTFS fixture.
    init(databaseURL: URL? = nil) {
        guard let url = databaseURL ?? Self.locateDatabaseURL() else { return }
        database = Self.open(url)
        searchDatabase = Self.open(url)
        calendarTables = Set(rows("SELECT name FROM sqlite_master WHERE type = 'table'", on: database).compactMap { $0[0] })
        hasServiceCalendar = calendarTables.contains("calendar") || calendarTables.contains("calendar_dates") || calendarTables.contains("calendar_date_masks")
        let tripColumns = Set(rows("PRAGMA table_info(trips)", on: database).compactMap { $0[1] })
        let stopTimeColumns = Set(rows("PRAGMA table_info(stop_times)", on: database).compactMap { $0[1] })
        let shapeColumns = Set(rows("PRAGMA table_info(shapes)", on: database).compactMap { $0[1] })
        supportsShapes = tripColumns.contains("shape_id") && stopTimeColumns.contains("shape_dist_traveled") &&
            Set(["shape_id", "shape_pt_lat", "shape_pt_lon", "shape_pt_sequence", "shape_dist_traveled"]).isSubset(of: shapeColumns)
        for row in rows("SELECT agency_id, agency_name, agency_url, agency_timezone FROM agency", on: database) {
            guard let id = row[0], let name = row[1] else { continue }
            agenciesById[id] = AgencyInfo(id: id, name: name, url: row[2], timezone: row[3])
        }
    }

    deinit {
        sqlite3_close(database)
        sqlite3_close(searchDatabase)
    }

    private static func open(_ url: URL) -> OpaquePointer? {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            return nil
        }
        return connection
    }

    private static func locateDatabaseURL() -> URL? {
        if let url = Bundle.main.url(forResource: "mini_feed", withExtension: "sqlite") { return url }
        #if DEBUG
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("blitz/mini_feed.sqlite")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        #endif
        return nil
    }

    private func rows(_ sql: String, _ bindings: [String] = [], on connection: OpaquePointer?) -> [[String?]] {
        guard let connection else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            #if DEBUG
            print("[GTFSDataSource] \(String(cString: sqlite3_errmsg(connection)))")
            #endif
            return []
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var result: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            })
        }
        return result
    }

    func agencyInfo(for id: String?) -> AgencyInfo? {
        guard let id else { return nil }
        return agenciesById[id]
    }

    func stationUIC(for stopID: String?) -> String? {
        guard let stopID else { return nil }
        readLock.lock()
        defer { readLock.unlock() }
        return rows("SELECT didok FROM stops WHERE stop_id = ? OR parent_station = ? LIMIT 1", [stopID, stopID], on: database).first?[0]
    }

    enum SharedImportError: LocalizedError {
        case noMatch(String)
        var errorDescription: String? {
            switch self {
            case let .noMatch(service):
                return "The shared journey contains invalid trip information (\(service)). It has been kept for retry."
            }
        }
    }

    /// SBB's shared journey is authoritative. An exact static match can enrich
    /// it, but missing/stale GTFS must never prevent importing a valid leg.
    func importTrips(from journey: SharedJourney) throws -> [Trip] {
        readLock.lock()
        defer { readLock.unlock() }
        guard !journey.legs.isEmpty else { throw SharedImportError.noMatch("an empty journey") }
        let journeyID = journey.legs.map { leg in
            "\(leg.origin.id)>\(leg.destination.id)@\(Int(leg.departure.timeIntervalSince1970))"
        }.joined(separator: "|")
        return try journey.legs.map { leg in
            let parts = leg.service.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let number = parts.last, leg.arrival >= leg.departure,
                  !leg.origin.name.isEmpty, !leg.destination.name.isEmpty else {
                throw SharedImportError.noMatch(leg.service)
            }
            let line = parts.dropLast().joined().uppercased()
            let stableID = "sbb-import:\(line):\(number):\(leg.origin.id):\(leg.destination.id):\(Int(leg.departure.timeIntervalSince1970))"
            let routeText = "\(leg.origin.name) → \(leg.destination.name)"
            func stationIDs(_ station: SharedJourney.Station) -> Set<String> {
                Set(rows("SELECT DISTINCT COALESCE(NULLIF(parent_station, ''), stop_id) FROM stops WHERE didok = ?", [station.id], on: database).compactMap { $0[0] })
            }
            let origins = stationIDs(leg.origin)
            let destinations = stationIDs(leg.destination)
            let candidates = rows("""
                SELECT t.trip_id, t.trip_short_name, r.route_short_name, r.route_desc, r.agency_id
                FROM trips t JOIN routes r ON r.route_id = t.route_id
                WHERE t.trip_short_name = ? AND UPPER(REPLACE(r.route_short_name, ' ', '')) = ?
                ORDER BY t.trip_id
                """, [number, line], on: database)
            var matches: [Trip] = []
            for row in candidates {
                guard let id = row[0] else { continue }
                let times = route(for: id)
                guard let origin = times.first(where: { origins.contains($0.stop.id) }),
                      let destination = times.first(where: { destinations.contains($0.stop.id) && $0.stop.sequence > origin.stop.sequence }),
                      let departure = origin.departure, let arrival = destination.arrival else { continue }
                let base = ScheduleDateUtils.serviceDate(forBoardingDate: leg.departure, dayOffset: departure / 86400)
                guard operates(tripID: id, on: base) == true,
                      abs(base.addingTimeInterval(TimeInterval(departure)).timeIntervalSince(leg.departure)) < 1,
                      abs(base.addingTimeInterval(TimeInterval(arrival)).timeIntervalSince(leg.arrival)) < 1,
                      let trip = makeTrip(row, travelDate: nil) else { continue }
                matches.append(Trip(
                    id: stableID, title: trip.title, subtitle: routeText, agencyId: trip.agencyId,
                    detailRoute: routeText, gtfsTripId: id, travelDate: base,
                    sharedJourneyLeg: leg, sharedJourneyID: journeyID,
                    originStopId: origin.stop.id, originName: leg.origin.name,
                    destinationStopId: destination.stop.id, destinationName: leg.destination.name,
                    originPlatform: origin.platform, destinationPlatform: destination.platform,
                    stops: trip.stops, originSequence: origin.stop.sequence, destinationSequence: destination.stop.sequence,
                    trainType: trip.trainType
                ))
            }
            if Set(matches.compactMap(\.agencyId)).count <= 1,
               let match = matches.max(by: { ($0.stops?.count ?? 0) < ($1.stops?.count ?? 0) }) {
                return match
            }

            // Keep only known terminal geometry when the static service differs.
            // Do not borrow intermediate times/platforms from another day's run.
            func terminal(_ station: SharedJourney.Station, sequence: Int) -> StoredStop? {
                let row = rows("SELECT stop_lat, stop_lon FROM stops WHERE didok = ? LIMIT 1", [station.id], on: database).first
                let latitude = station.latitude ?? row.flatMap { $0[0].flatMap(Double.init) }
                let longitude = station.longitude ?? row.flatMap { $0[1].flatMap(Double.init) }
                guard let latitude, let longitude else { return nil }
                return StoredStop(id: "sbb-shared:\(station.id)", name: station.name,
                                  latitude: latitude, longitude: longitude, sequence: sequence)
            }
            let terminals = [terminal(leg.origin, sequence: 0), terminal(leg.destination, sequence: 1)].compactMap { $0 }
            let agencies = Set(candidates.compactMap { $0[4] })
            return Trip(
                id: stableID, title: [line, number].filter { !$0.isEmpty }.joined(separator: " "),
                subtitle: routeText, agencyId: agencies.count == 1 ? agencies.first : nil,
                detailRoute: routeText, travelDate: Self.calendar.startOfDay(for: leg.departure),
                sharedJourneyLeg: leg, sharedJourneyID: journeyID,
                originStopId: "sbb-shared:\(leg.origin.id)", originName: leg.origin.name,
                destinationStopId: "sbb-shared:\(leg.destination.id)", destinationName: leg.destination.name,
                stops: terminals, originSequence: 0, destinationSequence: 1
            )
        }
    }

    func searchTrips(matching query: String, limit: Int? = nil, travelDate: Date? = nil) -> [Trip] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let requestedLimit = max(1, limit ?? 25)
        return searchQueue.sync {
            searchTripsOnSearchConnection(query: query, limit: requestedLimit, travelDate: travelDate)
        }
    }

    // Called under readLock. Copy BLOB data before finalizing the SQLite statement,
    // and cache decoded masks so station filtering never repeatedly inflates them.
    private func exceptionMask(for service: String) -> ExceptionMask {
        if let cached = exceptionMasks[service] { return cached }
        let decoded = loadExceptionMask(for: service)
        exceptionMasks[service] = decoded
        return decoded
    }

    private func loadExceptionMask(for service: String) -> ExceptionMask {
        guard calendarTables.contains("calendar_date_masks"), let database else { return .missing }
        var statement: OpaquePointer?
        let sql = "SELECT start_date, day_count, codec, exceptions FROM calendar_date_masks WHERE service_id = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return .invalid }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, service, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return .missing }
        guard status == SQLITE_ROW,
              let dateText = sqlite3_column_text(statement, 0) else { return .invalid }
        let text = String(cString: dateText)
        guard text.count == 8, let number = Int(text) else { return .invalid }
        let parts = DateComponents(year: number / 10000, month: (number / 100) % 100, day: number % 100)
        guard let start = Self.calendar.date(from: parts),
              Self.calendar.dateComponents([.year, .month, .day], from: start) == parts else { return .invalid }
        let days = sqlite3_column_int64(statement, 1)
        // Bound malformed input before allocating; this covers over 10,000 years.
        guard days > 0, days <= 4_000_000 else { return .invalid }
        let expectedSize = (Int(days) + 3) / 4
        let size = Int(sqlite3_column_bytes(statement, 3))
        guard size > 0, let blob = sqlite3_column_blob(statement, 3) else { return .invalid }
        let encoded = Array(UnsafeRawBufferPointer(start: blob, count: size))
        let bytes: [UInt8]
        switch sqlite3_column_int(statement, 2) {
        case 0:
            guard encoded.count == expectedSize else { return .invalid }
            bytes = encoded
        case 1:
            var output = [UInt8](repeating: 0, count: expectedSize)
            var length = uLongf(expectedSize)
            let result = output.withUnsafeMutableBufferPointer { destination in
                encoded.withUnsafeBufferPointer { source in
                    uncompress(destination.baseAddress, &length, source.baseAddress, uLong(encoded.count))
                }
            }
            guard result == Z_OK, length == expectedSize else { return .invalid }
            bytes = output
        default:
            return .invalid
        }
        return .decoded(start: start, days: Int(days), bytes: bytes)
    }

    /// nil means this feed cannot validate dates; never infer daily service from an ID.
    func operates(tripID: String, on date: Date) -> Bool? {
        readLock.lock()
        defer { readLock.unlock() }
        guard hasServiceCalendar else { return nil }
        guard let service = rows("SELECT service_id FROM trips WHERE trip_id = ?", [tripID], on: database).first?[0] else { return false }
        let components = Self.calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let day = String(format: "%04d%02d%02d", components.year!, components.month!, components.day!)
        if calendarTables.contains("calendar_dates"),
           let exception = rows("SELECT exception_type FROM calendar_dates WHERE service_id = ? AND date = ?", [service, day], on: database).first?[0] {
            return exception == "1"
        }
        switch exceptionMask(for: service) {
        case .missing:
            break
        case .invalid:
            return false
        case let .decoded(start, days, bytes):
            let offset = Self.calendar.dateComponents([.day], from: start, to: Self.calendar.startOfDay(for: date)).day ?? -1
            if offset >= 0 && offset < days {
                let exception = (bytes[offset / 4] >> (2 * (offset % 4))) & 3
                switch exception {
                case 1: return true
                case 2, 3: return false
                default: break // No override: use the weekly calendar below.
                }
            }
        }
        guard calendarTables.contains("calendar") else { return false }
        let weekday = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"][components.weekday! - 1]
        return !rows("SELECT service_id FROM calendar WHERE service_id = ? AND start_date <= ? AND end_date >= ? AND \(weekday) = '1'", [service, day, day], on: database).isEmpty
    }

    /// Returns the concrete timetable variants behind a grouped public
    /// suggestion. These are intentionally kept separate until the rider has
    /// chosen the travel date and boarding/alighting stations.
    func variants(for suggestion: Trip, travelDate: Date?, matching query: String? = nil) -> [Trip] {
        searchQueue.sync {
            let routeCode = suggestion.title.split(separator: " ").first.map(String.init) ?? suggestion.title
            return searchTripsOnSearchConnection(
                query: query ?? routeCode, limit: Int.max, travelDate: travelDate, grouped: false
            ).filter { trip in
                trip.agencyId == suggestion.agencyId &&
                trip.title.split(separator: " ").first == suggestion.title.split(separator: " ").first &&
                normalizedSearchValue(trip.destinationName) == normalizedSearchValue(suggestion.destinationName)
            }
        }
    }

    /// Availability for the calendar uses the same boarding-day rules as station selection.
    /// Resolve variants once per month, not once per day or from a view body.
    func availableBoardingDates(for suggestion: Trip, matching query: String?, month: Date) -> Set<Date> {
        guard hasServiceCalendar,
              let interval = Self.calendar.dateInterval(of: .month, for: month),
              let days = Self.calendar.range(of: .day, in: .month, for: month) else { return [] }
        let candidates = variants(for: suggestion, travelDate: nil, matching: query)
        let services = candidates.map { trip in
            let id = trip.gtfsTripId ?? trip.id
            let offsets = Set(stops(for: id).dropLast().compactMap { stop in
                stopSchedule(for: id, stopId: stop.id)?.departureSeconds.map { $0 / 86400 }
            })
            return (id, offsets)
        }
        var available = Set<Date>()
        for day in days {
            guard let date = Self.calendar.date(byAdding: .day, value: day - 1, to: interval.start) else { continue }
            let runs = services.contains { id, offsets in
                offsets.contains { offset in
                    let serviceDate = ScheduleDateUtils.serviceDate(forBoardingDate: date, dayOffset: offset)
                    return operates(tripID: id, on: serviceDate) == true
                }
            }
            if runs { available.insert(date) }
        }
        return available
    }

    /// Station choices are the union across candidates, never one representative's route.
    func stationChoices(in trips: [Trip], after originID: String? = nil) -> [GTFSStop] {
        var choices: [String: GTFSStop] = [:]
        for trip in trips {
            let stops = stops(for: trip.gtfsTripId ?? trip.id)
            func canBoard(_ stop: GTFSStop) -> Bool {
                guard let date = trip.travelDate,
                      let seconds = stopSchedule(for: trip.gtfsTripId ?? trip.id, stopId: stop.id)?.departureSeconds else { return true }
                let serviceDate = ScheduleDateUtils.serviceDate(forBoardingDate: date, dayOffset: seconds / 86400)
                return operates(tripID: trip.gtfsTripId ?? trip.id, on: serviceDate) != false
            }
            if let originID {
                guard let index = stops.firstIndex(where: { $0.id == originID }), canBoard(stops[index]) else { continue }
                for stop in stops.dropFirst(index + 1) { choices[stop.id] = stop }
            } else {
                for stop in stops.dropLast() where canBoard(stop) { choices[stop.id] = stop }
            }
        }
        return choices.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Resolve stations against each candidate's own sequence and display its selected leg.
    func options(in trips: [Trip], originID: String, destinationID: String) -> [Trip] {
        var seen = Set<String>()
        var result: [(Int, Trip)] = []
        for trip in trips {
            let id = trip.gtfsTripId ?? trip.id
            let stops = stops(for: id)
            guard let origin = stops.first(where: { $0.id == originID }),
                  let destination = stops.first(where: { $0.id == destinationID && $0.sequence > origin.sequence }),
                  let departure = stopSchedule(for: id, stopId: originID)?.departureSeconds,
                  let arrival = stopSchedule(for: id, stopId: destinationID)?.arrivalSeconds else { continue }
            let serviceDate = trip.travelDate.map {
                ScheduleDateUtils.serviceDate(forBoardingDate: $0, dayOffset: departure / 86400)
            }
            if let serviceDate, operates(tripID: id, on: serviceDate) == false { continue }
            let key = "\(trip.agencyId ?? "")|\(trip.title)|\(departure)|\(arrival)"
            guard seen.insert(key).inserted else { continue }
            let leg = Trip(
                id: trip.id, title: trip.title, subtitle: "\(origin.name) → \(destination.name)",
                agencyId: trip.agencyId, detailRoute: "\(origin.name) → \(destination.name)",
                gtfsTripId: id, travelDate: serviceDate,
                originStopId: origin.id, originName: origin.name,
                destinationStopId: destination.id, destinationName: destination.name,
                originPlatform: platform(trainId: id, stationId: origin.id),
                destinationPlatform: platform(trainId: id, stationId: destination.id),
                stops: trip.stops, originSequence: origin.sequence, destinationSequence: destination.sequence,
                trainType: trip.trainType
            )
            result.append((departure, leg))
        }
        return result.sorted { $0.0 == $1.0 ? $0.1.id < $1.1.id : $0.0 < $1.0 }.map { $0.1 }
    }

    private func searchTripsOnSearchConnection(query: String, limit: Int, travelDate: Date?, grouped: Bool = true) -> [Trip] {
        let normalizedQuery = query.uppercased()
        let queryParts = normalizedQuery.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        let numberPart = queryParts.last(where: { $0.allSatisfy { $0.isNumber } })
        let routePart = queryParts.first(where: { $0.contains(where: { $0.isLetter }) && $0.contains(where: { $0.isNumber }) })
        let publicRouteSearch = routePart != nil && numberPart != nil
        let numeric = query.allSatisfy { $0.isNumber }
        let pattern = numeric ? query + "%" : "%" + query + "%"
        let predicate: String
        let bindings: [String]
        if publicRouteSearch, let routePart, let numberPart {
            predicate = "UPPER(r.route_short_name) = ? AND t.trip_short_name = ?"
            bindings = [routePart, numberPart]
        } else if let routePart {
            predicate = "UPPER(r.route_short_name) = ?"
            bindings = [routePart]
        } else if numeric {
            predicate = "t.trip_short_name = ?"
            bindings = [query]
        } else {
            predicate = """
                (t.trip_short_name LIKE ? OR r.route_short_name LIKE ? OR t.trip_id IN (
                    SELECT st.trip_id FROM stops s JOIN stop_times st ON s.stop_id = st.stop_id
                    WHERE s.stop_name LIKE ?))
                """
            bindings = [pattern, pattern, pattern]
        }
        var matches = rows("""
            SELECT t.trip_id, t.trip_short_name, r.route_short_name, r.route_desc, r.agency_id
            FROM trips t JOIN routes r ON r.route_id = t.route_id
            WHERE \(predicate)
            ORDER BY t.trip_short_name, t.trip_id
            """, bindings, on: searchDatabase)
        if numeric && matches.isEmpty {
            matches = rows("""
                SELECT t.trip_id, t.trip_short_name, r.route_short_name, r.route_desc, r.agency_id
                FROM trips t JOIN routes r ON r.route_id = t.route_id
                WHERE t.trip_short_name LIKE ?
                ORDER BY t.trip_short_name, t.trip_id
                """, [pattern], on: searchDatabase)
        }
        if !grouped { return matches.compactMap { makeTrip($0, travelDate: travelDate) } }
        var resultByPublicService: [String: Trip] = [:]
        var resultOrder: [String] = []
        for row in matches {
            guard let trip = makeTrip(row, travelDate: travelDate) else { continue }
            let schedule = self.route(for: trip.gtfsTripId ?? "")
            let headsign = trip.destinationName ?? trip.subtitle
            // Different train numbers belong to one line/headsign suggestion.
            let publicServiceKey = [row[4] ?? "", row[2] ?? "", normalizedSearchValue(headsign)].joined(separator: "|")
            if let existing = resultByPublicService[publicServiceKey] {
                let existingCount = self.route(for: existing.gtfsTripId ?? "").count
                if schedule.count > existingCount {
                    resultByPublicService[publicServiceKey] = trip
                }
            } else {
                resultByPublicService[publicServiceKey] = trip
                resultOrder.append(publicServiceKey)
            }
        }
        return resultOrder.compactMap { resultByPublicService[$0] }.prefix(limit).map { $0 }
    }

    private func makeTrip(_ row: [String?], travelDate: Date?) -> Trip? {
        guard let id = row[0] else { return nil }
        let stops = stops(for: id)
        guard let origin = stops.first, let destination = stops.last, stops.count > 1 else { return nil }
        if let travelDate, hasServiceCalendar {
            // Before station selection, retain any run that can be boarded on this date.
            let times = self.route(for: id)
            let offsets = Set(times.map { ($0.departure ?? $0.arrival ?? 0) / 86400 })
            let runs = offsets.contains { offset in
                let serviceDate = ScheduleDateUtils.serviceDate(forBoardingDate: travelDate, dayOffset: offset)
                return operates(tripID: id, on: serviceDate) == true
            }
            guard runs else { return nil }
        }
        let number = row[1]?.isEmpty == false ? row[1]! : (row[2] ?? "Train")
        let line = row[2]?.isEmpty == false ? row[2] : row[3]
        let title = [line == number ? nil : line, number].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let route = "\(origin.name) → \(destination.name)"
        return Trip(
            id: "sbb:\(id)", title: title, subtitle: route, agencyId: row[4], detailRoute: route,
            gtfsTripId: id, travelDate: travelDate.map { Self.calendar.startOfDay(for: $0) },
            originStopId: origin.id, originName: origin.name,
            destinationStopId: destination.id, destinationName: destination.name,
            stops: stops.map(StoredStop.init(gtfsStop:)),
            originSequence: origin.sequence, destinationSequence: destination.sequence,
            trainType: row[3].flatMap { TrainType(categoryCode: $0) }
        )
    }

    private func normalizedSearchValue(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func randomTrip() -> Trip? {
        readLock.lock()
        defer { readLock.unlock() }
        let matches = rows("""
            SELECT t.trip_id, t.trip_short_name, r.route_short_name, r.route_desc, r.agency_id
            FROM trips t JOIN routes r ON r.route_id = t.route_id ORDER BY RANDOM() LIMIT 1
            """, on: database)
        return matches.first.flatMap { makeTrip($0, travelDate: Date()) }
    }

    private struct StopTime {
        let stop: GTFSStop
        let arrival: Int?
        let departure: Int?
        let platform: String?
        let commercial: Bool
        let shapeDistance: Double?
    }

    private func route(for id: String) -> [StopTime] {
        readLock.lock()
        defer { readLock.unlock() }
        if let cached = routeCache[id] { return cached }
        let result = rows("""
            SELECT COALESCE(NULLIF(s.parent_station, ''), s.stop_id), s.stop_name,
                   s.stop_lat, s.stop_lon, st.stop_sequence, st.arrival_time, st.departure_time,
                   s.platform_code, st.pickup_type, st.drop_off_type,
                   \(supportsShapes ? "st.shape_dist_traveled" : "NULL")
            FROM stop_times st JOIN stops s ON s.stop_id = st.stop_id
            WHERE st.trip_id = ? ORDER BY CAST(st.stop_sequence AS INTEGER)
            """, [id], on: database).compactMap { row -> StopTime? in
                guard let stopID = row[0], let name = row[1],
                      let lat = row[2].flatMap(Double.init), let lon = row[3].flatMap(Double.init),
                      let sequence = row[4].flatMap(Int.init) else { return nil }
                return StopTime(stop: GTFSStop(id: stopID, name: name, sequence: sequence, latitude: lat, longitude: lon),
                                arrival: Self.seconds(row[5]), departure: Self.seconds(row[6]),
                                platform: row[7]?.isEmpty == false ? row[7] : nil,
                                commercial: row[8] != "1" || row[9] != "1",
                                shapeDistance: row[10].flatMap(Double.init))
            }
        routeCache[id] = result
        return result
    }

    static func seconds(_ value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3, parts[0] >= 0, (0..<60).contains(parts[1]), (0..<60).contains(parts[2]) else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    func preloadRouteData(for tripId: String) { _ = route(for: tripId) }

    /// Loaded off the UI thread; the bounded cache also remembers missing shapes.
    func routeGeometry(for tripId: String) -> GTFSRouteGeometry {
        readLock.lock()
        defer { readLock.unlock() }
        if let cached = geometryCache[tripId] { return cached }
        let times = route(for: tripId)
        var points: [GTFSRouteGeometry.Point] = []
        if supportsShapes {
            let values = rows("""
                SELECT shape_pt_lat, shape_pt_lon, shape_dist_traveled FROM shapes
                WHERE shape_id = (SELECT shape_id FROM trips WHERE trip_id = ?)
                ORDER BY CAST(shape_pt_sequence AS INTEGER)
                """, [tripId], on: database)
            let decoded = values.compactMap { row -> GTFSRouteGeometry.Point? in
                guard let latitude = row[0].flatMap(Double.init),
                      let longitude = row[1].flatMap(Double.init),
                      let distance = row[2].flatMap(Double.init) else { return nil }
                return .init(latitude: latitude, longitude: longitude, distance: distance)
            }
            // Never join across a corrupt/missing shape point.
            if decoded.count == values.count { points = decoded }
        }
        var distances: [Int: Double] = [:]
        for time in times { distances[time.stop.sequence] = time.shapeDistance }
        let geometry = GTFSRouteGeometry(stops: times.map(\.stop), points: points, stopDistances: distances)
        if geometryCache.count >= 128, let key = geometryCache.keys.first { geometryCache.removeValue(forKey: key) }
        geometryCache[tripId] = geometry
        return geometry
    }

    func stops(for tripId: String) -> [GTFSStop] {
        let times = route(for: tripId)
        return times.enumerated().filter { $0.element.commercial || $0.offset == 0 || $0.offset == times.count - 1 }.map { $0.element.stop }
    }

    func polylineStops(for tripId: String) -> [GTFSStop] { route(for: tripId).map(\.stop) }

    func segments(for tripId: String) -> [GTFSSegment] {
        if let saved = TripStaticScheduleStore.segments(for: tripId), !saved.isEmpty {
            return saved
        }
        let times = route(for: tripId)
        let result = zip(times, times.dropFirst()).map { start, end in
            GTFSSegment(id: start.stop.sequence, startId: start.stop.id, startName: start.stop.name,
                        endId: end.stop.id, endName: end.stop.name,
                        departureSeconds: start.departure, arrivalSeconds: end.arrival)
        }
        if !result.isEmpty { TripStaticScheduleStore.save(result, for: tripId) }
        return result
    }

    struct GTFSStopSchedule {
        let arrivalSeconds: Int?
        let departureSeconds: Int?
    }

    func stopSchedule(for tripId: String, stopId: String) -> GTFSStopSchedule? {
        guard let time = route(for: tripId).first(where: { $0.stop.id == stopId }) else { return nil }
        return GTFSStopSchedule(arrivalSeconds: time.arrival, departureSeconds: time.departure)
    }

    func stopSchedules(for tripId: String, stopIds: [String]) -> [String: GTFSStopSchedule] {
        let wanted = Set(stopIds)
        var result: [String: GTFSStopSchedule] = [:]
        for time in route(for: tripId) where wanted.contains(time.stop.id) && result[time.stop.id] == nil {
            result[time.stop.id] = GTFSStopSchedule(arrivalSeconds: time.arrival, departureSeconds: time.departure)
        }
        return result
    }

    func platform(trainId: String, stationId: String) -> String? {
        route(for: trainId).first { $0.stop.id == stationId }?.platform
    }

    func headsign(for tripID: String) -> String? {
        readLock.lock()
        defer { readLock.unlock() }
        if let cached = headsignCache[tripID] { return cached.isEmpty ? nil : cached }
        let value = rows("SELECT trip_headsign FROM trips WHERE trip_id = ? LIMIT 1", [tripID], on: database)
            .first?[0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        headsignCache[tripID] = value
        return value.isEmpty ? nil : value
    }

    func platform(forStopID stopID: String) -> String? {
        readLock.lock()
        defer { readLock.unlock() }
        return rows("SELECT platform_code FROM stops WHERE stop_id = ? LIMIT 1", [stopID], on: database)
            .first?[0].flatMap { $0.isEmpty ? nil : $0 }
    }

    func minimumTransferSeconds(from fromStopID: String, to toStopID: String) -> Int? {
        readLock.lock()
        defer { readLock.unlock() }
        guard calendarTables.contains("transfers") else { return nil }
        let cacheKey = "\(fromStopID)|\(toStopID)"
        if let cached = transferTimeCache[cacheKey] { return cached >= 0 ? cached : nil }
        func identifiers(for stopID: String) -> [String] {
            let parent = rows("SELECT parent_station FROM stops WHERE stop_id = ? LIMIT 1", [stopID], on: database).first?[0]
            let values = [stopID, parent].compactMap { $0 }
            return Array(Set(values + values.compactMap { value in
                value.hasPrefix("Parent") ? String(value.dropFirst("Parent".count)) : nil
            }))
        }
        for from in identifiers(for: fromStopID) {
            for to in identifiers(for: toStopID) {
                guard let value = rows("""
                    SELECT min_transfer_time FROM transfers
                    WHERE from_stop_id = ? AND to_stop_id = ? AND transfer_type = '2'
                    ORDER BY CAST(min_transfer_time AS INTEGER) DESC LIMIT 1
                    """, [from, to], on: database).first?[0],
                      let seconds = Int(value) else { continue }
                transferTimeCache[cacheKey] = seconds
                return seconds
            }
        }
        transferTimeCache[cacheKey] = -1
        return nil
    }

    /// Automatic alternative recommendations are not implemented for this feed.
    func departures(from stationID: String, after date: Date, excluding trainID: String? = nil, destinationStationID: String? = nil, limit: Int = 8) -> [Trip] { [] }
}
