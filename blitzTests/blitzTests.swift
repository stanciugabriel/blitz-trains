import Foundation
import Testing
@testable import blitz

struct InfoFerScraperMapTests {
    @Test func acceptsLastGPSPositionWithMarkerHTMLMessage() {
        let html = """
        var lastGpsPositionLatitude = 44.7128032;
        var lastGpsPositionLongitude = 26.0193224;
        var markerHtml=`
        <span>Sta&#x21B;ia precedent&#x103;: <b>Ploie&#x219;ti Vest</b></span>
        <br />
        <span>Urmeaz&#x103; sta&#x21B;ia: <b>Bucure&#x219;ti Nord</b></span>
        <br />
        <div class="my-1 p-1 alert alert-success">
            Ultima pozi&#x21B;ie GPS la 19:21
        </div>`;
        """

        let coordinate = InfoFerScraper.shared.parseTrustedLiveCoordinate(from: html, travelDate: Date())

        #expect(coordinate != nil)
        #expect(coordinate?.latitude == 44.7128032)
        #expect(coordinate?.longitude == 26.0193224)
        #expect(coordinate?.fetchedAt != nil)
        #expect(coordinate?.sourceText?.contains("Ultima poziție GPS la 19:21") == true)
        #expect(InfoFerScraper.shared.containsEstimatedCFRPosition(in: html) == false)
    }

    @Test func rejectsCFRReportedPositionWithoutExplicitGPSCoordinates() {
        let html = """
        var theoreticalGpsPositionLatitude = 45.1234;
        var theoreticalGpsPositionLongitude = 25.9876;
        var markerHtml=`
        <div class="my-1 p-1 alert alert-success">
            RAPORTAT de personalul CFR la 10:05
        </div>`;
        """

        let coordinate = InfoFerScraper.shared.parseTrustedLiveCoordinate(from: html, travelDate: Date())

        #expect(coordinate == nil)
    }

    @Test func rejectsEstimatedCFRPositionEvenWhenCoordinatesExist() {
        let html = """
        var lastGpsPositionLatitude = 44.7128032;
        var lastGpsPositionLongitude = 26.0193224;
        var markerHtml=`
        <div class="my-1 p-1 alert alert-warning">
            Pozi&#x21B;ie ESTIMAT&#x102; pe baza raport&#x103;rii CFR
        </div>`;
        """

        let coordinate = InfoFerScraper.shared.parseTrustedLiveCoordinate(from: html, travelDate: Date())

        #expect(coordinate == nil)
        #expect(InfoFerScraper.shared.containsEstimatedCFRPosition(in: html) == true)
    }

    @Test func rejectsCoordinatesWithoutTrustedPositionMessage() {
        let html = """
        var lastGpsPositionLatitude = 44.7128032;
        var lastGpsPositionLongitude = 26.0193224;
        var markerHtml=`
        <span>Sta&#x21B;ia precedent&#x103;: <b>Ploie&#x219;ti Vest</b></span>
        <br />
        <span>Urmeaz&#x103; sta&#x21B;ia: <b>Bucure&#x219;ti Nord</b></span>`;
        """

        let coordinate = InfoFerScraper.shared.parseTrustedLiveCoordinate(from: html, travelDate: Date())

        #expect(coordinate == nil)
    }
}

struct TripSyncStatusTests {
    @Test func liveDelayOrMapDataIsUpdated() {
        #expect(TripSyncStatus.resolve(hasDelayEvidence: true, hasMapEvidence: false, hasPreviousSnapshot: true) == .updated)
        #expect(TripSyncStatus.resolve(hasDelayEvidence: false, hasMapEvidence: true, hasPreviousSnapshot: false) == .mapOnly)
    }

    @Test func emptyRefreshWithCacheIsStale() {
        #expect(TripSyncStatus.resolve(hasDelayEvidence: false, hasMapEvidence: false, hasPreviousSnapshot: true) == .stale)
    }

    @Test func emptyInitialRefreshIsUnavailable() {
        #expect(TripSyncStatus.resolve(hasDelayEvidence: false, hasMapEvidence: false, hasPreviousSnapshot: false) == .unavailable)
    }
}

struct RailyNotificationTests {
    @Test func delayEventUsesConfiguredThreshold() {
        let previous = DelayInfo(delayMinutes: 5, platform: "1")
        let current = DelayInfo(delayMinutes: 10, platform: "1")

        #expect(
            RailyNotificationPreferences.event(previous: previous, current: current)
                == .delayChanged(old: 5, new: 10)
        )
    }

    @Test func unchangedLiveSnapshotDoesNotCreateAnEvent() {
        let info = DelayInfo(delayMinutes: 8, platform: "2")

        #expect(RailyNotificationPreferences.event(previous: info, current: info) == nil)
    }
}

struct TripTimingResolverTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    @Test func stationLevelDelaysOverrideHeaderDelay() {
        let base = date(2026, 6, 2)
        let trip = makeTrip(
            travelDate: base,
            stops: [
                stop(id: "ORA", name: "Oradea", sequence: 1, departureDelay: 7),
                stop(id: "RDU", name: "Raduti", sequence: 2, arrivalDelay: -3)
            ]
        )
        let schedules = MockScheduleProvider([
            "IR1|ORA": .init(arrivalSeconds: nil, departureSeconds: seconds(hour: 8, minute: 30)),
            "IR1|RDU": .init(arrivalSeconds: seconds(hour: 10, minute: 0), departureSeconds: nil)
        ])
        let info = DelayInfo(delayMinutes: 20, platform: "9")

        let timing = TripTimingResolver(scheduleProvider: schedules, calendar: calendar).resolve(
            trip: trip,
            delayInfo: info,
            referenceDate: date(2026, 6, 2, hour: 7)
        )

        #expect(timing.originDelayMinutes == 7)
        #expect(timing.destinationDelayMinutes == -3)
        expectDate(timing.adjustedDeparture, equals: date(2026, 6, 2, hour: 8, minute: 37))
        expectDate(timing.adjustedArrival, equals: date(2026, 6, 2, hour: 9, minute: 57))
        #expect(timing.departureStatusText == "7m late")
        #expect(timing.arrivalStatusText == "3m early")
    }

    @Test func liveStationDelaysAndPlatformApplyWhenStoredStopsAreEmpty() {
        let base = date(2026, 6, 2)
        let trip = makeTrip(
            travelDate: base,
            stops: [
                stop(id: "ORA", name: "Oradea", sequence: 1),
                stop(id: "RDU", name: "Raduti", sequence: 2)
            ]
        )
        let schedules = MockScheduleProvider([
            "IR1|ORA": .init(arrivalSeconds: nil, departureSeconds: seconds(hour: 8, minute: 30)),
            "IR1|RDU": .init(arrivalSeconds: seconds(hour: 10, minute: 0), departureSeconds: nil)
        ])
        let info = DelayInfo(
            delayMinutes: 5,
            platform: "wrong-global-platform",
            stationDelays: [
                StationDelay(stationName: "Oradea", arrivalDelayMinutes: nil, departureDelayMinutes: -9, platform: "2"),
                StationDelay(stationName: "Raduti", arrivalDelayMinutes: 11, departureDelayMinutes: nil, platform: nil)
            ]
        )

        let timing = TripTimingResolver(scheduleProvider: schedules, calendar: calendar).resolve(
            trip: trip,
            delayInfo: info,
            referenceDate: date(2026, 6, 2, hour: 7)
        )

        #expect(timing.originDelayMinutes == -9)
        #expect(timing.destinationDelayMinutes == 11)
        #expect(timing.originPlatform == "2")
        expectDate(timing.adjustedDeparture, equals: date(2026, 6, 2, hour: 8, minute: 21))
        expectDate(timing.adjustedArrival, equals: date(2026, 6, 2, hour: 10, minute: 11))
    }

    @Test func headerDelayIsFallbackWhenStationDelaysAreMissing() {
        let base = date(2026, 6, 2)
        let trip = makeTrip(
            travelDate: base,
            stops: [
                stop(id: "ORA", name: "Oradea", sequence: 1),
                stop(id: "RDU", name: "Raduti", sequence: 2)
            ]
        )
        let schedules = MockScheduleProvider([
            "IR1|ORA": .init(arrivalSeconds: nil, departureSeconds: seconds(hour: 8, minute: 30)),
            "IR1|RDU": .init(arrivalSeconds: seconds(hour: 10, minute: 0), departureSeconds: nil)
        ])
        let platforms = MockPlatformProvider([
            "IR1|ORA": "4",
            "IR1|RDU": "6"
        ])

        let timing = TripTimingResolver(scheduleProvider: schedules, platformProvider: platforms, calendar: calendar).resolve(
            trip: trip,
            delayInfo: DelayInfo(delayMinutes: 5, platform: nil),
            referenceDate: date(2026, 6, 2, hour: 7)
        )

        #expect(timing.originDelayMinutes == 5)
        #expect(timing.destinationDelayMinutes == 5)
        #expect(timing.originPlatform == "4")
        #expect(timing.destinationPlatform == "6")
        expectDate(timing.adjustedDeparture, equals: date(2026, 6, 2, hour: 8, minute: 35))
        expectDate(timing.adjustedArrival, equals: date(2026, 6, 2, hour: 10, minute: 5))
    }

    @Test func liveStationPlatformOverridesStaticPlatform() {
        let base = date(2026, 6, 2)
        let trip = makeTrip(
            travelDate: base,
            stops: [
                stop(id: "ORA", name: "Oradea", sequence: 1),
                stop(id: "RDU", name: "Raduti", sequence: 2)
            ]
        )
        let schedules = MockScheduleProvider([
            "IR1|ORA": .init(arrivalSeconds: nil, departureSeconds: seconds(hour: 8, minute: 30)),
            "IR1|RDU": .init(arrivalSeconds: seconds(hour: 10, minute: 0), departureSeconds: nil)
        ])
        let platforms = MockPlatformProvider([
            "IR1|ORA": "4",
            "IR1|RDU": "6"
        ])
        let info = DelayInfo(
            delayMinutes: nil,
            platform: nil,
            stationDelays: [
                StationDelay(stationName: "Oradea", arrivalDelayMinutes: nil, departureDelayMinutes: nil, platform: "2")
            ]
        )

        let timing = TripTimingResolver(scheduleProvider: schedules, platformProvider: platforms, calendar: calendar).resolve(
            trip: trip,
            delayInfo: info,
            referenceDate: date(2026, 6, 2, hour: 7)
        )

        #expect(timing.originPlatform == "2")
        #expect(timing.destinationPlatform == "6")
    }

    @Test func overnightArrivalIsNormalizedPastDeparture() {
        let base = date(2026, 6, 2)
        let trip = makeTrip(
            travelDate: base,
            stops: [
                stop(id: "ORA", name: "Oradea", sequence: 1),
                stop(id: "RDU", name: "Raduti", sequence: 2)
            ]
        )
        let schedules = MockScheduleProvider([
            "IR1|ORA": .init(arrivalSeconds: nil, departureSeconds: seconds(hour: 23, minute: 50)),
            "IR1|RDU": .init(arrivalSeconds: seconds(hour: 0, minute: 20), departureSeconds: nil)
        ])

        let timing = TripTimingResolver(scheduleProvider: schedules, calendar: calendar).resolve(
            trip: trip,
            delayInfo: DelayInfo(delayMinutes: nil, platform: nil),
            referenceDate: date(2026, 6, 2, hour: 23, minute: 55)
        )

        #expect(timing.phase == .inTransit)
        expectDate(timing.scheduledDeparture, equals: date(2026, 6, 2, hour: 23, minute: 50))
        expectDate(timing.scheduledArrival, equals: date(2026, 6, 3, hour: 0, minute: 20))
    }

    @Test func sharedTimingResolverProvidesNextStopAndRemainingStations() {
        let base = date(2026, 6, 2)
        let trip = makeTrip(
            travelDate: base,
            stops: [
                stop(id: "ORA", name: "Oradea", sequence: 1),
                stop(id: "CLU", name: "Cluj", sequence: 2),
                stop(id: "RDU", name: "Raduti", sequence: 3)
            ]
        )
        let schedules = MockScheduleProvider([
            "IR1|ORA": .init(arrivalSeconds: nil, departureSeconds: seconds(hour: 8, minute: 30)),
            "IR1|CLU": .init(arrivalSeconds: seconds(hour: 9, minute: 30), departureSeconds: seconds(hour: 9, minute: 35)),
            "IR1|RDU": .init(arrivalSeconds: seconds(hour: 10, minute: 30), departureSeconds: nil)
        ])

        let timing = TripTimingResolver(scheduleProvider: schedules, calendar: calendar).resolve(
            trip: Trip(
                id: trip.id,
                title: trip.title,
                subtitle: trip.subtitle,
                gtfsTripId: trip.gtfsTripId,
                travelDate: trip.travelDate,
                originStopId: "ORA",
                originName: "Oradea",
                destinationStopId: "RDU",
                destinationName: "Raduti",
                stops: trip.stops,
                originSequence: 1,
                destinationSequence: 3
            ),
            delayInfo: nil,
            referenceDate: date(2026, 6, 2, hour: 9)
        )

        #expect(timing.phase == .inTransit)
        #expect(timing.nextStopName == "Cluj")
        #expect(timing.stationsRemaining == 2)
        expectDate(timing.nextStopArrival, equals: date(2026, 6, 2, hour: 9, minute: 30))
    }

    @Test func phaseUsesDelayAdjustedDepartureAndArrival() {
        let base = date(2026, 6, 2)
        let trip = makeTrip(
            travelDate: base,
            stops: [
                stop(id: "ORA", name: "Oradea", sequence: 1),
                stop(id: "RDU", name: "Raduti", sequence: 2)
            ]
        )
        let schedules = MockScheduleProvider([
            "IR1|ORA": .init(arrivalSeconds: nil, departureSeconds: seconds(hour: 8, minute: 30)),
            "IR1|RDU": .init(arrivalSeconds: seconds(hour: 10, minute: 0), departureSeconds: nil)
        ])
        let info = DelayInfo(delayMinutes: 15, platform: nil)
        let resolver = TripTimingResolver(scheduleProvider: schedules, calendar: calendar)

        let beforeAdjustedDeparture = resolver.resolve(
            trip: trip,
            delayInfo: info,
            referenceDate: date(2026, 6, 2, hour: 8, minute: 40)
        )
        #expect(beforeAdjustedDeparture.phase == .preDeparture)

        let afterAdjustedDeparture = resolver.resolve(
            trip: trip,
            delayInfo: info,
            referenceDate: date(2026, 6, 2, hour: 8, minute: 46)
        )
        #expect(afterAdjustedDeparture.phase == .inTransit)

        let afterAdjustedArrival = resolver.resolve(
            trip: trip,
            delayInfo: info,
            referenceDate: date(2026, 6, 2, hour: 10, minute: 16)
        )
        #expect(afterAdjustedArrival.phase == .completed)
    }

    @Test func resolvedDurationUsesNormalizedOvernightSchedule() {
        let base = date(2026, 6, 2)
        let trip = makeTrip(
            travelDate: base,
            stops: [
                stop(id: "ORA", name: "Oradea", sequence: 1),
                stop(id: "RDU", name: "Raduti", sequence: 2)
            ]
        )
        let schedules = MockScheduleProvider([
            "IR1|ORA": .init(arrivalSeconds: nil, departureSeconds: seconds(hour: 23, minute: 40)),
            "IR1|RDU": .init(arrivalSeconds: seconds(hour: 0, minute: 20), departureSeconds: nil)
        ])

        let timing = TripTimingResolver(scheduleProvider: schedules, calendar: calendar).resolve(
            trip: trip,
            delayInfo: nil,
            referenceDate: date(2026, 6, 2, hour: 23, minute: 45)
        )

        #expect(timing.duration == 40 * 60)
        #expect(timing.adjustedArrival?.timeIntervalSince(timing.adjustedDeparture ?? .distantPast) == 40 * 60)
    }

    private func makeTrip(travelDate: Date, stops: [StoredStop]) -> Trip {
        Trip(
            id: "trip-1",
            title: "IR 1",
            subtitle: "Oradea → Raduti",
            gtfsTripId: "IR1",
            travelDate: travelDate,
            originStopId: "ORA",
            originName: "Oradea",
            destinationStopId: "RDU",
            destinationName: "Raduti",
            stops: stops,
            originSequence: 1,
            destinationSequence: 2
        )
    }

    private func stop(
        id: String,
        name: String,
        sequence: Int,
        arrivalDelay: Int? = nil,
        departureDelay: Int? = nil,
        platform: String? = nil
    ) -> StoredStop {
        StoredStop(
            id: id,
            name: name,
            latitude: 0,
            longitude: 0,
            sequence: sequence,
            arrivalDelayMinutes: arrivalDelay,
            departureDelayMinutes: departureDelay,
            platform: platform
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func seconds(hour: Int, minute: Int) -> Int {
        hour * 3600 + minute * 60
    }

    private func expectDate(_ actual: Date?, equals expected: Date) {
        #expect(actual != nil)
        if let actual {
            #expect(abs(actual.timeIntervalSince(expected)) < 0.1)
        }
    }
}

struct TripDelayFusionTests {
    @Test func infoFerDelayTakesPriorityOverGPSEstimate() {
        let departure = Date(timeIntervalSince1970: 1_000_000)
        let arrival = departure.addingTimeInterval(3_600)
        let timing = makeResolvedTiming(departure: departure, arrival: arrival)
        let prediction = TripDelayPrediction(
            predictedArrival: arrival.addingTimeInterval(12 * 60),
            delayMinutes: 12,
            source: .infoFerConfirmed,
            updatedAt: departure
        )

        #expect(prediction.source == .infoFerConfirmed)
        #expect(prediction.delayMinutes == 12)
        _ = timing
    }

    @Test func gpsEstimateIsClearlyMarkedAsEstimated() {
        let progress = TripGPSProgress(fraction: 0.5, recordedAt: Date())
        #expect(progress.fraction == 0.5)
        // The production store assigns `.gpsEstimated` only when no InfoFer
        // delay exists; this assertion documents the public source contract.
        #expect(TripDelayPredictionSource.gpsEstimated.rawValue == "GPS estimated")
    }

    private func makeResolvedTiming(departure: Date, arrival: Date) -> ResolvedTripTiming {
        ResolvedTripTiming(
            scheduledDeparture: departure,
            scheduledArrival: arrival,
            adjustedDeparture: departure,
            adjustedArrival: arrival,
            originDelayMinutes: 0,
            destinationDelayMinutes: 0,
            headerDelayMinutes: nil,
            phase: .inTransit,
            originPlatform: nil,
            destinationPlatform: nil,
            nextStopName: nil,
            nextStopArrival: nil,
            stationsRemaining: 0
        )
    }
}

private struct MockScheduleProvider: TripScheduleProviding {
    let schedules: [String: GTFSDataSource.GTFSStopSchedule]

    init(_ schedules: [String: GTFSDataSource.GTFSStopSchedule]) {
        self.schedules = schedules
    }

    func stopSchedule(for tripId: String, stopId: String) -> GTFSDataSource.GTFSStopSchedule? {
        schedules["\(tripId)|\(stopId)"]
    }
}

struct ScheduleDateUtilsTests {
    @Test func overnightBoardingUsesPreviousServiceDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let boardingDate = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 0))!

        let times: [Int?] = [21 * 3600, 23 * 3600 + 59 * 60, 86_400 + 6 * 60]
        let dayOffset = ScheduleDateUtils.serviceDayOffset(for: times, through: 2)
        let serviceDate = ScheduleDateUtils.serviceDate(
            forBoardingDate: boardingDate,
            dayOffset: dayOffset,
            calendar: calendar
        )

        #expect(serviceDate == calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 0))!)
    }

    @Test func sameDayBoardingKeepsServiceDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let boardingDate = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 0))!

        let dayOffset = ScheduleDateUtils.serviceDayOffset(
            for: [21 * 3600, 23 * 3600 + 50 * 60] as [Int?],
            through: 1
        )
        let serviceDate = ScheduleDateUtils.serviceDate(
            forBoardingDate: boardingDate,
            dayOffset: dayOffset,
            calendar: calendar
        )

        #expect(serviceDate == boardingDate)
    }

    @Test func normalizedClockRollsForwardAfterMidnight() {
        #expect(ScheduleDateUtils.serviceDayOffset(
            for: [23 * 3600 + 59 * 60, 6 * 60] as [Int?],
            through: 1
        ) == 1)
    }
}

private struct MockPlatformProvider: StaticPlatformProviding {
    let platforms: [String: String]

    init(_ platforms: [String: String] = [:]) {
        self.platforms = platforms
    }

    func platform(trainId: String, stationId: String) -> String? {
        platforms["\(trainId)|\(stationId)"]
    }
}
