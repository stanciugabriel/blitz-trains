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
        WITH first_segment AS (
            SELECT ts.train_number, ts.sequence_id, ts.uic_start
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
               destination.name AS destination_name
        FROM trains t
        LEFT JOIN first_segment fs ON fs.train_number = t.train_number
        LEFT JOIN stations origin ON origin.uic_code = fs.uic_start
        LEFT JOIN last_segment ls ON ls.train_number = t.train_number
        LEFT JOIN stations destination ON destination.uic_code = ls.uic_end
        WHERE t.train_number LIKE ?
           OR t.train_number LIKE ?
           OR COALESCE(origin.search_index, '') LIKE ?
           OR COALESCE(destination.search_index, '') LIKE ?
        ORDER BY t.train_number ASC
        LIMIT ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare statement")
            return []
        }
        defer { sqlite3_finalize(statement) }

        let pattern = "%\(trimmed)%"
        let numericQuery = trimmed.filter { $0.isNumber }
        let numericPattern = numericQuery.isEmpty ? pattern : "%\(numericQuery)%"
        var normalizedQuery = normalizedSearchQuery(trimmed)
        if normalizedQuery.isEmpty {
            normalizedQuery = trimmed.lowercased()
        }
        let normalizedPattern = "%\(normalizedQuery)%"
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, numericPattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, normalizedPattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, normalizedPattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 5, fetchLimit)

        var trips: [Trip] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let numberPointer = sqlite3_column_text(statement, 0) else { continue }
            let trainNumber = String(cString: numberPointer)
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

            let routeName = routeDescription(origin: originName, destination: destinationName)
            let subtitle = routeName ?? "Route info unavailable"
            let displayTitle = formattedTrainTitle(category: category, number: trainNumber)
            trips.append(
                Trip(
                    id: trainNumber,
                    title: displayTitle,
                    subtitle: subtitle,
                    agencyId: agencyId,
                    detailRoute: routeName,
                    gtfsTripId: trainNumber
                )
            )
        }

        return trips
    }

    func stops(for tripId: String) -> [GTFSStop] {
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
        guard let database else { return [] }
        let sql = """
        SELECT
            trip_segments.sequence_id,
            trip_segments.uic_start,
            trip_segments.uic_end,
            trip_segments.departure_time,
            trip_segments.arrival_time,
            trip_segments.max_speed_kmh,
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
            let startName = sqlite3_column_text(statement, 6).map { String(cString: $0) }
            let endName = sqlite3_column_text(statement, 7).map { String(cString: $0) }

            let segment = GTFSSegment(
                id: sequence,
                startId: startId,
                startName: startName,
                endId: endId,
                endName: endName,
                departureSeconds: departureSeconds,
                arrivalSeconds: arrivalSeconds,
                maxSpeed: maxSpeed
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
