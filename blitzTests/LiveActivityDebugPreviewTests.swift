#if DEBUG
import ActivityKit
import Foundation
import Testing
@testable import blitz

@MainActor
struct LiveActivityDebugPreviewTests {
    @Test func sampleDatesDisplayTheSelectedJourneyPhase() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expected: [(LiveActivityDebugPreview.Phase, TrainLiveActivityAttributes.ContentState.JourneyPhase)] = [
            (.readyToGo, .preDeparture),
            (.headToTrain, .boarding),
            (.onTrain, .inTransit),
            (.prepareToChange, .prepareToChange),
            (.prepareToArrive, .prepareToArrive),
            (.makeConnection, .connection),
            (.arrived, .completed),
            (.platformChanged, .boarding),
            (.tightConnection, .connection),
            (.missedConnection, .prepareToChange)
        ]

        for (phase, journeyPhase) in expected {
            let state = LiveActivityDebugPreview.state(for: phase, at: now)
            #expect(state.effectivePhase(at: now) == journeyPhase)
            #expect(state.serviceNumber == "2145")
            #expect(state.routeName == "IC8")
        }

        #expect(LiveActivityDebugPreview.state(for: .tightConnection, at: now).connectionStatus == .tight)
        #expect(LiveActivityDebugPreview.state(for: .missedConnection, at: now).connectionStatus == .missed)
    }

    @Test func canStartAndStopTheSeparateMockActivity() async throws {
        #expect(ActivityAuthorizationInfo().areActivitiesEnabled)
        try await LiveActivityDebugPreview.show(.readyToGo)
        #expect(LiveActivityDebugPreview.isRunning)
        await LiveActivityDebugPreview.stop()
    }
}
#endif
