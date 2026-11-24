import Foundation

/// A WGS84 coordinate. Kept independent of CoreLocation so the core stays portable.
public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && !(latitude == 0 && longitude == 0)
    }

    /// Stable key used for route caching (≈1 m precision).
    public var cacheKey: String {
        String(format: "%.5f,%.5f", latitude, longitude)
    }
}

public enum Geo {
    public static let earthRadius = 6_371_008.8

    /// Great-circle distance in metres.
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Total length of a polyline in metres.
    public static func length(of points: [Coordinate]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count { total += distance(points[i - 1], points[i]) }
        return total
    }

    public struct Bounds: Equatable, Sendable {
        public var minLatitude: Double
        public var maxLatitude: Double
        public var minLongitude: Double
        public var maxLongitude: Double

        public var center: Coordinate {
            Coordinate(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2)
        }
        public var latitudeSpan: Double { maxLatitude - minLatitude }
        public var longitudeSpan: Double { maxLongitude - minLongitude }
    }

    public static func bounds(of points: [Coordinate]) -> Bounds? {
        guard let first = points.first else { return nil }
        var b = Bounds(minLatitude: first.latitude, maxLatitude: first.latitude,
                       minLongitude: first.longitude, maxLongitude: first.longitude)
        for p in points.dropFirst() {
            b.minLatitude = min(b.minLatitude, p.latitude)
            b.maxLatitude = max(b.maxLatitude, p.latitude)
            b.minLongitude = min(b.minLongitude, p.longitude)
            b.maxLongitude = max(b.maxLongitude, p.longitude)
        }
        return b
    }

    /// Coordinate-wise median; robust "where is this trip" estimate used to spot outliers.
    public static func median(of points: [Coordinate]) -> Coordinate? {
        guard !points.isEmpty else { return nil }
        func med(_ v: [Double]) -> Double {
            let s = v.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        return Coordinate(latitude: med(points.map(\.latitude)), longitude: med(points.map(\.longitude)))
    }
}

public enum Format {
    /// "850 m", "1.2 km", "12 km"
    public static func distance(_ metres: Double) -> String {
        if metres < 950 { return "\(Int((metres / 10).rounded() * 10)) m" }
        let km = metres / 1000
        return km < 10 ? String(format: "%.1f km", km) : String(format: "%.0f km", km)
    }

    /// "4 min", "1 h 05 min"
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// "0:42:07" style clock for live elapsed time.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

/// Route ordering helpers for "optimise route".
public enum RouteOptimizer {
    /// Returns a visiting order (indices into `points`) that keeps the first point fixed
    /// and roughly minimises total walking distance (nearest neighbour + 2-opt).
    public static func optimizedOrder(_ points: [Coordinate], keepFirst: Bool = true) -> [Int] {
        let n = points.count
        guard n > 3 else { return Array(0..<n) }
        var order = [0]
        var remaining = Set(1..<n)
        while !remaining.isEmpty {
            let last = points[order.last!]
            let next = remaining.min { Geo.distance(last, points[$0]) < Geo.distance(last, points[$1]) }!
            order.append(next)
            remaining.remove(next)
        }
        // 2-opt on an open path.
        func d(_ i: Int, _ j: Int) -> Double { Geo.distance(points[order[i]], points[order[j]]) }
        var improved = true
        var iterations = 0
        while improved && iterations < 50 {
            improved = false
            iterations += 1
            for i in 1..<(n - 1) {
                for k in (i + 1)..<n {
                    let before = d(i - 1, i) + (k + 1 < n ? d(k, k + 1) : 0)
                    let after = d(i - 1, k) + (k + 1 < n ? d(i, k + 1) : 0)
                    if after + 1e-6 < before {
                        order[i...k].reverse()
                        improved = true
                    }
                }
            }
        }
        return order
    }

    public static func pathLength(_ points: [Coordinate], order: [Int]) -> Double {
        Geo.length(of: order.map { points[$0] })
    }
}
