import Foundation
import CoreLocation
import Observation
import UIKit
import WandererCore

/// Bridges a `SessionEngine` (pure state + persistence) to CoreLocation, CoreMotion and the UI.
@MainActor
@Observable
final class LiveSession {
    let engine: SessionEngine
    private unowned let model: AppModel
    private let tracker = LocationTracker()
    private let pedometer = Pedometer()

    // Observable mirrors of engine state.
    private(set) var session: ExplorationSession
    private(set) var places: [Place]
    private(set) var statuses: [String: PlaceStatus] = [:]
    private(set) var path: [[Coordinate]] = []
    private(set) var nextPlaceId: String?
    private(set) var events: [VisitEvent] = []

    private(set) var currentLocation: CLLocation?
    private(set) var steps: Int?
    private(set) var pedometerDistance: Double?
    private var stepsBase = Pedometer.Reading(steps: 0, distance: nil)
    /// Walking route from where you are to the next stop.
    private(set) var legToNext: RouteLeg?
    private var legOrigin: Coordinate?
    private var legTarget: String?
    /// Planned legs between the remaining stops, in visiting order.
    private(set) var remainingLegs: [RouteLeg] = []
    /// Most recent automatic visit, for the "Visited X · Undo" banner.
    private(set) var lastAutoVisit: VisitEvent?
    private(set) var locationDenied = false
    private(set) var reducedAccuracy = false
    /// The session was restored after a relaunch; there may be a gap in the path.
    let isRestored: Bool

    init(engine: SessionEngine, model: AppModel, isRestored: Bool) {
        self.engine = engine
        self.model = model
        self.isRestored = isRestored
        self.session = engine.session
        self.places = engine.places
        sync()
        configureServices()
    }

    var nextPlace: Place? { nextPlaceId.flatMap { id in places.first { $0.id == id } } }
    var isPaused: Bool { session.status == .paused }
    var isFinished: Bool { session.status == .finished }
    var visitedCount: Int { places.filter { statuses[$0.id] == .visited }.count }
    var locatedPlaces: [Place] { places.filter { $0.coordinate != nil } }

    func status(_ place: Place) -> PlaceStatus { statuses[place.id] ?? .pending }

    func elapsed(at date: Date) -> TimeInterval { engine.elapsed(now: date) }

    /// Distance to the next stop: walking route if we have one, else straight line.
    var distanceToNext: Double? {
        guard let next = nextPlace?.coordinate, let here = currentLocation.map({ Coordinate($0.coordinate) }) else { return nil }
        if let leg = legToNext, leg.to == next, let origin = legOrigin {
            // Adjust the routed distance for how far we've walked since it was computed.
            let moved = Geo.distance(origin, here)
            return max(Geo.distance(here, next), leg.distance - moved)
        }
        return Geo.distance(here, next) * 1.25 // typical street-grid detour
    }

    var timeToNext: TimeInterval? {
        distanceToNext.map { $0 / model.settings.walkingSpeed }
    }

    // MARK: Lifecycle

    private func configureServices() {
        tracker.onLocations = { [weak self] locations in self?.handle(locations) }
        tracker.onAuthorizationChange = { [weak self] status in
            guard let self else { return }
            self.locationDenied = status == .denied || status == .restricted
            self.reducedAccuracy = self.tracker.hasReducedAccuracy
        }
        locationDenied = tracker.isDenied
        if model.settings.notifyOnVisit { VisitNotifier.requestPermission() }
        if isRestored { engine.markTrackingGap() }
        isForeground = UIApplication.shared.applicationState != .background
        updateTracking()
        if session.status == .active { startSteps() }
        Task { await refreshSteps() }
        Task { await refreshRoutes() }
    }

    /// Whether the app is on screen. GPS runs only then, unless background tracking is on.
    private var isForeground = true

    /// Chooses the cheapest location mode that serves what's needed right now.
    private func updateTracking() {
        guard session.status == .active else { tracker.stop(); return }
        if isForeground {
            tracker.startForeground()
        } else if model.settings.backgroundTracking {
            tracker.startBackground()
        } else {
            tracker.stop()
        }
    }

    func stopServices() {
        tracker.stop()
        pedometer.stopLive()
    }

    private func sync() {
        session = engine.session
        places = engine.places
        statuses = engine.statuses
        path = engine.path
        nextPlaceId = engine.nextPlaceId
        events = engine.events
    }

    // MARK: Location

    private func handle(_ locations: [CLLocation]) {
        for location in locations {
            // Ignore cached fixes from before the session started (or from before a resume).
            guard location.timestamp > session.startedAt.addingTimeInterval(-5) else { continue }
            if let current = currentLocation, location.timestamp <= current.timestamp { continue }
            currentLocation = location
            reducedAccuracy = tracker.hasReducedAccuracy
            guard session.status == .active else { continue }
            let sample = GPSSample(timestamp: location.timestamp, coordinate: Coordinate(location.coordinate),
                                   horizontalAccuracy: location.horizontalAccuracy, speed: location.speed)
            do {
                let visits = try engine.ingest(sample)
                if !visits.isEmpty { didAutoVisit(visits) }
            } catch {
                print("Failed to record sample: \(error)")
            }
        }
        let previousNext = nextPlaceId
        sync()
        if previousNext != nextPlaceId { Task { await refreshRoutes() } }
        updateLegToNextIfNeeded()
    }

    private func didAutoVisit(_ visits: [VisitEvent]) {
        lastAutoVisit = visits.last
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if model.settings.notifyOnVisit, UIApplication.shared.applicationState != .active, let v = visits.last {
            sync()
            VisitNotifier.notify(visited: v.placeName, next: nextPlace?.name)
        }
    }

    /// Refetches the "you → next stop" walking route when the target changes or you've
    /// strayed from where it was computed. Throttled to respect MKDirections limits.
    private func updateLegToNextIfNeeded() {
        guard let next = nextPlace, let target = next.coordinate,
              let here = currentLocation.map({ Coordinate($0.coordinate) }),
              (currentLocation?.horizontalAccuracy ?? 999) < 50 else { return }
        let targetChanged = legTarget != next.id
        let moved = legOrigin.map { Geo.distance($0, here) } ?? .infinity
        guard targetChanged || moved > 120 else { return }
        // Only bother with the network in the foreground; in the pocket nobody is looking.
        guard UIApplication.shared.applicationState == .active else { return }
        legTarget = next.id
        legOrigin = here
        Task {
            let leg = await model.routes.leg(from: here, to: target, persist: false)
            if self.legTarget == next.id { self.legToNext = leg }
        }
    }

    func appBecameActive() {
        let wasTracking = tracker.isTracking
        isForeground = true
        if session.status == .active {
            // GPS was off in the pocket: the path continues in a new segment.
            if !wasTracking { engine.markTrackingGap() }
            updateTracking()
            startSteps()
        }
        legOrigin = nil // force a fresh leg
        updateLegToNextIfNeeded()
        Task { await refreshSteps() }
    }

    func appEnteredBackground() {
        isForeground = false
        updateTracking()
        pedometer.stopLive() // live updates aren't delivered in the background anyway
        Task { await refreshSteps() }
    }

    func backgroundTrackingSettingChanged() {
        updateTracking()
    }

    /// A pending place you're standing at right now, for a one-tap "Visited".
    /// Cheap stand-in for dwell detection when you've only just pulled the phone out.
    var nearbyPendingPlace: Place? {
        guard let here = currentLocation, here.horizontalAccuracy >= 0, here.horizontalAccuracy < 50,
              Date().timeIntervalSince(here.timestamp) < 60 else { return nil }
        let config = model.settings.detection
        let c = Coordinate(here.coordinate)
        return locatedPlaces
            .filter { status($0) == .pending }
            .map { ($0, Geo.distance(c, $0.coordinate!)) }
            .filter { $0.1 - min(here.horizontalAccuracy, config.accuracyAllowance) <= ($0.0.radius ?? config.arrivalRadius) }
            .min { $0.1 < $1.1 }?.0
    }

    /// Best current walking distance: pedometer (counts in the pocket) or GPS path.
    var walkedDistance: Double {
        max(pedometerDistance ?? 0, session.walkedDistance)
    }

    /// Remaining stops in the order you'll walk them, starting with the next one.
    var remainingOrder: [Place] {
        let pending = locatedPlaces.filter { status($0) == .pending }
        guard let next = nextPlace, let i = pending.firstIndex(where: { $0.id == next.id }) else { return pending }
        return Array(pending[i...]) + Array(pending[..<i])
    }

    func refreshRoutes() async {
        let coords = remainingOrder.compactMap(\.coordinate)
        remainingLegs = await model.routes.legs(for: coords)
    }

    // MARK: Steps

    private func startSteps() {
        guard Pedometer.isUsable else { steps = nil; return }
        pedometer.stopLive()
        let intervals = engine.activeIntervals()
        let closed = intervals.dropLast()
        let currentStart = intervals.last?.0 ?? session.startedAt
        Task {
            stepsBase = await pedometer.reading(in: Array(closed)) ?? Pedometer.Reading(steps: 0, distance: nil)
            pedometer.startLive(from: currentStart) { [weak self] live in
                guard let self else { return }
                self.steps = self.stepsBase.steps + live.steps
                if let d = live.distance { self.pedometerDistance = (self.stepsBase.distance ?? 0) + d }
            }
        }
    }

    private func refreshSteps() async {
        guard Pedometer.isUsable else { steps = nil; return }
        if let total = await pedometer.reading(in: engine.activeIntervals()) {
            steps = total.steps
            pedometerDistance = total.distance
            try? engine.updateSteps(total.steps, distance: total.distance)
            session = engine.session
        }
    }

    // MARK: Controls

    func pause() {
        try? engine.pause()
        pedometer.stopLive()
        sync()
        updateTracking() // paused: GPS off
        Task { await refreshSteps() }
    }

    func resume() {
        try? engine.resume()
        sync()
        updateTracking()
        Task {
            await refreshSteps()
            startSteps()
        }
    }

    func finish() async {
        pedometer.stopLive()
        tracker.stop()
        let end = Date()
        let intervals = SessionClock.activeIntervals(start: session.startedAt, end: end, pauses: engine.pauses)
        let total = Pedometer.isUsable ? await pedometer.reading(in: intervals) : nil
        try? engine.finish(at: end, steps: total?.steps ?? steps, pedometerDistance: total?.distance ?? pedometerDistance)
        sync()
    }

    func mark(_ place: Place, _ kind: VisitKind) {
        try? engine.mark(place.id, kind)
        if kind == .reset, lastAutoVisit?.placeId == place.id { lastAutoVisit = nil }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sync()
        Task { await refreshRoutes() }
    }

    func undoLastAutoVisit() {
        guard let e = lastAutoVisit, let place = places.first(where: { $0.id == e.placeId }) else { return }
        mark(place, .reset)
        lastAutoVisit = nil
    }

    func dismissAutoVisitBanner() { lastAutoVisit = nil }

    func goNext(_ place: Place) {
        try? engine.setTarget(place.id)
        UISelectionFeedbackGenerator().selectionChanged()
        sync()
        Task { await refreshRoutes() }
        updateLegToNextIfNeeded()
    }

    func addSpontaneous(name: String, address: String?, coordinate: Coordinate, category: String?) {
        guard var p = try? engine.addSpontaneousPlace(name: name, address: address, coordinate: coordinate) else { return }
        if let category {
            p.category = category
            try? model.store.save(p)
            try? engine.reloadPlaces()
        }
        sync()
        model.changed()
        Task { await refreshRoutes() }
    }

    func reorder(_ ids: [String]) {
        try? model.store.reorderPlaces(dayId: session.dayId, orderedIds: ids)
        planChanged()
        model.changed()
    }

    /// Call after the day's plan was edited elsewhere.
    func planChanged() {
        try? engine.reloadPlaces()
        sync()
        Task { await refreshRoutes() }
    }

    func updateDetection(_ config: VisitDetectionConfig) {
        engine.detector.config = config
    }
}
