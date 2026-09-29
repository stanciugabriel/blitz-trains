import Foundation
import Testing
@testable import blitz

@MainActor
struct SBBSharedJourneyResolverTests {
    @Test func decodesMilanoShareWithFourConnections() throws {
        let html = #"<a href="https://www.sbb.ch/en/trip?tripId=3HA.eNqlVNtu4kYYFmSXsGSvfNMuUiVrjaqVooh_TvYYCSnGECAGLIw53qyyhIQkHJYzG-37tE-QB0j7HL3rQ1Sq1I4xp2Rzs-1YGs_3z3zzf9_M6I_8HZb-Cj8-5Kz844MbM5Lo1E4Wb3oXg6FsdgbT8UWvc9pI6hgox_y0maSMcg1RclpIcgJIAzi9SCIxteYWZteCKyhcp6quI4-iAjCqax6FASM7Cgasgo4pwpTsAGE85mRkDjJmDPFYDMVW7fEX978k8Sl2b9oZCIamg6YB8RgaYUgn3GcARvwbWRTwDqiYx_KmjJGscnhB1Pdk8BlOZ9AZTORaWrBUpnGdsJUTRgRf91kIvaBLpWgHOFrpYjLDL53V9ybxWdnO4Ldf597Vq4hiynwORoBhwwH4VhjHe_fIGYvlHVkHWcT3pD1Y5uODUssoWDHPFLGPYhqK6Iqiq-RNV0GKUVSESZWJARZRwwWjpNhpRXFchaiKt8V6D1AyTlYRGZVcvuQh01LEe1KBfN39dI1tfiA-7xiQF2CUfvVCiK_iJxhRjXKiUu6lcDY5kEAVMUYfc3SSN_xmGrhuu9V5upwys3E-azdZrzQutLQihVSFn5XbS_OuqzZaaNLtT49Zrth0-SVuuykrSzqXjLG-bYw017iukLpVKV9f3d-n6ozOJ4OpaWnHqbSaStcW51fn41z-ul40z-dds5PpzW5md-nxtDSsohvSKC9ai8UXZzi1gTZpj1sNrTroa0acLq9tPq82ZiM1jutjISrTil-VFk5jWLXu0KKQXcRdh82LXFMb6dtP95P7XK5THuFGd7KsdWfLpT274vGzMrstfx5_0qFXnLi128asPp_eNhYFKLVHBWt0pqL-8ItbzWr29KbVLFzN26kSpnGKLNu6vGDxeJ9dnlUXw5H9OZtpL9ExWLW03ipnxBEmk9LvASkWOVxXEumd93ZOQD_B1EU4QUkC4Biw6KUjfxXBWA5sAeJy0AfiKgmWD7YzoMmvVmBVCzT59Q4wObQDSD6Uft4AiD4RQBKMbwXI4ei7SNDJSEEO0derwvQ-BKIhBGHpD9-Gv8tTGzSx4u_ZEKswIsLGYeQAaXRtQUQBqLDgRcmefJFDyPdFejXkqUg1gfdEhqI_RIJ5UwpiFD0QZWorMfT-p0jAkII1R_5n0wIfdsP1tCO_PC39GdhTID1TQNGeAl8_Fud6tCaI4w-vARXHI7_ZACxqaWQLxMzROolXj57a5Am0Z_Nt9MeVzQCLHoiqt3H5IQRv_6fP3p4C6ZkCvHuOwsN6naiCz5UytlsXiUaFUkcK6hB95ZXBrdY3EPkXeyzsMw.eNqrVirLTCxWsoqO1QGz_PJLkDkhRYl5xWmpRRCx1IrknNKUVJfEktSUsNSMzOScVK_80qK81EqoCf5KVkoWxgaG5gYGSjpKLiCeqYGhgYEFkJcC5BkZGJnpGljqGpkABYAWKRkaWhkYA9mJQLYfkM4B0o5AOk_JKq80J0dHKRdkcC0AlwQuRA">Open in browser</a>"#
        let journey = try SBBSharedJourneyResolver.parseLandingPage(html)
        #expect(journey.legs.count == 4)
        #expect(journey.legs.map(\.service) == ["RE 80 25518", "IC 21 680", "IC 5 528", "IR 90 1828"])
        #expect(journey.legs.first?.origin.name == "Milano Centrale")
        #expect(journey.legs.last?.destination.name == "Genève")
        let trips = try GTFSDataSource.shared.importTrips(from: journey)
        #expect(trips.count == 4)
    }

    @Test func decodesRealThreeConnectionShare() throws {
        // Browser handoff captured from the supplied mJbDlS3I share on 2026-09-24.
        let html = #"<a href="https://www.sbb.ch/en/trip?tripId=3HA.eNqdU9tu4kYYFtmo0bJ75asWqZK1RtVKUZT55-RxJCSMTbCXAMEYSnJTgWNCCDgHA5tE-w59h960L9A8QPY5KvVN2jGGwGb3ph1L4_k8_g7z23_27x3lr52nR6fqPj36ebMAxUahFN5GxW5Bp8QAAsWTAuUGFYLQ4lFBMKQjhIq9AmBRXBLq4SwYfv5tGo4ljRuEccNIaQbXsZHSKMawomGEOTIwBcTIGsitvOupnKsEg8jnIb8YT7_7_9cnpXlhFEax2rETFtOFJC5YjOiILFkAIL5KB8RYgySSa6lMZcC_ke2_mqSsShh9_mMeJhygmLKUgwFhtOIg9HUwjDfKhhlLymYgFcRmtMeq9fSodcoa1qxDTepolqnJqSanlmv5GmhmTQMuM8oFlk9NH5l1rWFrmudrhGuJxFIDaWWvohHNcevJ2qpq0pga5NP6xoGtbkhewBeQCv4JEigWT_cwUJ0KwqlI5L2VPkjUkmv4xaGxa6bDMjFu-O253SxZlX0xC05YVJ7enuo1hOzxVXXILix3yLuncO3X-1N8fHI-kqVns7LZMh4Gx43anbCJ2yyVZuM4apctGsfevOEz3WGNXq0ZxWalraPr84v7Zrvhl2pNZ9oNrIH74Jf6dHR1VL_qyBO0P94NLluXvQ8-cazuh6jkDVqTM9ys6xVhA3DTgHln6EEvmlC7Dx9JadSOB_xoYgofdqfHl9Qn8-vAasxCgoPp2L69aR0-TAPTGTXCeMLoDb0_J2wkiNd5MIJg3zo8CXoTux561RukV36-vbeHd73eWXytg3cV70JHtibpXdBpvwr65Cx0nO6hHRpuJT692zf7-H4S8dNmWZawUFB-zSj57M6ycZUfkv9mDxl7mPqADhg5QGgXYTkrb5K3QH4_qmZSgChFSN16BoKor5SfUiDbLPeFGBxg8Symbue-z265nrLFeW476ed330l7RAjaVv7MbIgoL0SIsRbJrpyxBG-WpKSLvnTGB7Dh_HbhbCkZlnslj5P6ArzPorfvfsxmTGWr46n_rEbm_Xq53PbUb28r440EyosEeF1I9fXqPdm7L5MytnG8XC6tkYFy20nzPmd9jbL_AoryeU4.eNqrVirLTCxWsoqO1QGz_PJLkDkhRYl5xWmpRRCx1IrknNKUVJfEktSUsNSMzOScVK_80qK81EqoCf5KVkoWpgbmBgYGSjpKLhCeoYGBBZCXAuQZGRiZ6RpY6hqZAAWAFikZGliZmAHZiUC2H5DOAdKOQDpPySqvNCdHRykXZHAtAJgzLks">Open in browser</a>"#
        let journey = try SBBSharedJourneyResolver.parseLandingPage(html)
        #expect(journey.legs.count == 3)
        #expect(journey.legs.map(\.service) == ["IR 66 3218", "IC 5 516", "IR 90 1816"])
        #expect(journey.legs.map { $0.origin.name } == ["Bern", "Neuchâtel", "Renens VD"])
        #expect(journey.legs.map { $0.destination.name } == ["Neuchâtel", "Renens VD", "Genève"])
        #expect(journey.legs.first?.origin.id == "8507000")
        #expect(journey.legs.last?.destination.id == "8501008")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Zurich")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        #expect(journey.legs.map { formatter.string(from: $0.departure) } == ["2026-09-24 10:53", "2026-09-24 11:39", "2026-09-24 12:23"])
        #expect(journey.legs.map { formatter.string(from: $0.arrival) } == ["2026-09-24 11:28", "2026-09-24 12:18", "2026-09-24 12:55"])
        let trips = try GTFSDataSource.shared.importTrips(from: journey)
        #expect(trips.count == 3)
        #expect(trips.map(\.title) == ["IR66 3218", "IC5 516", "IR90 1816"])
        #expect(trips.map(\.originName) == ["Bern", "Neuchâtel", "Renens VD"])
        #expect(trips.map(\.destinationName) == ["Neuchâtel", "Renens VD", "Genève"])
        #expect(trips.allSatisfy { $0.gtfsTripId != nil && ($0.stops?.count ?? 0) >= 2 })
        let replay = try GTFSDataSource.shared.importTrips(from: journey)
        #expect(trips.map(\.id) == replay.map(\.id))
        let invalid = SharedJourney.Leg(origin: journey.legs[0].origin, destination: journey.legs[0].destination,
                                       departure: journey.legs[0].departure, arrival: journey.legs[0].arrival, service: "IC999 999999")
        let unmatched = try GTFSDataSource.shared.importTrips(from: SharedJourney(legs: [journey.legs[0], invalid]))
        #expect(unmatched.count == 2)
        #expect(unmatched[1].gtfsTripId == nil)
        #expect(unmatched[1].sharedJourneyLeg == invalid)
        #expect(unmatched[1].stops?.count == 2)
        #expect(journey.legs[0].origin.latitude != nil)

        // A changed time or a date outside the bundled feed is not an import error.
        let shifted = SharedJourney.Leg(origin: journey.legs[0].origin, destination: journey.legs[0].destination,
                                       departure: journey.legs[0].departure.addingTimeInterval(60),
                                       arrival: journey.legs[0].arrival.addingTimeInterval(180), service: journey.legs[0].service)
        let future = SharedJourney.Leg(origin: shifted.origin, destination: shifted.destination,
                                      departure: shifted.departure.addingTimeInterval(86400 * 730),
                                      arrival: shifted.arrival.addingTimeInterval(86400 * 730), service: shifted.service)
        for leg in [shifted, future, invalid] {
            let imported = try #require(GTFSDataSource.shared.importTrips(from: SharedJourney(legs: [leg])).first)
            let saved = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(imported))
            let updated = saved.updatingTicketQRCode("ticket").updatingStops(saved.stops ?? [])
            #expect(updated.sharedJourneyLeg == leg)
            let timing = TripTimingResolver().resolve(trip: updated, delayInfo: nil, referenceDate: leg.departure)
            #expect(timing.scheduledDeparture == leg.departure)
            #expect(timing.scheduledArrival == leg.arrival)
            #expect(timing.nextStopName == leg.destination.name)
        }
    }

    @Test func importsWithoutStaticStationsOrCoordinates() throws {
        let text = "¶HKI¶T$A=1@O=New Origin@L=missing-a@$A=1@O=New Destination@L=missing-b@$202609242353$202609250128$IC 999999$$"
        let journey = try SBBSharedJourneyResolver.parseReconstruction(text)
        let trip = try #require(GTFSDataSource.shared.importTrips(from: journey).first)
        #expect(trip.gtfsTripId == nil)
        #expect(trip.stops?.isEmpty == true)
        let timing = TripTimingResolver().resolve(trip: trip, delayInfo: nil)
        #expect(timing.scheduledDeparture == journey.legs[0].departure)
        #expect(timing.scheduledArrival == journey.legs[0].arrival)
        #expect(abs((timing.duration ?? 0) - 95 * 60) < 1)
    }

    @Test func rejectsMissingCorruptOrUnknownData() {
        #expect(throws: (any Error).self) { try SBBSharedJourneyResolver.parseLandingPage("<html>Expired share</html>") }
        #expect(throws: (any Error).self) { try SBBSharedJourneyResolver.decodeToken("4HA.eA.eA") }
        #expect(throws: (any Error).self) { try SBBSharedJourneyResolver.decodeToken("3HA.eA.eA") }
        #expect(throws: (any Error).self) { try SBBSharedJourneyResolver.parseReconstruction("¶HKI¶T$broken") }
    }

    @Test func rejectsPartialJourneyInsteadOfDroppingConnection() {
        let text = "¶HKI¶T$A=1@O=A@L=1@$A=1@O=B@L=2@$202609241053$202609241128$IC 1$$§UNKNOWN"
        #expect(throws: (any Error).self) { try SBBSharedJourneyResolver.parseReconstruction(text) }
    }

    @Test func inboxPersistsUntilAcknowledgedAndKeepsSeparateSubmissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "¶HKI¶T$A=1@O=A@L=1@$A=1@O=B@L=2@$202609241053$202609241128$IC 1$$"
        let journey = try SBBSharedJourneyResolver.parseReconstruction(text)
        try SharedJourneyInbox(directory: directory).enqueue(journey)
        try SharedJourneyInbox(directory: directory).enqueue(journey)
        let inbox = try SharedJourneyInbox(directory: directory)
        let pending = try inbox.pending()
        #expect(pending.count == 2)
        let restored = try inbox.read(pending[0])
        #expect(restored.legs.first?.departure == journey.legs.first?.departure)
        #expect(restored.legs.first?.service == "IC 1")
        #expect(try inbox.pending().count == 2)
        try inbox.acknowledge(pending[0])
        #expect(try inbox.pending().count == 1)
    }
}
