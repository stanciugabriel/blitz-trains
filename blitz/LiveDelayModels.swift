import Foundation

struct StationDelay: Equatable, Codable {
    let stationName: String
    let arrivalDelayMinutes: Int?
    let departureDelayMinutes: Int?
    let platform: String?
}

/// The latest delay snapshot received from the live trip API.
struct DelayInfo: Equatable, Codable {
    let delayMinutes: Int?
    let platform: String?
    let statusText: String?
    let stationDelays: [StationDelay]
    let fetchedAt: Date?

    init(
        delayMinutes: Int?,
        platform: String?,
        statusText: String? = nil,
        stationDelays: [StationDelay] = [],
        fetchedAt: Date? = Date()
    ) {
        self.delayMinutes = delayMinutes
        self.platform = platform
        self.statusText = statusText
        self.stationDelays = stationDelays
        self.fetchedAt = fetchedAt
    }
}

extension DelayInfo {
    var freshnessText: String? {
        guard let fetchedAt else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(fetchedAt)))
        if seconds < 60 { return "Synced just now" }
        if seconds < 3600 { return "Synced \(max(1, seconds / 60))m ago" }
        return "Synced \(seconds / 3600)h ago"
    }
}
