import Foundation
import SQLite3

struct GTFSStop: Identifiable, Equatable {
    let id: String
    let name: String
    let sequence: Int
    let latitude: Double
    let longitude: Double
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

final class GTFSDataSource {
    static let shared = GTFSDataSource()

    private var database: OpaquePointer?
    private let searchLimit = 25

    private init() {
        openDatabase()
    }

    deinit {
        sqlite3_close(database)
    }

    func searchTrips(matching query: String, limit: Int? = nil) -> [Trip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let database else { return [] }

        let fetchLimit = Int32(limit ?? searchLimit)
        let sql = """
        SELECT trips.trip_id,
               COALESCE(trips.trip_short_name, trips.trip_id) AS train_code,
               COALESCE(routes.route_long_name, routes.route_short_name, '') AS route_name,
               routes.agency_id
        FROM trips
        LEFT JOIN routes ON trips.route_id = routes.route_id
        WHERE trips.trip_id LIKE ? OR routes.route_long_name LIKE ?
        ORDER BY trips.trip_id ASC
        LIMIT ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare statement")
            return []
        }
        defer { sqlite3_finalize(statement) }

        let pattern = "%\(trimmed)%"
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 3, fetchLimit)

        var trips: [Trip] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let tripCString = sqlite3_column_text(statement, 0) else { continue }
            let tripID = String(cString: tripCString)
            let trainCode: String
            if let codeCString = sqlite3_column_text(statement, 1) {
                trainCode = String(cString: codeCString).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                trainCode = ""
            }
            let routeName: String
            if let routeCString = sqlite3_column_text(statement, 2) {
                routeName = String(cString: routeCString).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                routeName = ""
            }
            let agencyId: String?
            if let agencyCString = sqlite3_column_text(statement, 3) {
                let raw = String(cString: agencyCString).trimmingCharacters(in: .whitespacesAndNewlines)
                agencyId = raw.isEmpty ? nil : raw
            } else {
                agencyId = nil
            }

            let subtitle = routeName.isEmpty ? "Route info unavailable" : routeName
            let displayTitle: String
            if trainCode.isEmpty {
                displayTitle = tripID
            } else if trainCode.contains(tripID) {
                displayTitle = trainCode
            } else {
                displayTitle = "\(trainCode) \(tripID)"
            }
            trips.append(
                Trip(
                    id: tripID,
                    title: displayTitle,
                    subtitle: subtitle,
                    agencyId: agencyId,
                    detailRoute: subtitle,
                    gtfsTripId: tripID
                )
            )
        }

        return trips
    }

    func stops(for tripId: String) -> [GTFSStop] {
        guard let database else { return [] }
        let sql = """
        SELECT stops.stop_id, stops.stop_name, stop_times.stop_sequence, stops.stop_lat, stops.stop_lon
        FROM stop_times
        INNER JOIN stops ON stops.stop_id = stop_times.stop_id
        WHERE stop_times.trip_id = ?
        ORDER BY stop_times.stop_sequence ASC
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
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let stopIdC = sqlite3_column_text(statement, 0),
                let stopNameC = sqlite3_column_text(statement, 1)
            else { continue }

            let sequence = Int(sqlite3_column_int(statement, 2))
            let latitude = sqlite3_column_double(statement, 3)
            let longitude = sqlite3_column_double(statement, 4)
            let stop = GTFSStop(
                id: String(cString: stopIdC),
                name: String(cString: stopNameC),
                sequence: sequence,
                latitude: latitude,
                longitude: longitude
            )
            stops.append(stop)
        }

        return stops
    }

    struct GTFSStopSchedule {
        let arrivalSeconds: Int?
        let departureSeconds: Int?
    }

    func stopSchedule(for tripId: String, stopId: String) -> GTFSStopSchedule? {
        guard let database else { return nil }
        let sql = """
        SELECT arrival_time, departure_time
        FROM stop_times
        WHERE trip_id = ? AND stop_id = ?
        LIMIT 1
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

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let arrivalSeconds = sqlite3_column_text(statement, 0).flatMap { parseTimeSeconds(String(cString: $0)) }
        let departureSeconds = sqlite3_column_text(statement, 1).flatMap { parseTimeSeconds(String(cString: $0)) }

        return GTFSStopSchedule(arrivalSeconds: arrivalSeconds, departureSeconds: departureSeconds)
    }

    private func parseTimeSeconds(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]),
              let seconds = Int(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    private func openDatabase() {
        guard database == nil else { return }
        guard let url = locateDatabaseURL() else {
            logError("Unable to locate gtfs.sqlite")
            return
        }

        if sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            logError("Unable to open gtfs.sqlite at \(url.path)")
            sqlite3_close(database)
            database = nil
        }
    }

    private func locateDatabaseURL() -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "gtfs", withExtension: "sqlite") {
            return bundleURL
        }
        #if DEBUG
        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidate = cwd.appendingPathComponent("blitz/gtfs.sqlite")
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
