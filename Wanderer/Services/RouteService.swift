import Foundation
import MapKit
import WandererCore

/// Walking directions from Apple Maps (MKDirections): free, no API key, and consistent with
/// the map tiles. Results are cached in SQLite by coordinate pair so a day's routes are only
/// fetched once, even across launches. Failures fall back to a straight dashed line and are
/// not cached, so they are retried later.
@MainActor
final class RouteService {
    private let store: Store
    private var memory: [String: RouteLeg] = [:]
    private var inFlight: [String: Task<RouteLeg, Never>] = [:]

    init(store: Store) {
        self.store = store
    }

    private func key(_ a: Coordinate, _ b: Coordinate) -> String { a.cacheKey + ">" + b.cacheKey }

    func cachedLeg(from: Coordinate, to: Coordinate) -> RouteLeg? {
        if let leg = memory[key(from, to)] { return leg }
        if let leg = try? store.cachedLeg(from: from, to: to) {
            memory[key(from, to)] = leg
            return leg
        }
        return nil
    }

    /// `persist: false` for throwaway legs such as "current location → next stop".
    func leg(from: Coordinate, to: Coordinate, persist: Bool = true) async -> RouteLeg {
        if Geo.distance(from, to) < 15 { return .straight(from: from, to: to) }
        if let cached = cachedLeg(from: from, to: to) { return cached }
        let k = key(from, to)
        if let task = inFlight[k] { return await task.value }
        let task = Task { await Self.fetch(from: from, to: to) }
        inFlight[k] = task
        let leg = await task.value
        inFlight[k] = nil
        if leg.isWalkingRoute {
            memory[k] = leg
            if persist { try? store.cache(leg) }
        }
        return leg
    }

    /// Legs between consecutive coordinates, fetched one at a time (MKDirections is rate limited).
    func legs(for coordinates: [Coordinate]) async -> [RouteLeg] {
        guard coordinates.count > 1 else { return [] }
        var result: [RouteLeg] = []
        for i in 1..<coordinates.count {
            result.append(await leg(from: coordinates[i - 1], to: coordinates[i]))
        }
        return result
    }

    private static func fetch(from: Coordinate, to: Coordinate) async -> RouteLeg {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.cl))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.cl))
        request.transportType = .walking
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else { return .straight(from: from, to: to) }
            let count = route.polyline.pointCount
            var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
            route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
            return RouteLeg(from: from, to: to, points: coords.map(Coordinate.init),
                            distance: route.distance, expectedTravelTime: route.expectedTravelTime)
        } catch {
            return .straight(from: from, to: to)
        }
    }
}
