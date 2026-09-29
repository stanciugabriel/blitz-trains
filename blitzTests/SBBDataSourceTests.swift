import Foundation
import CoreLocation
import SQLite3
import Testing
@testable import blitz

struct SBBDataSourceTests {
    private func fixture() throws -> (GTFSDataSource, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE agency(agency_id TEXT, agency_name TEXT, agency_url TEXT, agency_timezone TEXT);
        CREATE TABLE routes(route_id TEXT, agency_id TEXT, route_short_name TEXT, route_desc TEXT);
        CREATE TABLE trips(trip_id TEXT, route_id TEXT, trip_short_name TEXT);
        CREATE TABLE stops(stop_id TEXT, stop_name TEXT, stop_lat TEXT, stop_lon TEXT, parent_station TEXT, platform_code TEXT);
        CREATE TABLE stop_times(trip_id TEXT, stop_id TEXT, stop_sequence TEXT, arrival_time TEXT, departure_time TEXT, pickup_type TEXT, drop_off_type TEXT);
        INSERT INTO agency VALUES('11', 'SBB', 'https://sbb.ch', 'Europe/Berlin');
        INSERT INTO routes VALUES('r', '11', 'IC1', 'IC');
        INSERT INTO trips VALUES('service-a', 'r', '101'), ('service-b', 'r', '101'), ('service-duplicate', 'r', '101');
        INSERT INTO stops VALUES
          ('a1', 'Zürich HB', '47.38', '8.54', 'station-a', '4'),
          ('b1', 'Bern', '46.95', '7.44', 'station-b', '7'),
          ('c1', 'Checkpoint', '46.8', '7.2', '', ''),
          ('d1', 'Lausanne', '46.52', '6.63', 'station-d', '1');
        INSERT INTO stop_times VALUES
          ('service-a', 'a1', '1', '23:50:00', '23:50:00', '0', '0'),
          ('service-a', 'b1', '2', '24:30:00', '24:30:00', '0', '0'),
          ('service-a', 'c1', '10', '24:50:00', '24:50:00', '1', '1'),
          ('service-a', 'd1', '11', '25:10:00', '25:10:00', '0', '0'),
          ('service-b', 'a1', '1', '10:00:00', '10:00:00', '0', '0'),
          ('service-b', 'd1', '2', '12:00:00', '12:00:00', '0', '0'),
          ('service-duplicate', 'a1', '1', '23:50:00', '23:50:00', '0', '0'),
          ('service-duplicate', 'b1', '2', '24:30:00', '24:30:00', '0', '0'),
          ('service-duplicate', 'c1', '10', '24:50:00', '24:50:00', '1', '1'),
          ('service-duplicate', 'd1', '11', '25:10:00', '25:10:00', '0', '0');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return (GTFSDataSource(databaseURL: url), url)
    }

    @Test func preservesServicesSharingTrainNumber() throws {
        let (source, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let trips = source.searchTrips(matching: "101")
        #expect(trips.count == 1)
        #expect(Set(trips.map(\.id)).count == 1)
        #expect(trips.first?.gtfsTripId == "service-a")
        #expect(trips.allSatisfy { $0.title == "IC1 101" && $0.agencyId == "11" })
        #expect(source.searchTrips(matching: "Zürich").count == 1)
        #expect(source.agencyInfo(for: "11")?.name == "SBB")
    }

    @Test func mapsPlatformsCommercialStopsAndOvernightSegments() throws {
        let (source, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let stops = source.stops(for: "service-a")
        #expect(stops.map(\.id) == ["station-a", "station-b", "station-d"])
        #expect(stops.map(\.sequence) == [1, 2, 11])
        #expect(source.polylineStops(for: "service-a").count == 4)
        #expect(source.platform(trainId: "service-a", stationId: "station-b") == "7")
        #expect(source.platform(trainId: "service-a", stationId: "c1") == nil)
        let segments = source.segments(for: "service-a")
        #expect(segments.map(\.id) == [1, 2, 10])
        #expect(segments.last?.arrivalSeconds == 25 * 3600 + 10 * 60)
        let schedules = source.stopSchedules(for: "service-a", stopIds: ["station-a", "station-d"])
        #expect(schedules["station-d"]?.arrivalSeconds == 90600)
        #expect(source.departures(from: "station-a", after: Date()).isEmpty)
    }

    @Test func sharedJourneyLegsKeepTheirConnectionIdentity() throws {
        let (source, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let departure = Date(timeIntervalSince1970: 1_000_000)
        let zurich = SharedJourney.Station(id: "8503000", name: "Zürich HB")
        let bern = SharedJourney.Station(id: "8507000", name: "Bern")
        let lausanne = SharedJourney.Station(id: "8501120", name: "Lausanne")
        let journey = SharedJourney(legs: [
            .init(origin: zurich, destination: bern, departure: departure,
                  arrival: departure.addingTimeInterval(60 * 60), service: "IC1 101"),
            .init(origin: bern, destination: lausanne,
                  departure: departure.addingTimeInterval(70 * 60),
                  arrival: departure.addingTimeInterval(130 * 60), service: "IC1 102")
        ])
        let trips = try source.importTrips(from: journey)
        #expect(trips.count == 2)
        #expect(trips[0].sharedJourneyID != nil)
        #expect(trips[0].sharedJourneyID == trips[1].sharedJourneyID)
        #expect(trips[0].updatingSeatInfo(car: "4", seats: ["12"], trainType: nil,
                                         trainLength: nil, trainTonnage: nil,
                                         trainIdentifier: nil, trainPower: nil).sharedJourneyID == trips[0].sharedJourneyID)
    }

    @Test func transferMinimumUsesActualStopPairAndParentFallback() throws {
        let (_, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE transfers(from_stop_id TEXT, to_stop_id TEXT, transfer_type TEXT, min_transfer_time TEXT);
        INSERT INTO transfers VALUES('a1', 'b1', '2', '240');
        INSERT INTO transfers VALUES('station-a', 'station-d', '2', '420');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let source = GTFSDataSource(databaseURL: url)
        #expect(source.minimumTransferSeconds(from: "a1", to: "b1") == 240)
        #expect(source.minimumTransferSeconds(from: "a1", to: "d1") == 420)
        #expect(source.minimumTransferSeconds(from: "b1", to: "d1") == nil)
    }

    @Test func bundledSwissDatabaseLoadsRealServices() {
        let source = GTFSDataSource.shared
        let trips = source.searchTrips(matching: "12768")
        #expect(!trips.isEmpty)
        #expect(trips.allSatisfy { $0.gtfsTripId?.hasPrefix(".ojp-") == true })
        let zurich = trips.first { $0.destinationName == "Zürich HB" }
        #expect(zurich != nil)
        if let zurich {
            let variants = source.variants(for: zurich, travelDate: nil, matching: "12768")
            #expect(variants.contains { $0.originName == "Zürich Triemli" && $0.destinationName == "Zürich HB" })
        }
    }

    @Test func shapeGeometryUsesNumericOrderAndClipsAtSelectedStops() throws {
        let (_, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
        ALTER TABLE trips ADD COLUMN shape_id TEXT;
        ALTER TABLE stop_times ADD COLUMN shape_dist_traveled REAL;
        CREATE TABLE shapes(shape_id TEXT, shape_pt_lat REAL, shape_pt_lon REAL, shape_pt_sequence TEXT, shape_dist_traveled REAL);
        UPDATE trips SET shape_id = CASE trip_id WHEN 'service-a' THEN 'curve' ELSE 'missing' END;
        UPDATE stop_times SET shape_dist_traveled = CASE stop_sequence WHEN '1' THEN 0 WHEN '2' THEN 15 WHEN '10' THEN 30 ELSE 40 END;
        INSERT INTO shapes VALUES
          ('curve',47.38,8.54,'1',0),
          ('curve',47.5,8.0,'2',10),
          ('curve',46.95,7.44,'10',20),
          ('curve',46.8,7.2,'11',30),
          ('curve',46.52,6.63,'12',40);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let source = GTFSDataSource(databaseURL: url)
        let geometry = source.routeGeometry(for: "service-a")
        #expect(geometry.hasShape)
        #expect(geometry.stops.count == 4) // Noncommercial checkpoint stays in geometry.
        #expect(source.stops(for: "service-a").count == 3)
        #expect(geometry.coordinates().map(\.longitude) == [8.54, 8.0, 7.44, 7.2, 6.63])
        let leg = geometry.coordinates(fromSequence: 2, toSequence: 10)
        #expect(leg.count == 3)
        #expect(abs((leg.first?.longitude ?? 0) - 7.72) < 0.00001)
        #expect(leg.last?.longitude == 7.2)
        let missing = source.routeGeometry(for: "service-b")
        #expect(!missing.hasShape)
        #expect(missing.coordinates().count == 2)
        #expect(source.routeGeometry(for: "unknown").coordinates().isEmpty)
    }

    @Test func missingShapeSchemaKeepsStationGeometry() throws {
        let (source, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let geometry = source.routeGeometry(for: "service-a")
        #expect(!geometry.hasShape)
        #expect(geometry.coordinates().count == 4)
        #expect(geometry.coordinates(fromSequence: 2, toSequence: 11).map(\.longitude) == [7.44, 7.2, 6.63])
    }

    @Test func bundledMiniFeedHasShapesAndPreservesStationIdentity() throws {
        #expect(Bundle.main.url(forResource: "mini_feed", withExtension: "sqlite") != nil)
        #expect(Bundle.main.url(forResource: "sbb_gtfs", withExtension: "db") == nil)
        let source = GTFSDataSource.shared
        let trip = try #require(source.searchTrips(matching: "IC1 728").first { $0.destinationName == "Genève-Aéroport" })
        let identifier = try #require(trip.gtfsTripId)
        let geometry = source.routeGeometry(for: identifier)
        #expect(geometry.hasShape)
        #expect(geometry.coordinates().count > geometry.stops.count)
        let origin = try #require(geometry.stops.first)
        #expect(origin.id.hasPrefix("Parent"))
        #expect(source.stationUIC(for: origin.id) != nil)
        #expect(source.stopSchedule(for: identifier, stopId: origin.id)?.departureSeconds != nil)
        #expect(source.platform(trainId: identifier, stationId: origin.id) != nil)
    }

    @Test func publicServiceVariantsCollapseToLongestRoute() {
        let trips = GTFSDataSource.shared.searchTrips(matching: "728")
        #expect(trips.contains { $0.title == "IC1 728" })

        let ic1Trips = GTFSDataSource.shared.searchTrips(matching: "IC1 728")
        #expect(ic1Trips.count == 3)
        #expect(ic1Trips.allSatisfy { $0.title == "IC1 728" })
        #expect(ic1Trips.contains { $0.destinationName == "Genève-Aéroport" })

        let ic1Services = GTFSDataSource.shared.searchTrips(matching: "IC1")
        #expect(!ic1Services.isEmpty)
        #expect(ic1Services.allSatisfy { $0.title.hasPrefix("IC1 ") })
    }

    @Test func groupedSuggestionExposesConcreteDepartureVariants() {
        let suggestions = GTFSDataSource.shared.searchTrips(matching: "IC1 728")
        guard let airport = suggestions.first(where: { $0.destinationName == "Genève-Aéroport" }) else {
            #expect(Bool(false))
            return
        }
        let variants = GTFSDataSource.shared.variants(for: airport, travelDate: nil, matching: "IC1 728")
        #expect(!variants.isEmpty)
        #expect(variants.allSatisfy { $0.title == "IC1 728" && $0.destinationName == "Genève-Aéroport" })
        #expect(variants.allSatisfy { $0.originName == "St. Gallen" })
    }

    @Test func r12SuggestionsAreUniqueByOperatorLineAndHeadsign() {
        let trips = GTFSDataSource.shared.searchTrips(matching: "R12")
        let keys = trips.map { "\($0.agencyId ?? "")|\($0.destinationName ?? "")" }
        #expect(trips.count == 4)
        #expect(Set(keys).count == trips.count)
    }

    @Test func stationsAndFinalOptionsUseAllVariants() throws {
        let (source, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let suggestion = try #require(source.searchTrips(matching: "IC1").first)
        let variants = source.variants(for: suggestion, travelDate: nil)
        #expect(variants.count == 3)
        #expect(Set(source.stationChoices(in: variants).map(\.id)) == ["station-a", "station-b"])
        #expect(source.stationChoices(in: variants, after: "station-b").map(\.id) == ["station-d"])
        let options = source.options(in: variants, originID: "station-b", destinationID: "station-d")
        #expect(options.count == 1)
        #expect(options.first?.originSequence == 2)
        #expect(options.first?.destinationSequence == 11)
        #expect(options.first?.originName == "Bern")
        #expect(source.options(in: variants, originID: "station-d", destinationID: "station-a").isEmpty)
        #expect(source.options(in: variants, originID: "station-a", destinationID: "station-d").count == 2)
        #expect(source.operates(tripID: "service-a", on: Date()) == nil)
    }

    @Test func calendarWeekdaysExceptionsAndOvernightBoarding() throws {
        let (_, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
        ALTER TABLE trips ADD COLUMN service_id TEXT;
        UPDATE trips SET service_id = 'weekdays';
        CREATE TABLE calendar(service_id TEXT, monday TEXT, tuesday TEXT, wednesday TEXT, thursday TEXT, friday TEXT, saturday TEXT, sunday TEXT, start_date TEXT, end_date TEXT);
        INSERT INTO calendar VALUES('weekdays','1','1','1','1','1','0','0','20260101','20261231');
        CREATE TABLE calendar_dates(service_id TEXT, date TEXT, exception_type TEXT);
        INSERT INTO calendar_dates VALUES('weekdays','20260924','2'),('weekdays','20260926','1');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let source = GTFSDataSource(databaseURL: url)
        func date(_ day: Int) -> Date {
            GTFSDataSource.calendar.date(from: DateComponents(year: 2026, month: 9, day: day))!
        }
        #expect(source.operates(tripID: "service-a", on: date(23)) == true)
        #expect(source.operates(tripID: "service-a", on: date(24)) == false)
        #expect(source.operates(tripID: "service-a", on: date(26)) == true)
        #expect(source.operates(tripID: "service-a", on: date(27)) == false)
        let suggestion = try #require(source.searchTrips(matching: "IC1").first)
        let variants = source.variants(for: suggestion, travelDate: date(24))
        #expect(source.options(in: variants, originID: "station-a", destinationID: "station-d").isEmpty)
        let overnight = source.options(in: variants, originID: "station-b", destinationID: "station-d")
        #expect(overnight.count == 1)
        #expect(overnight.first?.travelDate == date(23))
        let available = source.availableBoardingDates(for: suggestion, matching: "IC1", month: date(1))
        #expect(available.contains(date(23)))
        #expect(available.contains(date(24))) // Boarding after midnight on Wednesday's service.
        #expect(available.contains(date(26))) // Added Saturday service.
        #expect(!available.contains(date(6))) // Sunday with no Saturday service.
        #expect(available.allSatisfy { GTFSDataSource.calendar.component(.month, from: $0) == 9 })
    }

    @Test func packedExceptionsRespectBitOrderWeeklyFallbackAndDST() throws {
        let (_, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
        ALTER TABLE trips ADD COLUMN service_id TEXT;
        UPDATE trips SET service_id = trip_id;
        CREATE TABLE calendar(service_id TEXT, monday TEXT, tuesday TEXT, wednesday TEXT, thursday TEXT, friday TEXT, saturday TEXT, sunday TEXT, start_date TEXT, end_date TEXT);
        INSERT INTO calendar SELECT trip_id,'1','1','1','1','1','0','0','20260101','20261231' FROM trips;
        CREATE TABLE calendar_date_masks(service_id TEXT PRIMARY KEY, start_date TEXT NOT NULL, day_count INTEGER NOT NULL, codec INTEGER NOT NULL, exceptions BLOB NOT NULL) WITHOUT ROWID;
        INSERT INTO calendar_date_masks VALUES('service-a','20261024',4,0,X'61');
        INSERT INTO calendar_date_masks VALUES('service-b','20261024',32,1,X'78da4b4c8400000dac0309');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let source = GTFSDataSource(databaseURL: url)
        func date(_ day: Int) -> Date {
            GTFSDataSource.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
        }
        #expect(source.hasServiceCalendar)
        // Europe/Zurich's DST transition is on October 25: offsets must use calendar days.
        for id in ["service-a", "service-b"] {
            #expect(source.operates(tripID: id, on: date(23)) == true)
            #expect(source.operates(tripID: id, on: date(24)) == true)
            #expect(source.operates(tripID: id, on: date(25)) == false)
            #expect(source.operates(tripID: id, on: date(26)) == false)
            #expect(source.operates(tripID: id, on: date(27)) == true)
        }
        #expect(source.operates(tripID: "service-a", on: date(28)) == true)
        #expect(source.operates(tripID: "service-b", on: date(29)) == true)
        #expect(source.operates(tripID: "service-b", on: date(30)) == false)
        #expect(source.operates(tripID: "service-b", on: date(31)) == true)
        // Missing masks preserve weekly service.
        #expect(source.operates(tripID: "service-duplicate", on: date(26)) == true)
        #expect(source.operates(tripID: "service-duplicate", on: date(25)) == false)
    }

    @Test func swissTimeZoneAndInvalidTimes() {
        #expect(GTFSDataSource.calendar.timeZone.identifier == "Europe/Zurich")
        #expect(GTFSDataSource.seconds("26:05:00") == 93900)
        #expect(GTFSDataSource.seconds("12:60:00") == nil)
        #expect(GTFSDataSource.seconds(nil) == nil)
    }
}
