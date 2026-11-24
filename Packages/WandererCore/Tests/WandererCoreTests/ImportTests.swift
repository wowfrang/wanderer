import XCTest
@testable import WandererCore

final class ImportTests: XCTestCase {
    func testParsesDocumentedSchema() throws {
        let json = """
        {"version":1,"trip_name":"Milan","days":[{"name":"Day A","date":"2026-11-25","places":[
          {"name":"Pinacoteca di Brera","address":"Via Brera 28, Milano","lat":45.4719,"lng":9.1879,
           "description":"Art","category":"museum","opening_hours":"8:30–19:15","visit_minutes":90},
          {"name":"Duomo"}
        ]}]}
        """
        let draft = try ItineraryParser.parse(json)
        XCTAssertEqual(draft.name, "Milan")
        XCTAssertEqual(draft.days.count, 1)
        XCTAssertEqual(draft.days[0].date, "2026-11-25")
        let p = draft.days[0].places[0]
        XCTAssertEqual(p.name, "Pinacoteca di Brera")
        XCTAssertEqual(p.providedCoordinate, Coordinate(latitude: 45.4719, longitude: 9.1879))
        XCTAssertEqual(p.visitMinutes, 90)
        XCTAssertEqual(p.openingHours, "8:30–19:15")
        XCTAssertEqual(p.resolution, .provided)
        XCTAssertEqual(draft.days[0].places[1].resolution, .pending)
    }

    func testStripsCodeFencesAndProse() throws {
        let text = """
        Sure! Here's your itinerary:

        ```json
        {"trip_name":"X","days":[{"places":[{"name":"A"}]}]}
        ```
        Enjoy Milan!
        """
        let draft = try ItineraryParser.parse(text)
        XCTAssertEqual(draft.name, "X")
        XCTAssertEqual(draft.days[0].name, "Day 1")
    }

    func testAliasesAndNestedCoordinates() throws {
        let json = """
        {"name":"T","days":[{"title":"D","places":[
          {"title":"A","location":{"latitude":45.46,"longitude":9.18},"duration":"1h 30m"},
          {"name":"B","coordinates":[45.47,9.19],"duration_minutes":"45 min"},
          {"name":"C","latitude":"45.48","lon":"9.2"}
        ]}]}
        """
        let places = try ItineraryParser.parse(json).days[0].places
        XCTAssertEqual(places[0].providedCoordinate?.latitude, 45.46)
        XCTAssertEqual(places[0].visitMinutes, 90)
        XCTAssertEqual(places[1].providedCoordinate?.longitude, 9.19)
        XCTAssertEqual(places[1].visitMinutes, 45)
        XCTAssertEqual(places[2].providedCoordinate?.latitude, 45.48)
    }

    func testTopLevelPlacesAndStrings() throws {
        let draft = try ItineraryParser.parse(#"{"trip_name":"T","places":["Duomo","Brera"]}"#)
        XCTAssertEqual(draft.days.count, 1)
        XCTAssertEqual(draft.days[0].places.map(\.name), ["Duomo", "Brera"])
    }

    func testWarningsForBadEntries() throws {
        let draft = try ItineraryParser.parse("""
        {"trip_name":"T","days":[{"name":"D","date":"next tuesday","places":[{"address":"x"},{"name":"Ok","lat":999,"lng":9}]}]}
        """)
        XCTAssertEqual(draft.days[0].places.count, 1)
        XCTAssertNil(draft.days[0].places[0].providedCoordinate)
        XCTAssertEqual(draft.warnings.count, 3)
    }

    func testErrors() {
        XCTAssertThrowsError(try ItineraryParser.parse("hello"))
        XCTAssertThrowsError(try ItineraryParser.parse(#"{"trip_name":"T"}"#))
        XCTAssertThrowsError(try ItineraryParser.parse(#"{"days":[{"places":[]}]}"#))
    }

    func testBundledSampleParses() throws {
        let draft = try ItineraryParser.parse(ItineraryFormat.sampleMilanJSON())
        let names = draft.days[0].places.map(\.name)
        XCTAssertEqual(names, ["Via Gian Giacomo Mora", "Via Cesare Correnti", "Via Santa Marta", "Via San Maurilio", "Brera"])
        XCTAssertEqual(draft.days[0].places[0].radius, 60)
    }

    // MARK: Google Maps

    func testGoogleMapsPathURL() throws {
        let url = "https://www.google.com/maps/dir/Duomo+di+Milano,+Piazza+del+Duomo,+Milano/Pinacoteca+di+Brera,+Via+Brera,+28,+Milano/@45.468,9.18,15z/data=!3m1!4b1!4m14!4m13!1m5!1m1!1s0x0:0x1!2m2!1d9.1919!2d45.4641!1m5!1m1!1s0x0:0x2!2m2!1d9.1879!2d45.4719!3e2"
        let draft = try GoogleMapsURLParser.parse(url)
        let places = draft.days[0].places
        XCTAssertEqual(places.map(\.name), ["Duomo di Milano", "Pinacoteca di Brera"])
        XCTAssertEqual(places[1].providedCoordinate, Coordinate(latitude: 45.4719, longitude: 9.1879))
        XCTAssertEqual(places[0].resolution, .provided)
    }

    func testGoogleMapsAPIURL() throws {
        let url = "https://www.google.com/maps/dir/?api=1&origin=Duomo%20Milano&destination=45.4719,9.1879&waypoints=Via%20Santa%20Marta%2C%20Milano%7CBrera&travelmode=walking"
        let places = try GoogleMapsURLParser.parse(url).days[0].places
        XCTAssertEqual(places.count, 4)
        XCTAssertEqual(places[0].name, "Duomo Milano")
        XCTAssertEqual(places[1].name, "Via Santa Marta")
        XCTAssertEqual(places[3].providedCoordinate?.latitude, 45.4719)
    }

    func testGoogleMapsRejectsOtherLinks() {
        XCTAssertThrowsError(try GoogleMapsURLParser.parse("https://example.com/maps/dir/a/b"))
        XCTAssertThrowsError(try GoogleMapsURLParser.parse("https://www.google.com/maps/place/Duomo"))
        XCTAssertTrue(GoogleMapsURLParser.isShortLink(URL(string: "https://maps.app.goo.gl/abc")!))
    }

    // MARK: Resolution

    func testResolverPrefersGeocodedAddressAndFlagsConflicts() async throws {
        let brera = Coordinate(latitude: 45.4719, longitude: 9.1879)
        let json = """
        {"trip_name":"T","days":[{"places":[
          {"name":"Brera","address":"Via Brera 28, Milano","lat":45.4722,"lng":9.1881},
          {"name":"Wrong","address":"Via Torino 1, Milano","lat":45.50,"lng":9.30},
          {"name":"Nowhere"},
          {"name":"Two Options"}
        ]}]}
        """
        let geocoder = FakeGeocoder(results: [
            "Via Brera 28, Milano": [GeocodeCandidate(name: "Brera", coordinate: brera)],
            "Wrong, Via Torino 1, Milano": [GeocodeCandidate(name: "Via Torino", coordinate: offset(duomo, east: -300))],
            "Two Options": [GeocodeCandidate(name: "A", coordinate: duomo),
                            GeocodeCandidate(name: "B", coordinate: offset(duomo, north: 2000))],
        ])
        let draft = await ItineraryResolver.resolve(try ItineraryParser.parse(json), using: geocoder)
        let p = draft.days[0].places
        XCTAssertEqual(p[0].resolution, .resolved)
        XCTAssertEqual(p[0].resolvedCoordinate, brera)
        XCTAssertEqual(p[1].resolution, .ambiguous) // geocode disagrees with the LLM by > 1 km
        XCTAssertEqual(p[2].resolution, .unresolved)
        XCTAssertNil(p[2].resolvedCoordinate)
        XCTAssertEqual(p[3].resolution, .ambiguous)
        XCTAssertEqual(p[3].candidates.count, 2)
        XCTAssertEqual(draft.needsAttentionCount, 3)
    }

    func testResolverUsesCityHintFallback() async throws {
        let json = #"{"trip_name":"T","days":[{"places":[{"name":"Duomo"}]}]}"#
        let geocoder = FakeGeocoder(results: ["Duomo, Milan": [GeocodeCandidate(name: "Duomo", coordinate: duomo)]])
        let draft = await ItineraryResolver.resolve(try ItineraryParser.parse(json), using: geocoder, cityHint: "Milan")
        XCTAssertEqual(draft.days[0].places[0].resolution, .resolved)
    }
}
