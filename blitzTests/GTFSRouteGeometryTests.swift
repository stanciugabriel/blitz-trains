import Testing
import CoreLocation
@testable import blitz

struct GTFSRouteGeometryTests {
    private let stops = [
        GTFSStop(id: "a", name: "A", sequence: 1, latitude: 47, longitude: 8),
        GTFSStop(id: "b", name: "B", sequence: 2, latitude: 47.1, longitude: 8.1),
        GTFSStop(id: "a", name: "A", sequence: 3, latitude: 47, longitude: 8)
    ]
    private let points = [
        GTFSRouteGeometry.Point(latitude: 47, longitude: 8, distance: 0),
        GTFSRouteGeometry.Point(latitude: 47.1, longitude: 8.1, distance: 100),
        GTFSRouteGeometry.Point(latitude: 47.2, longitude: 8, distance: 200),
        GTFSRouteGeometry.Point(latitude: 47, longitude: 8, distance: 300)
    ]

    @Test func repeatedStationsUseStopSequenceAndStayOnTheirLeg() throws {
        let geometry = GTFSRouteGeometry(stops: stops, points: points, stopDistances: [1: 0, 2: 100, 3: 300])
        #expect(geometry.hasShape)
        #expect(geometry.coordinates(fromSequence: 2, toSequence: 3).map(\.latitude) == [47.1, 47.2, 47])
    }

    @Test func invalidShapesAndDistancesFallBackToStations() {
        let invalidPoints: [[GTFSRouteGeometry.Point]] = [
            [], Array(points.reversed()),
            [points[0], .init(latitude: 100, longitude: 8, distance: 300)],
            [points[0], .init(latitude: 47, longitude: 8, distance: .nan)]
        ]
        for shape in invalidPoints {
            let geometry = GTFSRouteGeometry(stops: stops, points: shape, stopDistances: [1: 0, 2: 100, 3: 300])
            #expect(!geometry.hasShape)
            #expect(geometry.coordinates().count == 3)
        }
        let invalidDistances: [[Int: Double]] = [[1: 0, 3: 300], [1: 0, 2: 400, 3: 300], [1: 0, 2: 100, 3: 400]]
        for distances in invalidDistances {
            #expect(!GTFSRouteGeometry(stops: stops, points: points, stopDistances: distances).hasShape)
        }
    }

    @Test func equalDistancesDoNotProduceInvalidCoordinates() throws {
        let duplicated = [points[0], points[1], points[1], points[2], points[3]]
        let geometry = GTFSRouteGeometry(stops: stops, points: duplicated, stopDistances: [1: 0, 2: 100, 3: 300])
        let clipped = geometry.coordinates(fromSequence: 2, toSequence: 3)
        #expect(clipped.first?.latitude == 47.1)
        #expect(clipped.first?.longitude == 8.1)
    }

    @Test func simplifiedShapeKeepsItsPolylineWhenStopDistancesAreSlightlyLonger() {
        let geometry = GTFSRouteGeometry(stops: stops, points: points, stopDistances: [1: 0, 2: 100.5, 3: 301.5])
        #expect(geometry.hasShape)
        #expect(geometry.coordinates().count == 4)
        #expect(geometry.coordinates(fromSequence: 2, toSequence: 3).map(\.latitude) == [47.1, 47.2, 47])
    }
}
