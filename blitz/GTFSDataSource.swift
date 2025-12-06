import Foundation
import SQLite3

struct ScheduleStop: Identifiable, Equatable {
    let id: String
    let name: String
    let sequence: Int
    let latitude: Double
    let longitude: Double
}

extension TrainScheduleDataSource.StopSchedule {
    func arrivalDate(on baseDate: Date) -> Date? {
        guard let arrivalSeconds else { return nil }
        return baseDate.addingTimeInterval(TimeInterval(arrivalSeconds))
    }

    func departureDate(on baseDate: Date) -> Date? {
        guard let departureSeconds else { return nil }
        return baseDate.addingTimeInterval(TimeInterval(departureSeconds))
    }
}

final class TrainScheduleDataSource {
    static let shared = TrainScheduleDataSource()

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
        SELECT DISTINCT train_id, category, operator, total_km
        FROM trains
        WHERE train_id LIKE ?
           OR train_id IN (
               SELECT train_id FROM route_segments
               WHERE station_origin_name LIKE ? OR station_dest_name LIKE ?
           )
        ORDER BY train_id ASC
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
        sqlite3_bind_text(statement, 3, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 4, fetchLimit)

        var trips: [Trip] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let tripCString = sqlite3_column_text(statement, 0) else { continue }
            let tripID = String(cString: tripCString)
            let category = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let operatorCode = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let totalKM = sqlite3_column_double(statement, 3)

            let (originName, destinationName) = routeEndpoints(for: tripID)
            let routeText: String
            if let originName, let destinationName {
                routeText = "\(originName) → \(destinationName)"
            } else {
                routeText = "Route information unavailable"
            }

            let displayTitle = category.isEmpty ? tripID : "\(category) \(tripID)"
            let detailDistance: String?
            if totalKM > 0 {
                detailDistance = formattedDistance(from: totalKM)
            } else {
                detailDistance = nil
            }

            trips.append(
                Trip(
                    id: tripID,
                    title: displayTitle,
                    subtitle: routeText,
                    agencyId: operatorCode,
                    detailRoute: routeText,
                    gtfsTripId: tripID,
                    detailDistance: detailDistance
                )
            )
        }

        return trips
    }

    func stops(for tripId: String) -> [ScheduleStop] {
        guard let database else { return [] }
        let sql = """
        SELECT rs.sequence,
               rs.station_origin_code,
               rs.station_origin_name,
               so.stop_lat,
               so.stop_lon,
               rs.station_dest_code,
               rs.station_dest_name,
               sd.stop_lat,
               sd.stop_lon
        FROM route_segments rs
        LEFT JOIN stations so ON so.stop_id = rs.station_origin_code
        LEFT JOIN stations sd ON sd.stop_id = rs.station_dest_code
        WHERE rs.train_id = ?
        ORDER BY rs.sequence ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare stops query")
            return []
        }
        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, tripId, -1, SQLITE_TRANSIENT)

        var orderedStops: [ScheduleStop] = []
        var seen: Set<String> = []
        var sequenceCounter = 1

        while sqlite3_step(statement) == SQLITE_ROW {
            let originCode = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let originName = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let originLat = sqlite3_column_double(statement, 3)
            let originLon = sqlite3_column_double(statement, 4)
            let destinationCode = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            let destinationName = sqlite3_column_text(statement, 6).map { String(cString: $0) }
            let destinationLat = sqlite3_column_double(statement, 7)
            let destinationLon = sqlite3_column_double(statement, 8)

            if let originCode, let originName, !seen.contains(originCode) {
                orderedStops.append(
                    ScheduleStop(
                        id: originCode,
                        name: originName,
                        sequence: sequenceCounter,
                        latitude: originLat,
                        longitude: originLon
                    )
                )
                seen.insert(originCode)
                sequenceCounter += 1
            }

            if let destinationCode, let destinationName, !seen.contains(destinationCode) {
                orderedStops.append(
                    ScheduleStop(
                        id: destinationCode,
                        name: destinationName,
                        sequence: sequenceCounter,
                        latitude: destinationLat,
                        longitude: destinationLon
                    )
                )
                seen.insert(destinationCode)
                sequenceCounter += 1
            }
        }

        return orderedStops
    }

    struct StopSchedule {
        let arrivalSeconds: Int?
        let departureSeconds: Int?
    }

    func stopSchedule(for tripId: String, stopId: String) -> StopSchedule? {
        guard let database else { return nil }

        let arrivalSQL = """
        SELECT arrival_time_seconds
        FROM route_segments
        WHERE train_id = ? AND station_dest_code = ?
        ORDER BY sequence ASC
        LIMIT 1
        """

        let departureSQL = """
        SELECT departure_time_seconds
        FROM route_segments
        WHERE train_id = ? AND station_origin_code = ?
        ORDER BY sequence ASC
        LIMIT 1
        """

        let arrivalSeconds = fetchTime(sql: arrivalSQL, tripId: tripId, stopId: stopId)
        let departureSeconds = fetchTime(sql: departureSQL, tripId: tripId, stopId: stopId)

        return StopSchedule(arrivalSeconds: arrivalSeconds, departureSeconds: departureSeconds)
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

    private func fetchTime(sql: String, tripId: String, stopId: String) -> Int? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare time query")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, tripId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, stopId, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL {
            return nil
        }
        let seconds = sqlite3_column_int(statement, 0)
        return Int(seconds)
    }

    private func routeEndpoints(for trainId: String) -> (String?, String?) {
        guard let database else { return (nil, nil) }
        let firstSQL = """
        SELECT station_origin_name
        FROM route_segments
        WHERE train_id = ?
        ORDER BY sequence ASC
        LIMIT 1
        """

        let lastSQL = """
        SELECT station_dest_name
        FROM route_segments
        WHERE train_id = ?
        ORDER BY sequence DESC
        LIMIT 1
        """

        let origin = singleString(sql: firstSQL, trainId: trainId)
        let destination = singleString(sql: lastSQL, trainId: trainId)
        return (origin, destination)
    }

    private func singleString(sql: String, trainId: String) -> String? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, trainId, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: cString)
    }

    private func formattedDistance(from kilometers: Double) -> String {
        if kilometers >= 1 {
            return String(format: "%.0f km", kilometers)
        }
        let meters = kilometers * 1000
        return String(format: "%.0f m", meters)
    }

    private func openDatabase() {
        guard database == nil else { return }
        guard let url = locateDatabaseURL() else {
            logError("Unable to locate train_schedule.sqlite")
            return
        }

        if sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            logError("Unable to open train_schedule.sqlite at \(url.path)")
            sqlite3_close(database)
            database = nil
        }
    }

    private func locateDatabaseURL() -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "train_schedule", withExtension: "sqlite") {
            return bundleURL
        }
        if let bundleDBURL = Bundle.main.url(forResource: "train_schedule", withExtension: "db") {
            return bundleDBURL
        }
        #if DEBUG
        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let directSQLite = cwd.appendingPathComponent("train_schedule.sqlite")
        if fileManager.fileExists(atPath: directSQLite.path) {
            return directSQLite
        }
        let directDB = cwd.appendingPathComponent("train_schedule.db")
        if fileManager.fileExists(atPath: directDB.path) {
            return directDB
        }
        let nestedSQLite = cwd.appendingPathComponent("blitz/train_schedule.sqlite")
        if fileManager.fileExists(atPath: nestedSQLite.path) {
            return nestedSQLite
        }
        let nestedDB = cwd.appendingPathComponent("blitz/train_schedule.db")
        if fileManager.fileExists(atPath: nestedDB.path) {
            return nestedDB
        }
        #endif
        return nil
    }

    private func logError(_ message: String) {
        #if DEBUG
        print("[TrainScheduleDataSource] \(message)")
        #endif
    }
}
