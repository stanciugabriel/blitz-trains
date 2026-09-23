import Foundation

protocol TripScheduleProviding {
    func stopSchedule(for tripId: String, stopId: String) -> GTFSDataSource.GTFSStopSchedule?

    func stopSchedules(for tripId: String, stopIds: [String]) -> [String: GTFSDataSource.GTFSStopSchedule]
}

extension GTFSDataSource: TripScheduleProviding {}

extension TripScheduleProviding {
    func stopSchedules(for tripId: String, stopIds: [String]) -> [String: GTFSDataSource.GTFSStopSchedule] {
        stopIds.reduce(into: [:]) { result, stopID in
            if let schedule = stopSchedule(for: tripId, stopId: stopID) {
                result[stopID] = schedule
            }
        }
    }
}

enum TripPhase: Equatable {
    case preDeparture
    case inTransit
    case completed
}

enum TripTerminalEvent {
    case departure
    case arrival
}

struct ResolvedTripTiming: Equatable {
    let scheduledDeparture: Date?
    let scheduledArrival: Date?
    let adjustedDeparture: Date?
    let adjustedArrival: Date?
    let originDelayMinutes: Int
    let destinationDelayMinutes: Int
    let headerDelayMinutes: Int?
    let phase: TripPhase
    let originPlatform: String?
    let destinationPlatform: String?
    let nextStopName: String?
    let nextStopArrival: Date?
    let stationsRemaining: Int

    var duration: TimeInterval? {
        guard let scheduledDeparture, let scheduledArrival else { return nil }
        return scheduledArrival.timeIntervalSince(scheduledDeparture)
    }

    static let empty = ResolvedTripTiming(
        scheduledDeparture: nil,
        scheduledArrival: nil,
        adjustedDeparture: nil,
        adjustedArrival: nil,
        originDelayMinutes: 0,
        destinationDelayMinutes: 0,
        headerDelayMinutes: nil,
        phase: .preDeparture,
        originPlatform: nil,
        destinationPlatform: nil,
        nextStopName: nil,
        nextStopArrival: nil,
        stationsRemaining: 0
    )

    var departureStatusText: String {
        TripTimingResolver.statusText(for: originDelayMinutes)
    }

    var arrivalStatusText: String {
        TripTimingResolver.statusText(for: destinationDelayMinutes)
    }
}

struct TripTimingResolver {
    private let scheduleProvider: TripScheduleProviding
    private let platformProvider: StaticPlatformProviding
    private let calendar: Calendar

    init(
        scheduleProvider: TripScheduleProviding = GTFSDataSource.shared,
        platformProvider: StaticPlatformProviding = StaticPlatformDataSource.shared,
        calendar: Calendar = .current
    ) {
        self.scheduleProvider = scheduleProvider
        self.platformProvider = platformProvider
        self.calendar = calendar
    }

    func resolve(
        trip: Trip,
        delayInfo: DelayInfo?,
        referenceDate: Date = Date(),
        includeProgressDetails: Bool = true
    ) -> ResolvedTripTiming {
        guard let travelDate = trip.travelDate else {
            return emptyTiming(trip: trip, delayInfo: delayInfo)
        }

        let activeDelay = delayInfo?.delayMinutes ?? trip.delayMinutes ?? 0
        let tripIdentifier = trip.gtfsTripId ?? trip.id
        let stops = trip.stops?.sorted { $0.sequence < $1.sequence } ?? []
        let originStop = resolvedStop(id: trip.originStopId, sequence: trip.originSequence, in: stops)
        let destinationStop = resolvedStop(id: trip.destinationStopId, sequence: trip.destinationSequence, in: stops)
        let originId = trip.originStopId ?? originStop?.id
        let destinationId = trip.destinationStopId ?? destinationStop?.id

        let originSchedule = originId.flatMap { scheduleProvider.stopSchedule(for: tripIdentifier, stopId: $0) }
        let destinationSchedule = destinationId.flatMap { scheduleProvider.stopSchedule(for: tripIdentifier, stopId: $0) }
        let baseDate = serviceBaseDate(
            for: travelDate,
            originSchedule: originSchedule,
            destinationSchedule: destinationSchedule,
            referenceDate: referenceDate
        )

        let originDelay = terminalDelay(
            for: .departure,
            stop: originStop,
            stopName: trip.originName,
            delayInfo: delayInfo,
            fallback: activeDelay
        )
        let destinationDelay = terminalDelay(
            for: .arrival,
            stop: destinationStop,
            stopName: trip.destinationName,
            delayInfo: delayInfo,
            fallback: activeDelay
        )

        let rawDeparture = originSchedule?.departureDate(on: baseDate) ?? originSchedule?.arrivalDate(on: baseDate)
        let rawArrival = destinationSchedule?.arrivalDate(on: baseDate) ?? destinationSchedule?.departureDate(on: baseDate)
        let scheduledDeparture = rawDeparture
        let scheduledArrival = ScheduleDateUtils.normalizedArrival(rawArrival, relativeTo: scheduledDeparture)
        let adjustedDeparture = scheduledDeparture?.addingTimeInterval(TimeInterval(originDelay * 60))
        let adjustedArrival = scheduledArrival?.addingTimeInterval(TimeInterval(destinationDelay * 60))
        let phase = phase(
            referenceDate: referenceDate,
            departure: adjustedDeparture,
            arrival: adjustedArrival
        )
        let nextStop = includeProgressDetails
            ? nextStop(
                for: trip,
                stops: stops,
                baseDate: baseDate,
                referenceDate: referenceDate,
                activeDelay: activeDelay,
                delayInfo: delayInfo
            )
            : (name: nil, arrivalTime: nil, stationsRemaining: 0)

        return ResolvedTripTiming(
            scheduledDeparture: scheduledDeparture,
            scheduledArrival: scheduledArrival,
            adjustedDeparture: adjustedDeparture,
            adjustedArrival: adjustedArrival,
            originDelayMinutes: originDelay,
            destinationDelayMinutes: destinationDelay,
            headerDelayMinutes: delayInfo?.delayMinutes ?? trip.delayMinutes,
            phase: phase,
            originPlatform: terminalPlatform(for: .departure, trip: trip, stop: originStop, delayInfo: delayInfo),
            destinationPlatform: terminalPlatform(for: .arrival, trip: trip, stop: destinationStop, delayInfo: delayInfo),
            nextStopName: phase == .inTransit ? nextStop.name : nil,
            nextStopArrival: phase == .inTransit ? nextStop.arrivalTime : nil,
            stationsRemaining: phase == .inTransit ? nextStop.stationsRemaining : 0
        )
    }

    static func statusText(for minutes: Int) -> String {
        if minutes > 0 { return "\(minutes)m late" }
        if minutes < 0 { return "\(abs(minutes))m early" }
        return "On time"
    }

    private func emptyTiming(trip: Trip, delayInfo: DelayInfo?) -> ResolvedTripTiming {
        let activeDelay = delayInfo?.delayMinutes ?? trip.delayMinutes ?? 0
        return ResolvedTripTiming(
            scheduledDeparture: nil,
            scheduledArrival: nil,
            adjustedDeparture: nil,
            adjustedArrival: nil,
            originDelayMinutes: activeDelay,
            destinationDelayMinutes: activeDelay,
            headerDelayMinutes: delayInfo?.delayMinutes ?? trip.delayMinutes,
            phase: .preDeparture,
            originPlatform: nil,
            destinationPlatform: nil,
            nextStopName: nil,
            nextStopArrival: nil,
            stationsRemaining: 0
        )
    }

    private func serviceBaseDate(
        for travelDate: Date,
        originSchedule: GTFSDataSource.GTFSStopSchedule?,
        destinationSchedule: GTFSDataSource.GTFSStopSchedule?,
        referenceDate: Date
    ) -> Date {
        let storedBase = calendar.startOfDay(for: travelDate)
        let candidateBases = [-1, 0, 1].compactMap {
            calendar.date(byAdding: .day, value: $0, to: storedBase)
        }

        let candidates = candidateBases.compactMap { base -> (base: Date, departure: Date, arrival: Date?)? in
            guard let departure = originSchedule?.departureDate(on: base) ?? originSchedule?.arrivalDate(on: base) else {
                return nil
            }
            let rawArrival = destinationSchedule?.arrivalDate(on: base) ?? destinationSchedule?.departureDate(on: base)
            let arrival = ScheduleDateUtils.normalizedArrival(rawArrival, relativeTo: departure)
            return (base, departure, arrival)
        }

        if let activeService = candidates
            .filter({
                guard let arrival = $0.arrival else { return false }
                return referenceDate >= $0.departure.addingTimeInterval(-5 * 60)
                    && referenceDate <= arrival.addingTimeInterval(60 * 60)
            })
            .min(by: { lhs, rhs in
                guard let lhsArrival = lhs.arrival, let rhsArrival = rhs.arrival else {
                    return lhs.departure < rhs.departure
                }
                return lhsArrival < rhsArrival
            }) {
            return activeService.base
        }

        if let nearestUpcoming = candidates
            .filter({ $0.departure >= referenceDate.addingTimeInterval(-5 * 60) })
            .min(by: { $0.departure < $1.departure }) {
            return nearestUpcoming.base
        }

        return storedBase
    }

    private func phase(referenceDate: Date, departure: Date?, arrival: Date?) -> TripPhase {
        guard let departure else { return .preDeparture }
        if let arrival, referenceDate >= arrival {
            return .completed
        }
        if referenceDate >= departure {
            return .inTransit
        }
        return .preDeparture
    }

    private func terminalDelay(
        for event: TripTerminalEvent,
        stop: StoredStop?,
        stopName: String?,
        delayInfo: DelayInfo?,
        fallback: Int
    ) -> Int {
        switch event {
        case .departure:
            if let value = stop?.departureDelayMinutes { return value }
        case .arrival:
            if let value = stop?.arrivalDelayMinutes { return value }
        }

        if let stationDelay = stationDelay(for: stopName ?? stop?.name, in: delayInfo) {
            switch event {
            case .departure:
                if let value = stationDelay.departureDelayMinutes { return value }
            case .arrival:
                if let value = stationDelay.arrivalDelayMinutes { return value }
            }
        }

        return fallback
    }

    private func nextStop(
        for trip: Trip,
        stops: [StoredStop],
        baseDate: Date,
        referenceDate: Date,
        activeDelay: Int,
        delayInfo: DelayInfo?
    ) -> (name: String?, arrivalTime: Date?, stationsRemaining: Int) {
        guard !stops.isEmpty else { return (nil, nil, 0) }

        let lower = trip.originSequence ?? stops.first?.sequence ?? 0
        let upper = trip.destinationSequence ?? stops.last?.sequence ?? lower
        let segmentStops = stops.filter { $0.sequence > lower && $0.sequence <= upper }
        guard !segmentStops.isEmpty else { return (trip.destinationName, nil, 0) }

        let tripIdentifier = trip.gtfsTripId ?? trip.id
        let schedules = scheduleProvider.stopSchedules(
            for: tripIdentifier,
            stopIds: segmentStops.map(\.id)
        )
        var remaining: [(name: String?, arrivalTime: Date?)] = []
        var previousDate: Date?

        for stop in segmentStops {
            guard let schedule = schedules[stop.id] else { continue }
            let rawArrival = schedule.arrivalDate(on: baseDate) ?? schedule.departureDate(on: baseDate)
            let delay = terminalDelay(
                for: .arrival,
                stop: stop,
                stopName: stop.name,
                delayInfo: delayInfo,
                fallback: activeDelay
            )
            guard let arrival = ScheduleDateUtils
                .normalizedArrival(rawArrival, relativeTo: previousDate)
                .map({ $0.addingTimeInterval(TimeInterval(delay * 60)) })
            else { continue }

            previousDate = arrival
            if arrival > referenceDate {
                remaining.append((stop.name, arrival))
            }
        }

        if let next = remaining.first {
            return (next.name, next.arrivalTime, remaining.count)
        }

        return (trip.destinationName, nil, 0)
    }

    private func terminalPlatform(
        for event: TripTerminalEvent,
        trip: Trip,
        stop: StoredStop?,
        delayInfo: DelayInfo?
    ) -> String? {
        let trainId = trip.gtfsTripId ?? trip.id
        let stopId: String?
        let stopName: String?
        let tripPlatform: String?

        switch event {
        case .departure:
            stopId = trip.originStopId ?? stop?.id
            stopName = trip.originName ?? stop?.name
            tripPlatform = trip.originPlatform
        case .arrival:
            stopId = trip.destinationStopId ?? stop?.id
            stopName = trip.destinationName ?? stop?.name
            tripPlatform = trip.destinationPlatform
        }

        if let platform = sanitizedPlatform(stationDelay(for: stopName, in: delayInfo)?.platform) {
            return platform
        }
        if let stopId, let platform = sanitizedPlatform(platformProvider.platform(trainId: trainId, stationId: stopId)) {
            return platform
        }
        if let platform = sanitizedPlatform(stop?.platform) {
            return platform
        }
        return sanitizedPlatform(tripPlatform)
    }

    private func sanitizedPlatform(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func stationDelay(for stationName: String?, in delayInfo: DelayInfo?) -> StationDelay? {
        guard let stationName, let delayInfo else { return nil }
        let normalized = normalizeStationName(stationName)
        return delayInfo.stationDelays.first { normalizeStationName($0.stationName) == normalized }
    }

    private func normalizeStationName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedStop(id: String?, sequence: Int?, in stops: [StoredStop]) -> StoredStop? {
        if let id, let stop = stops.first(where: { $0.id == id }) {
            return stop
        }
        if let sequence, let stop = stops.first(where: { $0.sequence == sequence }) {
            return stop
        }
        return nil
    }
}
