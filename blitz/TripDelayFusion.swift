import Foundation

enum TripDelayPredictionSource: String, Codable {
    case infoFerConfirmed = "InfoFer confirmed"
    case gpsEstimated = "GPS estimated"
    case awaitingNextStationUpdate = "Awaiting next station update"
}

struct TripDelayPrediction: Equatable, Codable {
    let predictedArrival: Date?
    let delayMinutes: Int?
    let source: TripDelayPredictionSource
    let updatedAt: Date
}

final class TripDelayFusionStore {
    static let shared = TripDelayFusionStore()

    private static let infoFerFreshnessWindow: TimeInterval = 15 * 60

    private let key = "raily.tripDetection.delayPredictions"
    private var predictions: [String: TripDelayPrediction]

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: TripDelayPrediction].self, from: data) {
            predictions = decoded
        } else {
            predictions = [:]
        }
    }

    func prediction(for trip: Trip) -> TripDelayPrediction? {
        guard let prediction = predictions[stateKey(for: trip)] else { return nil }
        guard prediction.source == .infoFerConfirmed else { return prediction }

        // A persisted InfoFer estimate must not remain authoritative forever.
        // Once it is stale, expose a neutral state until GPS progress or a
        // new station update supplies better evidence.
        guard Date().timeIntervalSince(prediction.updatedAt) <= Self.infoFerFreshnessWindow else {
            return TripDelayPrediction(
                predictedArrival: nil,
                delayMinutes: nil,
                source: .awaitingNextStationUpdate,
                updatedAt: prediction.updatedAt
            )
        }
        return prediction
    }

    func update(
        trip: Trip,
        progress: TripGPSProgress?,
        timing: ResolvedTripTiming,
        infoFer: DelayInfo?,
        now: Date = Date()
    ) {
        let tripKey = stateKey(for: trip)
        let freshInfoFer: DelayInfo? = {
            guard let infoFer,
                  let fetchedAt = infoFer.fetchedAt,
                  now.timeIntervalSince(fetchedAt) <= Self.infoFerFreshnessWindow else {
                return nil
            }
            return infoFer
        }()

        if let confirmedDelay = freshInfoFer?.delayMinutes {
            predictions[tripKey] = TripDelayPrediction(
                predictedArrival: timing.adjustedArrival,
                delayMinutes: confirmedDelay,
                source: .infoFerConfirmed,
                updatedAt: now
            )
        } else if let progress, let scheduledDeparture = timing.scheduledDeparture,
                  let scheduledArrival = timing.scheduledArrival,
                  progress.fraction > 0, progress.fraction < 1,
                  now >= scheduledDeparture {
            let scheduledDuration = max(scheduledArrival.timeIntervalSince(scheduledDeparture), 60)
            let expectedElapsed = scheduledDuration * progress.fraction
            let expectedNow = scheduledDeparture.addingTimeInterval(expectedElapsed)
            let estimatedDelay = Int((now.timeIntervalSince(expectedNow) / 60).rounded())
            let predictedArrival = now.addingTimeInterval(scheduledDuration * (1 - progress.fraction))
            predictions[tripKey] = TripDelayPrediction(
                predictedArrival: predictedArrival,
                delayMinutes: estimatedDelay,
                source: .gpsEstimated,
                updatedAt: now
            )
        } else {
            predictions[tripKey] = TripDelayPrediction(
                predictedArrival: timing.scheduledArrival,
                delayMinutes: nil,
                source: .awaitingNextStationUpdate,
                updatedAt: now
            )
        }
        persist()
    }

    func remove(tripIDs: Set<String>) {
        predictions = predictions.filter { entry in
            !tripIDs.contains(where: { entry.key.hasPrefix("\($0)|") })
        }
        persist()
    }

    func clearAll() {
        predictions.removeAll()
        persist()
    }

    private func stateKey(for trip: Trip) -> String {
        let day = trip.travelDate.map { ISO8601DateFormatter().string(from: $0).prefix(10) } ?? "undated"
        return "\(trip.id)|\(day)"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(predictions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
