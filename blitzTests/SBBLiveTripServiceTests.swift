import Foundation
import Testing
@testable import blitz

@MainActor
struct SBBLiveTripServiceTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!
    private let serviceID = ".new-live-service-not-in-a-bundled-list"

    private func trip() -> Trip {
        Trip(
            id: "live-delay-test", title: "IC 101", subtitle: "Origin → Destination",
            gtfsTripId: serviceID, travelDate: GTFSDataSource.calendar.startOfDay(for: now),
            sharedJourneyLeg: .init(origin: .init(id: "a", name: "Origin"),
                                    destination: .init(id: "b", name: "Destination"),
                                    departure: now.addingTimeInterval(-300),
                                    arrival: now.addingTimeInterval(3300), service: "IC 101"),
            originStopId: "origin", originName: "Origin",
            destinationStopId: "destination", destinationName: "Destination",
            stops: [
                StoredStop(id: "origin", name: "Origin", latitude: 47, longitude: 8, sequence: 1),
                StoredStop(id: "middle", name: "Middle", latitude: 46.9, longitude: 7.7, sequence: 2),
                StoredStop(id: "destination", name: "Destination", latitude: 46.8, longitude: 7.4, sequence: 4)
            ], originSequence: 1, destinationSequence: 4
        )
    }

    private func payload(
        updates: [[String: Any]]? = [["stop_sequence": 1, "departure": ["delay": 120]],
                                   ["stop_sequence": 4, "arrival": ["delay": 300]]],
        day: String = "20260929", delay: Int? = nil,
        observed: Date? = nil, relationship: String = "SCHEDULED"
    ) throws -> Data {
        var update: [String: Any] = ["trip": ["trip_id": serviceID, "start_date": day,
                                              "schedule_relationship": relationship]]
        if let updates { update["stop_time_update"] = updates }
        if let delay { update["delay"] = delay }
        return try JSONSerialization.data(withJSONObject: [
            "trip_id": serviceID, "fetched_at": ISO8601DateFormatter().string(from: now),
            "header": ["timestamp": String(Int((observed ?? now).timeIntervalSince1970))],
            "entities": [["trip_update": update]]
        ])
    }

    private func decode(_ data: Data, schedules: TripScheduleProviding = EmptyDelaySchedules()) throws -> DelayInfo? {
        let response = try JSONDecoder().decode(SBBRTTripResponse.self, from: data)
        return response.delayInfo(for: trip(), serviceDate: trip().travelDate!, scheduleProvider: schedules)
    }

    @Test func requestsUnlistedTripAndPublishesLiveDelay() async throws {
        let data = try payload()
        var requests: [URLRequest] = []
        var saved: [String: DelayInfo] = [:]
        let service = SBBLiveTripService(load: { request in
            requests.append(request)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, cachedDelay: { saved[$0] }, saveDelay: { saved[$1] = $0 })
        await service.refresh(trips: [trip()], now: now)
        let request = try #require(requests.first)
        #expect(request.url?.path == "/trips/\(serviceID)")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        let info = try #require(saved[trip().id])
        #expect(info.delayMinutes == 5)
        #expect(info.stationDelays.first?.departureDelayMinutes == 2)
        let timing = TripTimingResolver(scheduleProvider: EmptyDelaySchedules()).resolve(
            trip: trip(), delayInfo: info, referenceDate: now)
        #expect(timing.adjustedDeparture == trip().sharedJourneyLeg?.departure.addingTimeInterval(120))
        #expect(timing.adjustedArrival == trip().sharedJourneyLeg?.arrival.addingTimeInterval(300))
        #expect(Bundle.main.url(forResource: "sbb_rt_supported_trips", withExtension: "json") == nil)
    }

    @Test func absentTripRetriesNextMinuteWithoutClearingLastDelay() async throws {
        let data = try payload()
        let old = DelayInfo(delayMinutes: 9, platform: nil, fetchedAt: now.addingTimeInterval(-60))
        var saved = old
        var requests = 0
        let service = SBBLiveTripService(load: { request in
            requests += 1
            let status = requests == 1 ? 404 : 200
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }, cachedDelay: { _ in saved }, saveDelay: { info, _ in saved = info })
        await service.refresh(trips: [trip()], now: now)
        #expect(saved == old)
        await service.refresh(trips: [trip()], now: now.addingTimeInterval(30))
        #expect(requests == 1)
        await service.refresh(trips: [trip()], now: now.addingTimeInterval(60))
        #expect(requests == 2)
        #expect(saved.delayMinutes == 5)
    }

    @Test func staleWrongDayAndFailedResponsesDoNotOverwriteDelay() async throws {
        let old = DelayInfo(delayMinutes: 7, platform: nil, fetchedAt: now)
        let cases: [(Data, Int)] = [
            (try payload(observed: now.addingTimeInterval(-600)), 200),
            (try payload(day: "20260928"), 200),
            (try payload(relationship: "CANCELED"), 200),
            (Data("not JSON".utf8), 200),
            (try payload(), 503)
        ]
        for (data, status) in cases {
            var saved = old
            let service = SBBLiveTripService(load: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }, cachedDelay: { _ in saved }, saveDelay: { info, _ in saved = info })
            await service.refresh(trips: [trip()], now: now)
            #expect(saved == old)
        }
    }

    @Test func partialUpdatesPropagateForwardAndZeroClearsDelay() throws {
        let info = try #require(try decode(payload(updates: [
            ["stop_sequence": 1, "stop_id": "destination", "departure": ["delay": 120]],
            ["stop_sequence": 4, "arrival": ["delay": 0]],
            ["stop_sequence": 9, "arrival": ["delay": 900]]
        ])))
        #expect(info.stationDelays.map(\.stationName) == ["Origin", "Middle", "Destination"])
        #expect(info.stationDelays[0].departureDelayMinutes == 2)
        #expect(info.stationDelays[1].arrivalDelayMinutes == 2)
        #expect(info.stationDelays[2].arrivalDelayMinutes == 0)
        #expect(info.delayMinutes == 0)
        #expect(info.platform == nil)
        #expect(info.stationDelays.allSatisfy { $0.platform == nil })
    }

    @Test func negativeDelaysAndNoDataArePreserved() throws {
        let early = try #require(try decode(payload(updates: [
            ["stop_sequence": 1, "departure": ["delay": -120]]
        ])))
        #expect(early.delayMinutes == -2)
        let noData = try #require(try decode(payload(updates: [
            ["stop_sequence": 1, "departure": ["delay": 300]],
            ["stop_sequence": 2, "schedule_relationship": "NO_DATA"]
        ])))
        #expect(noData.stationDelays.map(\.stationName) == ["Origin"])
        #expect(noData.delayMinutes == nil)
    }

    @Test func tripLevelDelayWorksWithoutStopUpdates() throws {
        let info = try #require(try decode(payload(updates: nil, delay: 180)))
        #expect(info.delayMinutes == 3)
        #expect(info.stationDelays.allSatisfy { $0.departureDelayMinutes == 3 })
        #expect(try decode(payload(updates: nil)) == nil)
    }

    @Test func absoluteEventTimesUseServiceDateIncludingAfterMidnight() throws {
        let base = trip().travelDate!
        let departure = Int64(base.addingTimeInterval(23 * 3600 + 50 * 60 + 120).timeIntervalSince1970)
        let arrival = Int64(base.addingTimeInterval(25 * 3600 + 10 * 60 + 300).timeIntervalSince1970)
        let schedules = EmptyDelaySchedules(values: [
            "origin": .init(arrivalSeconds: nil, departureSeconds: 23 * 3600 + 50 * 60),
            "destination": .init(arrivalSeconds: 25 * 3600 + 10 * 60, departureSeconds: nil)
        ])
        let info = try #require(try decode(payload(updates: [
            ["stop_sequence": 1, "departure": ["time": String(departure)]],
            ["stop_sequence": 4, "arrival": ["time": arrival]]
        ]), schedules: schedules))
        #expect(info.stationDelays.first?.departureDelayMinutes == 2)
        #expect(info.delayMinutes == 5)
    }
}

private struct EmptyDelaySchedules: TripScheduleProviding {
    var values: [String: GTFSDataSource.GTFSStopSchedule] = [:]
    func stopSchedule(for tripId: String, stopId: String) -> GTFSDataSource.GTFSStopSchedule? {
        values[stopId]
    }
}
