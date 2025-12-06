import SwiftUI
import CoreLocation
import Combine

struct SheetContent: View {
    @Binding var trips: [Trip]
    @Binding var selectedTrip: Trip?
    @Binding var isAddTripMode: Bool
    @Binding var trainSearchQuery: String
    @Binding var pastTrips: [Trip]

    @FocusState private var isTextFieldFocused: Bool
    @State private var searchResults: [Trip] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var addStep: AddTripStep = .search
    @State private var pendingTrip: Trip?
    @State private var availableStops: [GTFSStop] = []
    @State private var selectedDate: Date = Date()
    @State private var selectedOrigin: GTFSStop?
    @State private var originQuery: String = ""
    @State private var destinationQuery: String = ""
    @State private var tripSortKeys: [String: Date] = [:]
    @State private var isShowingPastSheet = false
    @State private var pendingDeletionIDs: [String] = []
    @State private var isShowingDeleteConfirmation = false

    private let dataSource = GTFSDataSource.shared
    private let pruneTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init(
        trips: Binding<[Trip]>,
        selectedTrip: Binding<Trip?>,
        isAddTripMode: Binding<Bool>,
        trainSearchQuery: Binding<String>,
        pastTrips: Binding<[Trip]> = .constant([])
    ) {
        self._trips = trips
        self._selectedTrip = selectedTrip
        self._isAddTripMode = isAddTripMode
        self._trainSearchQuery = trainSearchQuery
        self._pastTrips = pastTrips
    }

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(.secondary)
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            if !isShowingDetailHeader {
                HStack {
                    Text(headerTitle)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Spacer()
                    headerTrailing
                }
                .padding(.horizontal)
            }

            contentView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: isAddTripMode) { _, newValue in
            newValue ? startAddFlow() : resetAddFlow()
        }
        .onChange(of: addStep) { _, newValue in
            updateFocus(for: newValue)
        }
        .onChange(of: trainSearchQuery) { _, newValue in
            guard isAddTripMode, addStep == .search else { return }
            performTrainSearch(query: newValue)
        }
        .onAppear {
            refreshSortKeys()
            pruneCompletedTrips()
        }
        .onReceive(pruneTimer) { _ in
            pruneCompletedTrips()
        }
        .onChange(of: trips) { _, _ in
            refreshSortKeys()
            pruneCompletedTrips()
        }
        .onDisappear { searchTask?.cancel() }
        .sheet(isPresented: $isShowingPastSheet) {
            PastTripsSheet(
                trips: sortedPastTrips,
                onDismiss: { isShowingPastSheet = false },
                onDeleteTrip: deletePastTrip,
                onSelectTrip: { trip in
                    selectedTrip = trip
                    isAddTripMode = false
                    isShowingPastSheet = false
                }
            )
            .presentationDetents([.fraction(0.6), .large])
            .presentationDragIndicator(.visible)
        }
        .alert("Delete Trip?", isPresented: $isShowingDeleteConfirmation, actions: {
            Button("Delete", role: .destructive) {
                confirmDeletion()
            }
            Button("Cancel", role: .cancel) {
                cancelDeletion()
            }
        }, message: {
            Text("This trip will be removed from My Trips.")
        })
    }

    @ViewBuilder
    private var contentView: some View {
        if let trip = selectedTrip {
            TripDetailSheet(
                trip: trip,
                pastTrips: pastTrips,
                onClose: exitDetailView,
                onUpdateTrip: handleTripUpdate
            )
        } else if isAddTripMode {
            addFlowContent
        } else {
            defaultContent
        }
    }

    private var defaultContent: some View {
        VStack(spacing: 16) {
            SearchButton {
                isAddTripMode = true
            }

            List {
                if trips.isEmpty {
                    SearchPlaceholderView(text: "No saved trips yet. Tap search to add one.")
                        .listRowInsets(EdgeInsets(top: 40, leading: 0, bottom: 40, trailing: 0))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(sortedTrips) { trip in
                        Button {
                            selectedTrip = trip
                        } label: {
                            TripRowView(trip: trip)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        requestDeletion(for: offsets, from: sortedTrips)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var addFlowContent: some View {
        VStack(spacing: 16) {
            addInputField
            addStepContent
        }
    }

    @ViewBuilder
    private var addInputField: some View {
        switch addStep {
        case .search, .origin, .destination:
            let placeholder = addStep.placeholder
            let binding = bindingForCurrentInput
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: binding)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
            .focused($isTextFieldFocused)
            .submitLabel(.search)
        case .date:
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose travel date")
                    .font(.headline)
                DatePicker(
                    "Travel Date",
                    selection: $selectedDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var addStepContent: some View {
        switch addStep {
        case .search:
            if normalizedTrainQuery.isEmpty {
                SearchPlaceholderView(text: "Type a train number to look up schedules.")
            } else if searchResults.isEmpty {
                SearchPlaceholderView(text: "No trains found for \"\(trainSearchQuery)\"")
            } else {
                List(searchResults) { trip in
                    Button {
                        handleTrainSelection(trip)
                    } label: {
                        TripRowView(trip: trip, displayMode: .scheduled)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        case .date:
            VStack(spacing: 12) {
                Text("Next: Choose your origin station")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    advanceToOrigin()
                } label: {
                    Text("Continue to Origin")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(availableStops.isEmpty)
                .opacity(availableStops.isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal)
        case .origin:
            stopListView(stops: filteredOriginStops, emptyText: "No stations match your search.") { stop in
                selectedOrigin = stop
                destinationQuery = ""
                addStep = .destination
            }
        case .destination:
            stopListView(stops: filteredDestinationStops, emptyText: destinationEmptyMessage) { stop in
                finalizeTrip(with: stop)
            }
        }
    }

    private func stopListView(stops: [GTFSStop], emptyText: String, action: @escaping (GTFSStop) -> Void) -> some View {
        Group {
            if stops.isEmpty {
                SearchPlaceholderView(text: emptyText)
            } else {
                List(stops) { stop in
                    Button {
                        action(stop)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(stop.name)
                                    .font(.headline)
                                Text("Stop #\(stop.sequence)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private var headerTitle: String {
        if isAddTripMode { return addStep.title }
        return "My Trips"
    }

    @ViewBuilder
    private var headerTrailing: some View {
        if isAddTripMode {
            Button(addStep == .search ? "Cancel" : "Back") {
                handleAddFlowBack()
            }
            .foregroundStyle(.blue)
        } else {
            Button {
                isShowingPastSheet = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.25))
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
        }
    }

    private var isShowingDetailHeader: Bool {
        selectedTrip != nil && !isAddTripMode
    }

    private func exitDetailView() {
        selectedTrip = nil
        isAddTripMode = false
    }

    private func handleAddFlowBack() {
        switch addStep {
        case .search:
            isAddTripMode = false
        case .date:
            addStep = .search
            pendingTrip = nil
            availableStops = []
        case .origin:
            addStep = .date
            selectedOrigin = nil
        case .destination:
            addStep = .origin
            destinationQuery = ""
        }
    }

    private func startAddFlow() {
        addStep = .search
        pendingTrip = nil
        availableStops = []
        selectedDate = Date()
        selectedOrigin = nil
        originQuery = ""
        destinationQuery = ""
        searchResults = []
        searchTask?.cancel()
        trainSearchQuery = ""
    }

    private func resetAddFlow() {
        addStep = .search
        pendingTrip = nil
        availableStops = []
        selectedDate = Date()
        selectedOrigin = nil
        originQuery = ""
        destinationQuery = ""
        searchResults = []
        searchTask?.cancel()
        trainSearchQuery = ""
        isTextFieldFocused = false
    }

    private func updateFocus(for step: AddTripStep) {
        DispatchQueue.main.async {
            isTextFieldFocused = step.showsTextField
        }
    }

    private func handleTrainSelection(_ trip: Trip) {
        pendingTrip = trip
        availableStops = dataSource.stops(for: trip.id)
        addStep = .date
        trainSearchQuery = trip.title
        originQuery = ""
        destinationQuery = ""
        selectedOrigin = nil
    }

    private func advanceToOrigin() {
        guard !availableStops.isEmpty else { return }
        selectedOrigin = nil
        originQuery = ""
        addStep = .origin
    }

    private func finalizeTrip(with destination: GTFSStop) {
        guard let baseTrip = pendingTrip, let origin = selectedOrigin else { return }
        guard destination.sequence > origin.sequence else { return }

        let summaryTitle = baseTrip.title
        let dateText = formattedDate(selectedDate)
        let routeText = "\(origin.name) → \(destination.name)"
        let subtitle = "\(routeText) · \(dateText)"
        let composedID = "\(baseTrip.id)-\(origin.id)-\(destination.id)-\(Int(selectedDate.timeIntervalSince1970))"
        let storedStops = availableStops.map { stop in
            StoredStop(
                id: stop.id,
                name: stop.name,
                latitude: stop.latitude,
                longitude: stop.longitude,
                sequence: stop.sequence
            )
        }

        let distanceText = formattedDistance(for: storedStops)

        let savedTrip = Trip(
            id: composedID,
            title: summaryTitle,
            subtitle: subtitle,
            agencyId: baseTrip.agencyId,
            detailDate: dateText,
            detailRoute: routeText,
            gtfsTripId: baseTrip.gtfsTripId ?? baseTrip.id,
            travelDate: selectedDate,
            originStopId: origin.id,
            originName: origin.name,
            destinationStopId: destination.id,
            destinationName: destination.name,
            originPlatform: baseTrip.originPlatform,
            destinationPlatform: baseTrip.destinationPlatform,
            delayMinutes: baseTrip.delayMinutes,
            detailDistance: distanceText,
            stops: storedStops,
            originSequence: origin.sequence,
            destinationSequence: destination.sequence
        )

        if !trips.contains(where: { $0.id == savedTrip.id }) {
            trips.append(savedTrip)
        }

        selectedTrip = savedTrip
        pendingTrip = nil
        availableStops = []
        selectedOrigin = nil
        originQuery = ""
        destinationQuery = ""
        isAddTripMode = false
    }

    private func requestDeletion(for offsets: IndexSet, from orderedTrips: [Trip]) {
        let ids = offsets.compactMap { index -> String? in
            guard orderedTrips.indices.contains(index) else { return nil }
            return orderedTrips[index].id
        }

        guard !ids.isEmpty else { return }
        pendingDeletionIDs = ids
        isShowingDeleteConfirmation = true
    }

    private func confirmDeletion() {
        deleteTrips(with: pendingDeletionIDs)
        pendingDeletionIDs = []
        isShowingDeleteConfirmation = false
    }

    private func cancelDeletion() {
        pendingDeletionIDs = []
        isShowingDeleteConfirmation = false
    }

    private func deleteTrips(with ids: [String]) {
        let removalSet = Set(ids)
        guard !removalSet.isEmpty else { return }

        trips.removeAll { removalSet.contains($0.id) }

        if let activeTrip = selectedTrip, removalSet.contains(activeTrip.id) {
            selectedTrip = nil
        }
    }

    private func performTrainSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }

        searchTask = Task(priority: .userInitiated) {
            let matches = dataSource.searchTrips(matching: trimmed)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                searchResults = matches
            }
        }
    }

    private var bindingForCurrentInput: Binding<String> {
        switch addStep {
        case .search:
            return $trainSearchQuery
        case .origin:
            return $originQuery
        case .destination:
            return $destinationQuery
        case .date:
            return .constant("")
        }
    }

    private var normalizedTrainQuery: String {
        trainSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sortedTrips: [Trip] {
        trips.sorted { lhs, rhs in
            let lhsDate = tripSortKeys[lhs.id] ?? fallbackSortDate(for: lhs)
            let rhsDate = tripSortKeys[rhs.id] ?? fallbackSortDate(for: rhs)
            if lhsDate == rhsDate {
                return lhs.title < rhs.title
            }
            return lhsDate < rhsDate
        }
    }

    private var sortedPastTrips: [Trip] {
        pastTrips.sorted { lhs, rhs in
            let lhsArrival = arrivalDateWithDelay(for: lhs) ?? .distantPast
            let rhsArrival = arrivalDateWithDelay(for: rhs) ?? .distantPast
            if lhsArrival == rhsArrival {
                return lhs.title < rhs.title
            }
            return lhsArrival > rhsArrival
        }
    }

    private func fallbackSortDate(for trip: Trip) -> Date {
        if let date = trip.travelDate {
            return date
        }
        return .distantFuture
    }

    private var filteredOriginStops: [GTFSStop] {
        guard !availableStops.isEmpty else { return [] }
        let keyword = originQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return availableStops }
        return availableStops.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    private var filteredDestinationStops: [GTFSStop] {
        guard let origin = selectedOrigin else { return [] }
        let candidates = availableStops.filter { $0.sequence > origin.sequence }
        let keyword = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return candidates }
        return candidates.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    private var destinationEmptyMessage: String {
        if selectedOrigin == nil {
            return "Pick an origin before selecting a destination."
        }
        return "No destination matches your search."
    }

    private func formattedDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func refreshSortKeys() {
        var updated: [String: Date] = [:]
        for trip in trips {
            updated[trip.id] = computeSortKey(for: trip)
        }
        tripSortKeys = updated
    }

    private func computeSortKey(for trip: Trip) -> Date {
        guard let travelDate = trip.travelDate, let originId = trip.originStopId else {
            return fallbackSortDate(for: trip)
        }

        let base = Calendar.current.startOfDay(for: travelDate)
        let identifier = trip.gtfsTripId ?? trip.id
        let schedule = dataSource.stopSchedule(for: identifier, stopId: originId)
        let departure = schedule?.departureDate(on: base) ?? schedule?.arrivalDate(on: base)
        let delaySeconds = TimeInterval((trip.delayMinutes ?? 0) * 60)

        if let departure {
            return departure.addingTimeInterval(delaySeconds)
        }

        return travelDate
    }

    private func pruneCompletedTrips() {
        let now = Date()
        let completedTrips = trips.filter { trip in
            guard let cutoff = removalCutoffDate(for: trip) else { return false }
            return now >= cutoff
        }

        guard !completedTrips.isEmpty else { return }

        archiveTrips(completedTrips)

        let expiredIDs = Set(completedTrips.map { $0.id })
        trips.removeAll { expiredIDs.contains($0.id) }
        if let activeTrip = selectedTrip, expiredIDs.contains(activeTrip.id) {
            selectedTrip = nil
        }
    }

    private func removalCutoffDate(for trip: Trip) -> Date? {
        guard let arrival = arrivalDateWithDelay(for: trip) else { return nil }
        return arrival.addingTimeInterval(20 * 60)
    }

    private func arrivalDateWithDelay(for trip: Trip) -> Date? {
        guard let travelDate = trip.travelDate else { return nil }
        guard let destinationId = trip.destinationStopId else { return nil }

        let base = Calendar.current.startOfDay(for: travelDate)
        let identifier = trip.gtfsTripId ?? trip.id
        guard let schedule = dataSource.stopSchedule(for: identifier, stopId: destinationId) else { return nil }
        guard let arrival = schedule.arrivalDate(on: base) ?? schedule.departureDate(on: base) else { return nil }
        let delaySeconds = TimeInterval((trip.delayMinutes ?? 0) * 60)
        return arrival.addingTimeInterval(delaySeconds)
    }

    private func archiveTrips(_ completedTrips: [Trip]) {
        guard !completedTrips.isEmpty else { return }
        var combined = pastTrips
        combined.append(contentsOf: completedTrips)

        var unique: [String: Trip] = [:]
        for trip in combined {
            unique[trip.id] = trip
        }

        let merged = unique.values.sorted { lhs, rhs in
            let lhsArrival = arrivalDateWithDelay(for: lhs) ?? .distantPast
            let rhsArrival = arrivalDateWithDelay(for: rhs) ?? .distantPast
            if lhsArrival == rhsArrival {
                return lhs.title < rhs.title
            }
            return lhsArrival > rhsArrival
        }

        pastTrips = merged
    }

    private func deletePastTrip(_ trip: Trip) {
        pastTrips.removeAll { $0.id == trip.id }
    }

    private func handleTripUpdate(_ updatedTrip: Trip) {
        if let index = trips.firstIndex(where: { $0.id == updatedTrip.id }) {
            trips[index] = updatedTrip
        }
        if selectedTrip?.id == updatedTrip.id {
            selectedTrip = updatedTrip
        }
    }
}

struct TripRowView: View {
    enum DisplayMode {
        case live
        case scheduled
    }

    let trip: Trip
    var showsCardBackground: Bool = false
    var displayMode: DisplayMode = .live

    @State private var timing = TripRowTiming()
    @State private var derivedStops: StopPair?
    @State private var now = Date()
    @State private var liveDelayInfo: DelayInfo?
    private let dataSource = GTFSDataSource.shared
    private let secondTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init(trip: Trip, showsCardBackground: Bool = false, displayMode: DisplayMode = .live) {
        self.trip = trip
        self.showsCardBackground = showsCardBackground
        self.displayMode = displayMode
        _liveDelayInfo = State(initialValue: LiveDelayStore.shared.info(for: trip.id))
    }

    var body: some View {
        Group {
            if showsCardBackground {
                rowCore
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color(.separator).opacity(0.4), lineWidth: 1)
                    )
            } else {
                rowCore
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: trip.id) {
            loadTiming()
        }
        .onReceive(secondTimer) { value in
            guard shouldTickEverySecond else { return }
            now = value
        }
        .onReceive(minuteTimer) { value in
            guard shouldTickEveryMinute else { return }
            now = value
        }
        .onReceive(NotificationCenter.default.publisher(for: .liveDelayInfoUpdated)) { notification in
            guard let updatedID = notification.object as? String, updatedID == trip.id else { return }
            liveDelayInfo = LiveDelayStore.shared.info(for: trip.id)
        }
    }

    private var rowCore: some View {
        HStack(alignment: .center, spacing: 16) {
            leadingColumn

            VStack(alignment: .leading, spacing: 12) {
                headerRow
                routeRow
                terminalTimesRow
            }
        }
    }


    private var headerRow: some View {
        HStack(spacing: 5) {
//            Image("cfr")
//                .resizable()
//                .scaledToFit()
//                .frame(width: 35, height: 17)
//                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
//                .overlay(
//                    RoundedRectangle(cornerRadius: 8, style: .continuous)
//                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
//                )

            Text(trip.title)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(statusText)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .textCase(.none)
                .foregroundStyle(statusColor)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var routeRow: some View {
        Text(routeLine)
            .font(.system(size: 18, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var terminalTimesRow: some View {
        HStack(spacing: 16) {
            terminalTimeView(
                icon: "arrow.up.right.circle.fill",
                text: formattedTime(adjustedDepartureDate)
            )

            terminalTimeView(
                icon: "arrow.down.right.circle.fill",
                text: formattedTime(adjustedArrivalDate)
            )

            Spacer(minLength: 0)
        }
    }

    private func terminalTimeView(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(timeTint(for: text))
            Text(text)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(timeTint(for: text))
        }
        .font(.system(size: 16, weight: .semibold, design: .rounded))
    }

    @ViewBuilder
    private var leadingColumn: some View {
        switch displayMode {
        case .live:
            countdownColumn
        case .scheduled:
            scheduledColumn
        }
    }

    private var countdownColumn: some View {
        let countdown = countdownTexts
        let subtitle: String
        if hasArrived {
            subtitle = "ARRIVED"
        } else if hasDepartedButNotArrived {
            subtitle = "DEPARTED"
        } else {
            subtitle = countdown.secondary
        }

        return VStack(spacing: 4) {
            if hasArrived {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
            } else if hasDepartedButNotArrived {
                ZStack {
                    Circle()
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Circle()
                                .stroke(Color(.quaternarySystemFill), lineWidth: 1)
                        )
                        .frame(maxWidth: .infinity)
                    Image(systemName: "train.side.front.car")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
            } else {
                Text(countdown.primary)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            Text(subtitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(hasArrived ? .green : (hasDepartedButNotArrived ? .primary : .secondary))
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
        .frame(width: 78)
    }

    private var scheduledColumn: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text("SCHEDULED")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .frame(width: 78)
    }

    private var countdownTexts: (primary: String, secondary: String) {
        guard let departure = adjustedDepartureDate else {
            return ("--", "SCHEDULE")
        }
        let remaining = departure.timeIntervalSince(now)

        guard remaining > 0 else {
            return ("—", "DEPARTED")
        }

        let seconds = Int(remaining)
        let minute = 60
        let hour = 60 * minute
        let day = 24 * hour
        let week = 7 * day
        let month = 30 * day

        if seconds >= month {
            let months = seconds / month
            return ("\(months)", months == 1 ? "MONTH" : "MONTHS")
        }

        if seconds >= week {
            let weeks = seconds / week
            return ("\(weeks)", weeks == 1 ? "WEEK" : "WEEKS")
        }

        if seconds >= day {
            let days = seconds / day
            return ("\(days)", days == 1 ? "DAY" : "DAYS")
        }

        if seconds >= hour {
            let hours = seconds / hour
            let minutes = (seconds % hour) / minute
            let minuteLabel = minutes == 1 ? "1 MINUTE" : "\(minutes) MINUTES"
            return ("\(hours)h", minuteLabel)
        }

        if seconds >= minute {
            let minutes = max(1, seconds / minute)
            return ("\(minutes)", minutes == 1 ? "MINUTE" : "MINUTES")
        }

        let secs = max(seconds, 1)
        return ("\(secs)", secs == 1 ? "SECOND" : "SECONDS")
    }

    private var routeLine: String {
        let origin = sanitizedName(resolvedOriginName)
        let destination = sanitizedName(resolvedDestinationName)

        if let origin, let destination {
            return "\(origin) to \(destination)"
        }

        if let origin {
            return origin
        }

        if let destination {
            return destination
        }

        return trip.subtitle
    }

    private var statusColor: Color {
        if displayMode == .scheduled { return .primary }
        if isFarOutTrip { return .secondary }
        let delay = effectiveDelayMinutes
        if delay > 0 { return .red }
        return .green
    }

    private var statusText: String {
        if displayMode == .scheduled {
            return "SCHEDULED"
        }
        if isFarOutTrip, let departure = adjustedDepartureDate {
            return Self.longDateFormatter.string(from: departure)
        }

        let delay = effectiveDelayMinutes
        if delay > 0 {
            return "\(formattedDelay(minutes: delay)) late"
        }
        if delay < 0 {
            return "\(formattedDelay(minutes: abs(delay))) early"
        }
        return "Departs On Time"
    }

    private var hasDelay: Bool {
        effectiveDelayMinutes > 0
    }

    private var isFarOutTrip: Bool {
        guard let departure = adjustedDepartureDate else { return false }
        return departure.timeIntervalSince(now) > 24 * 60 * 60
    }

    private var hasArrived: Bool {
        if let arrival = adjustedArrivalDate {
            return arrival <= now
        }
        return false
    }

    private var hasDepartedButNotArrived: Bool {
        guard let departure = adjustedDepartureDate else { return false }
        guard departure <= now else { return false }
        if let arrival = adjustedArrivalDate {
            return arrival > now
        }
        return true
    }

    private var shouldTickEverySecond: Bool {
        guard let departure = adjustedDepartureDate else { return false }
        let remaining = departure.timeIntervalSince(now)
        return remaining <= 3600 && remaining > 0
    }

    private var shouldTickEveryMinute: Bool {
        guard let departure = adjustedDepartureDate else { return false }
        let remaining = departure.timeIntervalSince(now)
        return remaining <= 24 * 3600 && remaining > 3600
    }

    private var effectiveDelayMinutes: Int {
        liveDelayInfo?.delayMinutes ?? trip.delayMinutes ?? 0
    }

    private func formattedDelay(minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if mins > 0 { parts.append("\(mins)m") }
        if parts.isEmpty { parts.append("0m") }
        return parts.joined(separator: " ")
    }

    private var adjustedDepartureDate: Date? {
        guard let date = timing.departureDate else { return nil }
        return applyDelay(to: date)
    }

    private var adjustedArrivalDate: Date? {
        guard let date = timing.arrivalDate else { return nil }
        return applyDelay(to: date)
    }

    private func applyDelay(to date: Date) -> Date {
        guard effectiveDelayMinutes != 0 else { return date }
        return date.addingTimeInterval(TimeInterval(effectiveDelayMinutes * 60))
    }

    private func formattedTime(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        return Self.timeFormatter.string(from: date)
    }

    private func timeTint(for text: String) -> Color {
        if displayMode == .scheduled { return .primary }
        if text == "--:--" { return .secondary }
        if isFarOutTrip { return .secondary }
        return effectiveDelayMinutes > 0 ? .red : .green
    }

    private func loadTiming() {
        ensureDerivedStops()

        guard
            let originId = resolvedOriginStopId,
            let destinationId = resolvedDestinationStopId
        else {
            timing = TripRowTiming()
            return
        }

        let base = Calendar.current.startOfDay(for: resolvedTravelDate)
        let tripIdentifier = trip.gtfsTripId ?? trip.id
        let originSchedule = dataSource.stopSchedule(for: tripIdentifier, stopId: originId)
        let destinationSchedule = dataSource.stopSchedule(for: tripIdentifier, stopId: destinationId)

        let departure = originSchedule?.departureDate(on: base) ?? originSchedule?.arrivalDate(on: base)
        let arrival = destinationSchedule?.arrivalDate(on: base) ?? destinationSchedule?.departureDate(on: base)
        timing = TripRowTiming(departureDate: departure, arrivalDate: arrival)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM"
        return formatter
    }()
    private func ensureDerivedStops() {
        if derivedStops != nil { return }

        if let storedStops = trip.stops, !storedStops.isEmpty {
            let sorted = storedStops.sorted { $0.sequence < $1.sequence }
            let originStored = storedStop(from: storedStops, id: trip.originStopId, sequence: trip.originSequence, fallback: sorted.first)
            let destinationStored = storedStop(from: storedStops, id: trip.destinationStopId, sequence: trip.destinationSequence, fallback: sorted.last)

            if let originStored, let destinationStored {
                derivedStops = StopPair(origin: StopDescriptor(originStored), destination: StopDescriptor(destinationStored))
                return
            }
        }

        let tripIdentifier = trip.gtfsTripId ?? trip.id
        let gtfsStops = dataSource.stops(for: tripIdentifier)
        guard let first = gtfsStops.first, let last = gtfsStops.last else { return }
        derivedStops = StopPair(origin: StopDescriptor(first), destination: StopDescriptor(last))
    }

    private func storedStop(
        from stops: [StoredStop],
        id: String?,
        sequence: Int?,
        fallback: StoredStop?
    ) -> StoredStop? {
        if let id, let match = stops.first(where: { $0.id == id }) {
            return match
        }
        if let sequence, let match = stops.first(where: { $0.sequence == sequence }) {
            return match
        }
        return fallback
    }

    private var resolvedOriginStopId: String? {
        trip.originStopId ?? derivedStops?.origin.id
    }

    private var resolvedDestinationStopId: String? {
        trip.destinationStopId ?? derivedStops?.destination.id
    }

    private var resolvedOriginName: String? {
        trip.originName ?? derivedStops?.origin.name
    }

    private var resolvedDestinationName: String? {
        trip.destinationName ?? derivedStops?.destination.name
    }

    private var resolvedTravelDate: Date {
        trip.travelDate ?? now
    }

    private func sanitizedName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct TripRowTiming {
    var departureDate: Date?
    var arrivalDate: Date?
}

private struct StopPair {
    let origin: StopDescriptor
    let destination: StopDescriptor
}

private struct StopDescriptor {
    let id: String
    let name: String

    init(_ stop: StoredStop) {
        id = stop.id
        name = stop.name
    }

    init(_ stop: GTFSStop) {
        id = stop.id
        name = stop.name
    }
}

struct PastTripsSheet: View {
    let trips: [Trip]
    var onDismiss: () -> Void
    var onDeleteTrip: (Trip) -> Void = { _ in }
    var onSelectTrip: (Trip) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            Group {
                if trips.isEmpty {
                    SearchPlaceholderView(text: "No past rides yet.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground).opacity(0.8))
                } else {
                    List {
                        ForEach(trips) { trip in
                            Button {
                                onSelectTrip(trip)
                            } label: {
                                TripRowView(trip: trip)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    withAnimation {
                                        onDeleteTrip(trip)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal)
            .navigationTitle("Past Rides")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss()
                    }
                }
            }
        }
    }
}

struct SearchButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("Search to add trains")
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }
}

struct SearchPlaceholderView: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "train.side.front.car")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

private func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func formattedDistance(for stops: [StoredStop]) -> String? {
    guard stops.count > 1 else { return nil }
    let sorted = stops.sorted { $0.sequence < $1.sequence }
    var totalMeters: CLLocationDistance = 0
    for pair in zip(sorted, sorted.dropFirst()) {
        let start = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
        let end = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
        totalMeters += start.distance(from: end)
    }
    let kilometers = totalMeters / 1000
    guard kilometers > 1 else { return nil }
    return String(format: "%.0f km", kilometers)
}

enum AddTripStep {
    case search
    case date
    case origin
    case destination

    var title: String {
        switch self {
        case .search: return "Add Trip"
        case .date: return "Add Date"
        case .origin: return "Add Origin"
        case .destination: return "Add Destination"
        }
    }

    var placeholder: String {
        switch self {
        case .search: return "Search train number"
        case .origin: return "Search origin station"
        case .destination: return "Search destination station"
        case .date: return ""
        }
    }

    var showsTextField: Bool {
        switch self {
        case .date: return false
        default: return true
        }
    }
}
