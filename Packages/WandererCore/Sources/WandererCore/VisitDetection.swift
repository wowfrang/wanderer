import Foundation

/// Tunables for automatic visit detection. Persisted by the app so they can be adjusted
/// on the street (Settings → Visit detection) without a rebuild.
public struct VisitDetectionConfig: Codable, Equatable, Sendable {
    /// Default arrival radius in metres (a place can override it).
    public var arrivalRadius: Double = 35
    /// Up to this much of the reported GPS uncertainty is added to the radius.
    public var accuracyAllowance: Double = 20
    /// Samples less accurate than this are ignored entirely.
    public var maxAccuracy: Double = 65
    /// You must be this much further than the arrival radius before a dwell is reset.
    /// The gap between the two radii is hysteresis so GPS wobble doesn't restart the clock.
    public var exitMargin: Double = 30
    /// Lingering rule: inside for at least this long, while roughly standing still.
    public var dwellSeconds: Double = 75
    /// Average net speed (metres moved per second since arriving) below which you count as lingering.
    public var maxLingerSpeed: Double = 0.7
    /// Strolling rule: inside for at least this long at any speed (e.g. walking along a street).
    public var strollSeconds: Double = 180
    /// Minimum number of inside samples before anything is decided.
    public var minSamples: Int = 3

    public init() {}

    public static let `default` = VisitDetectionConfig()
}

public struct DetectablePlace: Sendable {
    public var id: String
    public var name: String
    public var coordinate: Coordinate
    public var radius: Double?

    public init(id: String, name: String, coordinate: Coordinate, radius: Double? = nil) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.radius = radius
    }
}

/// Decides when the walker has genuinely visited a place: close enough, accurately enough,
/// for long enough, and not just walking straight past.
public struct VisitDetector: Sendable {
    public struct Dwell: Equatable, Sendable {
        public var enteredAt: Date
        public var entryCoordinate: Coordinate
        public var lastInsideAt: Date
        public var samples: Int
    }

    public var config: VisitDetectionConfig
    public private(set) var dwells: [String: Dwell] = [:]
    /// Places whose automatic visit was undone: they need an exit before they can trigger again.
    public private(set) var suppressed: Set<String> = []

    public init(config: VisitDetectionConfig = .default) {
        self.config = config
    }

    public func radius(for place: DetectablePlace) -> Double { place.radius ?? config.arrivalRadius }

    /// Feeds one location sample. `candidates` should be the places that may still be detected
    /// (pending or skipped). Returns ids of places detected as visited by this sample.
    public mutating func ingest(_ sample: GPSSample, candidates: [DetectablePlace]) -> [String] {
        guard sample.horizontalAccuracy >= 0, sample.horizontalAccuracy <= config.maxAccuracy else { return [] }
        var detected: [String] = []
        let allowance = min(sample.horizontalAccuracy, config.accuracyAllowance)
        let candidateIds = Set(candidates.map(\.id))
        dwells = dwells.filter { candidateIds.contains($0.key) }

        for place in candidates {
            let r = radius(for: place)
            let d = Geo.distance(sample.coordinate, place.coordinate)
            let inside = d - allowance <= r
            // Only an accurate fix beyond the exit radius counts as leaving.
            let outside = d - sample.horizontalAccuracy > r + config.exitMargin

            if outside {
                dwells[place.id] = nil
                suppressed.remove(place.id)
                continue
            }
            guard inside, !suppressed.contains(place.id) else { continue }

            var dwell = dwells[place.id] ?? Dwell(enteredAt: sample.timestamp, entryCoordinate: sample.coordinate,
                                                  lastInsideAt: sample.timestamp, samples: 0)
            dwell.samples += 1
            dwell.lastInsideAt = sample.timestamp
            dwells[place.id] = dwell

            let duration = sample.timestamp.timeIntervalSince(dwell.enteredAt)
            guard dwell.samples >= config.minSamples else { continue }
            let netSpeed = duration > 0 ? Geo.distance(dwell.entryCoordinate, sample.coordinate) / duration : 0
            let lingered = duration >= config.dwellSeconds && netSpeed <= config.maxLingerSpeed
            let strolled = duration >= config.strollSeconds
            if lingered || strolled {
                detected.append(place.id)
                dwells[place.id] = nil
            }
        }
        return detected
    }

    /// Call when the user undoes a visit so standing in the same spot doesn't re-mark it.
    public mutating func suppressUntilExit(_ placeId: String) {
        suppressed.insert(placeId)
        dwells[placeId] = nil
    }

    public mutating func reset() {
        dwells = [:]
    }
}

/// Turns raw fixes into a walked path and a distance, rejecting noise.
public struct PathAccumulator: Sendable {
    public struct Config: Codable, Equatable, Sendable {
        /// Fixes worse than this don't extend the path.
        public var maxAccuracy: Double = 40
        /// Minimum movement before a new point is added (stops jitter from inflating distance).
        public var minStep: Double = 6
        /// Faster than this between fixes is a GPS jump, not walking (or you got on a tram).
        public var maxSpeed: Double = 9
        public init() {}
    }

    public var config: Config
    public private(set) var distance: Double
    public private(set) var segment: Int
    public private(set) var lastAccepted: GPSSample?

    public init(config: Config = .init(), distance: Double = 0, segment: Int = 0, lastAccepted: GPSSample? = nil) {
        self.config = config
        self.distance = distance
        self.segment = segment
        self.lastAccepted = lastAccepted
    }

    /// Starts a new path segment (after a pause or a tracking gap).
    public mutating func breakSegment() {
        if lastAccepted != nil { segment += 1 }
        lastAccepted = nil
    }

    /// Returns the sample annotated with its segment and whether it was accepted into the path.
    public mutating func ingest(_ sample: GPSSample) -> GPSSample {
        var s = sample
        s.segment = segment
        s.accepted = false
        guard sample.horizontalAccuracy >= 0, sample.horizontalAccuracy <= config.maxAccuracy else { return s }
        guard let last = lastAccepted else {
            s.accepted = true
            lastAccepted = s
            return s
        }
        let d = Geo.distance(last.coordinate, sample.coordinate)
        let dt = sample.timestamp.timeIntervalSince(last.timestamp)
        guard dt > 0 else { return s }
        let step = max(config.minStep, min(sample.horizontalAccuracy, last.horizontalAccuracy) * 0.5)
        guard d >= step else { return s }
        guard d / dt <= config.maxSpeed else { return s }
        distance += d
        s.accepted = true
        lastAccepted = s
        return s
    }
}

public enum SessionClock {
    /// Active (unpaused) time between start and `end ?? now`.
    public static func elapsed(start: Date, end: Date?, pauses: [SessionPause], now: Date = .now) -> TimeInterval {
        let stop = end ?? now
        var paused: TimeInterval = 0
        for p in pauses {
            let resumed = p.resumedAt ?? stop
            paused += max(0, min(resumed, stop).timeIntervalSince(max(p.pausedAt, start)))
        }
        return max(0, stop.timeIntervalSince(start) - paused)
    }

    /// The unpaused intervals, used to ask the pedometer for steps.
    public static func activeIntervals(start: Date, end: Date?, pauses: [SessionPause], now: Date = .now) -> [(Date, Date)] {
        let stop = end ?? now
        var intervals: [(Date, Date)] = []
        var cursor = start
        for p in pauses.sorted(by: { $0.pausedAt < $1.pausedAt }) {
            if p.pausedAt > cursor { intervals.append((cursor, min(p.pausedAt, stop))) }
            cursor = max(cursor, p.resumedAt ?? stop)
        }
        if cursor < stop { intervals.append((cursor, stop)) }
        return intervals.filter { $0.0 < $0.1 }
    }
}

public enum NextDestination {
    /// Picks the place to head to next. Visits don't have to follow the plan: after visiting
    /// #3 the next is #4 even if #2 is still pending; pending places before it come after
    /// the ones ahead. A manual target always wins while it is still pending.
    public static func choose(order: [String], statuses: [String: PlaceStatus], lastVisitedId: String?,
                              target: String?) -> String? {
        func pending(_ id: String) -> Bool { (statuses[id] ?? .pending) == .pending }
        if let target, order.contains(target), pending(target) { return target }
        let start = lastVisitedId.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let rotated = Array(order[min(start, order.count)...]) + Array(order[..<min(start, order.count)])
        return rotated.first(where: pending)
    }
}
