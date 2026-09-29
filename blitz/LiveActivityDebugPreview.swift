#if DEBUG
import ActivityKit
import SwiftUI

@MainActor
enum LiveActivityDebugPreview {
    enum Phase: String, CaseIterable, Identifiable {
        case readyToGo
        case headToTrain
        case onTrain
        case prepareToChange
        case prepareToArrive
        case makeConnection
        case arrived
        case platformChanged
        case tightConnection
        case missedConnection

        var id: String { rawValue }

        var title: String {
            switch self {
            case .readyToGo: "Ready to go"
            case .headToTrain: "Head to your train"
            case .onTrain: "On the train"
            case .prepareToChange: "Prepare to change"
            case .prepareToArrive: "Prepare to arrive"
            case .makeConnection: "Make the connection"
            case .arrived: "Arrived"
            case .platformChanged: "Platform changed"
            case .tightConnection: "Tight connection"
            case .missedConnection: "Missed connection"
            }
        }

        var next: Phase {
            let phases = Self.allCases
            guard let index = phases.firstIndex(of: self) else { return .readyToGo }
            return phases[(index + 1) % phases.count]
        }
    }

    private static let tripID = "blitz-debug-live-activity-preview"
    typealias State = TrainLiveActivityAttributes.ContentState

    private static var activity: Activity<TrainLiveActivityAttributes>? {
        Activity<TrainLiveActivityAttributes>.activities.first { $0.attributes.tripID == tripID }
    }

    static var isRunning: Bool { activity != nil }

    static var diagnosticSummary: String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return "Live Activities are disabled for Blitz in iOS Settings."
        }
        guard let activity else {
            return "No mock activity registered."
        }
        return "Mock \(String(describing: activity.activityState)) · ID \(activity.id.prefix(8))"
    }

    static var currentPhase: Phase? {
        guard let state = activity?.content.state else { return nil }
        switch state.attention?.kind {
        case .platformChange: return .platformChanged
        case .tightConnection: return .tightConnection
        case .missedConnection: return .missedConnection
        default: break
        }
        switch state.journeyPhase {
        case .preDeparture: return .readyToGo
        case .boarding: return .headToTrain
        case .inTransit: return .onTrain
        case .prepareToChange: return .prepareToChange
        case .prepareToArrive: return .prepareToArrive
        case .connection: return .makeConnection
        case .completed: return .arrived
        }
    }

    static func show(_ phase: Phase) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw PreviewError.activitiesDisabled
        }
        let now = Date()
        let content = ActivityContent(
            state: state(for: phase, at: now),
            staleDate: now.addingTimeInterval(2 * 60 * 60),
            relevanceScore: 100
        )
        if let activity {
            await activity.update(content)
        } else {
            let attributes = TrainLiveActivityAttributes(
                tripID: tripID,
                trainNumber: "IC82145",
                operatorName: "SBB",
                originStationCode: "ZUE",
                originStationName: "Zürich HB",
                destinationStationCode: "BERN",
                destinationStationName: "Bern",
                coachAndSeat: "Car 6 • Seat 7",
                agencyId: "11",
                operatorLogoName: "sbb"
            )
            _ = try Activity.request(attributes: attributes, content: content)
        }
    }

    static func stop() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    static func state(for phase: Phase, at now: Date) -> State {
        func minutes(_ value: Double) -> Date { now.addingTimeInterval(value * 60) }

        var departure = minutes(25)
        var arrival = minutes(88)
        var journeyPhase: State.JourneyPhase = .preDeparture
        var boardingConfirmed = false
        var arrivalConfirmed = false
        var connection: State.Connection?
        var platform = "7"
        var attention: State.Attention?

        func sampleConnection(departure nextDeparture: Double) -> State.Connection {
            State.Connection(
                stationName: "Bern",
                nextTrainNumber: "IC6 971",
                nextOperatorLogoName: "sbb",
                nextAgencyId: "11",
                nextDestinationName: "Basel SBB",
                nextArrivalTime: minutes(80),
                departureTime: minutes(nextDeparture),
                displayUntil: minutes(30),
                fromPlatform: "7",
                toPlatform: "10",
                minimumTransferSeconds: 6 * 60,
                hasFreshTiming: true,
                nextPlatformIsLive: true
            )
        }

        switch phase {
        case .readyToGo:
            break
        case .headToTrain, .platformChanged:
            departure = minutes(8)
            arrival = minutes(71)
            journeyPhase = .boarding
            if phase == .platformChanged {
                platform = "8"
                attention = State.Attention(
                    kind: .platformChange, message: "Platform changed to 8",
                    previousPlatform: "7", newPlatform: "8", expiresAt: minutes(10)
                )
            }
        case .onTrain:
            departure = minutes(-20)
            arrival = minutes(38)
            journeyPhase = .inTransit
            boardingConfirmed = true
        case .prepareToChange:
            departure = minutes(-48)
            arrival = minutes(12)
            journeyPhase = .prepareToChange
            boardingConfirmed = true
            connection = sampleConnection(departure: 24)
        case .prepareToArrive:
            departure = minutes(-52)
            arrival = minutes(8)
            journeyPhase = .prepareToArrive
            boardingConfirmed = true
        case .makeConnection, .tightConnection:
            departure = minutes(-65)
            arrival = minutes(-2)
            journeyPhase = .connection
            boardingConfirmed = true
            arrivalConfirmed = true
            connection = sampleConnection(departure: phase == .tightConnection ? 2 : 15)
            if phase == .tightConnection {
                attention = State.Attention(
                    kind: .tightConnection,
                    message: "Connection is tight — head to platform 10",
                    previousPlatform: nil, expiresAt: minutes(10)
                )
            }
        case .arrived:
            departure = minutes(-75)
            arrival = minutes(-3)
            journeyPhase = .completed
            boardingConfirmed = true
            arrivalConfirmed = true
        case .missedConnection:
            departure = minutes(-60)
            arrival = minutes(3)
            journeyPhase = .prepareToChange
            boardingConfirmed = true
            connection = sampleConnection(departure: 2)
            attention = State.Attention(
                kind: .missedConnection, message: "Connection likely missed",
                previousPlatform: nil, expiresAt: minutes(10)
            )
        }

        var state = State(
            journeyPhase: journeyPhase,
            platform: platform,
            departureTime: departure,
            arrivalTime: arrival,
            nextStopName: "Olten",
            nextStopArrivalTime: minutes(19),
            stationsRemaining: 2,
            isDelayed: false,
            dataTimestamp: now,
            delayMinutes: 0,
            coach: "6",
            seats: "7",
            connection: connection
        )
        state.trainNumber = "IC82145"
        state.serviceNumber = "2145"
        state.routeName = "IC8"
        state.operatorLogoName = "sbb"
        state.agencyId = "11"
        state.originName = "Zürich HB"
        state.destinationName = "Bern"
        state.headsign = "Brig"
        state.boardingConfirmed = boardingConfirmed
        state.arrivalConfirmed = arrivalConfirmed
        state.liveUpdatedAt = now
        state.platformIsLive = true
        state.attention = attention
        return state
    }

    private enum PreviewError: LocalizedError {
        case activitiesDisabled

        var errorDescription: String? {
            "Live Activities are disabled for Blitz in iOS Settings."
        }
    }
}

struct LiveActivityPreviewControls: View {
    @State private var phase: LiveActivityDebugPreview.Phase = .readyToGo
    @State private var isRunning = false
    @State private var isUpdating = false
    @State private var status = "No preview running"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Dynamic Island preview", systemImage: "rectangle.on.rectangle.angled")
                .font(.headline)

            Picker("Phase", selection: $phase) {
                ForEach(LiveActivityDebugPreview.Phase.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 10) {
                Button(isRunning ? "Apply phase" : "Start preview") {
                    apply(phase)
                }
                .buttonStyle(.borderedProminent)

                Button("Next phase") {
                    apply(phase.next)
                }
                .buttonStyle(.bordered)
                .disabled(!isRunning)
            }
            .disabled(isUpdating)

            if isRunning {
                Button("Stop preview", role: .destructive) {
                    isUpdating = true
                    Task {
                        await LiveActivityDebugPreview.stop()
                        isRunning = false
                        isUpdating = false
                        status = "Preview stopped"
                    }
                }
                .disabled(isUpdating)
            }

            Text(status)
                .font(.caption)
                .foregroundStyle(status.hasPrefix("Could not") ? .red : .secondary)
                .textSelection(.enabled)
            Button("Check ActivityKit status") {
                isRunning = LiveActivityDebugPreview.isRunning
                status = LiveActivityDebugPreview.diagnosticSummary
            }
            .font(.caption)
            Text("Touch and hold the Island to open the expanded view. This sample never changes saved trips.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .onAppear {
            isRunning = LiveActivityDebugPreview.isRunning
            if let current = LiveActivityDebugPreview.currentPhase { phase = current }
            status = LiveActivityDebugPreview.diagnosticSummary
        }
    }

    private func apply(_ selected: LiveActivityDebugPreview.Phase) {
        guard !isUpdating else { return }
        phase = selected
        isUpdating = true
        Task {
            do {
                try await LiveActivityDebugPreview.show(selected)
                isRunning = LiveActivityDebugPreview.isRunning
                status = "\(selected.title): \(LiveActivityDebugPreview.diagnosticSummary)"
            } catch {
                status = "Could not start preview: \(error.localizedDescription)"
            }
            isUpdating = false
        }
    }
}
#endif
