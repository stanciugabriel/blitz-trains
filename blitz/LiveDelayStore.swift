import Foundation
import UserNotifications

enum RailyNotificationPreferences {
    private static let delayKey = "raily.notifications.delayChanges"
    private static let platformKey = "raily.notifications.platformChanges"
    private static let earlyKey = "raily.notifications.earlyTrains"
    private static let thresholdKey = "raily.notifications.delayThreshold"

    static var delayChangesEnabled: Bool {
        get { UserDefaults.standard.object(forKey: delayKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: delayKey) }
    }

    static var platformChangesEnabled: Bool {
        get { UserDefaults.standard.object(forKey: platformKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: platformKey) }
    }

    static var earlyTrainsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: earlyKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: earlyKey) }
    }

    static var delayChangeThreshold: Int {
        get { UserDefaults.standard.object(forKey: thresholdKey) as? Int ?? 5 }
        set { UserDefaults.standard.set(newValue, forKey: thresholdKey) }
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

enum RailyNotificationEvent: Equatable {
    case delayChanged(old: Int, new: Int)
    case platformChanged(old: String, new: String)
    case becameEarly(minutes: Int)

    var identifierSuffix: String {
        switch self {
        case let .delayChanged(old, new): return "delay-\(old)-\(new)"
        case let .platformChanged(old, new): return "platform-\(old)-\(new)"
        case let .becameEarly(minutes): return "early-\(minutes)"
        }
    }
}

extension RailyNotificationPreferences {
    static func event(
        previous: DelayInfo,
        current: DelayInfo,
        trip: Trip? = nil
    ) -> RailyNotificationEvent? {
        let oldDelay = effectiveDelay(for: previous, trip: trip)
        let newDelay = effectiveDelay(for: current, trip: trip)

        if delayChangesEnabled,
           let oldDelay,
           let newDelay,
           abs(newDelay - oldDelay) >= delayChangeThreshold {
            return .delayChanged(old: oldDelay, new: newDelay)
        }

        if platformChangesEnabled,
           let oldPlatform = previous.platform,
           let newPlatform = current.platform,
           oldPlatform != newPlatform {
            return .platformChanged(old: oldPlatform, new: newPlatform)
        }

        if earlyTrainsEnabled,
           let oldDelay,
           let newDelay,
           oldDelay >= 0,
           newDelay < 0 {
            return .becameEarly(minutes: abs(newDelay))
        }

        return nil
    }

    private static func effectiveDelay(for info: DelayInfo, trip: Trip?) -> Int? {
        guard let trip else { return info.delayMinutes }
        return TripTimingResolver().resolve(
            trip: trip,
            delayInfo: info,
            includeProgressDetails: false
        ).destinationDelayMinutes
    }
}

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
        let previous = cache[tripID]
        cache[tripID] = info
        persist()
        scheduleNotifications(for: tripID, previous: previous, current: info)
        NotificationCenter.default.post(name: .liveDelayInfoUpdated, object: tripID)
    }

    func clear(tripID: String) {
        cache.removeValue(forKey: tripID)
        persist()
        NotificationCenter.default.post(name: .liveDelayInfoUpdated, object: tripID)
    }

    func clearAll() {
        cache.removeAll()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func scheduleNotifications(for tripID: String, previous: DelayInfo?, current: DelayInfo) {
        guard let previous,
              let fetchedAt = current.fetchedAt,
              Date().timeIntervalSince(fetchedAt) <= 20 * 60 else { return }

        let trip = TripStorage.shared.loadTrips().first { $0.id == tripID }
        guard let event = RailyNotificationPreferences.event(
            previous: previous,
            current: current,
            trip: trip
        ) else { return }

        let title: String
        let body: String
        switch event {
        case let .delayChanged(_, new):
            let direction = new >= 0 ? "late" : "early"
            title = "Train timing changed"
            body = "\(trip?.title ?? "Your train") is now \(abs(new)) minutes \(direction)."
        case let .platformChanged(old, new):
            title = "Platform changed"
            body = "\(trip?.title ?? "Your train") changed from platform \(old) to platform \(new)."
        case let .becameEarly(minutes):
            title = "Train is running early"
            body = "\(trip?.title ?? "Your train") is currently \(minutes) minutes early."
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "ro.openlabs.blitz.\(tripID)-\(event.identifierSuffix)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

extension Notification.Name {
    static let liveDelayInfoUpdated = Notification.Name("liveDelayInfoUpdated")
}
