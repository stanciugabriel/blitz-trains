import ActivityKit
import SwiftUI
import WidgetKit

private let liveActivityContentHorizontalInset: CGFloat = 10
private let swissTimeZone = TimeZone(identifier: "Europe/Zurich")!

private func displayedTrainNumber(
    _ state: TrainLiveActivityAttributes.ContentState,
    attributes: TrainLiveActivityAttributes, at date: Date
) -> String {
    if state.showingNextLeg(at: date), let next = state.connection { return next.nextTrainNumber }
    return state.trainNumber ?? attributes.trainNumber
}

private func preDepartureServiceLabel(
    _ state: TrainLiveActivityAttributes.ContentState,
    attributes: TrainLiveActivityAttributes
) -> String {
    guard let number = state.serviceNumber, !number.isEmpty else {
        return state.trainNumber ?? attributes.trainNumber
    }
    let category = state.routeName.map { String($0.prefix(while: { $0.isLetter })) } ?? ""
    return category.isEmpty ? number : "\(category) \(number)"
}

private func displayedLogoName(
    _ state: TrainLiveActivityAttributes.ContentState,
    attributes: TrainLiveActivityAttributes, at date: Date
) -> String? {
    if state.showingNextLeg(at: date), let next = state.connection { return next.nextOperatorLogoName }
    return state.operatorLogoName ?? attributes.operatorLogoName
}

private func displayedAgencyID(
    _ state: TrainLiveActivityAttributes.ContentState,
    attributes: TrainLiveActivityAttributes, at date: Date
) -> String? {
    if state.showingNextLeg(at: date), let next = state.connection { return next.nextAgencyId }
    return state.agencyId ?? attributes.agencyId
}

@main
struct blitzWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainLiveActivityAttributes.self) { context in
            TrainLiveActivityView(context: context)
                .environment(\.timeZone, swissTimeZone)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        if context.state.effectivePhase(at: timeline.date) == .preDeparture {
                            HStack(spacing: 5) {
                                OperatorLogoView(
                                    logoName: displayedLogoName(context.state, attributes: context.attributes, at: timeline.date),
                                    agencyId: displayedAgencyID(context.state, attributes: context.attributes, at: timeline.date),
                                    size: 23
                                )
                                Text(preDepartureServiceLabel(context.state, attributes: context.attributes))
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .lineLimit(1)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        } else {
                            HeaderRegionContainer(alignment: .leading) {
                                TrainHeaderLeadingView(
                                    logoName: displayedLogoName(context.state, attributes: context.attributes, at: timeline.date),
                                    agencyId: displayedAgencyID(context.state, attributes: context.attributes, at: timeline.date),
                                    trainNumber: displayedTrainNumber(context.state, attributes: context.attributes, at: timeline.date)
                                )
                            }
                        }
                    }
                }
                .contentMargins(.leading, 14)

                DynamicIslandExpandedRegion(.trailing) {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        if context.state.effectivePhase(at: timeline.date) == .preDeparture {
                            EmptyView()
                        } else {
                            HeaderRegionContainer(alignment: .trailing) {
                                if let connection = context.state.connection,
                                   [.prepareToChange, .connection].contains(context.state.effectivePhase(at: timeline.date)) {
                                    TrainHeaderLeadingView(
                                        logoName: connection.nextOperatorLogoName,
                                        agencyId: connection.nextAgencyId,
                                        trainNumber: connection.nextTrainNumber
                                    )
                                }
                            }
                        }
                    }
                }
                .contentMargins(.trailing, 14)

                DynamicIslandExpandedRegion(.bottom) {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        if context.state.effectivePhase(at: timeline.date) == .preDeparture {
                            PreDepartureContent(attributes: context.attributes, state: context.state)
                        } else {
                            TrainActivityExpandedBody(attributes: context.attributes, state: context.state)
                                .environment(\.timeZone, swissTimeZone)
                        }
                    }
                }
                .contentMargins(.horizontal, 14)
                .contentMargins(.bottom, 0)
            } compactLeading: {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    CompactTrainNumberView(
                        trainNumber: displayedTrainNumber(context.state, attributes: context.attributes, at: timeline.date),
                        logoName: displayedLogoName(context.state, attributes: context.attributes, at: timeline.date),
                        agencyId: displayedAgencyID(context.state, attributes: context.attributes, at: timeline.date)
                    )
                }
            } compactTrailing: {
                CompactStatusView(state: context.state)
                    .environment(\.timeZone, swissTimeZone)
            } minimal: {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    if context.state.effectivePhase(at: timeline.date) == .preDeparture {
                        MinimalDepartureMinutesView(departureTime: context.state.departureTime)
                    } else {
                        OperatorLogoView(
                            logoName: displayedLogoName(context.state, attributes: context.attributes, at: timeline.date),
                            agencyId: displayedAgencyID(context.state, attributes: context.attributes, at: timeline.date),
                            size: 18
                        )
                    }
                }
            }
            .keylineTint(activityTint(for: context.state))
        }
        .supplementalActivityFamilies([.small, .medium])
    }
}

private struct DepartureCountdownView: View {
    let departureTime: Date
    let showsSeconds: Bool

    var body: some View {
        let full = Text(TimeDataSource<Range<Date>>.dateRange(endingAt: departureTime),
                        format: .components(style: .narrow, fields: [.minute, .second]))
        let minutes = Text(TimeDataSource<Range<Date>>.dateRange(endingAt: departureTime),
                           format: .components(style: .narrow, fields: [.minute]))
        Text(showsSeconds ? "Departs in \(full)" : "Departs in \(minutes)")
        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .contentTransition(.numericText())
    }
}

private struct MinimalDepartureMinutesView: View {
    let departureTime: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let minutesLeft = max(0, Int(ceil(departureTime.timeIntervalSince(timeline.date) / 60)))
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(minutesLeft)")
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                Text("m")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .baselineOffset(5)
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(minutesLeft) minutes until departure")
        }
    }
}

private struct PreDepartureContent: View {
    let attributes: TrainLiveActivityAttributes
    let state: TrainLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(routeText)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let platform = state.platform, !platform.isEmpty {
                    Text("P\(platform)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.yellow, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            ViewThatFits(in: .horizontal) {
                detailsRow(showsSeconds: true)
                detailsRow(showsSeconds: false)
            }
        }
    }

    private func detailsRow(showsSeconds: Bool) -> some View {
        HStack(spacing: 8) {
            DepartureCountdownView(departureTime: state.departureTime, showsSeconds: showsSeconds)
                .fixedSize(horizontal: showsSeconds, vertical: false)
                .layoutPriority(1)
            if let seatSummary {
                Spacer(minLength: 4)
                Text(seatSummary)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var routeText: String {
        let route = state.routeName ?? state.trainNumber ?? attributes.trainNumber
        guard let headsign = state.headsign, !headsign.isEmpty else { return route }
        return "\(route) to \(headsign)"
    }

    private var seatSummary: String? {
        guard let rawCars = state.coach?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawCars.isEmpty else { return nil }
        let cars = rawCars
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .components(separatedBy: CharacterSet(charactersIn: ",;/&+"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cars.isEmpty else { return nil }
        if cars.count > 1 { return "Cars \(cars.joined(separator: ", "))" }

        let car = "Car \(cars[0])"
        let seats = (state.seats ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !seats.isEmpty, seats.count < 3 else { return car }
        return "\(car) • \(seats.count == 1 ? "Seat" : "Seats") \(seats.joined(separator: ", "))"
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
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                HStack(alignment: .center, spacing: 10) {
                    TrainHeaderLeadingView(
                        logoName: displayedLogoName(context.state, attributes: context.attributes, at: timeline.date),
                        agencyId: displayedAgencyID(context.state, attributes: context.attributes, at: timeline.date),
                        trainNumber: displayedTrainNumber(context.state, attributes: context.attributes, at: timeline.date)
                    )

                    Spacer(minLength: 12)

                    if let headsign = context.state.headsign, !context.state.showingNextLeg(at: timeline.date) {
                        Text("to \(headsign)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .padding(.horizontal, liveActivityContentHorizontalInset)
            }

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
                    logoName: wristConnection?.nextOperatorLogoName ?? context.state.operatorLogoName ?? context.attributes.operatorLogoName,
                    agencyId: wristConnection?.nextAgencyId ?? context.state.agencyId ?? context.attributes.agencyId,
                    size: 24
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(wristConnection?.nextTrainNumber ?? context.state.trainNumber ?? context.attributes.trainNumber)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(context.state.headsign.map { "to \($0)" } ?? "Journey")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(wristPlatform ?? "")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isLuminanceReduced ? Color.primary : Color.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isLuminanceReduced ? Color.secondary.opacity(0.25) : Color.yellow, in: Capsule())
                    .opacity(wristPlatform != nil ? 1 : 0)
            }

            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                Text(stationShorthand(wristConnection?.stationName ?? context.state.originName ?? context.attributes.originStationName))
                        .font(.system(size: 17, weight: .bold, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(wristConnection?.departureTime ?? context.state.departureTime, style: .time)
                        .font(.system(size: 15, weight: .semibold, design: .default).monospacedDigit())
                        .foregroundStyle(delayStatusColor(for: context.state.delayMinutes))
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 2) {
                Text(stationShorthand(wristConnection?.nextDestinationName ?? context.state.destinationName ?? context.attributes.destinationStationName))
                        .font(.system(size: 17, weight: .bold, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(wristConnection?.nextArrivalTime ?? context.state.arrivalTime, style: .time)
                        .font(.system(size: 15, weight: .semibold, design: .default).monospacedDigit())
                        .foregroundStyle(delayStatusColor(for: context.state.delayMinutes))
                }
            }

            HStack(spacing: 8) {
                Text(wristStatusText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(activityTint(for: context.state))
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
        if let attention = context.state.activeAttention(at: Date()) { return attention.message }
        switch context.state.effectivePhase(at: Date()) {
        case .preDeparture: return "Ready to go"
        case .boarding: return "Head to your train"
        case .inTransit: return context.state.showingNextLeg(at: Date()) ? "Arrival ahead" :
            (context.state.boardingConfirmed == true ? "On the train" : "Arrival ahead")
        case .prepareToChange: return "Prepare to change"
        case .prepareToArrive: return "Get ready to leave"
        case .connection: return "Make your connection"
        case .completed: return "Arrived"
        }
    }

    private var wristPlatform: String? {
        let value = [.prepareToChange, .connection].contains(context.state.effectivePhase(at: Date()))
            ? context.state.connection?.toPlatform : context.state.platform
        return value?.isEmpty == false ? value : nil
    }

    private var wristConnection: TrainLiveActivityAttributes.ContentState.Connection? {
        ([.prepareToChange, .connection].contains(context.state.effectivePhase(at: Date())) ||
         context.state.showingNextLeg(at: Date()))
            ? context.state.connection : nil
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
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let phase = state.effectivePhase(at: timeline.date)
            VStack(alignment: .leading, spacing: 8) {
                if let attention = state.activeAttention(at: timeline.date) {
                    HStack(spacing: 7) {
                        Image(systemName: attention.kind == .missedConnection ? "exclamationmark.triangle.fill" : "bell.badge.fill")
                        Text(attention.message)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(attention.kind == .missedConnection ? .red : .orange)
                    if let old = attention.previousPlatform, let new = attention.newPlatform {
                        Text("Platform \(old) → \(new)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                }
                phaseBody(phase, at: timeline.date)
            }
        }
    }

    @ViewBuilder
    private func phaseBody(_ phase: TrainLiveActivityAttributes.ContentState.JourneyPhase, at date: Date) -> some View {
        let nextLeg = state.showingNextLeg(at: date) ? state.connection : nil
        let arrival = nextLeg?.nextArrivalTime ?? state.arrivalTime
        let destination = nextLeg?.nextDestinationName ?? state.destinationName ?? attributes.destinationStationName
        switch phase {
        case .preDeparture:
            title(state.headsign.map { "\(state.trainNumber ?? attributes.trainNumber) to \($0)" }
                ?? "Your \(state.trainNumber ?? attributes.trainNumber) departs soon")
            HStack {
                Text("Departs")
                Text(state.departureTime, style: .time).fontWeight(.bold)
                Spacer()
                platformLabel(state.platform)
            }
            .font(.system(size: 14, design: .rounded))
            delayAndFreshness
        case .boarding:
            title(state.platform.map { "Go to platform \($0)" } ?? "Find your train")
            HStack {
                Text("Departs")
                Text(state.departureTime, style: .time).fontWeight(.bold)
                Spacer()
                seatLabel
            }
            .font(.system(size: 14, design: .rounded))
            if let headsign = state.headsign {
                Text("Towards \(headsign)")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        case .inTransit:
            if nextLeg == nil, state.boardingConfirmed != true && date < state.departureTime {
                title(state.platform.map { "Board now · Platform \($0)" } ?? "Board your train now")
            } else if let nextLeg {
                title("\(nextLeg.nextTrainNumber) reaches \(destination)")
            } else if state.boardingConfirmed == true {
                title("Arrive in \(destination)")
            } else {
                title("Train reaches \(destination)")
            }
            HStack(spacing: 6) {
                Text(arrival, style: .time).fontWeight(.bold)
                Text("·")
                Text(timerInterval: countdownInterval(to: arrival), countsDown: true, showsHours: true)
                Text("left")
                Spacer(minLength: 0)
            }
            .font(.system(size: 15, design: .rounded).monospacedDigit())
            if nextLeg == nil { delayAndFreshness }
        case .prepareToChange:
            if let connection = state.connection {
                title("Change at \(connection.stationName)")
                HStack(spacing: 6) {
                    Text("Next \(connection.nextTrainNumber)")
                    if let platform = connection.toPlatform { Text("· Platform \(platform)") }
                    Spacer(minLength: 0)
                    Text(connection.departureTime, style: .time)
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                connectionOutlook
            }
        case .prepareToArrive:
            title(nextLeg != nil || state.boardingConfirmed != true
                ? "Train arriving soon" : "Get ready to leave")
            HStack(spacing: 6) {
                Text(destination)
                Text("in")
                Text(timerInterval: countdownInterval(to: arrival), countsDown: true, showsHours: true)
                Spacer(minLength: 0)
                Text(arrival, style: .time)
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
        case .connection:
            if let connection = state.connection {
                if let from = connection.fromPlatform, let to = connection.toPlatform {
                    title(from == to ? "Stay on platform \(to)" : "Go from platform \(from) to \(to)")
                } else if let to = connection.toPlatform {
                    title("Go to platform \(to)")
                } else {
                    title("Find \(connection.nextTrainNumber) on the board")
                }
                HStack(spacing: 6) {
                    Text("Next \(connection.nextTrainNumber)")
                    Text("·")
                    Text(connection.departureTime, style: .time)
                    Spacer(minLength: 0)
                    if date >= connection.departureTime {
                        Text("Departed")
                    } else {
                        Text(timerInterval: countdownInterval(to: connection.departureTime), countsDown: true, showsHours: true)
                        Text("left")
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                connectionOutlook
            }
        case .completed:
            title(nextLeg == nil && state.arrivalConfirmed == true
                ? "You've arrived in \(destination)" : "Train arrived in \(destination)")
            Text(arrival, style: .time)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private func title(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private func platformLabel(_ value: String?) -> some View {
        if let value, !value.isEmpty {
            Text("Platform \(value)")
                .fontWeight(.bold)
                .foregroundStyle(.yellow)
        }
    }

    @ViewBuilder
    private var seatLabel: some View {
        if let coach = state.coach, !coach.isEmpty, let seats = state.seats, !seats.isEmpty {
            Text("Car \(coach) · Seat \(seats)")
                .fontWeight(.semibold)
        } else if let coach = state.coach, !coach.isEmpty {
            Text("Car \(coach)").fontWeight(.semibold)
        } else if let seats = state.seats, !seats.isEmpty {
            Text("Seat \(seats)").fontWeight(.semibold)
        }
    }

    @ViewBuilder
    private var delayAndFreshness: some View {
        if state.delayMinutes != 0 {
            Text(delayStatusText(for: state.delayMinutes))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(delayStatusColor(for: state.delayMinutes))
        }
        if let updated = state.liveUpdatedAt, Date().timeIntervalSince(updated) > 5 * 60 {
            Text("Last live update over 5 min ago · Check station signs")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var connectionOutlook: some View {
        switch state.connectionStatus {
        case .onTrack: Text("Connection on track").foregroundStyle(.green)
        case .tight: Text("Connection is tight").foregroundStyle(.orange)
        case .missed: Text("Connection likely missed").foregroundStyle(.red)
        case .unknown: Text("Check station signs for updates").foregroundStyle(.secondary)
        }
    }
}

private struct CompactTrainNumberView: View {
    let trainNumber: String
    let logoName: String?
    let agencyId: String?

    var body: some View {
        HStack(spacing: 3) {
            OperatorLogoView(logoName: logoName, agencyId: agencyId, size: 16)

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
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let phase = state.effectivePhase(at: timeline.date)
            let attention = state.activeAttention(at: timeline.date)
            if let attention, attention.kind == .platformChange, let platform = attention.newPlatform {
                Text("P\(platform)!")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
            } else if let attention, attention.kind == .missedConnection {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
            switch phase {
            case .preDeparture:
                Text(state.departureTime, style: .time)
                    .font(.caption2.weight(.semibold).monospacedDigit())
            case .boarding:
                if let platform = state.platform, !platform.isEmpty {
                    Text("P\(platform)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.yellow)
                } else {
                    Text(state.departureTime, style: .time)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                }
            case .inTransit, .prepareToArrive:
                if phase == .inTransit, !state.showingNextLeg(at: timeline.date), state.boardingConfirmed != true,
                   timeline.date < state.departureTime, let platform = state.platform {
                    Text("P\(platform)!")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.yellow)
                } else {
                    Text(timerInterval: countdownInterval(to: state.showingNextLeg(at: timeline.date)
                        ? (state.connection?.nextArrivalTime ?? state.arrivalTime) : state.arrivalTime),
                        countsDown: true, showsHours: true)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(width: 52, alignment: .trailing)
                        .clipped()
                        .contentTransition(.numericText())
                }
            case .prepareToChange, .connection:
                if let to = state.connection?.toPlatform {
                    Text("P\(to)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(activityTint(for: state))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text("Change")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(activityTint(for: state))
                }
            case .completed:
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
            }
        }
    }
}

private func activityTint(for state: TrainLiveActivityAttributes.ContentState) -> Color {
    if let attention = state.activeAttention(at: Date()) {
        return attention.kind == .missedConnection ? .red : .orange
    }
    if [.prepareToChange, .connection].contains(state.effectivePhase(at: Date())) {
        switch state.connectionStatus {
        case .onTrack: return .green
        case .tight: return .orange
        case .missed: return .red
        case .unknown: return .yellow
        }
    }
    return state.isDelayed ? .orange : .green
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
        "11": Entry(background: .red, foreground: .white, symbol: nil, initials: "SBB"),
        "351": Entry(background: .red, foreground: .white, symbol: nil, initials: "SBB"),
        "L7____": Entry(background: .red, foreground: .white, symbol: nil, initials: "SBB"),
        "33": Entry(background: .blue, foreground: .white, symbol: nil, initials: "BLS"),
        "65": Entry(background: .green, foreground: .white, symbol: nil, initials: "TH"),
        "23": Entry(background: .blue, foreground: .white, symbol: nil, initials: "TPC"),
        "32": Entry(background: .orange, foreground: .white, symbol: nil, initials: "JB"),
        "35": Entry(background: .orange, foreground: .white, symbol: nil, initials: "JB"),
        "157": Entry(background: .orange, foreground: .white, symbol: nil, initials: "JB"),
        "124": Entry(background: .orange, foreground: .white, symbol: nil, initials: "JB"),
        "78": Entry(background: .blue, foreground: .white, symbol: nil, initials: "SZU"),
        "72": Entry(background: .red, foreground: .white, symbol: nil, initials: "RhB"),
        "97": Entry(background: .blue, foreground: .white, symbol: nil, initials: "TR"),
        "96": Entry(background: .red, foreground: .white, symbol: nil, initials: "AVA"),
        "31": Entry(background: .red, foreground: .white, symbol: nil, initials: "AVA"),
        "82": Entry(background: .red, foreground: .white, symbol: nil, initials: "SOB")
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
