import CoreLocation

/// Shape distances use the feed's units, shared by shapes and stop_times.
/// Stop sequences, rather than station IDs, distinguish repeat station visits.
nonisolated struct GTFSRouteGeometry: Sendable {
    struct Point: Sendable {
        let latitude: Double
        let longitude: Double
        let distance: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    let stops: [GTFSStop]
    private let points: [Point]
    private let stopDistances: [Int: Double]

    var hasShape: Bool { !points.isEmpty }

    init(stops: [GTFSStop], points: [Point], stopDistances: [Int: Double]) {
        self.stops = stops
        let validPoints = points.count > 1 && points.allSatisfy {
            $0.latitude.isFinite && $0.longitude.isFinite && $0.distance.isFinite &&
            (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) && $0.distance >= 0
        } && zip(points, points.dropFirst()).allSatisfy { $0.distance <= $1.distance } &&
            (points.last?.distance ?? 0) > (points.first?.distance ?? 0)
        let distances = stops.compactMap { stopDistances[$0.sequence] }
        var alignedDistances = stopDistances
        // mini_feed simplifies the shape but retains stop distances measured
        // before simplification (e.g. 4,166.79 m of stops vs 4,165.32 m of shape).
        // Align those distance scales only when the endpoint discrepancy is small.
        if let start = points.first?.distance, let end = points.last?.distance,
           let stopStart = distances.first, let stopEnd = distances.last,
           stopEnd > stopStart, end > start,
           stopStart < start || stopEnd > end {
            let tolerance = max(5, (end - start) * 0.01)
            if abs(stopStart - start) <= tolerance, abs(stopEnd - end) <= tolerance {
                alignedDistances = stopDistances.mapValues { start + ($0 - stopStart) * (end - start) / (stopEnd - stopStart) }
            }
        }
        let aligned = stops.compactMap { alignedDistances[$0.sequence] }
        let validStops = aligned.count == stops.count && aligned.allSatisfy(\.isFinite) &&
            zip(aligned, aligned.dropFirst()).allSatisfy { $0 <= $1 } &&
            (aligned.first ?? -.infinity) >= (points.first?.distance ?? 0) &&
            (aligned.last ?? .infinity) <= (points.last?.distance ?? 0) + 0.000001
        self.points = validPoints && validStops ? points : []
        self.stopDistances = alignedDistances
    }

    func coordinates(fromSequence: Int? = nil, toSequence: Int? = nil) -> [CLLocationCoordinate2D] {
        guard let first = stops.first, let last = stops.last else { return [] }
        let start = fromSequence ?? first.sequence
        let end = toSequence ?? last.sequence
        guard start <= end else { return [] }
        if let range = shapeRange(from: start, to: end),
           let origin = coordinate(at: range.lowerBound), let destination = coordinate(at: range.upperBound) {
            let interior = points.filter { $0.distance > range.lowerBound && $0.distance < range.upperBound }
            return [origin] + interior.map(\.coordinate) + [destination]
        }
        return stops.filter { (start...end).contains($0.sequence) }.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private func shapeRange(from start: Int, to end: Int) -> ClosedRange<Double>? {
        guard hasShape, let lower = stopDistances[start], let upper = stopDistances[end], lower <= upper else { return nil }
        return lower...upper
    }

    private func coordinate(at distance: Double) -> CLLocationCoordinate2D? {
        guard let first = points.first, let last = points.last else { return nil }
        if distance <= first.distance { return first.coordinate }
        if distance >= last.distance { return last.coordinate }
        // Find the first point after the requested distance, including plateaus.
        var lower = 0
        var upper = points.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].distance <= distance { lower = middle + 1 } else { upper = middle }
        }
        let start = points[lower - 1]
        let end = points[lower]
        let fraction = (distance - start.distance) / (end.distance - start.distance)
        return CLLocationCoordinate2D(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction
        )
    }
}
