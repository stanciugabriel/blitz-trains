import Foundation
import SQLite3

protocol StaticPlatformProviding {
    func platform(trainId: String, stationId: String) -> String?
}

final class StaticPlatformDataSource: StaticPlatformProviding {
    static let shared = StaticPlatformDataSource()

    private var database: OpaquePointer?
    private let lock = NSLock()

    private init() {
        openDatabase()
    }

    deinit {
        sqlite3_close(database)
    }

    func platform(trainId: String, stationId: String) -> String? {
        let trainId = trainId.trimmingCharacters(in: .whitespacesAndNewlines)
        let stationId = stationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trainId.isEmpty, !stationId.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        guard let database else { return nil }
        let sql = """
        SELECT platform
        FROM station_platforms
        WHERE station_id = ? AND train_id = ?
        LIMIT 1
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logError("Failed to prepare platform query")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, stationId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, trainId, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0)
        else { return nil }

        let platform = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return platform.isEmpty ? nil : platform
    }

    private func openDatabase() {
        guard database == nil else { return }
        guard let url = locateDatabaseURL() else {
            logError("Unable to locate static_platforms.sqlite")
            return
        }

        if sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            logError("Unable to open static_platforms.sqlite at \(url.path)")
            sqlite3_close(database)
            database = nil
        }
    }

    private func locateDatabaseURL() -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "static_platforms", withExtension: "sqlite") {
            return bundleURL
        }
        #if DEBUG
        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidate = cwd.appendingPathComponent("blitz/static_platforms.sqlite")
        if fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        #endif
        return nil
    }

    private func logError(_ message: String) {
        #if DEBUG
        print("[StaticPlatformDataSource] \(message)")
        #endif
    }
}
