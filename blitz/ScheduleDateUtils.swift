import Foundation

enum ScheduleDateUtils {
    static let dayInterval: TimeInterval = 24 * 60 * 60

    /// Returns the calendar-day offset of a stop within a service. SQLite may
    /// encode this explicitly (`1 day, 0:06:00`) or as a normalized clock
    /// value (`0:06:00`) after the route crosses midnight.
    static func serviceDayOffset(for times: [Int?], through index: Int) -> Int {
        guard !times.isEmpty else { return 0 }

        var offset = 0
        var previousClockSeconds: Int?
        var previousHadExplicitDay = false

        for (position, value) in times.enumerated() {
            guard let value else { continue }
            let explicitDay = max(0, value / Int(dayInterval))
            let clockSeconds = value % Int(dayInterval)

            if explicitDay > 0 {
                offset = max(offset, explicitDay)
            } else if let previousClockSeconds,
                      clockSeconds < previousClockSeconds,
                      !previousHadExplicitDay {
                offset += 1
            }

            previousClockSeconds = clockSeconds
            previousHadExplicitDay = explicitDay > 0

            if position >= index {
                return offset
            }
        }
        return offset
    }

    static func serviceDate(forBoardingDate boardingDate: Date, dayOffset: Int, calendar: Calendar = .current) -> Date {
        let boardingDay = calendar.startOfDay(for: boardingDate)
        return calendar.date(byAdding: .day, value: -max(0, dayOffset), to: boardingDay) ?? boardingDay
    }

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
