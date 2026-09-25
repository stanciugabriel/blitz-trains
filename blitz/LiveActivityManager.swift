import ActivityKit
import Foundation
import BackgroundTasks

let automaticLiveActivityTaskIdentifier = "ro.openlabs.blitz.live-activity-start"

final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private let timingResolver = TripTimingResolver()

    private init() {}

    /// Starts an activity only when it is within the one-hour activation
    /// window. Future trips are picked up by the registered BGAppRefreshTask.
    @discardableResult
    func startOrSchedule(for trip: Trip, delayInfo: DelayInfo? = nil, now: Date = Date()) -> StartResult? {
        guard trip.travelDate != nil else {
            return startActivity(for: trip, delayInfo: delayInfo)
        }
        let timing = timingResolver.resolve(trip: trip, delayInfo: delayInfo ?? LiveDelayStore.shared.info(for: trip.id), referenceDate: now)
        guard let departure = timing.adjustedDeparture ?? timing.scheduledDeparture else {
            return startActivity(for: trip, delayInfo: delayInfo)
        }
        if departure.timeIntervalSince(now) <= 60 * 60 {
            return startActivity(for: trip, delayInfo: delayInfo)
        }
        scheduleNextAutomaticStart(for: [trip], now: now)
        return nil
    }

    func scheduleNextAutomaticStart(for trips: [Trip] = TripStorage.shared.loadTrips(), now: Date = Date()) {
        let candidates = trips.compactMap { trip -> Date? in
            let timing = timingResolver.resolve(
                trip: trip,
                delayInfo: LiveDelayStore.shared.info(for: trip.id),
                referenceDate: now
            )
            guard let departure = timing.adjustedDeparture ?? timing.scheduledDeparture,
                  departure > now.addingTimeInterval(60 * 60) else { return nil }
            return departure.addingTimeInterval(-60 * 60)
        }
        guard let earliest = candidates.min() else { return }

        let request = BGAppRefreshTaskRequest(identifier: automaticLiveActivityTaskIdentifier)
        request.earliestBeginDate = earliest
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            #if DEBUG
            print("[LiveActivityManager] Could not schedule automatic Live Activity start: \(error)")
            #endif
        }
    }

    func startScheduledActivities(now: Date = Date()) {
        for trip in TripStorage.shared.loadTrips() {
            let timing = timingResolver.resolve(
                trip: trip,
                delayInfo: LiveDelayStore.shared.info(for: trip.id),
                referenceDate: now
            )
            guard let departure = timing.adjustedDeparture ?? timing.scheduledDeparture,
                  departure <= now.addingTimeInterval(60 * 60),
                  !isActivityRunning(for: trip.id) else { continue }
            _ = startActivity(for: trip, delayInfo: LiveDelayStore.shared.info(for: trip.id))
        }
    }

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

    func endAllActivities() {
        for activity in Activity<TrainLiveActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
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
        case "sbb":
            return "SBB"
        case "bls":
            return "BLS AG"
        case "thurbo":
            return "THURBO"
        case "tpc":
            return "TPC"
        case "jungfrau":
            return "Lauterbrunnen-Mürren"
        case "szu":
            return "SZU"
        case "rhb":
            return "Rhätische Bahn"
        case "sob":
            return "SOB"
        case "travys":
            return "TRAVYS"
        case "aargau-verkehr":
            return "Aargau Verkehr"
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

}
