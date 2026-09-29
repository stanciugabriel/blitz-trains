#if DEBUG
import ActivityKit
import WidgetKit

// Select a surface in Xcode's canvas, then use the preview timeline to step
// through every phase. Times are relative to now so the states stay useful.
private enum TrainLiveActivityPreview {
    typealias State = TrainLiveActivityAttributes.ContentState

    static let attributes = TrainLiveActivityAttributes(
        tripID: "preview-ic8",
        trainNumber: "IC 8",
        operatorName: "SBB",
        originStationCode: "ZUE",
        originStationName: "Zürich HB",
        destinationStationCode: "BERN",
        destinationStationName: "Bern",
        coachAndSeat: "Car 6 · Seat 42",
        agencyId: "11",
        operatorLogoName: "sbb"
    )

    private static func minutes(_ value: Double) -> Date {
        Date.now.addingTimeInterval(value * 60)
    }

    private static func state(
        _ phase: State.JourneyPhase,
        departure: Double,
        arrival: Double,
        connection: State.Connection? = nil
    ) -> State {
        var result = State(
            journeyPhase: phase,
            platform: "7",
            departureTime: minutes(departure),
            arrivalTime: minutes(arrival),
            nextStopName: "Olten",
            nextStopArrivalTime: minutes(19),
            stationsRemaining: 2,
            isDelayed: false,
            dataTimestamp: .now,
            delayMinutes: 0,
            coach: "6",
            seats: "42",
            connection: connection
        )
        result.trainNumber = "IC 8"
        result.serviceNumber = "2145"
        result.routeName = "IC8"
        result.operatorLogoName = "sbb"
        result.agencyId = "11"
        result.originName = "Zürich HB"
        result.destinationName = "Bern"
        result.headsign = "Brig"
        result.platformIsLive = true
        result.liveUpdatedAt = .now
        return result
    }

    private static func connection(departure: Double = 15) -> State.Connection {
        State.Connection(
            stationName: "Bern",
            nextTrainNumber: "IC 6",
            nextOperatorLogoName: "sbb",
            nextAgencyId: "11",
            nextDestinationName: "Basel SBB",
            nextArrivalTime: minutes(75),
            departureTime: minutes(departure),
            displayUntil: minutes(25),
            fromPlatform: "7",
            toPlatform: "10",
            minimumTransferSeconds: 6 * 60,
            hasFreshTiming: true,
            nextPlatformIsLive: true
        )
    }

    static var readyToGo: State {
        state(.preDeparture, departure: 25, arrival: 88)
    }

    static var readyTwoSeats: State {
        var result = readyToGo
        result.seats = "7, 8"
        return result
    }

    static var readyNoSeat: State {
        var result = readyToGo
        result.coach = nil
        result.seats = nil
        return result
    }

    static var readyThreeSeats: State {
        var result = readyToGo
        result.seats = "7, 8, 9"
        return result
    }

    static var readyMultipleCars: State {
        var result = readyToGo
        result.coach = "6, 7"
        result.seats = "7, 8"
        return result
    }

    static var headToTrain: State {
        state(.boarding, departure: 8, arrival: 71)
    }

    static var onTrain: State {
        var result = state(.inTransit, departure: -20, arrival: 38)
        result.boardingConfirmed = true
        return result
    }

    static var prepareToChange: State {
        var result = state(.prepareToChange, departure: -48, arrival: 12,
                           connection: connection(departure: 24))
        result.boardingConfirmed = true
        return result
    }

    static var getReadyToLeave: State {
        var result = state(.prepareToArrive, departure: -52, arrival: 8)
        result.boardingConfirmed = true
        return result
    }

    static var makeConnection: State {
        var result = state(.connection, departure: -65, arrival: -2)
        result.connection = connection()
        result.boardingConfirmed = true
        result.arrivalConfirmed = true
        return result
    }

    static var arrived: State {
        var result = state(.completed, departure: -75, arrival: -3)
        result.boardingConfirmed = true
        result.arrivalConfirmed = true
        return result
    }

    static var platformChanged: State {
        var result = headToTrain
        result.platform = "8"
        result.attention = State.Attention(
            kind: .platformChange,
            message: "Platform changed to 8",
            previousPlatform: "7",
            newPlatform: "8",
            expiresAt: minutes(5)
        )
        return result
    }

    static var tightConnection: State {
        var result = makeConnection
        result.connection = connection(departure: 2)
        result.attention = State.Attention(
            kind: .tightConnection,
            message: "Connection is tight — head to platform 10",
            previousPlatform: nil,
            expiresAt: minutes(5)
        )
        return result
    }

    static var missedConnection: State {
        var result = state(.prepareToChange, departure: -60, arrival: 3,
                           connection: connection(departure: 2))
        result.boardingConfirmed = true
        result.attention = State.Attention(
            kind: .missedConnection,
            message: "Connection likely missed",
            previousPlatform: nil,
            expiresAt: minutes(5)
        )
        return result
    }
}

#Preview("Dynamic Island · Expanded", as: .dynamicIsland(.expanded), using: TrainLiveActivityPreview.attributes) {
    blitzWidget()
} contentStates: {
    TrainLiveActivityPreview.readyToGo
    TrainLiveActivityPreview.readyNoSeat
    TrainLiveActivityPreview.readyTwoSeats
    TrainLiveActivityPreview.readyThreeSeats
    TrainLiveActivityPreview.readyMultipleCars
    TrainLiveActivityPreview.headToTrain
    TrainLiveActivityPreview.onTrain
    TrainLiveActivityPreview.prepareToChange
    TrainLiveActivityPreview.getReadyToLeave
    TrainLiveActivityPreview.makeConnection
    TrainLiveActivityPreview.arrived
    TrainLiveActivityPreview.platformChanged
    TrainLiveActivityPreview.tightConnection
    TrainLiveActivityPreview.missedConnection
}

#Preview("Dynamic Island · Compact", as: .dynamicIsland(.compact), using: TrainLiveActivityPreview.attributes) {
    blitzWidget()
} contentStates: {
    TrainLiveActivityPreview.readyToGo
    TrainLiveActivityPreview.headToTrain
    TrainLiveActivityPreview.onTrain
    TrainLiveActivityPreview.prepareToChange
    TrainLiveActivityPreview.getReadyToLeave
    TrainLiveActivityPreview.makeConnection
    TrainLiveActivityPreview.arrived
    TrainLiveActivityPreview.platformChanged
    TrainLiveActivityPreview.tightConnection
    TrainLiveActivityPreview.missedConnection
}

#Preview("Dynamic Island · Minimal", as: .dynamicIsland(.minimal), using: TrainLiveActivityPreview.attributes) {
    blitzWidget()
} contentStates: {
    TrainLiveActivityPreview.readyToGo
    TrainLiveActivityPreview.headToTrain
    TrainLiveActivityPreview.onTrain
    TrainLiveActivityPreview.prepareToChange
    TrainLiveActivityPreview.getReadyToLeave
    TrainLiveActivityPreview.makeConnection
    TrainLiveActivityPreview.arrived
    TrainLiveActivityPreview.platformChanged
    TrainLiveActivityPreview.tightConnection
    TrainLiveActivityPreview.missedConnection
}

#Preview("Lock Screen", as: .content, using: TrainLiveActivityPreview.attributes) {
    blitzWidget()
} contentStates: {
    TrainLiveActivityPreview.readyToGo
    TrainLiveActivityPreview.headToTrain
    TrainLiveActivityPreview.onTrain
    TrainLiveActivityPreview.prepareToChange
    TrainLiveActivityPreview.getReadyToLeave
    TrainLiveActivityPreview.makeConnection
    TrainLiveActivityPreview.arrived
    TrainLiveActivityPreview.platformChanged
    TrainLiveActivityPreview.tightConnection
    TrainLiveActivityPreview.missedConnection
}
#endif
