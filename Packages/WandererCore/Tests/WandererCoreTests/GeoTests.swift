import XCTest
@testable import WandererCore

final class GeoTests: XCTestCase {
    func testKnownDistance() {
        // Duomo di Milano → Pinacoteca di Brera ≈ 1.0 km as the crow flies.
        let brera = Coordinate(latitude: 45.4719, longitude: 9.1879)
        let d = Geo.distance(duomo, brera)
        XCTAssertEqual(d, 870, accuracy: 30)
    }

    func testZeroAndSymmetry() {
        let a = offset(duomo, north: 100, east: 50)
        XCTAssertEqual(Geo.distance(duomo, duomo), 0, accuracy: 1e-9)
        XCTAssertEqual(Geo.distance(duomo, a), Geo.distance(a, duomo), accuracy: 1e-9)
    }

    func testOffsetHelperMatchesHaversine() {
        XCTAssertEqual(Geo.distance(duomo, offset(duomo, north: 100)), 100, accuracy: 0.5)
        XCTAssertEqual(Geo.distance(duomo, offset(duomo, east: 100)), 100, accuracy: 0.5)
    }

    func testPolylineLength() {
        let pts = [duomo, offset(duomo, north: 100), offset(duomo, north: 100, east: 100)]
        XCTAssertEqual(Geo.length(of: pts), 200, accuracy: 1)
        XCTAssertEqual(Geo.length(of: [duomo]), 0)
        XCTAssertEqual(Geo.length(of: []), 0)
    }

    func testBoundsAndMedian() {
        let pts = [duomo, offset(duomo, north: 200), offset(duomo, east: 300)]
        let b = Geo.bounds(of: pts)!
        XCTAssertEqual(b.minLatitude, duomo.latitude)
        XCTAssertGreaterThan(b.maxLongitude, duomo.longitude)
        XCTAssertNil(Geo.bounds(of: []))
        XCTAssertNotNil(Geo.median(of: pts))
    }

    func testFormatting() {
        XCTAssertEqual(Format.distance(42), "40 m")
        XCTAssertEqual(Format.distance(1234), "1.2 km")
        XCTAssertEqual(Format.distance(15_400), "15 km")
        XCTAssertEqual(Format.duration(60 * 65), "1 h 05 min")
        XCTAssertEqual(Format.duration(240), "4 min")
        XCTAssertEqual(Format.clock(3725), "1:02:05")
    }

    func testOptimizerKeepsFirstAndImproves() {
        // A zig-zag order that is clearly worse than walking in a line.
        let line = (0..<6).map { offset(duomo, east: Double($0) * 200) }
        let shuffled = [line[0], line[4], line[1], line[5], line[2], line[3]]
        let order = RouteOptimizer.optimizedOrder(shuffled)
        XCTAssertEqual(order.first, 0)
        XCTAssertEqual(Set(order), Set(0..<6))
        XCTAssertLessThan(RouteOptimizer.pathLength(shuffled, order: order),
                          RouteOptimizer.pathLength(shuffled, order: Array(0..<6)))
        XCTAssertEqual(RouteOptimizer.pathLength(shuffled, order: order), 1000, accuracy: 5)
    }
}
