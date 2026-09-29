import ActivityKit
import Foundation

struct TrainLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        enum JourneyPhase: String, Codable, Hashable {
            case preDeparture
            case boarding
            case inTransit
            case prepareToChange
            case prepareToArrive
            case connection
            case completed
        }

        struct Attention: Codable, Hashable {
            enum Kind: String, Codable { case platformChange, earlyDeparture, delay, tightConnection, missedConnection }
            var kind: Kind
            var message: String
            var previousPlatform: String?
            var newPlatform: String? = nil
            var expiresAt: Date
        }

        struct Connection: Codable, Hashable {
            var stationName: String
            var nextTrainNumber: String
            var nextOperatorLogoName: String? = nil
            var nextAgencyId: String? = nil
            var nextDestinationName: String? = nil
            var nextArrivalTime: Date? = nil
            var departureTime: Date
            var displayUntil: Date
            var fromPlatform: String?
            var toPlatform: String?
            var minimumTransferSeconds: Int?
            var hasFreshTiming: Bool = false
            var nextPlatformIsLive: Bool = false
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
        var coach: String?
        var seats: String?
        var connection: Connection?
        var trainNumber: String? = nil
        var serviceNumber: String? = nil
        var routeName: String? = nil
        var operatorLogoName: String? = nil
        var agencyId: String? = nil
        var originName: String? = nil
        var destinationName: String? = nil
        var headsign: String? = nil
        var boardingConfirmed: Bool? = nil
        var arrivalConfirmed: Bool? = nil
        var liveUpdatedAt: Date? = nil
        var platformIsLive: Bool? = nil
        var attention: Attention? = nil

        func effectivePhase(at date: Date) -> JourneyPhase {
            if arrivalConfirmed == true || date >= arrivalTime {
                if let connection {
                    if date < connection.departureTime { return .connection }
                    if showingNextLeg(at: date), let nextArrival = connection.nextArrivalTime,
                       date < nextArrival {
                        return date >= nextArrival.addingTimeInterval(-15 * 60) ? .prepareToArrive : .inTransit
                    }
                    if date < connection.displayUntil { return .connection }
                }
                return .completed
            }
            if connection != nil, date >= arrivalTime.addingTimeInterval(-15 * 60),
               date < arrivalTime { return .prepareToChange }
            if date >= arrivalTime.addingTimeInterval(-15 * 60), date >= departureTime {
                return .prepareToArrive
            }
            if boardingConfirmed == true || date >= departureTime.addingTimeInterval(-5 * 60) {
                return .inTransit
            }
            if date >= departureTime.addingTimeInterval(-10 * 60) { return .boarding }
            return .preDeparture
        }

        func showingNextLeg(at date: Date) -> Bool {
            guard let connection, connection.nextArrivalTime != nil,
                  arrivalTime <= connection.departureTime else { return false }
            return date >= connection.departureTime
        }

        func activeAttention(at date: Date) -> Attention? {
            guard let attention, date < attention.expiresAt,
                  !showingNextLeg(at: date) else { return nil }
            return attention
        }

        enum ConnectionStatus: Equatable {
            case onTrack, tight, missed, unknown
        }

        var connectionStatus: ConnectionStatus {
            guard let connection, connection.hasFreshTiming else { return .unknown }
            let available = connection.departureTime.timeIntervalSince(arrivalTime)
            if available <= 0 { return .missed }
            guard let minimum = connection.minimumTransferSeconds else { return .unknown }
            return available >= Double(minimum) ? .onTrack : .tight
        }
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
    var tripIDs: [String]? = nil
    var sharedJourneyID: String? = nil
}
