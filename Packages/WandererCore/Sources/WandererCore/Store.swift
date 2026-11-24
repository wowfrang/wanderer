import Foundation

/// Versioned schema. Append new migrations; never edit a shipped one. Each runs in a
/// transaction and bumps PRAGMA user_version, so existing trip data is preserved.
public enum Migrations {
    public static let all: [String] = [
        // v1: initial schema
        """
        CREATE TABLE trips (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE days (
            id TEXT PRIMARY KEY,
            trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            date TEXT,
            position INTEGER NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX days_trip ON days(trip_id, position);
        CREATE TABLE places (
            id TEXT PRIMARY KEY,
            day_id TEXT NOT NULL REFERENCES days(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            name TEXT NOT NULL,
            address TEXT,
            latitude REAL,
            longitude REAL,
            notes TEXT,
            category TEXT,
            details TEXT,
            opening_hours TEXT,
            visit_minutes INTEGER,
            radius REAL,
            origin TEXT NOT NULL DEFAULT 'plan',
            created_at REAL NOT NULL
        );
        CREATE INDEX places_day ON places(day_id, position);
        CREATE TABLE route_legs (
            from_key TEXT NOT NULL,
            to_key TEXT NOT NULL,
            points TEXT NOT NULL,
            distance REAL NOT NULL,
            travel_time REAL NOT NULL,
            created_at REAL NOT NULL,
            PRIMARY KEY (from_key, to_key)
        );
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            day_id TEXT NOT NULL REFERENCES days(id) ON DELETE CASCADE,
            status TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            distance REAL NOT NULL DEFAULT 0,
            steps INTEGER,
            target_place_id TEXT
        );
        CREATE INDEX sessions_day ON sessions(day_id, started_at);
        CREATE TABLE session_pauses (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            paused_at REAL NOT NULL,
            resumed_at REAL
        );
        CREATE TABLE gps_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            timestamp REAL NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            accuracy REAL NOT NULL,
            speed REAL NOT NULL,
            segment INTEGER NOT NULL,
            accepted INTEGER NOT NULL
        );
        CREATE INDEX gps_session ON gps_samples(session_id, id);
        CREATE TABLE visit_events (
            id TEXT PRIMARY KEY,
            seq INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            place_id TEXT REFERENCES places(id) ON DELETE SET NULL,
            place_name TEXT NOT NULL,
            kind TEXT NOT NULL,
            source TEXT NOT NULL,
            timestamp REAL NOT NULL,
            latitude REAL,
            longitude REAL
        );
        CREATE INDEX visits_session ON visit_events(session_id, seq);
        """,
    ]
}

/// Typed persistence for plans and exploration sessions.
public final class Store {
    public let db: SQLiteConnection

    public init(path: String, migrations: [String] = Migrations.all) throws {
        db = try SQLiteConnection(path: path)
        try migrate(migrations)
    }

    public static func inMemory() throws -> Store { try Store(path: ":memory:") }

    public var schemaVersion: Int { db.userVersion }

    private func migrate(_ migrations: [String]) throws {
        let current = db.userVersion
        guard current < migrations.count else { return }
        for version in current..<migrations.count {
            try db.transaction {
                try db.execute(migrations[version])
                try db.setUserVersion(version + 1)
            }
        }
    }

    // MARK: Trips

    public func trips() throws -> [Trip] {
        try db.query("SELECT id, name, created_at, updated_at FROM trips ORDER BY updated_at DESC") {
            Trip(id: $0.string(0), name: $0.string(1), createdAt: $0.date(2), updatedAt: $0.date(3))
        }
    }

    public func trip(id: String) throws -> Trip? {
        try db.query("SELECT id, name, created_at, updated_at FROM trips WHERE id = ?", id) {
            Trip(id: $0.string(0), name: $0.string(1), createdAt: $0.date(2), updatedAt: $0.date(3))
        }.first
    }

    public func save(_ trip: Trip) throws {
        try db.run("""
            INSERT INTO trips (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at
            """, trip.id, trip.name, trip.createdAt, trip.updatedAt)
    }

    public func touchTrip(_ id: String) throws {
        try db.run("UPDATE trips SET updated_at = ? WHERE id = ?", Date(), id)
    }

    public func deleteTrip(_ id: String) throws {
        try db.run("DELETE FROM trips WHERE id = ?", id)
    }

    // MARK: Days

    private static let dayColumns = "id, trip_id, name, date, position, created_at"
    private func day(_ r: Row) -> Day {
        Day(id: r.string(0), tripId: r.string(1), name: r.string(2), date: r.optionalString(3),
            position: r.int(4), createdAt: r.date(5))
    }

    public func days(tripId: String) throws -> [Day] {
        try db.query("SELECT \(Self.dayColumns) FROM days WHERE trip_id = ? ORDER BY position, created_at", tripId, map: day)
    }

    public func day(id: String) throws -> Day? {
        try db.query("SELECT \(Self.dayColumns) FROM days WHERE id = ?", id, map: day).first
    }

    public func save(_ day: Day) throws {
        try db.run("""
            INSERT INTO days (id, trip_id, name, date, position, created_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, date = excluded.date, position = excluded.position
            """, day.id, day.tripId, day.name, day.date, day.position, day.createdAt)
        try touchTrip(day.tripId)
    }

    /// Appends a new day at the end of the trip.
    @discardableResult
    public func addDay(tripId: String, name: String, date: String? = nil) throws -> Day {
        let next = (try db.scalarInt("SELECT MAX(position) FROM days WHERE trip_id = ?", tripId) ?? -1) + 1
        let d = Day(tripId: tripId, name: name, date: date, position: next)
        try save(d)
        return d
    }

    public func deleteDay(_ id: String) throws {
        try db.run("DELETE FROM days WHERE id = ?", id)
    }

    // MARK: Places

    private static let placeColumns = """
        id, day_id, position, name, address, latitude, longitude, notes, category, details,
        opening_hours, visit_minutes, radius, origin, created_at
        """
    private func place(_ r: Row) -> Place {
        var coordinate: Coordinate?
        if let lat = r.optionalDouble(5), let lng = r.optionalDouble(6) {
            coordinate = Coordinate(latitude: lat, longitude: lng)
        }
        return Place(id: r.string(0), dayId: r.string(1), position: r.int(2), name: r.string(3),
                     address: r.optionalString(4), coordinate: coordinate, notes: r.optionalString(7),
                     category: r.optionalString(8), details: r.optionalString(9),
                     openingHours: r.optionalString(10), visitMinutes: r.optionalInt(11),
                     radius: r.optionalDouble(12), origin: PlaceOrigin(rawValue: r.string(13)) ?? .plan,
                     createdAt: r.date(14))
    }

    public func places(dayId: String) throws -> [Place] {
        try db.query("SELECT \(Self.placeColumns) FROM places WHERE day_id = ? ORDER BY position, created_at", dayId, map: place)
    }

    public func place(id: String) throws -> Place? {
        try db.query("SELECT \(Self.placeColumns) FROM places WHERE id = ?", id, map: place).first
    }

    public func save(_ p: Place) throws {
        try db.run("""
            INSERT INTO places (id, day_id, position, name, address, latitude, longitude, notes, category,
                                details, opening_hours, visit_minutes, radius, origin, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                day_id = excluded.day_id, position = excluded.position, name = excluded.name,
                address = excluded.address, latitude = excluded.latitude, longitude = excluded.longitude,
                notes = excluded.notes, category = excluded.category, details = excluded.details,
                opening_hours = excluded.opening_hours, visit_minutes = excluded.visit_minutes,
                radius = excluded.radius, origin = excluded.origin
            """, params: [p.id, p.dayId, p.position, p.name, p.address, p.coordinate?.latitude,
                          p.coordinate?.longitude, p.notes, p.category, p.details, p.openingHours,
                          p.visitMinutes, p.radius, p.origin.rawValue, p.createdAt])
    }

    /// Appends a place at the end of a day.
    @discardableResult
    public func addPlace(_ p: Place) throws -> Place {
        var p = p
        p.position = (try db.scalarInt("SELECT MAX(position) FROM places WHERE day_id = ?", p.dayId) ?? -1) + 1
        try save(p)
        return p
    }

    public func deletePlace(_ id: String) throws {
        try db.run("DELETE FROM places WHERE id = ?", id)
    }

    /// Rewrites positions so the day's places follow `orderedIds`.
    public func reorderPlaces(dayId: String, orderedIds: [String]) throws {
        try db.transaction {
            for (i, id) in orderedIds.enumerated() {
                try db.run("UPDATE places SET position = ? WHERE id = ? AND day_id = ?", i, id, dayId)
            }
        }
    }

    /// Moves a place to the end of another day.
    public func movePlace(_ id: String, toDay dayId: String) throws {
        guard var p = try place(id: id) else { return }
        let oldDay = p.dayId
        p.dayId = dayId
        p.position = (try db.scalarInt("SELECT MAX(position) FROM places WHERE day_id = ?", dayId) ?? -1) + 1
        try save(p)
        let remaining = try places(dayId: oldDay).map(\.id)
        try reorderPlaces(dayId: oldDay, orderedIds: remaining)
    }

    // MARK: Route cache

    public func cachedLeg(from: Coordinate, to: Coordinate) throws -> RouteLeg? {
        try db.query("SELECT points, distance, travel_time FROM route_legs WHERE from_key = ? AND to_key = ?",
                     from.cacheKey, to.cacheKey) { r -> RouteLeg? in
            guard let data = r.string(0).data(using: .utf8),
                  let flat = try? JSONDecoder().decode([Double].self, from: data) else { return nil }
            var points: [Coordinate] = []
            points.reserveCapacity(flat.count / 2)
            var i = 0
            while i + 1 < flat.count {
                points.append(Coordinate(latitude: flat[i], longitude: flat[i + 1]))
                i += 2
            }
            return RouteLeg(from: from, to: to, points: points, distance: r.double(1), expectedTravelTime: r.double(2))
        }.first ?? nil
    }

    public func cache(_ leg: RouteLeg) throws {
        guard leg.isWalkingRoute else { return } // never cache fallbacks
        let flat = leg.points.flatMap { [($0.latitude * 1e6).rounded() / 1e6, ($0.longitude * 1e6).rounded() / 1e6] }
        let json = String(data: try JSONEncoder().encode(flat), encoding: .utf8) ?? "[]"
        try db.run("""
            INSERT OR REPLACE INTO route_legs (from_key, to_key, points, distance, travel_time, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, leg.from.cacheKey, leg.to.cacheKey, json, leg.distance, leg.expectedTravelTime, Date())
    }

    // MARK: Sessions

    private static let sessionColumns = "id, day_id, status, started_at, ended_at, distance, steps, target_place_id"
    private func session(_ r: Row) -> ExplorationSession {
        ExplorationSession(id: r.string(0), dayId: r.string(1), status: SessionStatus(rawValue: r.string(2)) ?? .finished,
                           startedAt: r.date(3), endedAt: r.optionalDate(4), distance: r.double(5),
                           steps: r.optionalInt(6), targetPlaceId: r.optionalString(7))
    }

    public func save(_ s: ExplorationSession) throws {
        try db.run("""
            INSERT INTO sessions (id, day_id, status, started_at, ended_at, distance, steps, target_place_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET status = excluded.status, ended_at = excluded.ended_at,
                distance = excluded.distance, steps = excluded.steps, target_place_id = excluded.target_place_id
            """, params: [s.id, s.dayId, s.status.rawValue, s.startedAt, s.endedAt, s.distance, s.steps, s.targetPlaceId])
    }

    public func session(id: String) throws -> ExplorationSession? {
        try db.query("SELECT \(Self.sessionColumns) FROM sessions WHERE id = ?", id, map: session).first
    }

    /// The unfinished session, if any (at most one is allowed at a time).
    public func openSession() throws -> ExplorationSession? {
        try db.query("SELECT \(Self.sessionColumns) FROM sessions WHERE status != 'finished' ORDER BY started_at DESC LIMIT 1",
                     map: session).first
    }

    public func sessions(dayId: String) throws -> [ExplorationSession] {
        try db.query("SELECT \(Self.sessionColumns) FROM sessions WHERE day_id = ? ORDER BY started_at DESC", dayId, map: session)
    }

    public func finishedSessions(tripId: String) throws -> [ExplorationSession] {
        try db.query("""
            SELECT s.id, s.day_id, s.status, s.started_at, s.ended_at, s.distance, s.steps, s.target_place_id
            FROM sessions s JOIN days d ON d.id = s.day_id
            WHERE d.trip_id = ? AND s.status = 'finished' ORDER BY s.started_at DESC
            """, tripId, map: session)
    }

    public func deleteSession(_ id: String) throws {
        try db.run("DELETE FROM sessions WHERE id = ?", id)
    }

    public func pauses(sessionId: String) throws -> [SessionPause] {
        try db.query("SELECT paused_at, resumed_at FROM session_pauses WHERE session_id = ? ORDER BY paused_at", sessionId) {
            SessionPause(pausedAt: $0.date(0), resumedAt: $0.optionalDate(1))
        }
    }

    public func addPause(sessionId: String, at date: Date) throws {
        try db.run("INSERT INTO session_pauses (session_id, paused_at) VALUES (?, ?)", sessionId, date)
    }

    public func closePause(sessionId: String, at date: Date) throws {
        try db.run("UPDATE session_pauses SET resumed_at = ? WHERE session_id = ? AND resumed_at IS NULL", date, sessionId)
    }

    public func append(_ sample: GPSSample, sessionId: String) throws {
        try db.run("""
            INSERT INTO gps_samples (session_id, timestamp, latitude, longitude, accuracy, speed, segment, accepted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, params: [sessionId, sample.timestamp, sample.coordinate.latitude, sample.coordinate.longitude,
                          sample.horizontalAccuracy, sample.speed, sample.segment, sample.accepted])
    }

    public func samples(sessionId: String, acceptedOnly: Bool = false) throws -> [GPSSample] {
        let filter = acceptedOnly ? " AND accepted = 1" : ""
        return try db.query("""
            SELECT timestamp, latitude, longitude, accuracy, speed, segment, accepted
            FROM gps_samples WHERE session_id = ?\(filter) ORDER BY id
            """, sessionId) {
            GPSSample(timestamp: $0.date(0), coordinate: Coordinate(latitude: $0.double(1), longitude: $0.double(2)),
                      horizontalAccuracy: $0.double(3), speed: $0.double(4), segment: $0.int(5), accepted: $0.bool(6))
        }
    }

    public func append(_ e: VisitEvent) throws {
        let seq = (try db.scalarInt("SELECT MAX(seq) FROM visit_events WHERE session_id = ?", e.sessionId) ?? 0) + 1
        try db.run("""
            INSERT INTO visit_events (id, seq, session_id, place_id, place_name, kind, source, timestamp, latitude, longitude)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, params: [e.id, seq, e.sessionId, e.placeId, e.placeName, e.kind.rawValue, e.source.rawValue,
                          e.timestamp, e.coordinate?.latitude, e.coordinate?.longitude])
    }

    public func visitEvents(sessionId: String) throws -> [VisitEvent] {
        try db.query("""
            SELECT id, session_id, place_id, place_name, kind, source, timestamp, latitude, longitude
            FROM visit_events WHERE session_id = ? ORDER BY seq
            """, sessionId) { r in
            var c: Coordinate?
            if let lat = r.optionalDouble(7), let lng = r.optionalDouble(8) { c = Coordinate(latitude: lat, longitude: lng) }
            return VisitEvent(id: r.string(0), sessionId: r.string(1), placeId: r.optionalString(2),
                              placeName: r.string(3), kind: VisitKind(rawValue: r.string(4)) ?? .reset,
                              source: VisitSource(rawValue: r.string(5)) ?? .manual, timestamp: r.date(6), coordinate: c)
        }
    }

    // MARK: Import

    /// Persists an import draft as a new trip in one transaction. Returns the trip.
    @discardableResult
    public func insert(_ draft: TripDraft) throws -> Trip {
        try db.transaction {
            let trip = Trip(name: draft.name)
            try save(trip)
            for (dayIndex, d) in draft.days.enumerated() {
                let day = Day(tripId: trip.id, name: d.name, date: d.date, position: dayIndex)
                try save(day)
                var position = 0
                for p in d.places where p.include {
                    try save(Place(dayId: day.id, position: position, name: p.name, address: p.address,
                                   coordinate: p.resolvedCoordinate, notes: p.notes, category: p.category,
                                   details: p.details, openingHours: p.openingHours, visitMinutes: p.visitMinutes,
                                   radius: p.radius))
                    position += 1
                }
            }
            return trip
        }
    }
}
