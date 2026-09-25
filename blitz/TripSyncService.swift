import Foundation

enum TripSyncStatus: Equatable {
    case updated
    case mapOnly
    case stale
    case unavailable

    var detailText: String {
        switch self {
        case .updated: return "Live InfoFer data updated"
        case .mapOnly: return "Route map updated — delay data is unchanged"
        case .stale: return "InfoFer unavailable — showing last confirmed data"
        case .unavailable: return "InfoFer data unavailable"
        }
    }

    static func resolve(hasDelayEvidence: Bool, hasMapEvidence: Bool, hasPreviousSnapshot: Bool) -> TripSyncStatus {
        if hasDelayEvidence { return .updated }
        if hasMapEvidence { return .mapOnly }
        return hasPreviousSnapshot ? .stale : .unavailable
    }
}

struct TripSyncResult {
    let trip: Trip
    let info: DelayInfo
    let mapInfo: InfoFerMapInfo
    let status: TripSyncStatus
}

@MainActor
final class TripSyncService {
    static let shared = TripSyncService()

    private let dataSource = GTFSDataSource.shared

    private init() {}

    func sync(trip: Trip, shouldFetchMapInfo: Bool) async -> TripSyncResult? {
        // The Swiss timetable has no live provider. Never send Swiss train numbers to InfoFer.
        guard GTFSDataSource.supportsInfoFer, let trainNumber = trip.resolvedTrainNumber else { return nil }
        let previousInfo = LiveDelayStore.shared.info(for: trip.id)

        await InfoFerSessionManager.shared.refreshSession(for: trainNumber)
        let fetchedInfo = await InfoFerScraper.shared.fetchDelay(
            for: trainNumber,
            travelDate: trip.travelDate ?? Date()
        )

        let mapInfo = shouldFetchMapInfo
            ? await fetchMapInfo(for: trainNumber, trip: trip)
            : emptyMapInfo
        let hasDelayEvidence = fetchedInfo.delayMinutes != nil
            || fetchedInfo.platform != nil
            || !fetchedInfo.stationDelays.isEmpty
        let hasMapEvidence = !mapInfo.routePolylines.isEmpty || mapInfo.liveCoordinate != nil
        let status = TripSyncStatus.resolve(
            hasDelayEvidence: hasDelayEvidence,
            hasMapEvidence: hasMapEvidence,
            hasPreviousSnapshot: previousInfo != nil
        )
        var info = hasDelayEvidence ? fetchedInfo : (previousInfo ?? fetchedInfo)
        if let liveCoordinate = mapInfo.liveCoordinate {
            info = info.updatingLiveCoordinate(liveCoordinate)
        }

        var updatedTrip = trip
        if let stops = applyStationDelays(from: info, to: updatedTrip) {
            updatedTrip = updatedTrip.updatingStops(stops)
        }

        if updatedTrip.routePolylines?.isEmpty != false, !mapInfo.routePolylines.isEmpty {
            updatedTrip = updatedTrip.updatingRoutePolylines(mapInfo.routePolylines)
        }

        if mapInfo.gpsPermanentlyUnavailable, !updatedTrip.infoFerGPSUnavailable {
            updatedTrip = updatedTrip.updatingInfoFerGPSUnavailable(true)
        } else if mapInfo.liveCoordinate != nil, updatedTrip.infoFerGPSUnavailable {
            updatedTrip = updatedTrip.updatingInfoFerGPSUnavailable(false)
        }

        LiveDelayStore.shared.save(info: info, for: trip.id)
        LiveActivityManager.shared.updateActivity(for: updatedTrip, delayInfo: info)
        return TripSyncResult(trip: updatedTrip, info: info, mapInfo: mapInfo, status: status)
    }

    private var emptyMapInfo: InfoFerMapInfo {
        InfoFerMapInfo(routePolylines: [], liveCoordinate: nil, gpsPermanentlyUnavailable: false)
    }

    private func fetchMapInfo(for trainNumber: String, trip: Trip) async -> InfoFerMapInfo {
        let needsRoutePolyline = trip.routePolylines?.isEmpty != false
        let shouldRefreshGPS = !trip.infoFerGPSUnavailable
        guard needsRoutePolyline || shouldRefreshGPS,
              let departureDate = serviceDepartureDate(for: trip) else {
            return emptyMapInfo
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return await InfoFerScraper.shared.fetchMapInfo(
            for: trainNumber,
            travelDate: trip.travelDate ?? departureDate,
            departureTime: formatter.string(from: departureDate)
        )
    }

    private func serviceDepartureDate(for trip: Trip) -> Date? {
        let travelDate = trip.travelDate ?? Date()
        let identifier = trip.gtfsTripId ?? trip.id
        let segments = dataSource.segments(for: identifier)
        guard let first = segments.min(by: {
            ($0.departureSeconds ?? $0.arrivalSeconds ?? Int.max)
                < ($1.departureSeconds ?? $1.arrivalSeconds ?? Int.max)
        }), let seconds = first.departureSeconds ?? first.arrivalSeconds else {
            return nil
        }
        return Calendar.current.startOfDay(for: travelDate)
            .addingTimeInterval(TimeInterval(seconds))
    }

    private func applyStationDelays(from info: DelayInfo, to trip: Trip) -> [StoredStop]? {
        guard let storedStops = trip.stops, !storedStops.isEmpty else { return nil }
        var delays: [String: StationDelay] = [:]
        for detail in info.stationDelays {
            delays[normalizedStationName(detail.stationName)] = detail
        }

        var updatedStops = storedStops
        var changed = false
        for index in updatedStops.indices {
            guard let detail = delays[normalizedStationName(updatedStops[index].name)] else { continue }
            if updatedStops[index].arrivalDelayMinutes != detail.arrivalDelayMinutes {
                updatedStops[index].arrivalDelayMinutes = detail.arrivalDelayMinutes
                changed = true
            }
            if updatedStops[index].departureDelayMinutes != detail.departureDelayMinutes {
                updatedStops[index].departureDelayMinutes = detail.departureDelayMinutes
                changed = true
            }
            if updatedStops[index].platform != detail.platform {
                updatedStops[index].platform = detail.platform
                changed = true
            }
        }
        return changed ? updatedStops : nil
    }

    private func normalizedStationName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
