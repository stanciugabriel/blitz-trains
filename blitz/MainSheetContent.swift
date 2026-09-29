import SwiftUI
import CoreLocation
import Combine
import PhotosUI
import UniformTypeIdentifiers
internal import UIKit


struct SheetContent: View {
    @Binding var trips: [Trip]
    @Binding var selectedTrip: Trip?
    @Binding var isAddTripMode: Bool
    @Binding var trainSearchQuery: String
    @Binding var pastTrips: [Trip]
    @Binding var missedTrainPrompt: MissedTrainPrompt?
    @Binding var isShowingMissedTrainAlternatives: Bool
    let missedTrainAlternatives: [Trip]
    var onTripAdded: (Trip) -> Void
    var onMissedTrainFindAlternatives: (MissedTrainPrompt) -> Void
    var onMissedTrainKeepTracking: (MissedTrainPrompt) -> Void
    var onSelectMissedTrainAlternative: (Trip) -> Void
    @ObservedObject var locationPhaseDetector: TripLocationPhaseDetector

    @FocusState private var isTextFieldFocused: Bool
    @State private var searchResults: [Trip] = []
    @State private var trainSearchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearchingTrains = false
    @State private var searchRequestID = UUID()
    @State private var addStep: AddTripStep = .search
    @State private var pendingTrip: Trip?
    @State private var candidateTrips: [Trip] = []
    @State private var availableStops: [GTFSStop] = []
    @State private var selectedDate: Date = Date()
    @State private var isSelectedDateAvailable = false
    @State private var selectedOrigin: GTFSStop?
    @State private var selectedDestination: GTFSStop?
    @State private var originQuery: String = ""
    @State private var destinationQuery: String = ""
    @State private var tripSortKeys: [String: Date] = [:]
    @State private var isShowingPastSheet = false
    @State private var pendingDeletionIDs: [String] = []
    @State private var isShowingDeleteConfirmation = false
    @State private var pendingPastDeletionTrip: Trip?
    @State private var isShowingPastDeleteConfirmation = false
    @State private var activeConnectionInfo: ConnectionInfo?
    @State private var isGeneratingRandomTrip = false
    @State private var isSelectedTripPast = false
    @State private var selectedMainTab: MainSheetTab = .trips
    @State private var tabBeforeSearch: MainSheetTab = .trips
    @State private var searchFocusNonce = 0
    @State private var pendingSearchAutofocus = false
    @State private var isShowingLogAddedToast = false
    @State private var logAddedToastTask: Task<Void, Never>?
    @State private var profile = UserProfilePreferences.load()
    @State private var isShowingProfileEditor = false
    @State private var isShowingSettingsSheet = false
    

    private var dataSource: GTFSDataSource { GTFSDataSource.shared }
    private let pruneTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init(
        trips: Binding<[Trip]>,
        selectedTrip: Binding<Trip?>,
        isAddTripMode: Binding<Bool>,
        trainSearchQuery: Binding<String>,
        pastTrips: Binding<[Trip]> = .constant([]),
        missedTrainPrompt: Binding<MissedTrainPrompt?>,
        isShowingMissedTrainAlternatives: Binding<Bool>,
        missedTrainAlternatives: [Trip],
        locationPhaseDetector: TripLocationPhaseDetector,
        onTripAdded: @escaping (Trip) -> Void = { _ in },
        onMissedTrainFindAlternatives: @escaping (MissedTrainPrompt) -> Void = { _ in },
        onMissedTrainKeepTracking: @escaping (MissedTrainPrompt) -> Void = { _ in },
        onSelectMissedTrainAlternative: @escaping (Trip) -> Void = { _ in }
    ) {
        self._trips = trips
        self._selectedTrip = selectedTrip
        self._isAddTripMode = isAddTripMode
        self._trainSearchQuery = trainSearchQuery
        self._pastTrips = pastTrips
        self._missedTrainPrompt = missedTrainPrompt
        self._isShowingMissedTrainAlternatives = isShowingMissedTrainAlternatives
        self.missedTrainAlternatives = missedTrainAlternatives
        self.locationPhaseDetector = locationPhaseDetector
        self.onTripAdded = onTripAdded
        self.onMissedTrainFindAlternatives = onMissedTrainFindAlternatives
        self.onMissedTrainKeepTracking = onMissedTrainKeepTracking
        self.onSelectMissedTrainAlternative = onSelectMissedTrainAlternative
    }

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(.secondary)
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            if !isShowingDetailHeader && !isShowingMissedTrainAlternatives {
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
        .background(searchSheetBackground)
        .overlay(alignment: .top) {
            if isShowingLogAddedToast {
                Text("Added to Log")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.82), in: Capsule())
                    .padding(.top, 58)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: addStep) { _, newValue in
            updateFocus(for: newValue)
        }
        .onChange(of: selectedMainTab) { oldValue, newValue in
            if newValue == .search {
                if oldValue != .search {
                    tabBeforeSearch = oldValue
                }
                startAddFlow()
                withAnimation(.easeOut(duration: 0.1)) {
                    isAddTripMode = true
                }
            } else if isAddTripMode {
                resetAddFlow()
                withAnimation(.easeOut(duration: 0.1)) {
                    isAddTripMode = false
                }
            }
        }
        .onChange(of: selectedTrip) { _, newValue in
            if newValue == nil {
                
            }
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
        .onChange(of: pastTrips) { _, newValue in
            TripStorage.shared.savePastTrips(newValue)
        }
        .onDisappear {
            searchTask?.cancel()
            logAddedToastTask?.cancel()
        }
        .sheet(item: $activeConnectionInfo) { info in
            ConnectionDetailSheet(info: info) {
                activeConnectionInfo = nil
            }
        }
        .sheet(isPresented: $isShowingProfileEditor) {
            ProfileEditorSheet(profile: $profile)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingSettingsSheet) {
            SettingsSheet(trips: $trips, pastTrips: $pastTrips) {
                isShowingSettingsSheet = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $isShowingPastSheet) {
            PastTripsSheet(
                trips: sortedPastTrips,
                onDismiss: { isShowingPastSheet = false },
                onDeleteTrip: deletePastTrip,
                onSelectTrip: { trip in
                    isSelectedTripPast = true
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
        .alert("Delete Ride?", isPresented: $isShowingPastDeleteConfirmation, actions: {
            Button("Delete", role: .destructive) {
                confirmPastTripDeletion()
            }
            Button("Cancel", role: .cancel) {
                cancelPastTripDeletion()
            }
        }, message: {
            Text("This ride will be removed from your Rail Log.")
        })
    }

    private var searchSheetBackground: some View {
        Group {
                Color(.systemBackground)
                    .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if isShowingMissedTrainAlternatives {
            MissedTrainAlternativesView(
                alternatives: missedTrainAlternatives,
                onSelect: onSelectMissedTrainAlternative,
                onCancel: { isShowingMissedTrainAlternatives = false }
            )
        } else if let trip = selectedTrip {
            TripDetailSheet(
                trip: trip,
                pastTrips: pastTrips,
                isPastTrip: isSelectedTripPast,
                onClose: exitDetailView,
                onUpdateTrip: handleTripUpdate,
                locationPhaseDetector: locationPhaseDetector
            )
        } else {
            mainTabContent
        }
    }

    @ViewBuilder
    private var mainTabContent: some View {
        TabView(selection: $selectedMainTab) {
            Tab(MainSheetTab.trips.title, systemImage: MainSheetTab.trips.icon, value: MainSheetTab.trips) {
                tripsContent
            }

            Tab(MainSheetTab.friends.title, systemImage: MainSheetTab.friends.icon, value: MainSheetTab.friends) {
                friendsContent
            }

            Tab(MainSheetTab.log.title, systemImage: MainSheetTab.log.icon, value: MainSheetTab.log) {
                logContent
            }

            Tab(value: MainSheetTab.search, role: .search) {
                addFlowContent
            }
        }
        .tint(.blue)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: selectedMainTab)
    }


    private var tripsContent: some View {
        Group {
            if trips.isEmpty {
                SearchPlaceholderView(text: "No saved trips yet. Tap search to add one.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal)
            } else {
                tripsList
            }
        }
    }

    private var tripsList: some View {
        VStack(spacing: 16) {
            List {
                let trips = sortedTrips
                ForEach(Array(trips.enumerated()), id: \.element.id) { index, entry in
                    if index > 0, let connection = connectionInfo(between: trips[index - 1], and: entry) {
                        Button {
                            activeConnectionInfo = connection
                        } label: {
                            ConnectionRowView(info: connection)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        isSelectedTripPast = false
                        selectedTrip = entry
                    } label: {
                        TripRowView(trip: entry)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            requestDeletion(for: entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)

                        Button {
                            archiveActiveTrip(entry)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.blue)
                    }
                }
                .onDelete { offsets in
                    requestDeletion(for: offsets, from: trips)
                }
            }
            .listStyle(.plain)
        }
    }

    private var friendsContent: some View {
        SearchPlaceholderView(text: "Friends will land here soon.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal)
    }

    private var logContent: some View {
        Group {
            if sortedPastTrips.isEmpty {
                SearchPlaceholderView(text: "No past rides yet.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal)
            } else {
                List {
                    LogSummaryCard(metrics: logSummaryMetrics)
                        .padding(.horizontal)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    ForEach(groupedPastTripsByYear) { section in
                        LogYearHeaderView(year: section.year, tripCount: section.trips.count)
                            .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)

                        ForEach(Array(section.trips.enumerated()), id: \.element.id) { index, trip in
                            Button {
                                isSelectedTripPast = true
                                selectedTrip = trip
                                isAddTripMode = false
                            } label: {
                                LogTripRowView(
                                    trip: trip,
                                    showsDivider: index < section.trips.count - 1
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    requestPastTripDeletion(trip)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var addFlowContent: some View {
        if addStep == .date {
            VStack(spacing: 0) {
                addInputField
                addStepContent
            }
        } else {
            VStack(spacing: 8) {
                addInputField
                addStepContent
            }
        }
    }

    @ViewBuilder
    private var addInputField: some View {
        switch addStep {
        case .search:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TrainNumberSearchInput(focusNonce: searchFocusNonce) { query in
                        trainSearchText = query
                        performTrainSearch(query: query)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)

            }
        case .origin, .destination:
            let placeholder = addStep.placeholder
            let binding = bindingForCurrentInput
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: binding)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                    .keyboardType(.default)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.sentences)
                    .focused($isTextFieldFocused)
                    .id(searchFocusNonce)
                    .onAppear {
                        focusSearchFieldIfNeeded()
                    }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
            .submitLabel(.search)
        case .date:
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose travel date")
                    .font(.headline)
                if let pendingTrip {
                    ServiceAvailabilityCalendar(
                        trip: pendingTrip,
                        query: trainSearchQuery.isEmpty ? nil : trainSearchQuery,
                        selectedDate: $selectedDate,
                        isSelectedDateAvailable: $isSelectedDateAvailable
                    )
                    .id(pendingTrip.id)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
        case .results:
            EmptyView()
        }
    }

    @ViewBuilder
    private var addStepContent: some View {
        switch addStep {
        case .search:
            VStack(spacing: 12) {
                randomTripButton
                searchResultsPanel
            }
        case .date:
            VStack(spacing: 12) {
                Text(dataSource.hasServiceCalendar ? "Next: Choose your origin station" : "This timetable is missing operating dates. The selected date cannot filter services yet.")
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
                .disabled(pendingTrip == nil || !isSelectedDateAvailable)
            }
            .padding(.horizontal)
        case .origin:
            stopListView(stops: filteredOriginStops, emptyText: availableStops.isEmpty ? "No departures are available on this date. Choose another date." : "No stations match your search.") { stop in
                selectedOrigin = stop
                destinationQuery = ""
                addStep = .destination
            }
        case .destination:
            stopListView(stops: filteredDestinationStops, emptyText: destinationEmptyMessage) { stop in
                selectedDestination = stop
                addStep = .results
            }
        case .results:
            remainingTripOptions
        }
    }

    @ViewBuilder
    private var remainingTripOptions: some View {
        let options = dataSource.options(in: candidateTrips, originID: selectedOrigin?.id ?? "", destinationID: selectedDestination?.id ?? "")
        if options.isEmpty {
            SearchPlaceholderView(text: "No matching departures remain for these stations.")
                .padding(.horizontal)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose a departure")
                    .font(.headline)
                    .padding(.horizontal)
                List(options, id: \.id) { option in
                    Button {
                        guard let destination = selectedDestination else { return }
                        finalizeTrip(with: destination, using: option)
                    } label: {
                        TripRowView(trip: option, displayMode: .scheduled)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
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

    private var randomTripButton: some View {
        Button(action: addRandomTrip) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.headline)
                Text(isGeneratingRandomTrip ? "Adding random trip…" : "Add a random active trip")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isGeneratingRandomTrip {
                    ProgressView()
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .disabled(isGeneratingRandomTrip)
    }

    @ViewBuilder
    private var searchResultsPanel: some View {
        if normalizedTrainQuery.isEmpty {
            SearchPlaceholderView(text: "Type a train, operator, or station to look up schedules.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSearchingTrains {
            VStack(spacing: 10) {
                ProgressView()
                Text("Searching schedules…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchResults.isEmpty {
            SearchPlaceholderView(text: "No trains found for \"\(trainSearchText)\"")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(searchResults, id: \.id) { trip in
                Button {
                    handleTrainSelection(trip)
                } label: {
                    SearchSuggestionRow(trip: trip)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func addRandomTrip() {
        guard !isGeneratingRandomTrip else { return }
        isGeneratingRandomTrip = true
        defer { isGeneratingRandomTrip = false }
        guard let newTrip = generateRandomActiveTrip() else { return }
        trips.append(newTrip)
        TripDebugLog.added(newTrip)
        isSelectedTripPast = false
        selectedTrip = newTrip
        isAddTripMode = false
        onTripAdded(newTrip)
    }

    private func generateRandomActiveTrip() -> Trip? {
        let maxAttempts = 10
        for _ in 0..<maxAttempts {
            guard let baseTrip = dataSource.randomTrip() else { return nil }
            let tripIdentifier = baseTrip.gtfsTripId ?? baseTrip.id
            let gtfsStops = dataSource.stops(for: tripIdentifier)
            guard gtfsStops.count >= 2, let destination = gtfsStops.last else { continue }
            guard let destinationSchedule = dataSource.stopSchedule(for: tripIdentifier, stopId: destination.id) else { continue }
            guard let arrivalSeconds = destinationSchedule.arrivalSeconds ?? destinationSchedule.departureSeconds else { continue }

            var originCandidates = Array(gtfsStops.dropLast())
            originCandidates.shuffle()
            for origin in originCandidates {
                guard let originSchedule = dataSource.stopSchedule(for: tripIdentifier, stopId: origin.id) else { continue }
                guard let departureSeconds = originSchedule.departureSeconds ?? originSchedule.arrivalSeconds else { continue }
                guard departureSeconds < arrivalSeconds else { continue }
                guard let timing = makeTravelTiming(departureSeconds: departureSeconds, arrivalSeconds: arrivalSeconds) else { continue }
                let subsetStops = storedStops(from: gtfsStops, startingAt: origin.sequence)
                return assembleRandomTrip(
                    baseTrip: baseTrip,
                    origin: origin,
                    destination: destination,
                    travelDate: timing.travelDate,
                    stops: subsetStops
                )
            }
        }
        return nil
    }

    private func makeTravelTiming(departureSeconds: Int, arrivalSeconds: Int) -> (travelDate: Date, departureDate: Date, arrivalDate: Date)? {
        let calendar = GTFSDataSource.calendar
        let now = Date()
        let baseToday = calendar.startOfDay(for: now)
        let offsets = [0, -1, 1, -2, 2]

        for offset in offsets {
            guard let base = calendar.date(byAdding: .day, value: offset, to: baseToday) else { continue }
            let departureDate = base.addingTimeInterval(TimeInterval(departureSeconds))
            let arrivalBase = base.addingTimeInterval(TimeInterval(arrivalSeconds))
            let normalizedArrival = ScheduleDateUtils.normalizedArrival(arrivalBase, relativeTo: departureDate) ?? arrivalBase
            if departureDate <= now && normalizedArrival > now {
                return (base, departureDate, normalizedArrival)
            }
        }

        return nil
    }

    private func assembleRandomTrip(
        baseTrip: Trip,
        origin: GTFSStop,
        destination: GTFSStop,
        travelDate: Date,
        stops: [StoredStop]
    ) -> Trip {
        let routeLine = "\(origin.name) → \(destination.name)"
        let dateText = formattedDate(travelDate)
        let subtitle = "\(routeLine) · \(dateText)"
        let delayMinutes = Int.random(in: 0...12)

        return Trip(
            id: UUID().uuidString,
            title: baseTrip.title,
            subtitle: subtitle,
            agencyId: baseTrip.agencyId,
            detailDate: dateText,
            detailRoute: routeLine,
            gtfsTripId: baseTrip.gtfsTripId ?? baseTrip.id,
            travelDate: travelDate,
            originStopId: origin.id,
            originName: origin.name,
            destinationStopId: destination.id,
            destinationName: destination.name,
            delayMinutes: delayMinutes,
            detailDistance: baseTrip.detailDistance,
            stops: stops,
            originSequence: origin.sequence,
            destinationSequence: destination.sequence,
            trainType: baseTrip.trainType,
            trainLength: baseTrip.trainLength,
            trainTonnage: baseTrip.trainTonnage,
            trainIdentifier: baseTrip.trainIdentifier,
            trainPower: baseTrip.trainPower
        )
    }

    private func storedStops(from stops: [GTFSStop], startingAt sequence: Int) -> [StoredStop] {
        stops.filter { $0.sequence >= sequence }.map { StoredStop(gtfsStop: $0) }
    }

    private var headerTitle: String {
        if selectedMainTab == .search { return addStep.title }
        return selectedMainTab.title
    }

    @ViewBuilder
    private var headerTrailing: some View {
        if selectedMainTab == .search {
            Button(addStep == .search ? "Cancel" : "Back") {
                handleAddFlowBack()
            }
            .foregroundStyle(.blue)
        } else {
            ProfileAvatarButton(
                profile: profile,
                editAction: {
                    isShowingProfileEditor = true
                },
                settingsAction: {
                    isShowingSettingsSheet = true
                }
            )
        }
    }

    private var isShowingDetailHeader: Bool {
        selectedTrip != nil && !isAddTripMode && !isShowingMissedTrainAlternatives
    }

    private var shouldShowMainBottomBar: Bool {
        selectedTrip == nil && !isAddTripMode
    }

    private func exitDetailView() {
        selectedTrip = nil
        isSelectedTripPast = false
        selectedMainTab = .trips
        isAddTripMode = false
    }

    private func handleAddFlowBack() {
        switch addStep {
        case .search:
            selectedMainTab = tabBeforeSearch
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
        case .results:
            addStep = .destination
            selectedDestination = nil
        }
    }

    private func startAddFlow() {
        addStep = .search
        pendingTrip = nil
        candidateTrips = []
        availableStops = []
        selectedDate = Date()
        selectedOrigin = nil
        originQuery = ""
        destinationQuery = ""
        searchResults = []
        searchTask?.cancel()
        isSearchingTrains = false
        searchRequestID = UUID()
        trainSearchText = ""
        trainSearchQuery = ""
        isTextFieldFocused = false
        pendingSearchAutofocus = true
        searchFocusNonce += 1
    }

    private func resetAddFlow() {
        addStep = .search
        pendingTrip = nil
        candidateTrips = []
        availableStops = []
        selectedDate = Date()
        selectedOrigin = nil
        originQuery = ""
        destinationQuery = ""
        searchResults = []
        searchTask?.cancel()
        isSearchingTrains = false
        searchRequestID = UUID()
        trainSearchText = ""
        trainSearchQuery = ""
        isTextFieldFocused = false
        pendingSearchAutofocus = false
    }

    private func updateFocus(for step: AddTripStep) {
        DispatchQueue.main.async {
            if step.showsTextField {
                pendingSearchAutofocus = selectedMainTab == .search
                focusSearchFieldIfNeeded()
            } else {
                pendingSearchAutofocus = false
                isTextFieldFocused = false
            }
        }
    }

    private func focusSearchFieldIfNeeded() {
        guard pendingSearchAutofocus, selectedMainTab == .search, addStep.showsTextField else { return }
        pendingSearchAutofocus = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard selectedMainTab == .search, addStep.showsTextField, !isTextFieldFocused else { return }
            isTextFieldFocused = true
        }
    }

    private func handleTrainSelection(_ trip: Trip) {
        pendingTrip = trip
        isSelectedDateAvailable = false
        candidateTrips = []
        availableStops = dataSource.stops(for: trip.gtfsTripId ?? trip.id)
        addStep = .date
        trainSearchQuery = trainSearchText
        originQuery = ""
        destinationQuery = ""
        selectedOrigin = nil
        selectedDestination = nil
    }

    private func advanceToOrigin() {
        guard let pendingTrip, isSelectedDateAvailable else { return }
        candidateTrips = dataSource.variants(for: pendingTrip, travelDate: selectedDate, matching: trainSearchQuery.isEmpty ? nil : trainSearchQuery)
        availableStops = dataSource.stationChoices(in: candidateTrips)
        selectedDestination = nil
        selectedOrigin = nil
        originQuery = ""
        addStep = .origin
    }

    private func finalizeTrip(with destination: GTFSStop, using selectedCandidate: Trip) {
        let baseTrip = selectedCandidate
        guard let chosenOrigin = selectedOrigin else { return }
        availableStops = dataSource.stops(for: baseTrip.gtfsTripId ?? baseTrip.id)
        guard let origin = availableStops.first(where: { $0.id == chosenOrigin.id }),
              let destination = availableStops.first(where: { $0.id == destination.id && $0.sequence > origin.sequence }) else { return }

        let summaryTitle = baseTrip.title
        let dateText = formattedDate(selectedDate)
        let routeText = "\(origin.name) → \(destination.name)"
        let subtitle = "\(routeText) · \(dateText)"
        let composedID = "\(baseTrip.id)-\(origin.id)-\(destination.id)-\(Int(selectedDate.timeIntervalSince1970))"
        let routeSchedules = availableStops.sorted { $0.sequence < $1.sequence }.map { stop in
            dataSource.stopSchedule(for: baseTrip.gtfsTripId ?? baseTrip.id, stopId: stop.id)
        }
        let routeTimes = routeSchedules.map { $0?.departureSeconds ?? $0?.arrivalSeconds }
        let originIndex = availableStops.sorted { $0.sequence < $1.sequence }
            .firstIndex(where: { $0.id == origin.id }) ?? 0
        let serviceDayOffset = ScheduleDateUtils.serviceDayOffset(for: routeTimes, through: originIndex)
        let serviceDate = ScheduleDateUtils.serviceDate(forBoardingDate: selectedDate, dayOffset: serviceDayOffset)
        let storedStops = availableStops.map { stop in
            StoredStop(
                id: stop.id,
                name: stop.name,
                latitude: stop.latitude,
                longitude: stop.longitude,
                sequence: stop.sequence
            )
        }

        let rideStops = stopsForRide(
            storedStops,
            originStopID: origin.id,
            destinationStopID: destination.id,
            originSequence: origin.sequence,
            destinationSequence: destination.sequence
        )
        let distanceText = formattedDistance(for: rideStops)
        let trainId = baseTrip.gtfsTripId ?? baseTrip.id
        let originPlatform = StaticPlatformDataSource.shared.platform(trainId: trainId, stationId: origin.id)
            ?? baseTrip.originPlatform
        let destinationPlatform = StaticPlatformDataSource.shared.platform(trainId: trainId, stationId: destination.id)
            ?? baseTrip.destinationPlatform

        let savedTrip = Trip(
            id: composedID,
            title: summaryTitle,
            subtitle: subtitle,
            agencyId: baseTrip.agencyId,
            detailDate: dateText,
            detailRoute: routeText,
            gtfsTripId: baseTrip.gtfsTripId ?? baseTrip.id,
            travelDate: serviceDate,
            originStopId: origin.id,
            originName: origin.name,
            destinationStopId: destination.id,
            destinationName: destination.name,
            originPlatform: originPlatform,
            destinationPlatform: destinationPlatform,
            delayMinutes: baseTrip.delayMinutes,
            detailDistance: distanceText,
            stops: storedStops,
            originSequence: origin.sequence,
            destinationSequence: destination.sequence,
            trainType: baseTrip.trainType,
            trainLength: baseTrip.trainLength,
            trainTonnage: baseTrip.trainTonnage,
            trainIdentifier: baseTrip.trainIdentifier,
            trainPower: baseTrip.trainPower
        )

        let shouldAddToLog = GTFSDataSource.calendar.startOfDay(for: selectedDate) < GTFSDataSource.calendar.startOfDay(for: Date())
        if shouldAddToLog {
            let alreadyInLog = pastTrips.contains { $0.id == savedTrip.id }
            archiveTrips([savedTrip])
            if !alreadyInLog { TripDebugLog.added(savedTrip) }
            isSelectedTripPast = false
            selectedTrip = nil
            selectedMainTab = .log
            isAddTripMode = false
            showLogAddedToast()
        } else {
            if !trips.contains(where: { $0.id == savedTrip.id }) {
                trips.append(savedTrip)
                TripDebugLog.added(savedTrip)
            }

            isSelectedTripPast = false
            selectedMainTab = .trips
            isAddTripMode = false
            selectedTrip = savedTrip
            onTripAdded(savedTrip)
        }
        pendingTrip = nil
        availableStops = []
        selectedOrigin = nil
        selectedDestination = nil
        originQuery = ""
        destinationQuery = ""
        isAddTripMode = false
    }

    private func showLogAddedToast() {
        logAddedToastTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            isShowingLogAddedToast = true
        }
        logAddedToastTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.18)) {
                    isShowingLogAddedToast = false
                }
                logAddedToastTask = nil
            }
        }
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

    private func requestDeletion(for trip: Trip) {
        pendingDeletionIDs = [trip.id]
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
            isSelectedTripPast = false
        }
    }

    private func archiveActiveTrip(_ trip: Trip) {
        withAnimation {
            archiveTrips([trip])
            trips.removeAll { $0.id == trip.id }
            if selectedTrip?.id == trip.id {
                selectedTrip = nil
                isSelectedTripPast = false
            }
        }
    }

    private func performTrainSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        let requestID = UUID()
        searchRequestID = requestID

        guard !trimmed.isEmpty else {
            isSearchingTrains = false
            searchResults = []
            return
        }

        isSearchingTrains = true

        searchTask = Task { [dataSource] in
            // Search is submitted explicitly from the keyboard. Keep the
            // database work off the UI thread; there is intentionally no
            // debounce here.
            let matches = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: dataSource.searchTrips(
                        matching: trimmed,
                        travelDate: nil
                    ))
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard searchRequestID == requestID,
                      trainSearchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                isSearchingTrains = false
                searchResults = matches
            }
        }
    }

    private var bindingForCurrentInput: Binding<String> {
        switch addStep {
        case .search:
            return $trainSearchText
        case .origin:
            return $originQuery
        case .destination:
            return $destinationQuery
        case .date:
            return .constant("")
        case .results:
            return .constant("")
        }
    }

    private var normalizedTrainQuery: String {
        trainSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private var groupedPastTripsByYear: [LogYearSection] {
        let grouped = Dictionary(grouping: sortedPastTrips) { trip in
            logYear(for: trip)
        }

        return grouped
            .map { year, trips in
                LogYearSection(year: year, trips: trips)
            }
            .sorted { lhs, rhs in
                lhs.year > rhs.year
            }
    }

    private func logYear(for trip: Trip) -> Int {
        let date = arrivalDateWithDelay(for: trip) ?? trip.travelDate ?? fallbackSortDate(for: trip)
        return GTFSDataSource.calendar.component(.year, from: date)
    }

    private var logSummaryMetrics: LogSummaryMetrics {
        var totalDistance: Double = 0
        var totalDuration: TimeInterval = 0
        var visitedStations = Set<String>()

        for trip in pastTrips {
            if let distance = distanceKilometers(for: trip) {
                totalDistance += distance
            }

            if let duration = tripDuration(for: trip) {
                totalDuration += duration
            }

            if let origin = normalizedStationKey(id: trip.originStopId, name: trip.originName) {
                visitedStations.insert(origin)
            }

            if let destination = normalizedStationKey(id: trip.destinationStopId, name: trip.destinationName) {
                visitedStations.insert(destination)
            }
        }

        return LogSummaryMetrics(
            tripCount: pastTrips.count,
            totalDistance: totalDistance,
            totalDuration: totalDuration,
            visitedStationCount: visitedStations.count
        )
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
        let candidates = dataSource.stationChoices(in: candidateTrips, after: origin.id)
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
        formatter.timeZone = GTFSDataSource.calendar.timeZone
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
        TripTimingResolver().resolve(
            trip: trip,
            delayInfo: LiveDelayStore.shared.info(for: trip.id),
            referenceDate: Date(),
            includeProgressDetails: false
        ).adjustedDeparture ?? fallbackSortDate(for: trip)
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
            isSelectedTripPast = false
        }
    }

    private func removalCutoffDate(for trip: Trip) -> Date? {
        guard let arrival = TripTimingResolver().resolve(
            trip: trip,
            delayInfo: LiveDelayStore.shared.info(for: trip.id),
            referenceDate: Date(),
            includeProgressDetails: false
        ).adjustedArrival else { return nil }
        let calendar = GTFSDataSource.calendar
        let arrivalDay = calendar.startOfDay(for: arrival)
        return calendar.date(byAdding: .day, value: 1, to: arrivalDay)
    }

    private static let maxConnectionInterval: TimeInterval = 6 * 60 * 60

    private func connectionInfo(between arrivingTrip: Trip, and departingTrip: Trip) -> ConnectionInfo? {
        guard tripsShareStation(arrivingTrip: arrivingTrip, departingTrip: departingTrip) else { return nil }
        guard let arrivalDate = arrivalDateWithDelay(for: arrivingTrip),
              let departureDate = departureDateWithDelay(for: departingTrip) else { return nil }
        let interval = departureDate.timeIntervalSince(arrivalDate)
        guard interval > 0, interval <= Self.maxConnectionInterval else { return nil }
        let stationName = arrivingTrip.destinationName
            ?? departingTrip.originName
            ?? "Connection Station"
        let tightness = tightness(for: interval)
        return ConnectionInfo(
            fromTrip: arrivingTrip,
            toTrip: departingTrip,
            stationName: stationName,
            duration: interval,
            arrivalDate: arrivalDate,
            departureDate: departureDate,
            tightness: tightness
        )
    }

    private func tripsShareStation(arrivingTrip: Trip, departingTrip: Trip) -> Bool {
        if let destId = arrivingTrip.destinationStopId, let originId = departingTrip.originStopId, destId == originId {
            return true
        }
        if let destName = normalizedText(arrivingTrip.destinationName),
           let originName = normalizedText(departingTrip.originName),
           destName == originName {
            return true
        }
        return false
    }

    private func tightness(for interval: TimeInterval) -> ConnectionInfo.Tightness {
        if interval >= 2 * 60 * 60 {
            return .relaxed
        }
        if interval >= 45 * 60 {
            return .tight
        }
        return .risky
    }

    private func normalizedText(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let folded = raw.folding(options: [.diacriticInsensitive], locale: .current)
        return folded.lowercased()
    }

    private func arrivalDateWithDelay(for trip: Trip) -> Date? {
        TripTimingResolver().resolve(
            trip: trip,
            delayInfo: LiveDelayStore.shared.info(for: trip.id),
            referenceDate: Date(),
            includeProgressDetails: false
        ).adjustedArrival
    }

    private func departureDateWithDelay(for trip: Trip) -> Date? {
        TripTimingResolver().resolve(
            trip: trip,
            delayInfo: LiveDelayStore.shared.info(for: trip.id),
            referenceDate: Date(),
            includeProgressDetails: false
        ).adjustedDeparture
    }

    private func tripDuration(for trip: Trip) -> TimeInterval? {
        guard let departure = departureDateWithDelay(for: trip),
              let arrival = arrivalDateWithDelay(for: trip) else { return nil }
        let duration = arrival.timeIntervalSince(departure)
        return duration > 0 ? duration : nil
    }

    private func distanceKilometers(for trip: Trip) -> Double? {
        if let kilometers = distanceKilometersFromStops(for: trip) {
            return kilometers
        }
        return parsedDistanceKilometers(from: trip.detailDistance)
    }

    private func distanceKilometersFromStops(for trip: Trip) -> Double? {
        let sorted = stopsForRide(
            trip.stops,
            originStopID: trip.originStopId,
            destinationStopID: trip.destinationStopId,
            originSequence: trip.originSequence,
            destinationSequence: trip.destinationSequence
        )
        guard sorted.count > 1 else { return nil }
        var totalMeters: CLLocationDistance = 0
        for pair in zip(sorted, sorted.dropFirst()) {
            let start = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let end = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
            totalMeters += start.distance(from: end)
        }
        let kilometers = totalMeters / 1000
        return kilometers > 0 ? kilometers : nil
    }

    private func parsedDistanceKilometers(from value: String?) -> Double? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        return Double(normalized)
    }

    private func normalizedStationKey(id: String?, name: String?) -> String? {
        if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return "id:\(id)"
        }
        guard let name = normalizedText(name) else { return nil }
        return "name:\(name)"
    }

    private func normalizeStationName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func requestPastTripDeletion(_ trip: Trip) {
        pendingPastDeletionTrip = trip
        isShowingPastDeleteConfirmation = true
    }

    private func confirmPastTripDeletion() {
        guard let trip = pendingPastDeletionTrip else { return }
        withAnimation {
            deletePastTrip(trip)
        }
        pendingPastDeletionTrip = nil
        isShowingPastDeleteConfirmation = false
    }

    private func cancelPastTripDeletion() {
        pendingPastDeletionTrip = nil
        isShowingPastDeleteConfirmation = false
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

    @State private var timing = ResolvedTripTiming.empty
    @State private var derivedStops: StopPair?
    @State private var now = Date()
    @State private var liveDelayInfo: DelayInfo?
    private var dataSource: GTFSDataSource { GTFSDataSource.shared }
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
            await loadTiming()
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
            Task { await loadTiming() }
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
        HStack(spacing: 6) {
            OperatorLogoView(logoName: operatorLogoName, size: 18)

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

    private var operatorLogoName: String? {
        OperatorBrandingCatalog.branding(for: trip.agencyId).logoName
    }

    private var terminalTimesRow: some View {
        HStack(spacing: 16) {
            terminalTimeView(
                icon: "arrow.up.right.circle.fill",
                text: formattedTime(adjustedDepartureDate),
                color: timeTint(for: .departure)
            )

            terminalTimeView(
                icon: "arrow.down.right.circle.fill",
                text: formattedTime(adjustedArrivalDate),
                color: timeTint(for: .arrival)
            )

            Spacer(minLength: 0)
        }
    }

    private func terminalTimeView(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(color)
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
        if hasArrived {
            return "Arrived On Time"
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

    private var activeDelayMinutes: Int? {
        timing.headerDelayMinutes ?? trip.delayMinutes
    }

    private var effectiveDelayMinutes: Int {
        activeDelayMinutes ?? 0
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
        timing.adjustedDeparture
    }

    private var adjustedArrivalDate: Date? {
        timing.adjustedArrival
    }

    private func formattedTime(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        return Self.timeFormatter.string(from: date)
    }

    private func timeTint(for type: TerminalEventType) -> Color {
        if displayMode == .scheduled { return .primary }

        let delay = terminalDelayMinutes(for: type) ?? 0
        if delay > 0 { return .red }
        return .green
    }

    private func loadTiming() async {
        ensureDerivedStops()
        let trip = self.trip
        let delayInfo = liveDelayInfo
        let referenceDate = now
        let resolved = TripTimingResolver().resolve(
            trip: trip,
            delayInfo: delayInfo,
            referenceDate: referenceDate,
            includeProgressDetails: false
        )
        guard self.trip.id == trip.id else { return }
        timing = resolved
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = GTFSDataSource.calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = GTFSDataSource.calendar.timeZone
        formatter.dateFormat = "EEE, d MMM"
        return formatter
    }()

    private func terminalDelayMinutes(for type: TerminalEventType) -> Int? {
        switch type {
        case .departure:
            return timing.originDelayMinutes
        case .arrival:
            return timing.destinationDelayMinutes
        }
    }

    private enum TerminalEventType {
        case departure
        case arrival
    }
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

private struct ConnectionRowView: View {
    let info: ConnectionInfo

    var body: some View {
        HStack(spacing: 12) {
            Text("\(info.durationText) at \(info.stationName)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: info.tightness.iconName)
                    .foregroundStyle(info.tightness.tint)
                Text(info.tightness.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(info.tightness.tint)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ConnectionDetailSheet: View {
    let info: ConnectionInfo
    var onDismiss: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    connectionSummary
                    timelineSection
                    tipsSection
                }
                .padding()
            }
            .navigationTitle("Connection")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onDismiss?()
                    }
                }
            }
        }
    }

    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(info.durationText)
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Label(info.tightness.label, systemImage: info.tightness.iconName)
                .font(.headline)
                .foregroundStyle(info.tightness.tint)
            Text("Stay at \(info.stationName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Timeline")
                .font(.headline)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "clock.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    timelineRow(title: info.arrivalTitle, time: info.arrivalTimeText, detail: info.fromTrip.title)
                    timelineRow(title: info.departureTitle, time: info.departureTimeText, detail: info.toTrip.title)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection tips")
                .font(.headline)
            Text(info.tightness.tip)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timelineRow(title: String, time: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(time)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ConnectionInfo: Identifiable {
    enum Tightness {
        case relaxed
        case tight
        case risky

        var label: String {
            switch self {
            case .relaxed: return "Relaxed"
            case .tight: return "Tight"
            case .risky: return "Risky"
            }
        }

        var iconName: String {
            switch self {
            case .relaxed: return "figure.walk"
            case .tight: return "figure.run"
            case .risky: return "exclamationmark.triangle"
            }
        }

        var tint: Color {
            switch self {
            case .relaxed: return .green
            case .tight: return .orange
            case .risky: return .red
            }
        }

        var tip: String {
            switch self {
            case .relaxed:
                return "Plenty of time for a coffee or a lounge visit—watch the boards at your pace."
            case .tight:
                return "Head straight to the next platform and keep essentials handy for a brisk transfer."
            case .risky:
                return "Move quickly, ask staff for help, and be ready with contingency plans."
            }
        }
    }

    let fromTrip: Trip
    let toTrip: Trip
    let stationName: String
    let duration: TimeInterval
    let arrivalDate: Date
    let departureDate: Date
    let tightness: Tightness

    var id: String { "\(fromTrip.id)->\(toTrip.id)" }

    var durationText: String {
        ConnectionInfo.durationFormatter.string(from: duration) ?? "--"
    }

    var arrivalTitle: String {
        "Arrival"
    }

    var departureTitle: String {
        "Departure"
    }

    var arrivalTimeText: String {
        ConnectionInfo.timeFormatter.string(from: arrivalDate)
    }

    var departureTimeText: String {
        ConnectionInfo.timeFormatter.string(from: departureDate)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = GTFSDataSource.calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
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

private struct LogYearSection: Identifiable {
    let year: Int
    let trips: [Trip]

    var id: Int { year }
}

private struct LogYearHeaderView: View {
    let year: Int
    let tripCount: Int

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(year))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(tripCount) \(tripCount == 1 ? "TRIP" : "TRIPS")")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)

            Divider()
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

private struct LogTripRowView: View {
    let trip: Trip
    let showsDivider: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OperatorLogoView(logoName: operatorLogoName, size: 30)
                

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(trainTitle)
                            .font(rowMetaFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(shortRouteText)
                            .font(rowMetaFont)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text(dateText)
                            .font(rowMetaFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    Text(fullRouteText)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                if showsDivider {
                    Divider()
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
        .padding(.bottom, showsDivider ? 0 : 8)
        .padding(.horizontal)
    }

    private var rowMetaFont: Font {
        .system(size: 13, weight: .semibold, design: .rounded)
    }

    private var operatorLogoName: String? {
        OperatorBrandingCatalog.branding(for: trip.agencyId).logoName
    }

    private var trainTitle: String {
        let trimmed = trip.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Train" : trimmed
    }

    private var originName: String {
        firstNonEmpty(
            trip.originName,
            trip.stops?.sorted { $0.sequence < $1.sequence }.first?.name,
            routePartsFromSubtitle?.origin
        ) ?? "Origin"
    }

    private var destinationName: String {
        firstNonEmpty(
            trip.destinationName,
            trip.stops?.sorted { $0.sequence < $1.sequence }.last?.name,
            routePartsFromSubtitle?.destination
        ) ?? "Destination"
    }

    private var shortRouteText: String {
        "\(stationCode(originName)) → \(stationCode(destinationName))"
    }

    private var fullRouteText: String {
        "\(originName) to \(destinationName)"
    }

    private var dateText: String {
        if let travelDate = trip.travelDate {
            return Self.dateFormatter.string(from: travelDate)
        }
        return firstNonEmpty(trip.detailDate) ?? "-"
    }

    private var routePartsFromSubtitle: (origin: String, destination: String)? {
        let separators = ["→", "->", " to "]
        for separator in separators {
            let parts = trip.subtitle.components(separatedBy: separator)
            guard parts.count >= 2 else { continue }
            let origin = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !origin.isEmpty, !destination.isEmpty {
                return (origin, destination)
            }
        }
        return nil
    }

    private func stationCode(_ value: String) -> String {
        let normalized = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .uppercased()
        let letters = normalized.filter { $0.isLetter || $0.isNumber }
        let prefix = String(letters.prefix(3))
        return prefix.isEmpty ? "---" : prefix
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = GTFSDataSource.calendar.timeZone
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
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

private struct LogSummaryMetrics {
    let tripCount: Int
    let totalDistance: Double
    let totalDuration: TimeInterval
    let visitedStationCount: Int

    var distanceText: String {
        guard totalDistance > 0 else { return "—" }
        return "\(Int(totalDistance.rounded())) km"
    }

    var durationText: String {
        guard totalDuration > 0 else { return "—" }
        let totalMinutes = Int((totalDuration / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, minutes > 0 {
            return "\(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
    }
}

private struct LogSummaryCard: View {
    let metrics: LogSummaryMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rail Log")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("All past rides combined")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                LogSummaryTile(title: "Trips", value: "\(metrics.tripCount)", icon: "ticket.fill")
                LogSummaryTile(title: "Distance", value: metrics.distanceText, icon: "point.topleft.down.curvedto.point.bottomright.up")
                LogSummaryTile(title: "Trip Time", value: metrics.durationText, icon: "clock.fill")
                LogSummaryTile(title: "Stations", value: "\(metrics.visitedStationCount)", icon: "mappin.and.ellipse")
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct LogSummaryTile: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = .blue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct UserProfile: Equatable {
    var name: String
    var imageData: Data?
}

private enum UserProfilePreferences {
    private static let nameKey = "raily.profile.name"
    private static let imageDataKey = "raily.profile.imageData"

    static func load() -> UserProfile {
        let storedName = UserDefaults.standard.string(forKey: nameKey)
        let name = storedName == "Gabriel" ? defaultName : (storedName ?? defaultName)
        let imageData = normalizedImageData(UserDefaults.standard.data(forKey: imageDataKey))

        if let imageData {
            UserDefaults.standard.set(imageData, forKey: imageDataKey)
        }

        return UserProfile(
            name: name,
            imageData: imageData
        )
    }

    static func save(_ profile: UserProfile) {
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmedName.isEmpty ? defaultName : trimmedName, forKey: nameKey)
        if let imageData = normalizedImageData(profile.imageData) {
            UserDefaults.standard.set(imageData, forKey: imageDataKey)
        } else {
            UserDefaults.standard.removeObject(forKey: imageDataKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: nameKey)
        UserDefaults.standard.removeObject(forKey: imageDataKey)
    }

    private static let defaultName = "Your Name"

    private static func normalizedImageData(_ data: Data?) -> Data? {
        guard let data, let image = UIImage(data: data) else { return nil }
        return image.resizedForProfile(maxPixelSize: 512).pngData()
    }
}

private struct ProfileAvatarButton: View {
    let profile: UserProfile
    var editAction: () -> Void
    var settingsAction: () -> Void

    var body: some View {
        Menu {
            Button(action: editAction) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                        Text("Edit Profile")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(uiImage: ProfileAvatarRenderer.image(for: profile, size: 28))
                        .renderingMode(.original)
                }
            }

            Button(action: settingsAction) {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            ProfileAvatarView(profile: profile, size: 38)
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
    }

    private var displayName: String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Your Name" : trimmed
    }
}

private enum ProfileAvatarRenderer {
    static func image(for profile: UserProfile, size: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)

        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            let path = UIBezierPath(ovalIn: rect)
            path.addClip()

            if let image = profile.imageData.flatMap(UIImage.init(data:)) {
                drawAspectFill(image, in: rect)
            } else {
                UIColor.tertiarySystemFill.setFill()
                context.fill(rect)

                let symbolConfig = UIImage.SymbolConfiguration(
                    pointSize: max(11, size * 0.48),
                    weight: .semibold
                )
                let symbol = UIImage(systemName: "person.fill", withConfiguration: symbolConfig)?
                    .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
                let symbolSize = symbol?.size ?? .zero
                symbol?.draw(
                    at: CGPoint(
                        x: (size - symbolSize.width) / 2,
                        y: (size - symbolSize.height) / 2
                    )
                )

                /*
                 Keep a text fallback for environments where SF Symbols fail to
                 resolve during image rendering.
                 */
                guard symbol == nil else { return }
                let text = initials(for: profile)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: max(10, size * 0.34), weight: .bold),
                    .foregroundColor: UIColor.secondaryLabel
                ]
                let textSize = text.size(withAttributes: attributes)
                text.draw(
                    at: CGPoint(
                        x: (size - textSize.width) / 2,
                        y: (size - textSize.height) / 2
                    ),
                    withAttributes: attributes
                )
            }
        }
    }

    private static func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect)
    }

    private static func initials(for profile: UserProfile) -> String {
        let words = profile.name
            .split(separator: " ")
            .map(String.init)
        let letters = words.prefix(2).compactMap { $0.first }
        let value = String(letters).uppercased()
        return value.isEmpty ? "YN" : value
    }
}

private struct ProfileAvatarView: View {
    let profile: UserProfile
    let size: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                Image(systemName: "person.fill")
                    .font(.system(size: max(13, size * 0.46), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color(.separator).opacity(0.35), lineWidth: 1)
        }
        .contentShape(Circle())
    }

    private var image: UIImage? {
        guard let data = profile.imageData else { return nil }
        return UIImage(data: data)
    }

    private var initials: String {
        let words = profile.name
            .split(separator: " ")
            .map(String.init)
        let letters = words.prefix(2).compactMap { $0.first }
        let value = String(letters).uppercased()
        return value.isEmpty ? "YN" : value
    }
}

private struct ProfileEditorSheet: View {
    @Binding var profile: UserProfile
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            ProfileAvatarView(profile: profile, size: 72)
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Name", text: nameBinding)
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .textInputAutocapitalization(.words)

                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                Text("Change Picture")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        UserProfilePreferences.save(profile)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onChange(of: selectedPhoto) { _, newValue in
                loadSelectedPhoto(newValue)
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { profile.name },
            set: { newValue in
                profile.name = newValue
                UserProfilePreferences.save(profile)
            }
        )
    }

    private func loadSelectedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            await MainActor.run {
                let normalizedData = UIImage(data: data)?.resizedForProfile(maxPixelSize: 512).pngData()
                profile.imageData = normalizedData
                UserProfilePreferences.save(profile)
            }
        }
    }
}

private extension UIImage {
    func resizedForProfile(maxPixelSize: CGFloat) -> UIImage {
        let maxDimension = max(size.width, size.height)
        guard maxDimension > maxPixelSize else { return self }

        let scale = maxPixelSize / maxDimension
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

private struct SettingsSheet: View {
    @AppStorage(FormationSettings.key) private var formationServer = FormationSettings.defaultServer
    @Binding var trips: [Trip]
    @Binding var pastTrips: [Trip]
    var dismissAction: () -> Void
    @State private var automaticStationDetection = TripLocationDetectionPreferences.isEnabled
    @State private var batterySavingMode = TripLocationDetectionPreferences.batterySavingEnabled
    @State private var continuousSpeedCapsule = TripLocationDetectionPreferences.continuousSpeedCapsuleEnabled
    @State private var missedTrainDebugUI = TripLocationDetectionPreferences.missedTrainDebugUIEnabled
    @State private var missedTrainSimulation = TripLocationDetectionPreferences.missedTrainSimulationEnabled
    @State private var isImporting = false
    @State private var showDeleteAllConfirmation = false
    @State private var importError: String?

    private var exportData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(TripStorage.shared.exportDocument())) ?? Data()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.0.14:3001", text: $formationServer)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Formation server address")
                    if FormationSettings.endpoint(formationServer) == nil {
                        Text("Enter a valid IP address or hostname, optionally with a port.")
                            .font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Train Formation")
                } footer: {
                    Text("Use the server’s local IP address. Port 3001 is used by default.")
                }
                Section {
                    settingRow(
                        title: "Automatic boarding and arrival detection",
                        description: "Uses station proximity, route progress, movement, and GPS to detect when you board or reach your destination.",
                        isOn: $automaticStationDetection
                    )
                    .onChange(of: automaticStationDetection) { _, enabled in
                        TripLocationDetectionPreferences.isEnabled = enabled
                    }
                    settingRow(
                        title: "Save battery",
                        description: "Reduces GPS frequency and disables continuous background location updates. Detection may be less immediate.",
                        isOn: $batterySavingMode
                    )
                    .disabled(!automaticStationDetection)
                    .onChange(of: batterySavingMode) { _, enabled in
                        TripLocationDetectionPreferences.batterySavingEnabled = enabled
                    }
                    settingRow(
                        title: "Always show speed",
                        description: "Keeps your GPS speed visible in the glass capsule. Turn this off to reveal it for two minutes after tapping, which uses less battery.",
                        isOn: $continuousSpeedCapsule
                    )
                    .onChange(of: continuousSpeedCapsule) { _, enabled in
                        TripLocationDetectionPreferences.continuousSpeedCapsuleEnabled = enabled
                    }
                    settingRow(
                        title: "High-confidence arrival detection",
                        description: "Requires two reliable GPS fixes at your destination before confirming arrival, reducing false positives.",
                        isOn: highConfidenceArrivalBinding
                    )
                    .disabled(!automaticStationDetection)
                    settingRow(
                        title: "Missed-train suggestions",
                        description: "Will offer alternative trains when GPS suggests you reached the origin too late. It will not replace your trip automatically.",
                        isOn: missedTrainSuggestionsBinding
                    )
                    .disabled(!automaticStationDetection)
                } header: {
                    Text("Trip Tracking")
                } footer: {
                    Text("All preferences are remembered across launches. Location-based features require permission and work best with precise location enabled.")
                }

                Section {
                    settingRow(
                        title: "Missed-train debug UI",
                        description: "Shows the development status capsule explaining why a missed-train prompt is or is not ready.",
                        isOn: $missedTrainDebugUI
                    )
                    .onChange(of: missedTrainDebugUI) { _, enabled in
                        TripLocationDetectionPreferences.missedTrainDebugUIEnabled = enabled
                    }

                    settingRow(
                        title: "Missed-train simulation mode",
                        description: "Adds a Debug-only action to simulate the confirmation prompt for the selected trip. It never changes the trip automatically.",
                        isOn: $missedTrainSimulation
                    )
                    .onChange(of: missedTrainSimulation) { _, enabled in
                        TripLocationDetectionPreferences.missedTrainSimulationEnabled = enabled
                    }

                    #if DEBUG
                    LiveActivityPreviewControls()
                    #endif

                } header: {
                    Text("Experimental")
                } footer: {
                    Text("Simulation controls are intended for development and testing.")
                }

                Section {
                        ShareLink(item: exportData, preview: SharePreview("Blitz Trips", image: Image(systemName: "tram.fill"))) {
                        Label("Export Trips", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        isImporting = true
                    } label: {
                        Label("Import Trips", systemImage: "square.and.arrow.down")
                    }

                    Button(role: .destructive) {
                        showDeleteAllConfirmation = true
                    } label: {
                        Label("Delete All Data", systemImage: "trash")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Exports include active and past trips, route selections, delay/platform state, seats, tickets, and saved route data. Importing merges records without replacing existing trips.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: dismissAction) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Close Settings")
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                importDocument(result)
            }
            .alert("Delete all data?", isPresented: $showDeleteAllConfirmation) {
                Button("Delete Everything", role: .destructive) { deleteAllData() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes trips, profile data, ticket QR codes, tracking evidence, delay state, preferences, and Live Activities. Bundled schedules stay on this device.")
            }
            .alert("Import failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "The selected file is not a valid Blitz export.")
            }
        }
    }

    private func settingRow(title: String, description: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    private var highConfidenceArrivalBinding: Binding<Bool> {
        Binding(
            get: { TripLocationDetectionPreferences.highConfidenceArrivalEnabled },
            set: { TripLocationDetectionPreferences.highConfidenceArrivalEnabled = $0 }
        )
    }

    private var missedTrainSuggestionsBinding: Binding<Bool> {
        Binding(
            get: { TripLocationDetectionPreferences.missedTrainSuggestionsEnabled },
            set: { TripLocationDetectionPreferences.missedTrainSuggestionsEnabled = $0 }
        )
    }

    private func importDocument(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(TripExportDocument.self, from: data)
            guard document.schemaVersion == 1 else {
                importError = "This export version is not supported."
                return
            }
            let merged = TripStorage.shared.merge(document)
            trips = merged.active
            pastTrips = merged.past
        } catch {
            importError = "Choose a Blitz JSON export file."
        }
    }

    private func deleteAllData() {
        for trip in trips {
            LiveActivityManager.shared.endActivity(for: trip.id)
        }
        for trip in pastTrips {
            LiveActivityManager.shared.endActivity(for: trip.id)
        }
        LiveActivityManager.shared.endAllActivities()
        TripStorage.shared.deleteAllData()
        LiveDelayStore.shared.clearAll()
        TripDelayFusionStore.shared.clearAll()
        trips = []
        pastTrips = []
        UserProfilePreferences.clear()
    }

}

private struct TrainspotterDiaryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    var uicNumber: String
    var locomotive: String
    var formation: String
    var livery: String
    var station: String
    var notes: String
}

private enum TrainspotterDiaryStore {
    private static let key = "raily.trainspotter.diary"

    static func load() -> [TrainspotterDiaryEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([TrainspotterDiaryEntry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ entries: [TrainspotterDiaryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private struct TrainspotterDiaryView: View {
    @State private var entries = TrainspotterDiaryStore.load()
    @State private var isShowingEntryForm = false

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("Trainspotter Diary", systemImage: "binoculars.fill")
                    } description: {
                        Text("Record trains, locomotives, and sightings locally. Nothing is shared unless you choose to share it later.")
                    } actions: {
                        Button("Add First Sighting") {
                            isShowingEntryForm = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(entries) { entry in
                            TrainspotterEntryRow(entry: entry)
                        }
                        .onDelete { offsets in
                            entries.remove(atOffsets: offsets)
                            TrainspotterDiaryStore.save(entries)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Trainspotter")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingEntryForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add train sighting")
                }
            }
            .sheet(isPresented: $isShowingEntryForm) {
                TrainspotterEntryForm { entry in
                    entries.insert(entry, at: 0)
                    TrainspotterDiaryStore.save(entries)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

private struct TrainspotterEntryRow: View {
    let entry: TrainspotterDiaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.uicNumber.isEmpty ? "Unidentified train" : entry.uicNumber)
                    .font(.headline)
                Spacer()
                Text(entry.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !entry.locomotive.isEmpty || !entry.formation.isEmpty {
                Text([entry.locomotive, entry.formation].filter { !$0.isEmpty }.joined(separator: " • "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !entry.station.isEmpty {
                Label(entry.station, systemImage: "mappin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !entry.notes.isEmpty {
                Text(entry.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TrainspotterEntryForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var uicNumber = ""
    @State private var locomotive = ""
    @State private var formation = ""
    @State private var livery = ""
    @State private var station = ""
    @State private var notes = ""
    let onSave: (TrainspotterDiaryEntry) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Identification") {
                    TextField("UIC number", text: $uicNumber)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Locomotive details", text: $locomotive)
                    TextField("Wagon formation", text: $formation)
                    TextField("Livery", text: $livery)
                }
                Section("Context") {
                    TextField("Station or route", text: $station)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section {
                    Text("Entries are saved locally. UIC camera recognition, photos, ratings, and optional sharing will be added in later steps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Sighting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(TrainspotterDiaryEntry(
                            id: UUID(),
                            createdAt: Date(),
                            uicNumber: uicNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                            locomotive: locomotive.trimmingCharacters(in: .whitespacesAndNewlines),
                            formation: formation.trimmingCharacters(in: .whitespacesAndNewlines),
                            livery: livery.trimmingCharacters(in: .whitespacesAndNewlines),
                            station: station.trimmingCharacters(in: .whitespacesAndNewlines),
                            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                        dismiss()
                    }
                }
            }
        }
    }
}

private enum MainSheetTab: String, Identifiable {
    case trips
    case friends
    case log
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trips: return "My Trips"
        case .friends: return "Friends"
        case .log: return "Log"
        case .search: return "Search"
        }
    }

    var icon: String {
        switch self {
        case .trips: return "tram.fill"
        case .friends: return "person.2.fill"
        case .log: return "book.closed.fill"
        case .search: return "magnifyingglass"
        }
    }
}

private struct TrainNumberSearchInput: View {
    let focusNonce: Int
    let onSearch: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Search train or operator", text: $text)
            .textFieldStyle(.plain)
            // Swiss train numbers are reused across operators, so allow an
            // optional operator prefix such as "IC1 728".
            .keyboardType(.asciiCapable)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
            .focused($isFocused)
            .onAppear {
                isFocused = true
            }
            .onChange(of: focusNonce) { _, _ in
                text = ""
                isFocused = true
            }
            .onChange(of: text) { _, newValue in
                let cleaned = String(newValue.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" })
                    .uppercased()
                if cleaned != newValue {
                    text = cleaned
                }
            }
            .onSubmit {
                onSearch(text)
            }
            .submitLabel(.search)
    }
}

private struct SearchSuggestionRow: View {
    let trip: Trip

    private var routeCode: String {
        trip.title.split(separator: " ").first.map(String.init) ?? trip.title
    }

    private var headsign: String {
        trip.destinationName ?? trip.subtitle
    }

    var body: some View {
        HStack(spacing: 12) {
            OperatorLogoView(
                logoName: OperatorBrandingCatalog.branding(for: trip.agencyId).logoName,
                size: 34
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(routeCode)
                    .font(.headline)
                Text(headsign)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
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
    case results

    var title: String {
        switch self {
        case .search: return "Add Trip"
        case .date: return "Add Date"
        case .origin: return "Add Origin"
        case .destination: return "Add Destination"
        case .results: return "Choose Departure"
        }
    }

    var placeholder: String {
        switch self {
        case .search: return "Search train number"
        case .origin: return "Search origin station"
        case .destination: return "Search destination station"
        case .date: return ""
        case .results: return ""
        }
    }

    var showsTextField: Bool {
        switch self {
        case .date, .results: return false
        default: return true
        }
    }
}


/// A month grid with service availability decorations and only valid selectable days.
private struct ServiceAvailabilityCalendar: View {
    let trip: Trip
    let query: String?
    @Binding var selectedDate: Date
    @Binding var isSelectedDateAvailable: Bool
    @State private var month: Date
    @State private var availableDates: Set<Date> = []
    @State private var isLoading = true

    init(trip: Trip, query: String?, selectedDate: Binding<Date>, isSelectedDateAvailable: Binding<Bool>) {
        self.trip = trip
        self.query = query
        self._selectedDate = selectedDate
        self._isSelectedDateAvailable = isSelectedDateAvailable
        self._month = State(initialValue: GTFSDataSource.calendar.dateInterval(of: .month, for: selectedDate.wrappedValue)!.start)
    }

    private var calendar: Calendar { GTFSDataSource.calendar }
    private var dates: [Date?] {
        let start = calendar.dateInterval(of: .month, for: month)!.start
        let padding = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: start)!.count
        return Array(repeating: nil, count: padding) + (0..<count).map {
            calendar.date(byAdding: .day, value: $0, to: start)
        }
    }
    private var weekdayNames: [String] {
        let names = calendar.veryShortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(names[offset...]) + Array(names[..<offset])
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous month")
                Spacer()
                Text(month.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.wide).year()))
                    .font(.headline)
                Spacer()
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next month")
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    Text(weekdayNames[index]).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(dates.indices, id: \.self) { index in
                    if let date = dates[index] {
                        let available = !isLoading && availableDates.contains(date)
                        let selected = available && calendar.isDate(date, inSameDayAs: selectedDate)
                        Button {
                            selectedDate = date
                            isSelectedDateAvailable = true
                        } label: {
                            VStack(spacing: 3) {
                                Text(String(calendar.component(.day, from: date)))
                                    .font(.body.weight(selected ? .bold : .regular))
                                    .foregroundStyle(selected ? Color.white : (available ? Color.primary : Color.secondary.opacity(0.4)))
                                Circle()
                                    .fill(selected ? Color.white : Color.green)
                                    .frame(width: 5, height: 5)
                                    .opacity(available ? 1 : 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(!available)
                        .accessibilityLabel(date.formatted(date: .complete, time: .omitted) + (available ? ", service available" : ", service unavailable"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.small)
                    Text("Checking available dates…")
                } else {
                    Circle().fill(.green).frame(width: 5, height: 5)
                    Text(availableDates.isEmpty ? "No services this month" : "Service available")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .task(id: month) {
            isLoading = true
            isSelectedDateAvailable = false
            let requestedMonth = month
            let task = Task.detached(priority: .userInitiated) { [trip, query] in
                GTFSDataSource.shared.availableBoardingDates(for: trip, matching: query, month: requestedMonth)
            }
            let result = await task.value
            guard !Task.isCancelled else { return }
            availableDates = result
            isLoading = false
            isSelectedDateAvailable = result.contains(calendar.startOfDay(for: selectedDate))
        }
    }

    private func moveMonth(_ offset: Int) {
        guard let next = calendar.date(byAdding: .month, value: offset, to: month) else { return }
        isLoading = true
        isSelectedDateAvailable = false
        month = next
    }
}
