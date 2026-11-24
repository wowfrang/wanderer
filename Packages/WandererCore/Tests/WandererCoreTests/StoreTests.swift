import XCTest
@testable import WandererCore

final class StoreTests: XCTestCase {
    func testMigrationsSetVersion() throws {
        let store = try Store.inMemory()
        XCTAssertEqual(store.schemaVersion, Migrations.all.count)
    }

    func testMigrationPreservesData() throws {
        let path = NSTemporaryDirectory() + "wanderer-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let store = try Store(path: path)
            try store.save(Trip(id: "t1", name: "Milan"))
        }
        // A future migration adds a column; existing rows must survive.
        let extended = Migrations.all + ["ALTER TABLE trips ADD COLUMN cover TEXT;"]
        let store = try Store(path: path, migrations: extended)
        XCTAssertEqual(store.schemaVersion, extended.count)
        XCTAssertEqual(try store.trips().map(\.name), ["Milan"])
    }

    func testTripDayPlaceCRUDAndCascade() throws {
        let store = try Store.inMemory()
        let trip = Trip(name: "Milan")
        try store.save(trip)
        let d1 = try store.addDay(tripId: trip.id, name: "Mon")
        let d2 = try store.addDay(tripId: trip.id, name: "Tue")
        XCTAssertEqual(try store.days(tripId: trip.id).map(\.name), ["Mon", "Tue"])
        XCTAssertEqual(d2.position, 1)

        let a = try store.addPlace(Place(dayId: d1.id, name: "A", coordinate: duomo))
        let b = try store.addPlace(Place(dayId: d1.id, name: "B"))
        let c = try store.addPlace(Place(dayId: d1.id, name: "C", visitMinutes: 20))
        XCTAssertEqual(try store.places(dayId: d1.id).map(\.name), ["A", "B", "C"])
        XCTAssertEqual(try store.place(id: a.id)?.coordinate, duomo)
        XCTAssertEqual(try store.place(id: c.id)?.visitMinutes, 20)

        try store.reorderPlaces(dayId: d1.id, orderedIds: [c.id, a.id, b.id])
        XCTAssertEqual(try store.places(dayId: d1.id).map(\.name), ["C", "A", "B"])

        try store.movePlace(a.id, toDay: d2.id)
        XCTAssertEqual(try store.places(dayId: d1.id).map(\.name), ["C", "B"])
        XCTAssertEqual(try store.places(dayId: d1.id).map(\.position), [0, 1])
        XCTAssertEqual(try store.places(dayId: d2.id).map(\.name), ["A"])

        var renamed = d1
        renamed.name = "Monday"
        try store.save(renamed)
        XCTAssertEqual(try store.day(id: d1.id)?.name, "Monday")

        try store.deleteTrip(trip.id)
        XCTAssertTrue(try store.days(tripId: trip.id).isEmpty)
        XCTAssertNil(try store.place(id: b.id))
    }

    func testRouteCache() throws {
        let store = try Store.inMemory()
        let to = offset(duomo, north: 500)
        XCTAssertNil(try store.cachedLeg(from: duomo, to: to))
        let leg = RouteLeg(from: duomo, to: to, points: [duomo, offset(duomo, north: 250, east: 30), to],
                           distance: 540, expectedTravelTime: 420)
        try store.cache(leg)
        let cached = try XCTUnwrap(store.cachedLeg(from: duomo, to: to))
        XCTAssertEqual(cached.points.count, 3)
        XCTAssertEqual(cached.distance, 540)
        XCTAssertEqual(cached.points[1].latitude, leg.points[1].latitude, accuracy: 1e-6)
        // Fallback straight lines are never cached.
        try store.cache(RouteLeg.straight(from: to, to: duomo))
        XCTAssertNil(try store.cachedLeg(from: to, to: duomo))
    }

    func testInsertDraft() throws {
        let store = try Store.inMemory()
        var draft = try ItineraryParser.parse(ItineraryFormat.sampleMilanJSON())
        draft.days[0].places[0].chosenCoordinate = duomo
        draft.days[0].places[1].include = false
        let trip = try store.insert(draft)
        let day = try XCTUnwrap(store.days(tripId: trip.id).first)
        let places = try store.places(dayId: day.id)
        XCTAssertEqual(places.count, 4)
        XCTAssertEqual(places[0].coordinate, duomo)
        XCTAssertEqual(places[0].radius, 60)
        XCTAssertNil(places[1].coordinate)
    }

    func testVisitEventSnapshotSurvivesPlaceDeletion() throws {
        let store = try Store.inMemory()
        let trip = Trip(name: "T"); try store.save(trip)
        let day = try store.addDay(tripId: trip.id, name: "D")
        let p = try store.addPlace(Place(dayId: day.id, name: "Bar Basso", coordinate: duomo))
        let s = ExplorationSession(dayId: day.id); try store.save(s)
        try store.append(VisitEvent(sessionId: s.id, placeId: p.id, placeName: p.name, kind: .visited, source: .manual))
        try store.deletePlace(p.id)
        let events = try store.visitEvents(sessionId: s.id)
        XCTAssertEqual(events.first?.placeName, "Bar Basso")
        XCTAssertNil(events.first?.placeId)
    }
}
