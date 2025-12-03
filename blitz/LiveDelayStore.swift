import Foundation

final class LiveDelayStore {
    static let shared = LiveDelayStore()

    private let defaultsKey = "live_delay_store"
    private var cache: [String: DelayInfo]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: DelayInfo].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    func info(for tripID: String) -> DelayInfo? {
        cache[tripID]
    }

    func save(info: DelayInfo, for tripID: String) {
        cache[tripID] = info
        persist()
        NotificationCenter.default.post(name: .liveDelayInfoUpdated, object: tripID)
    }

    func clear(tripID: String) {
        cache.removeValue(forKey: tripID)
        persist()
        NotificationCenter.default.post(name: .liveDelayInfoUpdated, object: tripID)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

extension Notification.Name {
    static let liveDelayInfoUpdated = Notification.Name("liveDelayInfoUpdated")
}
