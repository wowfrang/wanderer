import Foundation
@testable import WandererCore

let duomo = Coordinate(latitude: 45.4642, longitude: 9.1900)

/// A coordinate `metres` north/east of `origin`.
func offset(_ origin: Coordinate, north: Double = 0, east: Double = 0) -> Coordinate {
    let dLat = north / 111_320
    let dLng = east / (111_320 * cos(origin.latitude * .pi / 180))
    return Coordinate(latitude: origin.latitude + dLat, longitude: origin.longitude + dLng)
}

func sample(_ c: Coordinate, t: TimeInterval, accuracy: Double = 8, base: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> GPSSample {
    GPSSample(timestamp: base.addingTimeInterval(t), coordinate: c, horizontalAccuracy: accuracy)
}

struct FakeGeocoder: PlaceGeocoder {
    var results: [String: [GeocodeCandidate]]
    func search(_ query: String, near: Coordinate?) async throws -> [GeocodeCandidate] {
        results[query] ?? []
    }
}
