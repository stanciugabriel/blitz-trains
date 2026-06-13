import ActivityKit
import Foundation

final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private let dataSource = GTFSDataSource.shared
    private let timingResolver = TripTimingResolver()

    private init() {}

    enum StartResult: Equatable {
        case started
        case alreadyRunning
        case activitiesDisabled
        case unavailable(String)
        case failed(String)

        var message: String {
            switch self {
            case .started:
                return "Live Activity started"
            case .alreadyRunning:
                return "Live Activity already running"
            case .activitiesDisabled:
                return "Live Activities are disabled for Blitz"
            case .unavailable(let message):
                return message
            case .failed(let message):
                return "Live Activity failed: \(message)"
            }
        }
    }

    func isActivityRunning(for tripID: String) -> Bool {
        activity(for: tripID) != nil
    }

    func activitiesEnabled() -> Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func activeActivityCount() -> Int {
        Activity<TrainLiveActivityAttributes>.activities.count
    }

    func diagnosticSummary(for tripID: String) -> String {
        let enabled = activitiesEnabled() ? "enabled" : "disabled"
        let running = isActivityRunning(for: tripID) ? "running" : "not running"
        return "Live Activities \(enabled) • \(running) • \(activeActivityCount()) active"
    }

    @discardableResult
    func startActivity(for trip: Trip, delayInfo: DelayInfo? = nil) -> StartResult {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return .activitiesDisabled }
        guard trip.travelDate != nil, trip.originStopId != nil, trip.destinationStopId != nil else {
            return .unavailable("Live Activity needs a saved trip with route timing")
        }
        guard activity(for: trip.id) == nil else {
            updateActivity(for: trip, delayInfo: delayInfo)
            return .alreadyRunning
        }

        let branding = OperatorBrandingCatalog.branding(for: trip.agencyId)
        let attributes = TrainLiveActivityAttributes(
            tripID: trip.id,
            trainNumber: trainNumber(for: trip),
            operatorName: operatorName(for: branding.logoName),
            originStationCode: stationCode(for: trip.originStopId, name: trip.originName),
            originStationName: trip.originName ?? "Origin",
            destinationStationCode: stationCode(for: trip.destinationStopId, name: trip.destinationName),
            destinationStationName: trip.destinationName ?? "Destination",
            coachAndSeat: coachAndSeatText(for: trip),
            agencyId: trip.agencyId,
            operatorLogoName: branding.logoName
        )
        let state = contentState(for: trip, delayInfo: delayInfo)

        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: staleDate(for: state))
            )
            return .started
        } catch {
            #if DEBUG
            print("[LiveActivityManager] Failed to start activity: \(error)")
            #endif
            return .failed(error.localizedDescription)
        }
    }

    func updateActivity(for trip: Trip, delayInfo: DelayInfo? = nil) {
        guard let activity = activity(for: trip.id) else { return }
        let state = contentState(for: trip, delayInfo: delayInfo)

        Task {
            let content = ActivityContent(state: state, staleDate: staleDate(for: state))
            if state.journeyPhase == .completed {
                await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(3600)))
            } else {
                await activity.update(content)
            }
        }
    }

    func endActivity(for tripID: String) {
        guard let activity = activity(for: tripID) else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func activity(for tripID: String) -> Activity<TrainLiveActivityAttributes>? {
        Activity<TrainLiveActivityAttributes>.activities.first { $0.attributes.tripID == tripID }
    }

    private func contentState(
        for trip: Trip,
        delayInfo: DelayInfo?
    ) -> TrainLiveActivityAttributes.ContentState {
        let now = Date()
        let effectiveDelayInfo = delayInfo ?? LiveDelayStore.shared.info(for: trip.id)
        let timing = timingResolver.resolve(
            trip: trip,
            delayInfo: effectiveDelayInfo,
            referenceDate: now
        )
        let activeDelay = timing.headerDelayMinutes ?? trip.delayMinutes ?? 0
        let phase: TrainLiveActivityAttributes.ContentState.JourneyPhase
        switch timing.phase {
        case .preDeparture:
            phase = .preDeparture
        case .inTransit:
            phase = .inTransit
        case .completed:
            phase = .completed
        }
        let departureTime = timing.adjustedDeparture ?? timing.scheduledDeparture ?? now
        let arrivalTime = timing.adjustedArrival ?? timing.scheduledArrival ?? departureTime.addingTimeInterval(60)

        return TrainLiveActivityAttributes.ContentState(
            journeyPhase: phase,
            platform: timing.originPlatform,
            departureTime: departureTime,
            arrivalTime: arrivalTime,
            nextStopName: phase == .inTransit ? timing.nextStopName : nil,
            nextStopArrivalTime: phase == .inTransit ? timing.nextStopArrival : nil,
            stationsRemaining: phase == .inTransit ? timing.stationsRemaining : 0,
            isDelayed: activeDelay > 0,
            dataTimestamp: now,
            delayMinutes: activeDelay
        )
    }

    private func staleDate(for state: TrainLiveActivityAttributes.ContentState) -> Date? {
        switch state.journeyPhase {
        case .preDeparture:
            return state.departureTime.addingTimeInterval(10 * 60)
        case .inTransit:
            return state.arrivalTime.addingTimeInterval(10 * 60)
        case .completed:
            return state.dataTimestamp.addingTimeInterval(60 * 60)
        }
    }

    private func timeline(
        for trip: Trip,
        delayInfo: DelayInfo?,
        activeDelay: Int
    ) -> (
        boardingArrival: Date?,
        boardingDeparture: Date?,
        destinationArrival: Date?,
        nextStopName: String?,
        nextStopArrivalTime: Date?,
        stationsRemaining: Int
    ) {
        guard let travelDate = trip.travelDate else {
            return (nil, nil, nil, nil, nil, 0)
        }

        let tripIdentifier = trip.gtfsTripId ?? trip.id
        let stops = trip.stops?.sorted { $0.sequence < $1.sequence } ?? []
        let originStop = resolvedStop(id: trip.originStopId, sequence: trip.originSequence, in: stops)
        let destinationStop = resolvedStop(id: trip.destinationStopId, sequence: trip.destinationSequence, in: stops)
        let originId = trip.originStopId ?? originStop?.id
        let destinationId = trip.destinationStopId ?? destinationStop?.id

        let originSchedule = originId.flatMap { dataSource.stopSchedule(for: tripIdentifier, stopId: $0) }
        let destinationSchedule = destinationId.flatMap { dataSource.stopSchedule(for: tripIdentifier, stopId: $0) }
        let baseDate = serviceBaseDate(
            for: travelDate,
            originSchedule: originSchedule,
            destinationSchedule: destinationSchedule
        )

        let boardingArrivalDelay = terminalDelay(
            for: .arrival,
            stop: originStop,
            stopName: trip.originName,
            delayInfo: delayInfo,
            fallback: activeDelay
        )
        let boardingDepartureDelay = terminalDelay(
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

        let rawBoardingArrival = originSchedule?.arrivalDate(on: baseDate)
        let rawBoardingDeparture = originSchedule?.departureDate(on: baseDate) ?? rawBoardingArrival
        let rawDestinationArrival = destinationSchedule?.arrivalDate(on: baseDate) ?? destinationSchedule?.departureDate(on: baseDate)

        let boardingArrival = adjustedDate(rawBoardingArrival, relativeTo: nil, delay: boardingArrivalDelay)
        let boardingDeparture = adjustedDate(rawBoardingDeparture, relativeTo: nil, delay: boardingDepartureDelay)
        let destinationArrival = adjustedDate(rawDestinationArrival, relativeTo: boardingDeparture, delay: destinationDelay)
        let nextStop = nextStop(for: trip, baseDate: baseDate, reference: Date(), delayInfo: delayInfo, activeDelay: activeDelay)

        return (
            boardingArrival,
            boardingDeparture,
            destinationArrival,
            nextStop.name,
            nextStop.arrivalTime,
            nextStop.stationsRemaining
        )
    }

    private func serviceBaseDate(
        for travelDate: Date,
        originSchedule: GTFSDataSource.GTFSStopSchedule?,
        destinationSchedule: GTFSDataSource.GTFSStopSchedule?
    ) -> Date {
        let calendar = Calendar.current
        let storedBase = calendar.startOfDay(for: travelDate)
        let now = Date()
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
                return now >= $0.departure.addingTimeInterval(-5 * 60)
                    && now <= arrival.addingTimeInterval(60 * 60)
            })
            .min(by: { lhs, rhs in
                guard let lhsArrival = lhs.arrival, let rhsArrival = rhs.arrival else { return lhs.departure < rhs.departure }
                return lhsArrival < rhsArrival
            }) {
            return activeService.base
        }

        if let nearestUpcoming = candidates
            .filter({ $0.departure >= now.addingTimeInterval(-5 * 60) })
            .min(by: { $0.departure < $1.departure }) {
            return nearestUpcoming.base
        }

        return storedBase
    }

    private enum StopEvent {
        case arrival
        case departure
    }

    private func terminalDelay(
        for event: StopEvent,
        stop: StoredStop?,
        stopName: String?,
        delayInfo: DelayInfo?,
        fallback: Int
    ) -> Int {
        switch event {
        case .arrival:
            if let value = stop?.arrivalDelayMinutes { return value }
        case .departure:
            if let value = stop?.departureDelayMinutes { return value }
        }

        if let stationDelay = stationDelay(for: stopName ?? stop?.name, in: delayInfo) {
            switch event {
            case .arrival:
                if let value = stationDelay.arrivalDelayMinutes { return value }
            case .departure:
                if let value = stationDelay.departureDelayMinutes { return value }
            }
        }

        return fallback
    }

    private func nextStop(
        for trip: Trip,
        baseDate: Date,
        reference: Date,
        delayInfo: DelayInfo?,
        activeDelay: Int
    ) -> (name: String?, arrivalTime: Date?, stationsRemaining: Int) {
        guard let stops = trip.stops?.sorted(by: { $0.sequence < $1.sequence }), !stops.isEmpty else {
            return (nil, nil, 0)
        }

        let lower = trip.originSequence ?? stops.first?.sequence ?? 0
        let upper = trip.destinationSequence ?? stops.last?.sequence ?? lower
        let segmentStops = stops.filter { $0.sequence > lower && $0.sequence <= upper }
        guard !segmentStops.isEmpty else { return (trip.destinationName, nil, 0) }

        let tripIdentifier = trip.gtfsTripId ?? trip.id
        var remaining: [(name: String?, arrivalTime: Date?)] = []
        for stop in segmentStops {
            guard let schedule = dataSource.stopSchedule(for: tripIdentifier, stopId: stop.id) else { continue }
            let rawArrival = schedule.arrivalDate(on: baseDate) ?? schedule.departureDate(on: baseDate)
            let delay = terminalDelay(
                for: .arrival,
                stop: stop,
                stopName: stop.name,
                delayInfo: delayInfo,
                fallback: activeDelay
            )
            guard let arrival = adjustedDate(rawArrival, relativeTo: nil, delay: delay) else { continue }
            if arrival > reference {
                remaining.append((stop.name, arrival))
            }
        }

        if let next = remaining.first {
            return (next.name, next.arrivalTime, remaining.count)
        }

        return (trip.destinationName, nil, 0)
    }

    private func adjustedDate(_ date: Date?, relativeTo reference: Date?, delay: Int) -> Date? {
        guard let date else { return nil }
        let normalized = ScheduleDateUtils.normalizedArrival(date, relativeTo: reference) ?? date
        return normalized.addingTimeInterval(TimeInterval(delay * 60))
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

    private func trainNumber(for trip: Trip) -> String {
        let compactTitle = trip.title
            .split(separator: " ")
            .joined()
        if compactTitle.contains(where: \.isLetter), compactTitle.contains(where: \.isNumber) {
            return compactTitle
        }

        if let last = trip.title.split(separator: " ").last {
            let value = String(last)
            if !value.isEmpty { return value }
        }
        return trip.gtfsTripId ?? trip.id
    }

    private func operatorName(for logoName: String) -> String {
        switch logoName {
        case "cfr":
            return "CFR Călători"
        case "regio":
            return "Regio Călători"
        case "softrans":
            return "Softrans"
        case "astra":
            return "Astra Trans Carpatic"
        case "tfc":
            return "Transferoviar"
        case "interregional":
            return "InterRegional"
        default:
            return "Blitz"
        }
    }

    private func stationCode(for stopId: String?, name: String?) -> String {
        if let stopId {
            let suffix = stopId
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .last
                .map(String.init) ?? stopId
            if suffix.count <= 4 { return suffix.uppercased() }
        }

        let words = (name ?? "")
            .split(separator: " ")
            .prefix(3)
            .compactMap(\.first)
        let code = String(words).uppercased()
        return code.isEmpty ? "STN" : code
    }

    private func coachAndSeatText(for trip: Trip) -> String? {
        let car = trip.seatCar?.trimmingCharacters(in: .whitespacesAndNewlines)
        let seats = trip.seatNumbers?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch (car?.isEmpty == false ? car : nil, seats?.isEmpty == false ? seats : nil) {
        case let (car?, seats?):
            return "Coach \(car) • Seat \(seats.joined(separator: ", "))"
        case let (car?, nil):
            return "Coach \(car)"
        case let (nil, seats?):
            return "Seat \(seats.joined(separator: ", "))"
        case (nil, nil):
            return nil
        }
    }

    private func platform(for trip: Trip, delayInfo: DelayInfo?) -> String? {
        let stops = trip.stops?.sorted(by: { $0.sequence < $1.sequence }) ?? []
        let originStop = resolvedStop(id: trip.originStopId, sequence: trip.originSequence, in: stops)

        if let platform = originStop?.platform, !platform.isEmpty {
            return platform
        }
        if let platform = stationDelay(for: trip.originName ?? originStop?.name, in: delayInfo)?.platform, !platform.isEmpty {
            return platform
        }
        if let storedInfo = LiveDelayStore.shared.info(for: trip.id),
           let platform = stationDelay(for: trip.originName ?? originStop?.name, in: storedInfo)?.platform,
           !platform.isEmpty {
            return platform
        }
        if let platform = trip.originPlatform, !platform.isEmpty { return platform }
        return nil
    }
}
