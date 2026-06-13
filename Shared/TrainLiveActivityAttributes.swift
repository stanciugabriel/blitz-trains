import ActivityKit
import Foundation

struct TrainLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        enum JourneyPhase: String, Codable, Hashable {
            case preDeparture
            case inTransit
            case completed
        }

        var journeyPhase: JourneyPhase
        var platform: String?
        var departureTime: Date
        var arrivalTime: Date
        var nextStopName: String?
        var nextStopArrivalTime: Date?
        var stationsRemaining: Int
        var isDelayed: Bool
        var dataTimestamp: Date
        var delayMinutes: Int
    }

    var tripID: String
    var trainNumber: String
    var operatorName: String
    var originStationCode: String
    var originStationName: String
    var destinationStationCode: String
    var destinationStationName: String
    var coachAndSeat: String?
    var agencyId: String?
    var operatorLogoName: String?
}
