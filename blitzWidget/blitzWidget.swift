import ActivityKit
import SwiftUI
import WidgetKit

private let liveActivityContentHorizontalInset: CGFloat = 10

@main
struct blitzWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainLiveActivityAttributes.self) { context in
            TrainLiveActivityView(context: context)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HeaderRegionContainer(alignment: .leading) {
                        TrainHeaderLeadingView(
                            logoName: context.attributes.operatorLogoName,
                            agencyId: context.attributes.agencyId,
                            trainNumber: context.attributes.trainNumber
                        )
                    }
                    .padding(.leading, liveActivityContentHorizontalInset)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    HeaderRegionContainer(alignment: .trailing) {
                        BlitzHeaderText()
                    }
                        .padding(.trailing, liveActivityContentHorizontalInset)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    TrainActivityExpandedBody(attributes: context.attributes, state: context.state)
                        .padding(.horizontal, liveActivityContentHorizontalInset)
                }
            } compactLeading: {
                CompactTrainNumberView(trainNumber: context.attributes.trainNumber)
            } compactTrailing: {
                CompactStatusView(state: context.state)
            } minimal: {
                Image(systemName: "tram.fill")
                    .foregroundStyle(context.state.isDelayed ? .orange : .green)
            }
            .keylineTint(context.state.isDelayed ? .orange : .green)
        }
        .supplementalActivityFamilies([.small, .medium])
    }
}

private struct TrainLiveActivityView: View {
    let context: ActivityViewContext<TrainLiveActivityAttributes>
    @Environment(\.activityFamily) private var activityFamily
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        switch activityFamily {
        case .small:
            wristBody
        default:
            iPhoneBody
        }
    }

    private var iPhoneBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                TrainHeaderLeadingView(
                    logoName: context.attributes.operatorLogoName,
                    agencyId: context.attributes.agencyId,
                    trainNumber: context.attributes.trainNumber
                )

                Spacer(minLength: 12)

                BlitzHeaderText()
            }
            .padding(.horizontal, liveActivityContentHorizontalInset)

            TrainActivityExpandedBody(attributes: context.attributes, state: context.state)
                .padding(.horizontal, liveActivityContentHorizontalInset)
        }
        .padding(.top, 12)
        .padding(.bottom, 15)
    }

    private var wristBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                OperatorLogoView(
                    logoName: context.attributes.operatorLogoName,
                    agencyId: context.attributes.agencyId,
                    size: 24
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(context.attributes.trainNumber)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text("BLITZ")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(context.state.platform ?? "")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isLuminanceReduced ? Color.primary : Color.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isLuminanceReduced ? Color.secondary.opacity(0.25) : Color.yellow, in: Capsule())
                    .opacity((context.state.platform?.isEmpty == false) ? 1 : 0)
            }

            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stationShorthand(context.attributes.originStationName))
                        .font(.system(size: 17, weight: .bold, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(context.state.departureTime, style: .time)
                        .font(.system(size: 15, weight: .semibold, design: .default).monospacedDigit())
                        .foregroundStyle(delayStatusColor(for: context.state.delayMinutes))
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(stationShorthand(context.attributes.destinationStationName))
                        .font(.system(size: 17, weight: .bold, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(context.state.arrivalTime, style: .time)
                        .font(.system(size: 15, weight: .semibold, design: .default).monospacedDigit())
                        .foregroundStyle(delayStatusColor(for: context.state.delayMinutes))
                }
            }

            HStack(spacing: 8) {
                Text(wristStatusText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(delayStatusColor(for: context.state.delayMinutes))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 0)

                Text(stationsLeftText(context.state.stationsRemaining))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, liveActivityContentHorizontalInset)
        .padding(.vertical, 10)
    }

    private var wristStatusText: String {
        if context.state.journeyPhase == .completed {
            return "Arrived"
        }
        if context.state.journeyPhase == .inTransit {
            return "On the way"
        }
        return delayStatusText(for: context.state.delayMinutes)
    }
}

private struct TrainHeaderLeadingView: View {
    let logoName: String?
    let agencyId: String?
    let trainNumber: String

    var body: some View {
        HStack(spacing: 2) {
            OperatorLogoView(logoName: logoName, agencyId: agencyId, size: 30)

            Text(trainNumber)
                .font(.system(size: 13, weight: .regular, design: .default))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private struct HeaderRegionContainer<Content: View>: View {
    let alignment: Alignment
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(height: 32, alignment: .center)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

private struct TrainActivityExpandedBody: View {
    let attributes: TrainLiveActivityAttributes
    let state: TrainLiveActivityAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: nextCountdownMinuteBoundary(to: state.departureTime), by: 60)) { timeline in
            let phase = effectivePhase(at: timeline.date)
            switch phase {
            case .preDeparture:
                PreDepartureBody(attributes: attributes, state: state)
            case .inTransit:
                InTransitBody(attributes: attributes, state: state)
            case .completed:
                CompletedBody(attributes: attributes, state: state)
            }
        }
    }

    private func effectivePhase(at date: Date) -> TrainLiveActivityAttributes.ContentState.JourneyPhase {
        if date >= state.arrivalTime {
            return .completed
        }

        if date >= state.departureTime {
            return .inTransit
        }

        return state.journeyPhase
    }
}

private struct PreDepartureBody: View {
    let attributes: TrainLiveActivityAttributes
    let state: TrainLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                StationTimeStatusView(
                    code: stationShorthand(attributes.originStationName),
                    time: state.departureTime,
                    status: delayStatusText(for: state.delayMinutes),
                    statusColor: delayStatusColor(for: state.delayMinutes),
                    order: .codeThenTime
                )

                Spacer(minLength: 4)

                Image(systemName: "train.side.front.car")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)

                Spacer(minLength: 4)

                StationTimeStatusView(
                    code: stationShorthand(attributes.destinationStationName),
                    time: state.arrivalTime,
                    status: delayStatusText(for: state.delayMinutes),
                    statusColor: delayStatusColor(for: state.delayMinutes),
                    order: .timeThenCode
                )
            }

            Divider()

            HStack(spacing: 10) {
                Text("Station Departure in \(Text(timerInterval: countdownInterval(to: state.departureTime), countsDown: true, showsHours: true))")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(delayStatusColor(for: state.delayMinutes))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                if let platformText {
                    Text("Plat. \(platformText)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.yellow, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
        }
    }

    private var platformText: String? {
        guard let platform = state.platform?.trimmingCharacters(in: .whitespacesAndNewlines), !platform.isEmpty else {
            return nil
        }
        return platform
    }
}

private struct InTransitBody: View {
    let attributes: TrainLiveActivityAttributes
    let state: TrainLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                StationTimeStatusView(
                    code: stationShorthand(attributes.originStationName),
                    time: state.departureTime,
                    status: "Departed",
                    statusColor: .secondary,
                    order: .codeThenTime
                )

                Spacer(minLength: 4)

                Image(systemName: "train.side.front.car")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)

                Spacer(minLength: 4)

                StationTimeStatusView(
                    code: stationShorthand(attributes.destinationStationName),
                    time: state.arrivalTime,
                    status: delayStatusText(for: state.delayMinutes),
                    statusColor: delayStatusColor(for: state.delayMinutes),
                    order: .timeThenCode
                )
            }

            JourneyProgressBar(
                startDate: state.departureTime,
                endDate: state.arrivalTime,
                fillColor: delayStatusColor(for: state.delayMinutes)
            )

            HStack(spacing: 10) {
                Text("Time left: \(Text(timerInterval: countdownInterval(to: state.arrivalTime), countsDown: true, showsHours: true))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text(stationsLeftText(state.stationsRemaining))
                    .lineLimit(1)
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
        }
    }
}

private struct JourneyProgressBar: View {
    let startDate: Date
    let endDate: Date
    let fillColor: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            GeometryReader { proxy in
                let progress = journeyProgress(at: timeline.date)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(fillColor)
                        .frame(width: proxy.size.width * progress)
                }
            }
        }
        .frame(height: 6)
    }

    private func journeyProgress(at date: Date) -> CGFloat {
        let total = endDate.timeIntervalSince(startDate)
        guard total > 0 else { return 1 }
        let elapsed = date.timeIntervalSince(startDate)
        return CGFloat(min(max(elapsed / total, 0), 1))
    }
}

private struct CompletedBody: View {
    let attributes: TrainLiveActivityAttributes
    let state: TrainLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Arrived")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.green)

            HStack(spacing: 4) {
                Text(attributes.destinationStationName)
                Text("at")
                Text(state.arrivalTime, style: .time)
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
        }
    }
}

private struct BlitzHeaderText: View {
    var body: some View {
        Text("BLITZ")
            .font(.system(size: 13, weight: .regular, design: .default))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }
}

private enum StationTimeOrder {
    case codeThenTime
    case timeThenCode
}

private struct StationTimeStatusView: View {
    let code: String
    let time: Date
    let status: String
    let statusColor: Color
    let order: StationTimeOrder

    var body: some View {
        VStack(alignment: order == .codeThenTime ? .leading : .trailing, spacing: 3) {
            HStack(spacing: 5) {
                if order == .codeThenTime {
                    stationCode
                    timeText
                } else {
                    timeText
                    stationCode
                }
            }

            Text(status)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: order == .codeThenTime ? .leading : .trailing)
    }

    private var stationCode: some View {
        Text(code)
            .font(.system(size: 21, weight: .bold, design: .default))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
    }

    private var timeText: some View {
        Text(time, style: .time)
            .font(.system(size: 21, weight: .semibold, design: .default).monospacedDigit())
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

private struct HeaderTimeView: View {
    let state: TrainLiveActivityAttributes.ContentState

    var body: some View {
        switch state.journeyPhase {
        case .preDeparture:
            HStack(spacing: 4) {
                if state.isDelayed {
                    Text(state.departureTime.addingTimeInterval(TimeInterval(-state.delayMinutes * 60)), style: .time)
                        .strikethrough()
                        .foregroundStyle(.red)
                }
                Text(state.departureTime, style: .time)
            }
            .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
        case .inTransit:
            IslandStatusText(state: state)
        case .completed:
            Text(state.arrivalTime, style: .time)
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }
}

private struct IslandStatusText: View {
    let state: TrainLiveActivityAttributes.ContentState

    var body: some View {
        Text(state.isDelayed ? "Delayed" : "On Schedule")
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(state.isDelayed ? .orange : .secondary)
    }
}

private struct CompactTrainNumberView: View {
    let trainNumber: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "tram.fill")
                .font(.caption2.weight(.semibold))

            Text(trainNumber)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct CompactStatusView: View {
    let state: TrainLiveActivityAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: nextCountdownMinuteBoundary(to: state.departureTime), by: 60)) { timeline in
            let phase = effectivePhase(at: timeline.date)
            switch phase {
            case .preDeparture:
                if let platform = state.platform, !platform.isEmpty {
                    Text("P\(platform)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.yellow)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text(timerInterval: countdownInterval(to: state.departureTime), countsDown: true, showsHours: true)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(width: 42, alignment: .trailing)
                        .clipped()
                        .contentTransition(.numericText())
                }
            case .inTransit:
                Text(timerInterval: countdownInterval(to: state.arrivalTime), countsDown: true, showsHours: true)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(width: 52, alignment: .trailing)
                    .clipped()
                    .contentTransition(.numericText())
            case .completed:
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
    }

    private func effectivePhase(at date: Date) -> TrainLiveActivityAttributes.ContentState.JourneyPhase {
        if date >= state.arrivalTime { return .completed }
        if date >= state.departureTime { return .inTransit }
        return state.journeyPhase
    }
}

private struct OperatorLogoView: View {
    let logoName: String?
    let agencyId: String?
    var size: CGFloat = 32

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(7, size * 0.22), style: .continuous)
        let fallback = AgencyBadgeStyle.entry(for: agencyId)

        Group {
            if let logoName, UIImage(named: logoName) != nil {
                Image(logoName)
                    .resizable()
                    .scaledToFit()
                    .clipShape(shape)
            } else {
                ZStack {
                    shape.fill(fallback.background)
                    if let symbol = fallback.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: size * 0.45, weight: .semibold))
                            .foregroundStyle(fallback.foreground)
                    } else if let initials = fallback.initials {
                        Text(initials)
                            .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                            .foregroundStyle(fallback.foreground)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

private enum AgencyBadgeStyle {
    struct Entry {
        let background: Color
        let foreground: Color
        let symbol: String?
        let initials: String?
    }

    static func entry(for agencyId: String?) -> Entry {
        registry[agencyId ?? ""] ?? defaultEntry
    }

    private static let defaultEntry = Entry(
        background: Color.gray.opacity(0.18),
        foreground: .primary,
        symbol: "tram.fill",
        initials: nil
    )

    private static let registry: [String: Entry] = [
        "6100826": Entry(background: Color.blue.opacity(0.8), foreground: .white, symbol: "tram.fill", initials: nil),
        "237330": Entry(background: Color.purple.opacity(0.8), foreground: .white, symbol: "sparkles", initials: nil),
        "906090": Entry(background: Color.green.opacity(0.8), foreground: .white, symbol: "leaf.fill", initials: nil),
        "236037": Entry(background: Color.orange.opacity(0.8), foreground: .white, symbol: "bus.fill", initials: nil),
        "227098": Entry(background: Color.teal.opacity(0.8), foreground: .white, symbol: "bolt.fill", initials: nil),
        "236025": Entry(background: Color.indigo.opacity(0.8), foreground: .white, symbol: "waveform", initials: nil),
        "228389": Entry(background: Color.pink.opacity(0.8), foreground: .white, symbol: "hexagon.fill", initials: nil)
    ]
}

private func nextCountdownMinuteBoundary(to targetDate: Date, referenceDate: Date = Date()) -> Date {
    let remaining = max(0, targetDate.timeIntervalSince(referenceDate))
    let secondsUntilMinuteDrops = remaining.truncatingRemainder(dividingBy: 60)
    let offset = secondsUntilMinuteDrops == 0 ? 60 : secondsUntilMinuteDrops
    return referenceDate.addingTimeInterval(offset + 0.1)
}

private func countdownInterval(to targetDate: Date) -> ClosedRange<Date> {
    let now = Date()
    guard now < targetDate else {
        return targetDate...targetDate
    }
    return now...targetDate
}

private func delayStatusText(for minutes: Int) -> String {
    if minutes > 0 { return "\(minutes)m late" }
    if minutes < 0 { return "\(abs(minutes))m early" }
    return "On time"
}

private func delayStatusColor(for minutes: Int) -> Color {
    minutes > 0 ? .red : .green
}

private func stationsLeftText(_ count: Int) -> String {
    let safeCount = max(0, count)
    return safeCount == 1 ? "1 station left" : "\(safeCount) stations left"
}

private func stationShorthand(_ stationName: String) -> String {
    let cleanedName = stationName
        .filter { $0.isLetter || $0.isNumber }
        .uppercased()
    if !cleanedName.isEmpty {
        return String(cleanedName.prefix(3))
    }
    return "STN"
}
