import Foundation

/// The state of one exploration session: what actually happened while walking a day.
/// Every change is written through to the store immediately, so the session survives the app
/// being killed; `restore` rebuilds it from the database.
public final class SessionEngine {
    public let store: Store
    public private(set) var session: ExplorationSession
    public private(set) var pauses: [SessionPause]
    public private(set) var events: [VisitEvent]
    /// Walked path, one array per segment.
    public private(set) var path: [[Coordinate]]
    /// The day's plan (refresh with `reloadPlaces()` after editing it).
    public private(set) var places: [Place]
    public var detector: VisitDetector
    private var accumulator: PathAccumulator
    public private(set) var lastSample: GPSSample?

    private init(store: Store, session: ExplorationSession, pauses: [SessionPause], events: [VisitEvent],
                 path: [[Coordinate]], places: [Place], detector: VisitDetector, accumulator: PathAccumulator) {
        self.store = store
        self.session = session
        self.pauses = pauses
        self.events = events
        self.path = path
        self.places = places
        self.detector = detector
        self.accumulator = accumulator
    }

    /// Begins a new session for a day. Fails if another session is still open.
    public static func start(dayId: String, store: Store, config: VisitDetectionConfig = .default,
                             pathConfig: PathAccumulator.Config = .init(), now: Date = .now) throws -> SessionEngine {
        if let open = try store.openSession() {
            throw ImportError("Another day is still being explored (started \(open.startedAt)). Finish it first.")
        }
        let session = ExplorationSession(dayId: dayId, status: .active, startedAt: now)
        try store.save(session)
        return SessionEngine(store: store, session: session, pauses: [], events: [], path: [],
                             places: try store.places(dayId: dayId), detector: VisitDetector(config: config),
                             accumulator: PathAccumulator(config: pathConfig))
    }

    /// Rebuilds a session from the database (after an app restart, or to show a summary).
    public static func restore(sessionId: String, store: Store, config: VisitDetectionConfig = .default,
                               pathConfig: PathAccumulator.Config = .init()) throws -> SessionEngine? {
        guard let session = try store.session(id: sessionId) else { return nil }
        let samples = try store.samples(sessionId: sessionId, acceptedOnly: true)
        var segments: [[Coordinate]] = []
        var currentSegment: Int?
        for s in samples {
            if s.segment != currentSegment {
                segments.append([])
                currentSegment = s.segment
            }
            segments[segments.count - 1].append(s.coordinate)
        }
        // A restart means we lost track for a while: continue in a fresh segment.
        let lastSegment = samples.last?.segment ?? -1
        let accumulator = PathAccumulator(config: pathConfig, distance: session.distance, segment: lastSegment + 1)
        return SessionEngine(store: store, session: session, pauses: try store.pauses(sessionId: sessionId),
                             events: try store.visitEvents(sessionId: sessionId), path: segments,
                             places: try store.places(dayId: session.dayId), detector: VisitDetector(config: config),
                             accumulator: accumulator)
    }

    // MARK: Derived state

    public var statuses: [String: PlaceStatus] { events.statuses() }

    public func status(of placeId: String) -> PlaceStatus { statuses[placeId] ?? .pending }

    public var lastVisitedId: String? {
        let s = statuses
        return events.last { $0.kind == .visited && $0.placeId.map { s[$0] == .visited } == true }?.placeId
    }

    public var nextPlaceId: String? {
        NextDestination.choose(order: places.filter { $0.coordinate != nil }.map(\.id), statuses: statuses,
                               lastVisitedId: lastVisitedId, target: session.targetPlaceId)
    }

    public var nextPlace: Place? { nextPlaceId.flatMap { id in places.first { $0.id == id } } }

    public var visitedCount: Int { places.filter { status(of: $0.id) == .visited }.count }

    public func elapsed(now: Date = .now) -> TimeInterval {
        SessionClock.elapsed(start: session.startedAt, end: session.endedAt, pauses: pauses, now: now)
    }

    public func activeIntervals(now: Date = .now) -> [(Date, Date)] {
        SessionClock.activeIntervals(start: session.startedAt, end: session.endedAt, pauses: pauses, now: now)
    }

    public var isActive: Bool { session.status == .active }
    public var isFinished: Bool { session.status == .finished }

    // MARK: Tracking

    /// Feeds one location fix. Returns visit events created automatically by this fix.
    @discardableResult
    public func ingest(_ sample: GPSSample) throws -> [VisitEvent] {
        guard session.status == .active else { return [] }
        let annotated = accumulator.ingest(sample)
        lastSample = annotated
        try store.append(annotated, sessionId: session.id)
        if annotated.accepted {
            if path.isEmpty || annotated.segment != currentPathSegment { path.append([]); currentPathSegment = annotated.segment }
            path[path.count - 1].append(annotated.coordinate)
            if accumulator.distance != session.distance {
                session.distance = accumulator.distance
                try store.save(session)
            }
        }
        let s = statuses
        let candidates = places.compactMap { p -> DetectablePlace? in
            guard let c = p.coordinate, s[p.id] != .visited else { return nil }
            return DetectablePlace(id: p.id, name: p.name, coordinate: c, radius: p.radius)
        }
        var created: [VisitEvent] = []
        for id in detector.ingest(sample, candidates: candidates) {
            guard let place = places.first(where: { $0.id == id }) else { continue }
            let e = VisitEvent(sessionId: session.id, placeId: id, placeName: place.name, kind: .visited,
                               source: .automatic, timestamp: sample.timestamp, coordinate: sample.coordinate)
            try store.append(e)
            events.append(e)
            created.append(e)
            if session.targetPlaceId == id { try setTarget(nil) }
        }
        return created
    }

    private var currentPathSegment: Int?

    /// Call when location updates restart after a gap the app couldn't track.
    public func markTrackingGap() { accumulator.breakSegment() }

    // MARK: Controls

    public func pause(at date: Date = .now) throws {
        guard session.status == .active else { return }
        session.status = .paused
        try store.save(session)
        try store.addPause(sessionId: session.id, at: date)
        pauses.append(SessionPause(pausedAt: date))
        accumulator.breakSegment()
        detector.reset()
    }

    public func resume(at date: Date = .now) throws {
        guard session.status == .paused else { return }
        session.status = .active
        try store.save(session)
        try store.closePause(sessionId: session.id, at: date)
        if let i = pauses.lastIndex(where: { $0.resumedAt == nil }) { pauses[i].resumedAt = date }
    }

    public func finish(at date: Date = .now, steps: Int?, pedometerDistance: Double? = nil) throws {
        guard session.status != .finished else { return }
        if session.status == .paused {
            try store.closePause(sessionId: session.id, at: date)
            if let i = pauses.lastIndex(where: { $0.resumedAt == nil }) { pauses[i].resumedAt = date }
        }
        session.status = .finished
        session.endedAt = date
        if let steps { session.steps = steps }
        if let pedometerDistance { session.pedometerDistance = pedometerDistance }
        try store.save(session)
    }

    public func updateSteps(_ steps: Int?, distance: Double? = nil) throws {
        guard let steps, steps != session.steps || distance != session.pedometerDistance else { return }
        session.steps = steps
        if let distance { session.pedometerDistance = distance }
        try store.save(session)
    }

    /// Manual visit/skip/undo. Undoing an automatic visit suppresses re-detection until you leave.
    public func mark(_ placeId: String, _ kind: VisitKind, at date: Date = .now) throws {
        guard let place = places.first(where: { $0.id == placeId }) else { return }
        let e = VisitEvent(sessionId: session.id, placeId: placeId, placeName: place.name, kind: kind,
                           source: .manual, timestamp: date, coordinate: lastSample?.coordinate)
        try store.append(e)
        events.append(e)
        if kind == .reset { detector.suppressUntilExit(placeId) }
        if kind != .reset, session.targetPlaceId == placeId { try setTarget(nil) }
    }

    public func setTarget(_ placeId: String?) throws {
        session.targetPlaceId = placeId
        try store.save(session)
    }

    /// Re-reads the day's plan after it changed (reordering, spontaneous additions).
    public func reloadPlaces() throws {
        places = try store.places(dayId: session.dayId)
    }

    /// Adds a spontaneous destination to the day without interrupting the session.
    @discardableResult
    public func addSpontaneousPlace(name: String, address: String?, coordinate: Coordinate,
                                    afterNext: Bool = true) throws -> Place {
        var p = Place(dayId: session.dayId, name: name, address: address, coordinate: coordinate, origin: .spontaneous)
        p = try store.addPlace(p)
        var ids = try store.places(dayId: session.dayId).map(\.id).filter { $0 != p.id }
        if afterNext, let next = nextPlaceId, let i = ids.firstIndex(of: next) {
            ids.insert(p.id, at: i) // becomes the next stop
        } else {
            ids.append(p.id)
        }
        try store.reorderPlaces(dayId: session.dayId, orderedIds: ids)
        try reloadPlaces()
        return p
    }
}
