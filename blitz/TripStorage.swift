import Foundation

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
    private let storageKey = "savedTrips"
    private let pastStorageKey = "pastTrips"
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
