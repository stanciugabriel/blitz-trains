import SwiftUI
import CoreLocation
import Combine
import PhotosUI
internal import UIKit


struct SheetContent: View {
    @Binding var trips: [Trip]
    @Binding var selectedTrip: Trip?
    @Binding var isAddTripMode: Bool
    @Binding var trainSearchQuery: String
    @Binding var pastTrips: [Trip]
    var onTripAdded: (Trip) -> Void

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
    

    private let dataSource = GTFSDataSource.shared
    private let pruneTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init(
        trips: Binding<[Trip]>,
        selectedTrip: Binding<Trip?>,
        isAddTripMode: Binding<Bool>,
        trainSearchQuery: Binding<String>,
        pastTrips: Binding<[Trip]> = .constant([]),
        onTripAdded: @escaping (Trip) -> Void = { _ in }
    ) {
        self._trips = trips
        self._selectedTrip = selectedTrip
        self._isAddTripMode = isAddTripMode
        self._trainSearchQuery = trainSearchQuery
        self._pastTrips = pastTrips
        self.onTripAdded = onTripAdded
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
        .onChange(of: trainSearchQuery) { _, newValue in
            guard isAddTripMode, addStep == .search else { return }
            performTrainSearch(query: newValue)
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
            SettingsSheet {
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
        if let trip = selectedTrip {
            TripDetailSheet(
                trip: trip,
                pastTrips: pastTrips,
                isPastTrip: isSelectedTripPast,
                onClose: exitDetailView,
                onUpdateTrip: handleTripUpdate
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

                    LogDelaySummaryCard(metrics: logDelaySummaryMetrics)
                        .padding(.horizontal)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
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
            VStack(spacing: 12) {
                randomTripButton
                searchResultsPanel
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
            SearchPlaceholderView(text: "Type a train number to look up schedules.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchResults.isEmpty {
            SearchPlaceholderView(text: "No trains found for \"\(trainSearchQuery)\"")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }

    private func addRandomTrip() {
        guard !isGeneratingRandomTrip else { return }
        isGeneratingRandomTrip = true
        defer { isGeneratingRandomTrip = false }
        guard let newTrip = generateRandomActiveTrip() else { return }
        trips.append(newTrip)
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
        let calendar = Calendar.current
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
        selectedTrip != nil && !isAddTripMode
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
        isTextFieldFocused = false
        pendingSearchAutofocus = true
        searchFocusNonce += 1
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
            travelDate: selectedDate,
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

        let shouldAddToLog = Calendar.current.startOfDay(for: selectedDate) < Calendar.current.startOfDay(for: Date())
        if shouldAddToLog {
            archiveTrips([savedTrip])
            isSelectedTripPast = false
            selectedTrip = nil
            selectedMainTab = .log
            isAddTripMode = false
            showLogAddedToast()
        } else {
            if !trips.contains(where: { $0.id == savedTrip.id }) {
                trips.append(savedTrip)
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
        return Calendar.current.component(.year, from: date)
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

    private var logDelaySummaryMetrics: LogDelaySummaryMetrics {
        var delayedTrips = 0
        var earlyTrips = 0
        var onTimeTrips = 0
        var totalLateMinutes = 0
        var worstDelayMinutes = 0

        for trip in pastTrips {
            let delay = arrivalDelayMinutes(for: trip)
            if delay > 0 {
                delayedTrips += 1
                totalLateMinutes += delay
                worstDelayMinutes = max(worstDelayMinutes, delay)
            } else if delay < 0 {
                earlyTrips += 1
            } else {
                onTimeTrips += 1
            }
        }

        return LogDelaySummaryMetrics(
            tripCount: pastTrips.count,
            delayedTrips: delayedTrips,
            earlyTrips: earlyTrips,
            onTimeTrips: onTimeTrips,
            totalLateMinutes: totalLateMinutes,
            worstDelayMinutes: worstDelayMinutes
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
            isSelectedTripPast = false
        }
    }

    private func removalCutoffDate(for trip: Trip) -> Date? {
        guard let arrival = arrivalDateWithDelay(for: trip) else { return nil }
        let calendar = Calendar.current
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
        guard let travelDate = trip.travelDate else { return nil }
        guard let destinationId = trip.destinationStopId else { return nil }

        let base = Calendar.current.startOfDay(for: travelDate)
        let identifier = trip.gtfsTripId ?? trip.id
        guard let destinationSchedule = dataSource.stopSchedule(for: identifier, stopId: destinationId) else { return nil }

        var departureReference: Date?
        if let originId = trip.originStopId,
           let originSchedule = dataSource.stopSchedule(for: identifier, stopId: originId) {
            departureReference = originSchedule.departureDate(on: base) ?? originSchedule.arrivalDate(on: base)
        }

        guard let rawArrival = destinationSchedule.arrivalDate(on: base) ?? destinationSchedule.departureDate(on: base) else { return nil }
        guard let arrival = ScheduleDateUtils.normalizedArrival(rawArrival, relativeTo: departureReference) else { return nil }
        let delaySeconds = TimeInterval((trip.delayMinutes ?? 0) * 60)
        return arrival.addingTimeInterval(delaySeconds)
    }

    private func departureDateWithDelay(for trip: Trip) -> Date? {
        guard let travelDate = trip.travelDate else { return nil }
        guard let originId = trip.originStopId else { return nil }

        let base = Calendar.current.startOfDay(for: travelDate)
        let identifier = trip.gtfsTripId ?? trip.id
        guard let originSchedule = dataSource.stopSchedule(for: identifier, stopId: originId) else { return nil }
        guard let departure = originSchedule.departureDate(on: base) ?? originSchedule.arrivalDate(on: base) else { return nil }
        let delaySeconds = TimeInterval((trip.delayMinutes ?? 0) * 60)
        return departure.addingTimeInterval(delaySeconds)
    }

    private func arrivalDelayMinutes(for trip: Trip) -> Int {
        let liveInfo = LiveDelayStore.shared.info(for: trip.id)
        let activeDelay = liveInfo?.delayMinutes ?? trip.delayMinutes
        let arrivalDelay = destinationStop(for: trip)?.arrivalDelayMinutes
            ?? destinationStationDelay(from: liveInfo, for: trip)?.arrivalDelayMinutes

        if let activeDelay {
            return activeDelay
        }

        return arrivalDelay ?? 0
    }

    private func destinationStationDelay(from info: DelayInfo?, for trip: Trip) -> StationDelay? {
        guard let info else { return nil }
        let targetName = trip.destinationName ?? destinationStop(for: trip)?.name ?? trip.stops?.sorted { $0.sequence < $1.sequence }.last?.name
        if let targetName {
            let normalizedTarget = normalizeStationName(targetName)
            if let match = info.stationDelays.first(where: { normalizeStationName($0.stationName) == normalizedTarget }) {
                return match
            }
        }
        return info.stationDelays.last
    }

    private func originStop(for trip: Trip) -> StoredStop? {
        guard let stops = trip.stops else { return nil }
        if let id = trip.originStopId, let stop = stops.first(where: { $0.id == id }) {
            return stop
        }
        if let sequence = trip.originSequence, let stop = stops.first(where: { $0.sequence == sequence }) {
            return stop
        }
        return nil
    }

    private func destinationStop(for trip: Trip) -> StoredStop? {
        guard let stops = trip.stops else { return nil }
        if let id = trip.destinationStopId, let stop = stops.first(where: { $0.id == id }) {
            return stop
        }
        if let sequence = trip.destinationSequence, let stop = stops.first(where: { $0.sequence == sequence }) {
            return stop
        }
        return nil
    }

    private func tripDuration(for trip: Trip) -> TimeInterval? {
        guard let departure = departureDateWithDelay(for: trip),
              let arrival = arrivalDateWithDelay(for: trip) else { return nil }
        let duration = arrival.timeIntervalSince(departure)
        return duration > 0 ? duration : nil
    }

    private func distanceKilometers(for trip: Trip) -> Double? {
        if let parsed = parsedDistanceKilometers(from: trip.detailDistance) {
            return parsed
        }
        return distanceKilometersFromStops(for: trip)
    }

    private func distanceKilometersFromStops(for trip: Trip) -> Double? {
        guard let stops = trip.stops, stops.count > 1 else { return nil }
        let sorted = stops.sorted { $0.sequence < $1.sequence }
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
        liveDelayInfo?.delayMinutes ?? trip.delayMinutes
    }

    private var effectiveDelayMinutes: Int {
        activeDelayMinutes ?? 0
    }

    private var orderedStops: [StoredStop] {
        trip.stops?.sorted(by: { $0.sequence < $1.sequence }) ?? []
    }

    private var originStoredStop: StoredStop? {
        storedStop(for: trip.originStopId, sequence: trip.originSequence, fallback: orderedStops.first)
    }

    private var destinationStoredStop: StoredStop? {
        storedStop(for: trip.destinationStopId, sequence: trip.destinationSequence, fallback: orderedStops.last)
    }

    private var departureStationDepartureDelayMinutes: Int? {
        originStoredStop?.departureDelayMinutes
            ?? stationDelayFromLiveInfo(for: .departure)?.departureDelayMinutes
    }

    private var arrivalStationArrivalDelayMinutes: Int? {
        destinationStoredStop?.arrivalDelayMinutes
            ?? stationDelayFromLiveInfo(for: .arrival)?.arrivalDelayMinutes
    }

    private var shouldApplyHeaderDelayToEntireTrip: Bool {
        departureStationDepartureDelayMinutes == nil && activeDelayMinutes != nil
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
        return applyDelay(to: date, minutes: terminalDelayMinutes(for: .departure))
    }

    private var adjustedArrivalDate: Date? {
        guard let date = timing.arrivalDate else { return nil }
        return applyDelay(to: date, minutes: terminalDelayMinutes(for: .arrival))
    }

    private func applyDelay(to date: Date, minutes: Int?) -> Date {
        guard let minutes, minutes != 0 else { return date }
        return date.addingTimeInterval(TimeInterval(minutes * 60))
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
        let rawArrival = destinationSchedule?.arrivalDate(on: base) ?? destinationSchedule?.departureDate(on: base)
        let arrival = ScheduleDateUtils.normalizedArrival(rawArrival, relativeTo: departure)
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

    private func terminalDelayMinutes(for type: TerminalEventType) -> Int? {
        switch type {
        case .departure:
            if let stationDelay = departureStationDepartureDelayMinutes {
                return stationDelay
            }
            return activeDelayMinutes
        case .arrival:
            if shouldApplyHeaderDelayToEntireTrip {
                return activeDelayMinutes
            }
            if let stationDelay = arrivalStationArrivalDelayMinutes {
                return stationDelay
            }
            return activeDelayMinutes
        }
    }

    private func stationDelayFromLiveInfo(for type: TerminalEventType) -> StationDelay? {
        guard let info = liveDelayInfo else { return nil }
        let targetName: String?
        switch type {
        case .departure:
            targetName = trip.originName ?? originStoredStop?.name ?? orderedStops.first?.name
        case .arrival:
            targetName = trip.destinationName ?? destinationStoredStop?.name ?? orderedStops.last?.name
        }
        if let name = targetName {
            let normalizedName = normalizeStationName(name)
            if let match = info.stationDelays.first(where: { normalizeStationName($0.stationName) == normalizedName }) {
                return match
            }
        }
        switch type {
        case .departure:
            return info.stationDelays.first
        case .arrival:
            return info.stationDelays.last
        }
    }

    private func storedStop(for stopId: String?, sequence: Int?, fallback: StoredStop?) -> StoredStop? {
        if let stopId, let stop = orderedStops.first(where: { $0.id == stopId }) {
            return stop
        }
        if let sequence, let stop = orderedStops.first(where: { $0.sequence == sequence }) {
            return stop
        }
        return fallback
    }

    private func normalizeStationName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
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

private struct LogDelaySummaryMetrics {
    let tripCount: Int
    let delayedTrips: Int
    let earlyTrips: Int
    let onTimeTrips: Int
    let totalLateMinutes: Int
    let worstDelayMinutes: Int

    var delayedShareText: String {
        percentageText(for: delayedTrips)
    }

    var earlyShareText: String {
        percentageText(for: earlyTrips)
    }

    var onTimeShareText: String {
        percentageText(for: onTimeTrips)
    }

    var averageLateText: String {
        guard delayedTrips > 0 else { return "—" }
        return "\(Int((Double(totalLateMinutes) / Double(delayedTrips)).rounded()))m"
    }

    var totalDelayText: String {
        guard totalLateMinutes > 0 else { return "—" }
        return formattedDuration(minutes: totalLateMinutes)
    }

    var worstDelayText: String {
        guard worstDelayMinutes > 0 else { return "—" }
        return "+\(worstDelayMinutes)m"
    }

    private func percentageText(for count: Int) -> String {
        guard tripCount > 0 else { return "0%" }
        let percent = Int((Double(count) / Double(tripCount) * 100).rounded())
        return "\(percent)%"
    }

    private func formattedDuration(minutes: Int) -> String {
        if minutes >= 24 * 60 {
            let days = minutes / (24 * 60)
            let hours = (minutes % (24 * 60)) / 60
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }

        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return remainingMinutes > 0 ? "\(hours)h \(remainingMinutes)m" : "\(hours)h"
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

private struct LogDelaySummaryCard: View {
    let metrics: LogDelaySummaryMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Delay Pattern")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("Arrival outcomes across past rides")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "clock.badge.exclamationmark.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                DelayOutcomePill(title: "Late", value: metrics.delayedShareText, color: .red)
                DelayOutcomePill(title: "On Time", value: metrics.onTimeShareText, color: .green)
                DelayOutcomePill(title: "Early", value: metrics.earlyShareText, color: .blue)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                LogSummaryTile(title: "Late Rides", value: "\(metrics.delayedTrips)", icon: "exclamationmark.triangle.fill", tint: .red)
                LogSummaryTile(title: "Avg Late", value: metrics.averageLateText, icon: "clock.arrow.circlepath", tint: .orange)
                LogSummaryTile(title: "Total Delay", value: metrics.totalDelayText, icon: "sum", tint: .red)
                LogSummaryTile(title: "Worst Delay", value: metrics.worstDelayText, icon: "clock.badge.exclamationmark.fill", tint: .red)
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

private struct DelayOutcomePill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
    var dismissAction: () -> Void

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
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
