import Foundation

enum ScheduleDateUtils {
    static let dayInterval: TimeInterval = 24 * 60 * 60

    static func normalizedArrival(_ arrival: Date?, relativeTo departure: Date?) -> Date? {
        guard var arrival else { return nil }
        guard let departure else { return arrival }
        if arrival > departure { return arrival }

        var iterations = 0
        while arrival <= departure && iterations < 7 {
            arrival = arrival.addingTimeInterval(dayInterval)
            iterations += 1
        }
        return arrival
    }

    static func shiftedForward(_ date: Date, after reference: Date?) -> Date {
        guard let reference else { return date }
        var candidate = date
        var iterations = 0
        while candidate < reference && iterations < 7 {
            candidate = candidate.addingTimeInterval(dayInterval)
            iterations += 1
        }
        return candidate
    }
}
