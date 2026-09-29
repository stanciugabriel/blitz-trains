import Foundation
import Testing
@testable import blitz

struct LiveActivityManagerTests {
    private func state(
        departure: Date,
        arrival: Date,
        connection: TrainLiveActivityAttributes.ContentState.Connection? = nil
    ) -> TrainLiveActivityAttributes.ContentState {
        .init(journeyPhase: .preDeparture, platform: "7", departureTime: departure,
              arrivalTime: arrival, nextStopName: nil, nextStopArrivalTime: nil,
              stationsRemaining: 0, isDelayed: false, dataTimestamp: departure,
              delayMinutes: 0, coach: "4", seats: "12", connection: connection)
    }

    @Test func startsThirtyMinutesBeforeDepartureAndBeforeArrival() {
        let departure = Date(timeIntervalSince1970: 1_000_000)
        let arrival = departure.addingTimeInterval(2 * 60 * 60)

        #expect(LiveActivityManager.activationWindow(
            departure: departure, arrival: arrival,
            now: departure.addingTimeInterval(-20 * 60 * 60)
        ) == .waiting(until: departure.addingTimeInterval(-30 * 60)))
        #expect(LiveActivityManager.activationWindow(
            departure: departure, arrival: arrival,
            now: departure.addingTimeInterval(-30 * 60)
        ) == .ready)
        #expect(LiveActivityManager.activationWindow(
            departure: departure, arrival: arrival,
            now: departure.addingTimeInterval(30 * 60)
        ) == .ready)
        #expect(LiveActivityManager.activationWindow(
            departure: departure, arrival: arrival, now: arrival
        ) == .finished)
        #expect(LiveActivityManager.activationWindow(
            departure: nil, arrival: arrival, now: departure
        ) == .unavailable)
    }

    @Test func islandPhasesChangeAtTenAndFiveMinutesThenApproachAndConnection() {
        let departure = Date(timeIntervalSince1970: 1_000_000)
        let arrival = departure.addingTimeInterval(60 * 60)
        let nextDeparture = arrival.addingTimeInterval(8 * 60)
        let connection = TrainLiveActivityAttributes.ContentState.Connection(
            stationName: "Zürich HB", nextTrainNumber: "IC 8",
            nextArrivalTime: nextDeparture.addingTimeInterval(45 * 60),
            departureTime: nextDeparture, displayUntil: arrival.addingTimeInterval(15 * 60),
            fromPlatform: "5", toPlatform: "7", minimumTransferSeconds: 300,
            hasFreshTiming: true
        )
        let live = state(departure: departure, arrival: arrival, connection: connection)
        #expect(live.effectivePhase(at: departure.addingTimeInterval(-11 * 60)) == .preDeparture)
        #expect(live.effectivePhase(at: departure.addingTimeInterval(-10 * 60)) == .boarding)
        #expect(live.effectivePhase(at: departure.addingTimeInterval(-5 * 60)) == .inTransit)
        #expect(live.effectivePhase(at: departure) == .inTransit)
        #expect(live.effectivePhase(at: arrival.addingTimeInterval(-15 * 60)) == .prepareToChange)
        #expect(live.effectivePhase(at: arrival) == .connection)
        #expect(live.effectivePhase(at: nextDeparture) == .inTransit)
        #expect(live.showingNextLeg(at: nextDeparture))
        #expect(live.effectivePhase(at: connection.nextArrivalTime!) == .completed)
        #expect(live.connectionStatus == .onTrack)
    }

    @Test func connectionStatusUsesMinimumTransferTime() {
        let departure = Date(timeIntervalSince1970: 1_000_000)
        let arrival = departure.addingTimeInterval(60 * 60)
        func connection(_ nextDeparture: Date, minimum: Int?) -> TrainLiveActivityAttributes.ContentState.Connection {
            .init(stationName: "Zürich HB", nextTrainNumber: "IC 8",
                  departureTime: nextDeparture, displayUntil: arrival.addingTimeInterval(15 * 60),
                  fromPlatform: "5", toPlatform: "7", minimumTransferSeconds: minimum,
                  hasFreshTiming: true)
        }
        #expect(state(departure: departure, arrival: arrival,
                      connection: connection(arrival.addingTimeInterval(200), minimum: 300)).connectionStatus == .tight)
        #expect(state(departure: departure, arrival: arrival,
                      connection: connection(arrival.addingTimeInterval(-30), minimum: 300)).connectionStatus == .missed)
        #expect(state(departure: departure, arrival: arrival,
                      connection: connection(arrival.addingTimeInterval(600), minimum: nil)).connectionStatus == .unknown)
    }

    @Test func finalApproachAndEarlyConfirmedBoarding() {
        let departure = Date(timeIntervalSince1970: 1_000_000)
        let arrival = departure.addingTimeInterval(60 * 60)
        var live = state(departure: departure, arrival: arrival)
        #expect(live.effectivePhase(at: arrival.addingTimeInterval(-15 * 60)) == .prepareToArrive)
        live.boardingConfirmed = true
        #expect(live.effectivePhase(at: departure.addingTimeInterval(-12 * 60)) == .inTransit)
    }

    @Test func liveTripPayloadUsesSelectedServiceDayAndTerminalDelays() throws {
        let serviceDate = GTFSDataSource.calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))!
        let trip = Trip(
            title: "IC 8", subtitle: "Zürich → Bern", gtfsTripId: "service-8",
            travelDate: serviceDate, originStopId: "origin", originName: "Zürich",
            destinationStopId: "destination", destinationName: "Bern",
            stops: [
                StoredStop(id: "origin", name: "Zürich", latitude: 47, longitude: 8, sequence: 1),
                StoredStop(id: "destination", name: "Bern", latitude: 46, longitude: 7, sequence: 4)
            ], originSequence: 1, destinationSequence: 4
        )
        let payload = """
        {"trip_id":"service-8","fetched_at":"2026-09-27T11:48:46.905962Z","entities":[
          {"trip_update":{"trip":{"trip_id":"service-8","start_date":"20260926"},
            "stop_time_update":[{"stop_sequence":1,"departure":{"delay":900}}]}},
          {"trip_update":{"trip":{"trip_id":"service-8","start_date":"20260927"},
            "stop_time_update":[{"stop_sequence":1,"stop_id":"origin","departure":{"delay":120}},
              {"stop_sequence":4,"stop_id":"destination","arrival":{"delay":300}}]}}
        ]}
        """
        let response = try JSONDecoder().decode(SBBRTTripResponse.self, from: Data(payload.utf8))
        let info = try #require(response.delayInfo(for: trip, serviceDate: serviceDate))
        #expect(info.delayMinutes == 5)
        #expect(info.stationDelays.first?.departureDelayMinutes == 2)
        #expect(info.stationDelays.last?.arrivalDelayMinutes == 5)
    }

    @Test func continuousActivityIncludesOnlyLegsImportedTogether() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let zurich = SharedJourney.Station(id: "8503000", name: "Zürich HB")
        let bern = SharedJourney.Station(id: "8507000", name: "Bern")
        let basel = SharedJourney.Station(id: "8500010", name: "Basel SBB")
        let firstLeg = SharedJourney.Leg(origin: zurich, destination: bern,
            departure: start, arrival: start.addingTimeInterval(3600), service: "IC 8")
        let secondLeg = SharedJourney.Leg(origin: bern, destination: basel,
            departure: start.addingTimeInterval(4200), arrival: start.addingTimeInterval(7800), service: "IC 6")
        let first = Trip(id: "first", title: "IC 8", subtitle: "Zürich → Bern",
            travelDate: start, sharedJourneyLeg: firstLeg, sharedJourneyID: "shared")
        let second = Trip(id: "second", title: "IC 6", subtitle: "Bern → Basel",
            travelDate: start, sharedJourneyLeg: secondLeg, sharedJourneyID: "shared")
        let separate = Trip(id: "separate", title: "IC 6", subtitle: "Bern → Basel",
            travelDate: start, sharedJourneyLeg: secondLeg, sharedJourneyID: "other")
        let oldImport = Trip(id: "old", title: "IC 6", subtitle: "Bern → Basel",
            travelDate: start, sharedJourneyLeg: secondLeg)
        let grouped = LiveActivityManager.journeyTrips(for: first,
            among: [oldImport, separate, second, first])
        #expect(grouped.map(\.id) == ["first", "second"])
    }

    @Test func connectingPlatformChangeTakesAttentionSlotOnlyWhenLive() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var old = state(departure: now.addingTimeInterval(-3600),
                        arrival: now.addingTimeInterval(300))
        old.trainNumber = "IC 8"
        old.connection = .init(stationName: "Bern", nextTrainNumber: "IC 6",
            departureTime: now.addingTimeInterval(900), displayUntil: now.addingTimeInterval(900),
            fromPlatform: "4", toPlatform: "7", minimumTransferSeconds: 300)
        var updated = old
        updated.connection?.toPlatform = "8"
        #expect(LiveActivityManager.attention(from: old, to: updated, now: now) == nil)
        updated.connection?.nextPlatformIsLive = true
        let attention = LiveActivityManager.attention(from: old, to: updated, now: now)
        #expect(attention?.kind == .platformChange)
        #expect(attention?.previousPlatform == "7")
        #expect(attention?.newPlatform == "8")
    }
}
