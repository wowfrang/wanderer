import Foundation
import Observation
import WandererCore

/// App-wide state: the database, settings and the (single) live exploration session.
@MainActor
@Observable
final class AppModel {
    let store: Store
    let settings = AppSettings()
    let routes: RouteService
    /// Bumped after any plan change so views re-read from the store.
    private(set) var revision = 0
    var live: LiveSession?
    /// The live screen is hidden so the plan can be browsed; a bar offers to return.
    var liveMinimized = false
    var startupError: String?

    init() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let path = url.appendingPathComponent("wanderer.sqlite").path
        let store: Store
        do {
            store = try Store(path: path)
        } catch {
            // Never delete the user's data on a failed open; fall back to memory and say so.
            startupError = "Couldn't open the database: \(error). Nothing will be saved this run."
            store = try! Store.inMemory()
        }
        self.store = store
        self.routes = RouteService(store: store)
        restoreOpenSession()
    }

    func changed() { revision += 1 }

    /// Resumes an unfinished session after the app was killed or relaunched.
    private func restoreOpenSession() {
        guard let open = try? store.openSession(),
              let engine = try? SessionEngine.restore(sessionId: open.id, store: store, config: settings.detection) else { return }
        live = LiveSession(engine: engine, model: self, isRestored: true)
    }

    func startSession(dayId: String) throws {
        let engine = try SessionEngine.start(dayId: dayId, store: store, config: settings.detection)
        live = LiveSession(engine: engine, model: self, isRestored: false)
        liveMinimized = false
        changed()
    }

    func endLiveSession() {
        live?.stopServices()
        live = nil
        liveMinimized = false
        changed()
    }

    // MARK: Convenience reads (errors surface as empty results; the store is local)

    func trips() -> [Trip] { _ = revision; return (try? store.trips()) ?? [] }
    func days(_ tripId: String) -> [Day] { _ = revision; return (try? store.days(tripId: tripId)) ?? [] }
    func places(_ dayId: String) -> [Place] { _ = revision; return (try? store.places(dayId: dayId)) ?? [] }
    func finishedSessions(_ tripId: String) -> [ExplorationSession] {
        _ = revision; return (try? store.finishedSessions(tripId: tripId)) ?? []
    }

    func perform(_ body: (Store) throws -> Void) {
        do { try body(store) } catch { print("Store error: \(error)") }
        changed()
        live?.planChanged()
    }

    @discardableResult
    func loadSample() -> Trip? {
        guard let draft = try? ItineraryParser.parse(ItineraryFormat.sampleMilanJSON()) else { return nil }
        let trip = try? store.insert(draft)
        changed()
        return trip
    }
}

extension AppModel {
    /// Planned walking distance for a day: routed where cached, straight-line estimate elsewhere.
    func plannedDistance(_ places: [Place]) -> (metres: Double, isEstimate: Bool) {
        let coords = places.compactMap(\.coordinate)
        guard coords.count > 1 else { return (0, false) }
        var total = 0.0
        var estimate = false
        for i in 1..<coords.count {
            if let leg = routes.cachedLeg(from: coords[i - 1], to: coords[i]) {
                total += leg.distance
            } else {
                total += Geo.distance(coords[i - 1], coords[i]) * 1.25
                estimate = true
            }
        }
        return (total, estimate)
    }
}
