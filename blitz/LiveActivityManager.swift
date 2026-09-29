import ActivityKit
import Foundation
import BackgroundTasks

let automaticLiveActivityTaskIdentifier = "ro.openlabs.blitz.live-activity-start"

final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private let timingResolver = TripTimingResolver()
    private let suppressedStartKey = "sbb.liveActivitySuppressedStarts"

    private init() {}

    private func tripDayKey(for trip: Trip) -> String? {
        guard let travelDate = trip.travelDate else { return nil }
        let day = GTFSDataSource.calendar.startOfDay(for: travelDate)
        return "\(trip.id)|\(day.timeIntervalSince1970)"
    }

    private func isAutomaticStartSuppressed(for trip: Trip) -> Bool {
        let keys = Set(UserDefaults.standard.stringArray(forKey: suppressedStartKey) ?? [])
        if let journeyID = trip.sharedJourneyID, keys.contains("journey|\(journeyID)") { return true }
        return tripDayKey(for: trip).map(keys.contains) ?? false
    }

    func stopActivityByUser(for trip: Trip) {
        var keys = Set(UserDefaults.standard.stringArray(forKey: suppressedStartKey) ?? [])
        if let key = tripDayKey(for: trip) { keys.insert(key) }
        if let journeyID = trip.sharedJourneyID { keys.insert("journey|\(journeyID)") }
        UserDefaults.standard.set(Array(keys), forKey: suppressedStartKey)
        endActivity(for: trip.id)
    }

    func allowAutomaticStart(for trip: Trip) {
        var keys = Set(UserDefaults.standard.stringArray(forKey: suppressedStartKey) ?? [])
        if let key = tripDayKey(for: trip) { keys.remove(key) }
        if let journeyID = trip.sharedJourneyID { keys.remove("journey|\(journeyID)") }
        UserDefaults.standard.set(Array(keys), forKey: suppressedStartKey)
    }

    enum ActivationWindow: Equatable {
        case unavailable
        case waiting(until: Date)
        case ready
        case finished
    }

    static func activationWindow(departure: Date?, arrival: Date?, now: Date) -> ActivationWindow {
        guard let departure, let arrival, arrival > departure else { return .unavailable }
        let start = departure.addingTimeInterval(-30 * 60)
        if now < start { return .waiting(until: start) }
        if now >= arrival { return .finished }
        return .ready
    }

    private func activationWindow(for trip: Trip, delayInfo: DelayInfo?, now: Date) -> ActivationWindow {
        let legs = journeyTrips(for: trip)
        guard let first = legs.first, let last = legs.last,
              first.travelDate != nil, last.travelDate != nil else { return .unavailable }
        let startTiming = timingResolver.resolve(
            trip: first, delayInfo: first.id == trip.id ? delayInfo : LiveDelayStore.shared.info(for: first.id),
            referenceDate: now, includeProgressDetails: false
        )
        let endTiming = timingResolver.resolve(
            trip: last, delayInfo: last.id == trip.id ? delayInfo : LiveDelayStore.shared.info(for: last.id),
            referenceDate: now, includeProgressDetails: false
        )
        return Self.activationWindow(
            departure: startTiming.adjustedDeparture ?? startTiming.scheduledDeparture,
            arrival: endTiming.adjustedArrival ?? endTiming.scheduledArrival,
            now: now
        )
    }

    /// Starts an activity only when it is within the thirty-minute activation
    /// window. Future trips are picked up by the registered BGAppRefreshTask.
    @discardableResult
    func startOrSchedule(for trip: Trip, delayInfo: DelayInfo? = nil, now: Date = Date()) -> StartResult? {
        guard !isAutomaticStartSuppressed(for: trip) else {
            return .unavailable("Live Activity is turned off for this trip")
        }
        switch activationWindow(for: trip, delayInfo: delayInfo, now: now) {
        case .ready:
            return startActivity(for: trip, delayInfo: delayInfo, now: now)
        case .waiting:
            let otherTrips = TripStorage.shared.loadTrips().filter { $0.id != trip.id }
            scheduleNextAutomaticStart(for: otherTrips + [trip], now: now)
            return nil
        case .unavailable:
            return .unavailable("Live Activity needs departure and arrival times")
        case .finished:
            return .unavailable("This trip has already arrived")
        }
    }

    func scheduleNextAutomaticStart(for trips: [Trip] = TripStorage.shared.loadTrips(), now: Date = Date()) {
        let candidates = trips.compactMap { trip -> Date? in
            guard !isAutomaticStartSuppressed(for: trip) else { return nil }
            guard case .waiting(let start) = activationWindow(
                for: trip, delayInfo: LiveDelayStore.shared.info(for: trip.id), now: now
            ) else { return nil }
            return start
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: automaticLiveActivityTaskIdentifier)
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

    func startScheduledActivities(for trips: [Trip] = TripStorage.shared.loadTrips(), now: Date = Date()) {
        for trip in trips {
            guard !isAutomaticStartSuppressed(for: trip) else { continue }
            let delayInfo = LiveDelayStore.shared.info(for: trip.id)
            switch activationWindow(for: trip, delayInfo: delayInfo, now: now) {
            case .ready where !isActivityRunning(for: trip.id):
                _ = startActivity(for: trip, delayInfo: delayInfo, now: now)
            case .waiting where isActivityRunning(for: trip.id):
                endActivity(for: trip.id)
            default:
                break
            }
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
    func startActivity(for trip: Trip, delayInfo: DelayInfo? = nil, now: Date = Date()) -> StartResult {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return .activitiesDisabled }
        guard !isAutomaticStartSuppressed(for: trip) else {
            return .unavailable("Live Activity is turned off for this trip")
        }
        guard trip.travelDate != nil, trip.originStopId != nil, trip.destinationStopId != nil else {
            return .unavailable("Live Activity needs a saved trip with route timing")
        }
        switch activationWindow(for: trip, delayInfo: delayInfo, now: now) {
        case .ready:
            break
        case .waiting:
            return .unavailable("Live Activity starts 30 minutes before departure")
        case .unavailable:
            return .unavailable("Live Activity needs departure and arrival times")
        case .finished:
            return .unavailable("This trip has already arrived")
        }
        guard activity(for: trip.id) == nil else {
            updateActivity(for: trip, delayInfo: delayInfo)
            return .alreadyRunning
        }

        let legs = journeyTrips(for: trip)
        let first = legs.first ?? trip
        let branding = OperatorBrandingCatalog.branding(for: first.agencyId)
        let attributes = TrainLiveActivityAttributes(
            tripID: first.id,
            trainNumber: trainNumber(for: first),
            operatorName: operatorName(for: branding.logoName),
            originStationCode: stationCode(for: first.originStopId, name: first.originName),
            originStationName: first.originName ?? "Origin",
            destinationStationCode: stationCode(for: first.destinationStopId, name: first.destinationName),
            destinationStationName: first.destinationName ?? "Destination",
            coachAndSeat: coachAndSeatText(for: first),
            agencyId: first.agencyId,
            operatorLogoName: branding.logoName,
            tripIDs: legs.map(\.id),
            sharedJourneyID: first.sharedJourneyID
        )
        let state = contentState(for: trip, delayInfo: delayInfo, now: now)

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
        var state = contentState(for: trip, delayInfo: delayInfo)
        state.attention = Self.attention(from: activity.content.state, to: state, now: Date())
        var comparableState = state
        comparableState.dataTimestamp = activity.content.state.dataTimestamp
        guard comparableState != activity.content.state else { return }

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
        Activity<TrainLiveActivityAttributes>.activities.first {
            $0.attributes.tripID == tripID || $0.attributes.tripIDs?.contains(tripID) == true
        }
    }

    private func journeyTrips(for trip: Trip) -> [Trip] {
        Self.journeyTrips(for: trip,
            among: TripStorage.shared.loadTrips() + TripStorage.shared.loadPastTrips())
    }

    static func journeyTrips(for trip: Trip, among stored: [Trip]) -> [Trip] {
        guard let journeyID = trip.sharedJourneyID, trip.sharedJourneyLeg != nil else { return [trip] }
        var legs = stored.filter { $0.sharedJourneyID == journeyID && $0.sharedJourneyLeg != nil }
        if !legs.contains(where: { $0.id == trip.id }) { legs.append(trip) }
        return legs.sorted {
            ($0.sharedJourneyLeg?.departure ?? .distantFuture) < ($1.sharedJourneyLeg?.departure ?? .distantFuture)
        }
    }

    private func contentState(
        for trip: Trip,
        delayInfo: DelayInfo?,
        now: Date = Date()
    ) -> TrainLiveActivityAttributes.ContentState {
        let legs = journeyTrips(for: trip)
        var currentIndex = 0
        if legs.count > 1 {
            for index in 1..<legs.count {
                let next = legs[index]
                let previous = legs[index - 1]
                let nextTiming = timingResolver.resolve(
                    trip: next, delayInfo: LiveDelayStore.shared.info(for: next.id),
                    referenceDate: now, includeProgressDetails: false
                )
                let previousTiming = timingResolver.resolve(
                    trip: previous, delayInfo: LiveDelayStore.shared.info(for: previous.id),
                    referenceDate: now, includeProgressDetails: false
                )
                let nextDeparture = nextTiming.adjustedDeparture ?? nextTiming.scheduledDeparture ?? .distantFuture
                let previousArrival = previousTiming.adjustedArrival ?? previousTiming.scheduledArrival ?? .distantFuture
                let boardedNext = TripLocationPhaseDetector.persistedPhase(for: next) == .boarded
                if boardedNext || (now >= nextDeparture && now >= previousArrival && previousArrival <= nextDeparture) {
                    currentIndex = index
                } else {
                    break
                }
            }
        }
        let current = legs[currentIndex]
        let effectiveDelayInfo = current.id == trip.id
            ? (delayInfo ?? LiveDelayStore.shared.info(for: current.id))
            : LiveDelayStore.shared.info(for: current.id)
        let timing = timingResolver.resolve(
            trip: current,
            delayInfo: effectiveDelayInfo,
            referenceDate: now
        )
        let departureTime = timing.adjustedDeparture ?? timing.scheduledDeparture ?? now
        let arrivalTime = timing.adjustedArrival ?? timing.scheduledArrival ?? departureTime.addingTimeInterval(60)
        let next = currentIndex + 1 < legs.count ? legs[currentIndex + 1] : nil
        let connection = connectionInfo(for: current, next: next,
                                        arrivalTime: arrivalTime,
                                        fromPlatform: timing.destinationPlatform, now: now)
        let detectedPhase = TripLocationPhaseDetector.persistedPhase(for: current)
        let branding = OperatorBrandingCatalog.branding(for: current.agencyId)
        let serviceIdentity = serviceIdentity(for: current)
        let liveUpdatedAt = effectiveDelayInfo?.fetchedAt
        let hasFreshLive = liveUpdatedAt.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 5 * 60 } ?? false
        var state = TrainLiveActivityAttributes.ContentState(
            journeyPhase: .preDeparture,
            platform: timing.originPlatform,
            departureTime: departureTime,
            arrivalTime: arrivalTime,
            nextStopName: timing.nextStopName,
            nextStopArrivalTime: timing.nextStopArrival,
            stationsRemaining: timing.stationsRemaining,
            isDelayed: timing.originDelayMinutes > 0 || timing.destinationDelayMinutes > 0,
            dataTimestamp: now,
            delayMinutes: timing.originDelayMinutes,
            coach: current.seatCar?.trimmingCharacters(in: .whitespacesAndNewlines),
            seats: current.seatNumbers?.joined(separator: ", "),
            connection: connection,
            trainNumber: trainNumber(for: current),
            serviceNumber: serviceIdentity.number,
            routeName: serviceIdentity.line,
            operatorLogoName: branding.logoName,
            agencyId: current.agencyId,
            originName: current.originName,
            destinationName: current.destinationName,
            headsign: current.gtfsTripId.flatMap { GTFSDataSource.shared.headsign(for: $0) },
            boardingConfirmed: detectedPhase == .boarded || detectedPhase == .arrived,
            arrivalConfirmed: detectedPhase == .arrived,
            liveUpdatedAt: liveUpdatedAt,
            platformIsLive: hasFreshLive && effectiveDelayInfo?.platform != nil
        )
        state.journeyPhase = state.effectivePhase(at: now)
        if state.journeyPhase == .inTransit || state.journeyPhase == .prepareToChange ||
            state.journeyPhase == .prepareToArrive {
            state.delayMinutes = timing.destinationDelayMinutes
        }
        return state
    }

    private func connectionInfo(
        for trip: Trip, next: Trip?, arrivalTime: Date, fromPlatform: String?, now: Date
    ) -> TrainLiveActivityAttributes.ContentState.Connection? {
        guard let journeyID = trip.sharedJourneyID, let leg = trip.sharedJourneyLeg,
              let next, next.sharedJourneyID == journeyID,
              let nextLeg = next.sharedJourneyLeg,
              nextLeg.origin.id == leg.destination.id,
              nextLeg.departure >= leg.arrival else { return nil }
        let nextDelay = LiveDelayStore.shared.info(for: next.id)
        let nextTiming = timingResolver.resolve(
            trip: next, delayInfo: nextDelay,
            referenceDate: arrivalTime, includeProgressDetails: false
        )
        guard let nextDeparture = nextTiming.adjustedDeparture ?? nextTiming.scheduledDeparture else { return nil }
        let minimumTransfer: Int? = if let fromStop = trip.destinationStopId,
                                 let toStop = next.originStopId,
                                 !fromStop.hasPrefix("sbb-shared:"), !toStop.hasPrefix("sbb-shared:") {
            GTFSDataSource.shared.minimumTransferSeconds(from: fromStop, to: toStop)
        } else {
            nil
        }
        let currentFresh = LiveDelayStore.shared.info(for: trip.id)?.fetchedAt.map {
            now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 5 * 60
        } ?? false
        let nextFresh = nextDelay?.fetchedAt.map {
            now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 5 * 60
        } ?? false
        let nextBranding = OperatorBrandingCatalog.branding(for: next.agencyId)
        return .init(
            stationName: trip.destinationName ?? leg.destination.name,
            nextTrainNumber: trainNumber(for: next),
            nextOperatorLogoName: nextBranding.logoName,
            nextAgencyId: next.agencyId,
            nextDestinationName: next.destinationName,
            nextArrivalTime: nextTiming.adjustedArrival ?? nextTiming.scheduledArrival,
            departureTime: nextDeparture,
            displayUntil: max(nextDeparture, arrivalTime.addingTimeInterval(nextDeparture < arrivalTime ? 15 * 60 : 0)),
            fromPlatform: fromPlatform,
            toPlatform: nextTiming.originPlatform,
            minimumTransferSeconds: minimumTransfer,
            hasFreshTiming: currentFresh && nextFresh,
            nextPlatformIsLive: nextFresh && nextDelay?.platform != nil
        )
    }

    private func staleDate(for state: TrainLiveActivityAttributes.ContentState) -> Date? {
        switch state.journeyPhase {
        case .preDeparture, .boarding:
            return state.departureTime.addingTimeInterval(10 * 60)
        case .inTransit, .prepareToChange, .prepareToArrive:
            return state.arrivalTime.addingTimeInterval(10 * 60)
        case .connection:
            return state.connection?.displayUntil.addingTimeInterval(10 * 60)
        case .completed:
            return state.dataTimestamp.addingTimeInterval(60 * 60)
        }
    }

    static func attention(
        from old: TrainLiveActivityAttributes.ContentState,
        to new: TrainLiveActivityAttributes.ContentState,
        now: Date
    ) -> TrainLiveActivityAttributes.ContentState.Attention? {
        typealias Attention = TrainLiveActivityAttributes.ContentState.Attention
        guard old.trainNumber == new.trainNumber else { return nil }
        if let oldPlatform = old.connection?.toPlatform,
           let next = new.connection, next.nextPlatformIsLive,
           let newPlatform = next.toPlatform, oldPlatform != newPlatform {
            return Attention(kind: .platformChange,
                             message: "Next platform changed: go to \(newPlatform)",
                             previousPlatform: oldPlatform, newPlatform: newPlatform,
                             expiresAt: now.addingTimeInterval(5 * 60))
        }
        let fresh = new.liveUpdatedAt.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 5 * 60 } ?? false
        if fresh, new.platformIsLive == true,
           let previous = old.platform, let platform = new.platform,
           !previous.isEmpty, !platform.isEmpty, previous != platform {
            return Attention(kind: .platformChange, message: "Platform changed: go to \(platform)",
                             previousPlatform: previous, newPlatform: platform,
                             expiresAt: now.addingTimeInterval(5 * 60))
        }
        if fresh, new.departureTime < old.departureTime.addingTimeInterval(-60), now < new.departureTime {
            let formatter = DateFormatter()
            formatter.timeZone = GTFSDataSource.calendar.timeZone
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return Attention(kind: .earlyDeparture,
                             message: "Now departs \(formatter.string(from: new.departureTime))",
                             previousPlatform: nil, expiresAt: now.addingTimeInterval(5 * 60))
        }
        if new.connectionStatus == .missed, old.connectionStatus != .missed {
            return Attention(kind: .missedConnection, message: "Connection likely missed",
                             previousPlatform: nil, expiresAt: now.addingTimeInterval(10 * 60))
        }
        if new.connectionStatus == .tight, old.connectionStatus != .tight {
            return Attention(kind: .tightConnection, message: "Connection is tight",
                             previousPlatform: nil, expiresAt: now.addingTimeInterval(5 * 60))
        }
        if fresh, new.delayMinutes >= old.delayMinutes + 5, now < new.arrivalTime {
            return Attention(kind: .delay, message: "\(new.delayMinutes)m late",
                             previousPlatform: nil, expiresAt: now.addingTimeInterval(5 * 60))
        }
        return old.activeAttention(at: now)
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

    private func serviceIdentity(for trip: Trip) -> (line: String?, number: String?) {
        let parts = trip.title.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let last = parts.last, !last.isEmpty,
              last.allSatisfy(\.isNumber) else { return (nil, nil) }
        let line = parts.dropLast().joined()
        return (line.isEmpty ? nil : line, last)
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
