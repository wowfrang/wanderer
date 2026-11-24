import Foundation

// MARK: - Plan (what you intend to do)

public struct Trip: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Day: Identifiable, Hashable, Sendable {
    public var id: String
    public var tripId: String
    public var name: String
    /// Calendar date as yyyy-MM-dd, optional.
    public var date: String?
    public var position: Int
    public var createdAt: Date

    public init(id: String = UUID().uuidString, tripId: String, name: String, date: String? = nil,
                position: Int = 0, createdAt: Date = .now) {
        self.id = id
        self.tripId = tripId
        self.name = name
        self.date = date
        self.position = position
        self.createdAt = createdAt
    }
}

public enum PlaceOrigin: String, Codable, Sendable {
    /// Part of the plan (created while planning or imported).
    case plan
    /// Added on the fly during an exploration session.
    case spontaneous
}

public struct Place: Identifiable, Hashable, Sendable {
    public var id: String
    public var dayId: String
    public var position: Int
    public var name: String
    public var address: String?
    public var coordinate: Coordinate?
    public var notes: String?
    public var category: String?
    public var details: String?
    public var openingHours: String?
    public var visitMinutes: Int?
    /// Optional per-place arrival radius override (e.g. a long street or a big park).
    public var radius: Double?
    public var origin: PlaceOrigin
    public var createdAt: Date

    public init(id: String = UUID().uuidString, dayId: String, position: Int = 0, name: String,
                address: String? = nil, coordinate: Coordinate? = nil, notes: String? = nil,
                category: String? = nil, details: String? = nil, openingHours: String? = nil,
                visitMinutes: Int? = nil, radius: Double? = nil, origin: PlaceOrigin = .plan,
                createdAt: Date = .now) {
        self.id = id
        self.dayId = dayId
        self.position = position
        self.name = name
        self.address = address
        self.coordinate = coordinate
        self.notes = notes
        self.category = category
        self.details = details
        self.openingHours = openingHours
        self.visitMinutes = visitMinutes
        self.radius = radius
        self.origin = origin
        self.createdAt = createdAt
    }
}

/// A calculated pedestrian route between two coordinates. Cached by coordinate key, so it is
/// shared by any places at the same location and survives reordering.
public struct RouteLeg: Hashable, Sendable {
    public var from: Coordinate
    public var to: Coordinate
    public var points: [Coordinate]
    public var distance: Double
    public var expectedTravelTime: TimeInterval
    /// False when this is a straight-line fallback (no directions available).
    public var isWalkingRoute: Bool

    public init(from: Coordinate, to: Coordinate, points: [Coordinate], distance: Double,
                expectedTravelTime: TimeInterval, isWalkingRoute: Bool = true) {
        self.from = from
        self.to = to
        self.points = points
        self.distance = distance
        self.expectedTravelTime = expectedTravelTime
        self.isWalkingRoute = isWalkingRoute
    }

    public static func straight(from: Coordinate, to: Coordinate, walkingSpeed: Double = 1.3) -> RouteLeg {
        let d = Geo.distance(from, to)
        return RouteLeg(from: from, to: to, points: [from, to], distance: d,
                        expectedTravelTime: d / walkingSpeed, isWalkingRoute: false)
    }
}

// MARK: - Reality (what actually happened)

public enum SessionStatus: String, Codable, Sendable {
    case active, paused, finished
}

public struct ExplorationSession: Identifiable, Hashable, Sendable {
    public var id: String
    public var dayId: String
    public var status: SessionStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var distance: Double
    /// nil when step counting is unavailable or not permitted.
    public var steps: Int?
    /// Manually chosen next destination, overriding the automatic choice.
    public var targetPlaceId: String?

    public init(id: String = UUID().uuidString, dayId: String, status: SessionStatus = .active,
                startedAt: Date = .now, endedAt: Date? = nil, distance: Double = 0, steps: Int? = nil,
                targetPlaceId: String? = nil) {
        self.id = id
        self.dayId = dayId
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distance = distance
        self.steps = steps
        self.targetPlaceId = targetPlaceId
    }
}

public struct SessionPause: Hashable, Sendable {
    public var pausedAt: Date
    public var resumedAt: Date?

    public init(pausedAt: Date, resumedAt: Date? = nil) {
        self.pausedAt = pausedAt
        self.resumedAt = resumedAt
    }
}

public struct GPSSample: Hashable, Sendable {
    public var timestamp: Date
    public var coordinate: Coordinate
    public var horizontalAccuracy: Double
    /// Metres per second; negative when unknown.
    public var speed: Double
    /// Path segment. A new segment starts after a pause or a tracking gap so the drawn path
    /// never pretends you walked through a wall.
    public var segment: Int
    /// Whether the sample was accepted into the walked path (passed accuracy/jitter filters).
    public var accepted: Bool

    public init(timestamp: Date, coordinate: Coordinate, horizontalAccuracy: Double, speed: Double = -1,
                segment: Int = 0, accepted: Bool = false) {
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.segment = segment
        self.accepted = accepted
    }
}

public enum VisitKind: String, Codable, Sendable {
    case visited
    case skipped
    /// Undo of a previous visited/skipped event; the place is pending again.
    case reset
}

public enum VisitSource: String, Codable, Sendable {
    case automatic, manual
}

public struct VisitEvent: Identifiable, Hashable, Sendable {
    public var id: String
    public var sessionId: String
    public var placeId: String?
    /// Snapshot so history survives the plan being edited or the place deleted.
    public var placeName: String
    public var kind: VisitKind
    public var source: VisitSource
    public var timestamp: Date
    public var coordinate: Coordinate?

    public init(id: String = UUID().uuidString, sessionId: String, placeId: String?, placeName: String,
                kind: VisitKind, source: VisitSource, timestamp: Date = .now, coordinate: Coordinate? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.placeId = placeId
        self.placeName = placeName
        self.kind = kind
        self.source = source
        self.timestamp = timestamp
        self.coordinate = coordinate
    }
}

public enum PlaceStatus: String, Sendable {
    case pending, visited, skipped
}

public extension Array where Element == VisitEvent {
    /// Latest status per place id, derived from the event log (expected in chronological order).
    func statuses() -> [String: PlaceStatus] {
        var result: [String: PlaceStatus] = [:]
        for event in self {
            guard let id = event.placeId else { continue }
            switch event.kind {
            case .visited: result[id] = .visited
            case .skipped: result[id] = .skipped
            case .reset: result[id] = .pending
            }
        }
        return result
    }
}
