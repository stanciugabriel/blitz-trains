import Foundation

struct StoredSegment: Codable, Equatable {
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

    init(_ segment: GTFSSegment) {
        id = segment.id
        startId = segment.startId
        startName = segment.startName
        endId = segment.endId
        endName = segment.endName
        departureSeconds = segment.departureSeconds
        arrivalSeconds = segment.arrivalSeconds
        maxSpeed = segment.maxSpeed
        trainLengthMeters = segment.trainLengthMeters
        trainTonnage = segment.trainTonnage
    }

    var gtfsSegment: GTFSSegment {
        GTFSSegment(id: id, startId: startId, startName: startName, endId: endId,
                    endName: endName, departureSeconds: departureSeconds,
                    arrivalSeconds: arrivalSeconds, maxSpeed: maxSpeed,
                    trainLengthMeters: trainLengthMeters, trainTonnage: trainTonnage)
    }
}

/// Static schedule data is captured once when a trip is added and reused on
/// later launches. This keeps the baked SQLite database off the UI path.
enum TripStaticScheduleStore {
    private static let key = "sbb.tripStaticSegments.v1"
    private static let lock = NSLock()
    private static var memory: [String: [StoredSegment]] = [:]

    static func segments(for tripID: String) -> [GTFSSegment]? {
        lock.lock()
        if let value = memory[tripID] {
            lock.unlock()
            return value.map(\.gtfsSegment)
        }
        let data = UserDefaults.standard.data(forKey: key)
        let decoded = (try? data.flatMap { try JSONDecoder().decode([String: [StoredSegment]].self, from: $0) }) ?? nil
        if let value = decoded?[tripID] {
            memory[tripID] = value
            lock.unlock()
            return value.map(\.gtfsSegment)
        }
        lock.unlock()
        return nil
    }

    static func save(_ segments: [GTFSSegment], for tripID: String) {
        let stored = segments.map(StoredSegment.init)
        lock.lock()
        memory[tripID] = stored
        var all = (try? UserDefaults.standard.data(forKey: key).flatMap {
            try JSONDecoder().decode([String: [StoredSegment]].self, from: $0)
        }) ?? [:]
        all[tripID] = stored
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
        lock.unlock()
    }
}

struct TripExportDocument: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let activeTrips: [Trip]
    let pastTrips: [Trip]
}

enum MissedTrainPromptStore {
    private static let storageKey = "raily.missedTrain.dismissals"

    static func isDismissed(tripID: String, travelDate: Date?) -> Bool {
        load()[identityKey(tripID: tripID, travelDate: travelDate)] != nil
    }

    static func dismiss(tripID: String, travelDate: Date?) {
        var records = load()
        records[identityKey(tripID: tripID, travelDate: travelDate)] = Date()
        save(records)
    }

    static func clear(tripID: String, travelDate: Date?) {
        var records = load()
        records.removeValue(forKey: identityKey(tripID: tripID, travelDate: travelDate))
        save(records)
    }

    static func prune() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        save(load().filter { $0.value >= cutoff })
    }

    private static func identityKey(tripID: String, travelDate: Date?) -> String {
        let date = travelDate.map { ISO8601DateFormatter().string(from: $0).prefix(10) } ?? "undated"
        return "\(tripID)|\(date)"
    }

    private static func load() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return records
    }

    private static func save(_ records: [String: Date]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

final class TripStorage {
    static let shared = TripStorage()

    private let defaults = UserDefaults.standard
    private let storageKey = "sbb.savedTrips"
    private let pastStorageKey = "sbb.pastTrips"
    private init() {}

    func loadTrips() -> [Trip] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([Trip].self, from: data)
        } catch {
            #if DEBUG
            print("[TripStorage] Failed to decode trips: \(error)")
            #endif
            return []
        }
    }

    func saveTrips(_ trips: [Trip]) {
        do {
            let data = try JSONEncoder().encode(trips)
            defaults.set(data, forKey: storageKey)
        } catch {
            #if DEBUG
            print("[TripStorage] Failed to encode trips: \(error)")
            #endif
        }
    }

    func loadPastTrips() -> [Trip] {
        guard let data = defaults.data(forKey: pastStorageKey) else { return [] }
        do {
            return try JSONDecoder().decode([Trip].self, from: data)
        } catch {
            #if DEBUG
            print("[TripStorage] Failed to decode past trips: \(error)")
            #endif
            return []
        }
    }

    func savePastTrips(_ trips: [Trip]) {
        do {
            let data = try JSONEncoder().encode(trips)
            defaults.set(data, forKey: pastStorageKey)
        } catch {
            #if DEBUG
            print("[TripStorage] Failed to encode past trips: \(error)")
            #endif
        }
    }

    /// Encode both lists before acknowledging a shared submission. Replaying a
    /// submission after interruption is safe because imported IDs are stable.
    func persistSharedImport(active: [Trip], past: [Trip]) throws {
        let activeData = try JSONEncoder().encode(active)
        let pastData = try JSONEncoder().encode(past)
        defaults.set(activeData, forKey: storageKey)
        defaults.set(pastData, forKey: pastStorageKey)
    }

    func exportDocument() -> TripExportDocument {
        TripExportDocument(
            schemaVersion: 1,
            exportedAt: Date(),
            activeTrips: loadTrips(),
            pastTrips: loadPastTrips()
        )
    }

    func merge(_ document: TripExportDocument) -> (active: [Trip], past: [Trip]) {
        let existingActive = loadTrips()
        let existingPast = loadPastTrips()
        let activeKeys = Set(existingActive.map(stableKey(for:)))
        let pastKeys = Set(existingPast.map(stableKey(for:)))
        let active = existingActive + document.activeTrips.filter { !activeKeys.contains(stableKey(for: $0)) }
        let past = existingPast + document.pastTrips.filter { !pastKeys.contains(stableKey(for: $0)) }
        saveTrips(active)
        savePastTrips(past)
        return (active, past)
    }

    func deleteAllData() {
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: pastStorageKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("raily.") {
            defaults.removeObject(forKey: key)
        }
    }

    private func stableKey(for trip: Trip) -> String {
        let date = trip.travelDate.map { ISO8601DateFormatter().string(from: $0).prefix(10) } ?? "undated"
        return "\(trip.id)|\(date)"
    }
}
