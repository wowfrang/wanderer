import XCTest
@testable import WandererCore

final class SessionEngineTests: XCTestCase {
    var store: Store!
    var day: Day!
    var places: [Place] = []
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        store = try Store.inMemory()
        let trip = Trip(name: "Milan")
        try store.save(trip)
        day = try store.addDay(tripId: trip.id, name: "Walk")
        places = try [0, 1, 2].map { i in
            try store.addPlace(Place(dayId: day.id, name: "P\(i)", coordinate: offset(duomo, north: Double(i) * 400)))
        }
    }

    func linger(_ engine: SessionEngine, at c: Coordinate, from t: TimeInterval, seconds: Int = 100) throws -> [VisitEvent] {
        var events: [VisitEvent] = []
        for s in stride(from: 0, to: seconds, by: 5) {
            events += try engine.ingest(sample(offset(c, east: Double(s % 2)), t: t + Double(s)))
        }
        return events
    }

    func testFullDayFlowAndRestore() throws {
        let engine = try SessionEngine.start(dayId: day.id, store: store, now: t0)
        XCTAssertEqual(engine.nextPlaceId, places[0].id)

        let first = try linger(engine, at: places[0].coordinate!, from: 0)
        XCTAssertEqual(first.map(\.placeId), [places[0].id])
        XCTAssertEqual(engine.nextPlaceId, places[1].id)

        // Walk to P1 (400 m) in 10 m steps.
        for i in 1...40 { try engine.ingest(sample(offset(duomo, north: Double(i) * 10), t: 100 + Double(i) * 7)) }
        XCTAssertEqual(engine.session.distance, 400, accuracy: 10)

        try engine.pause(at: t0.addingTimeInterval(500))
        // Samples while paused are ignored.
        XCTAssertTrue(try engine.ingest(sample(offset(duomo, north: 800), t: 520)).isEmpty)
        try engine.resume(at: t0.addingTimeInterval(800))

        try engine.mark(places[2].id, .skipped, at: t0.addingTimeInterval(810))
        XCTAssertEqual(engine.status(of: places[2].id), .skipped)

        // Simulate the app being killed and relaunched.
        let restored = try XCTUnwrap(SessionEngine.restore(sessionId: engine.session.id, store: store))
        XCTAssertEqual(restored.session.status, .active)
        XCTAssertEqual(restored.session.distance, engine.session.distance, accuracy: 0.001)
        XCTAssertEqual(restored.status(of: places[0].id), .visited)
        XCTAssertEqual(restored.status(of: places[2].id), .skipped)
        XCTAssertEqual(restored.pauses.count, 1)
        XCTAssertEqual(restored.path.count, 1)
        XCTAssertEqual(restored.nextPlaceId, places[1].id)

        // Tracking after a restart continues in a new segment and doesn't bridge distance.
        try restored.ingest(sample(offset(duomo, north: 2000), t: 900))
        XCTAssertEqual(restored.session.distance, engine.session.distance, accuracy: 0.001)
        XCTAssertEqual(restored.path.count, 2)

        try restored.finish(at: t0.addingTimeInterval(1000), steps: 1234)
        let finished = try XCTUnwrap(store.session(id: engine.session.id))
        XCTAssertEqual(finished.status, .finished)
        XCTAssertEqual(finished.steps, 1234)
        XCTAssertEqual(restored.elapsed(), 700, accuracy: 0.001) // 1000 s minus a 300 s pause
        XCTAssertNil(try store.openSession())
    }

    func testOnlyOneOpenSession() throws {
        _ = try SessionEngine.start(dayId: day.id, store: store, now: t0)
        XCTAssertThrowsError(try SessionEngine.start(dayId: day.id, store: store, now: t0))
    }

    func testUndoAutomaticVisit() throws {
        let engine = try SessionEngine.start(dayId: day.id, store: store, now: t0)
        _ = try linger(engine, at: places[0].coordinate!, from: 0)
        XCTAssertEqual(engine.status(of: places[0].id), .visited)
        try engine.mark(places[0].id, .reset, at: t0.addingTimeInterval(101))
        XCTAssertEqual(engine.status(of: places[0].id), .pending)
        // Still standing there: not re-detected.
        XCTAssertTrue(try linger(engine, at: places[0].coordinate!, from: 105, seconds: 200).isEmpty)
        XCTAssertEqual(engine.status(of: places[0].id), .pending)
    }

    func testSkippedPlaceCanStillBeVisited() throws {
        let engine = try SessionEngine.start(dayId: day.id, store: store, now: t0)
        try engine.mark(places[1].id, .skipped, at: t0)
        _ = try linger(engine, at: places[1].coordinate!, from: 10)
        XCTAssertEqual(engine.status(of: places[1].id), .visited)
    }

    func testManualTargetAndSpontaneousPlace() throws {
        let engine = try SessionEngine.start(dayId: day.id, store: store, now: t0)
        try engine.setTarget(places[2].id)
        XCTAssertEqual(engine.nextPlaceId, places[2].id)
        try engine.mark(places[2].id, .visited)
        XCTAssertNil(engine.session.targetPlaceId)

        let gelato = try engine.addSpontaneousPlace(name: "Gelato", address: nil, coordinate: offset(duomo, east: 200))
        XCTAssertEqual(engine.places.count, 4)
        XCTAssertEqual(engine.nextPlaceId, gelato.id)
        XCTAssertEqual(try store.place(id: gelato.id)?.origin, .spontaneous)
    }
}
