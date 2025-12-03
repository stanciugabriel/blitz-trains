import Foundation

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
}
