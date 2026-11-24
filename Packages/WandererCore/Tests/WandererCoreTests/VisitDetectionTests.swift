import XCTest
@testable import WandererCore

final class VisitDetectionTests: XCTestCase {
    let place = DetectablePlace(id: "p", name: "Café", coordinate: duomo)

    /// Feeds samples, returns the time (s) of the first detection or nil.
    func run(_ samples: [GPSSample], config: VisitDetectionConfig = .default, place: DetectablePlace? = nil) -> TimeInterval? {
        var detector = VisitDetector(config: config)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for s in samples where !detector.ingest(s, candidates: [place ?? self.place]).isEmpty {
            return s.timestamp.timeIntervalSince(base)
        }
        return nil
    }

    func testLingeringIsDetected() {
        // Arrive and stand within ~10 m for two minutes, a fix every 5 s.
        let samples = (0...24).map { i in
            sample(offset(duomo, north: Double(i % 3) * 3, east: 5), t: Double(i) * 5)
        }
        let t = run(samples)
        XCTAssertNotNil(t)
        XCTAssertEqual(t!, 75, accuracy: 5)
    }

    func testWalkingPastIsNotDetected() {
        // Walk straight past at 1.4 m/s, passing within 5 m.
        let samples = (0...60).map { i in
            sample(offset(duomo, north: -150 + Double(i) * 5, east: 5), t: Double(i) * 3.6)
        }
        XCTAssertNil(run(samples))
    }

    func testSlowStrollAlongStreetIsDetectedWithStrollRule() {
        // A 60 m radius street, strolled slowly (0.6 m/s) for 4 minutes but moving the whole time.
        let street = DetectablePlace(id: "s", name: "Via", coordinate: duomo, radius: 60)
        var config = VisitDetectionConfig()
        config.maxLingerSpeed = 0.3 // make sure the linger rule can't fire
        let samples = (0...48).map { i in sample(offset(duomo, north: -60 + Double(i) * 3), t: Double(i) * 5) }
        let t = run(samples, config: config, place: street)
        XCTAssertNotNil(t)
        XCTAssertGreaterThanOrEqual(t!, config.strollSeconds)
    }

    func testInaccurateFixesAreIgnored() {
        let samples = (0...40).map { i in sample(duomo, t: Double(i) * 5, accuracy: 120) }
        XCTAssertNil(run(samples))
    }

    func testBriefExitResetsDwell() {
        var samples: [GPSSample] = []
        for i in 0..<10 { samples.append(sample(duomo, t: Double(i) * 5)) }          // 45 s inside
        samples.append(sample(offset(duomo, north: 150), t: 50))                       // clearly left
        for i in 0..<10 { samples.append(sample(duomo, t: 55 + Double(i) * 5)) }       // 45 s inside again
        XCTAssertNil(run(samples))
    }

    func testGPSWobbleInHysteresisZoneDoesNotReset() {
        var samples: [GPSSample] = []
        for i in 0..<20 {
            // Every 4th fix wobbles to 50 m: outside the 35 m radius but inside the exit radius.
            let c = i % 4 == 3 ? offset(duomo, north: 50) : offset(duomo, east: 4)
            samples.append(sample(c, t: Double(i) * 5))
        }
        XCTAssertNotNil(run(samples))
    }

    func testSuppressAfterUndoUntilExit() {
        var detector = VisitDetector()
        var t = 0.0
        func feed(_ c: Coordinate, _ n: Int) -> Bool {
            var hit = false
            for _ in 0..<n {
                hit = hit || !detector.ingest(sample(c, t: t), candidates: [place]).isEmpty
                t += 5
            }
            return hit
        }
        XCTAssertTrue(feed(duomo, 20))
        detector.suppressUntilExit("p")
        XCTAssertFalse(feed(duomo, 30))                        // still standing there: stays undone
        XCTAssertFalse(feed(offset(duomo, north: 200), 2))     // leave
        XCTAssertTrue(feed(duomo, 20))                         // come back and linger: detected again
    }

    // MARK: Path

    func testPathRejectsJitterAndJumps() {
        var acc = PathAccumulator()
        // Standing still with jitter shouldn't add distance.
        for i in 0..<20 { _ = acc.ingest(sample(offset(duomo, east: Double(i % 2) * 2), t: Double(i))) }
        XCTAssertEqual(acc.distance, 0)
        // Walk 100 m north in 10 m steps every 7 s.
        for i in 1...10 { _ = acc.ingest(sample(offset(duomo, north: Double(i) * 10), t: 20 + Double(i) * 7)) }
        XCTAssertEqual(acc.distance, 100, accuracy: 3)
        // A 2 km jump one second later is rejected.
        let jump = acc.ingest(sample(offset(duomo, north: 2100), t: 91))
        XCTAssertFalse(jump.accepted)
        // A bad fix is rejected.
        XCTAssertFalse(acc.ingest(sample(offset(duomo, north: 150), t: 100, accuracy: 80)).accepted)
        XCTAssertEqual(acc.distance, 100, accuracy: 3)
    }

    func testSegmentBreakDoesNotBridgeDistance() {
        var acc = PathAccumulator()
        _ = acc.ingest(sample(duomo, t: 0))
        _ = acc.ingest(sample(offset(duomo, north: 50), t: 40))
        acc.breakSegment()
        let s = acc.ingest(sample(offset(duomo, north: 1000), t: 4000))
        XCTAssertTrue(s.accepted)
        XCTAssertEqual(s.segment, 1)
        XCTAssertEqual(acc.distance, 50, accuracy: 1)
    }

    // MARK: Clock & next destination

    func testElapsedExcludesPauses() {
        let start = Date(timeIntervalSince1970: 0)
        let pauses = [SessionPause(pausedAt: Date(timeIntervalSince1970: 600), resumedAt: Date(timeIntervalSince1970: 900)),
                      SessionPause(pausedAt: Date(timeIntervalSince1970: 1500))]
        XCTAssertEqual(SessionClock.elapsed(start: start, end: nil, pauses: pauses, now: Date(timeIntervalSince1970: 1800)), 1200)
        let intervals = SessionClock.activeIntervals(start: start, end: nil, pauses: pauses, now: Date(timeIntervalSince1970: 1800))
        XCTAssertEqual(intervals.map { $0.1.timeIntervalSince($0.0) }, [600, 600])
    }

    func testNextDestinationOutOfOrder() {
        let order = ["1", "2", "3", "4"]
        XCTAssertEqual(NextDestination.choose(order: order, statuses: [:], lastVisitedId: nil, target: nil), "1")
        // Visited #3 first: head to #4, #2 is still pending afterwards.
        XCTAssertEqual(NextDestination.choose(order: order, statuses: ["3": .visited], lastVisitedId: "3", target: nil), "4")
        XCTAssertEqual(NextDestination.choose(order: order, statuses: ["3": .visited, "4": .skipped], lastVisitedId: "3", target: nil), "1")
        XCTAssertEqual(NextDestination.choose(order: order, statuses: [:], lastVisitedId: nil, target: "3"), "3")
        XCTAssertNil(NextDestination.choose(order: order, statuses: ["1": .visited, "2": .visited, "3": .skipped, "4": .visited],
                                            lastVisitedId: "4", target: nil))
    }
}
