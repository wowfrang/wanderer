import Foundation

// MARK: - Draft (preview before import)

public struct GeocodeCandidate: Hashable, Sendable {
    public var name: String
    public var address: String?
    public var coordinate: Coordinate

    public init(name: String, address: String? = nil, coordinate: Coordinate) {
        self.name = name
        self.address = address
        self.coordinate = coordinate
    }
}

public enum Resolution: Hashable, Sendable {
    /// Coordinates came with the itinerary and were not checked.
    case provided
    /// Not looked up yet.
    case pending
    /// Exactly one plausible match.
    case resolved
    /// Several plausible matches, or the match disagrees with the supplied coordinates.
    case ambiguous
    /// Nothing found; the place imports without a location (can be fixed later).
    case unresolved
}

public struct PlaceDraft: Identifiable, Hashable, Sendable {
    public var id = UUID().uuidString
    public var name: String
    public var address: String?
    public var providedCoordinate: Coordinate?
    public var details: String?
    public var notes: String?
    public var category: String?
    public var openingHours: String?
    public var visitMinutes: Int?
    public var radius: Double?

    public var resolution: Resolution = .pending
    public var candidates: [GeocodeCandidate] = []
    public var chosenCoordinate: Coordinate?
    /// Lets the user leave out a place in the preview.
    public var include = true

    public var resolvedCoordinate: Coordinate? { chosenCoordinate ?? providedCoordinate }

    public init(name: String, address: String? = nil, providedCoordinate: Coordinate? = nil,
                details: String? = nil, notes: String? = nil, category: String? = nil,
                openingHours: String? = nil, visitMinutes: Int? = nil, radius: Double? = nil) {
        self.name = name
        self.address = address
        self.providedCoordinate = providedCoordinate
        self.details = details
        self.notes = notes
        self.category = category
        self.openingHours = openingHours
        self.visitMinutes = visitMinutes
        self.radius = radius
    }
}

public struct DayDraft: Identifiable, Hashable, Sendable {
    public var id = UUID().uuidString
    public var name: String
    public var date: String?
    public var places: [PlaceDraft]

    public init(name: String, date: String? = nil, places: [PlaceDraft]) {
        self.name = name
        self.date = date
        self.places = places
    }
}

public struct TripDraft: Hashable, Sendable {
    public var name: String
    public var days: [DayDraft]
    /// Non-fatal problems found while parsing (shown in the preview).
    public var warnings: [String]

    public init(name: String, days: [DayDraft], warnings: [String] = []) {
        self.name = name
        self.days = days
        self.warnings = warnings
    }

    public var allPlaces: [PlaceDraft] { days.flatMap(\.places) }
    public var needsAttentionCount: Int {
        allPlaces.filter { $0.include && ($0.resolution == .ambiguous || $0.resolution == .unresolved) }.count
    }
}

public struct ImportError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

// MARK: - JSON itinerary

/// Parses the documented itinerary JSON (see `ItineraryFormat.schemaDescription`).
///
/// Deliberately lenient, because LLM output varies: it strips Markdown code fences and
/// surrounding prose, accepts common key aliases (lat/latitude, lng/lon/longitude,
/// duration_minutes/visit_minutes, …) and nested `location`/`coordinates` objects.
public enum ItineraryParser {
    public static func parse(_ text: String) throws -> TripDraft {
        let json = extractJSON(from: text)
        guard let data = json.data(using: .utf8) else { throw ImportError("The text isn't valid UTF-8.") }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ImportError("That doesn't look like valid JSON. Paste the whole block, from the first { to the last }.")
        }

        var warnings: [String] = []
        let object: [String: Any]
        if let dict = root as? [String: Any] {
            object = (dict["trip"] as? [String: Any]) ?? dict
        } else if let array = root as? [Any] {
            object = ["days": array] // bare list of days
        } else {
            throw ImportError("Expected a JSON object with a \"days\" list.")
        }

        let tripName = string(object, "trip_name", "tripName", "name", "title", "trip") ?? "Imported trip"
        var rawDays = (object["days"] as? [Any]) ?? []
        if rawDays.isEmpty, let places = object["places"] as? [Any] {
            rawDays = [["name": "Day 1", "places": places]]
        }
        guard !rawDays.isEmpty else { throw ImportError("No days found. The JSON needs a \"days\" list.") }

        var days: [DayDraft] = []
        for (dayIndex, rawDay) in rawDays.enumerated() {
            guard let d = rawDay as? [String: Any] else {
                warnings.append("Day \(dayIndex + 1) isn't an object and was skipped.")
                continue
            }
            let dayName = string(d, "name", "title", "day_name", "dayName", "label") ?? "Day \(dayIndex + 1)"
            let date = normalizeDate(string(d, "date", "day_date"))
            if let raw = string(d, "date"), date == nil {
                warnings.append("\(dayName): couldn't read the date \"\(raw)\"; use YYYY-MM-DD.")
            }
            let rawPlaces = (d["places"] as? [Any]) ?? (d["stops"] as? [Any]) ?? (d["items"] as? [Any]) ?? []
            var places: [PlaceDraft] = []
            for (placeIndex, rawPlace) in rawPlaces.enumerated() {
                if let name = rawPlace as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    places.append(PlaceDraft(name: name))
                    continue
                }
                guard let p = rawPlace as? [String: Any] else {
                    warnings.append("\(dayName), stop \(placeIndex + 1) was skipped (not an object).")
                    continue
                }
                guard let name = string(p, "name", "title", "place", "place_name") else {
                    warnings.append("\(dayName), stop \(placeIndex + 1) has no name and was skipped.")
                    continue
                }
                var coordinate = self.coordinate(p)
                if let c = coordinate, !c.isValid {
                    warnings.append("\(name): coordinates are out of range and were ignored.")
                    coordinate = nil
                }
                places.append(PlaceDraft(
                    name: name,
                    address: string(p, "address", "street_address", "location_address"),
                    providedCoordinate: coordinate,
                    details: string(p, "description", "details", "summary", "why"),
                    notes: string(p, "notes", "note", "tips"),
                    category: string(p, "category", "type", "kind"),
                    openingHours: string(p, "opening_hours", "openingHours", "hours"),
                    visitMinutes: int(p, "visit_minutes", "visitMinutes", "duration_minutes", "durationMinutes", "duration", "minutes"),
                    radius: double(p, "radius_m", "radius", "arrival_radius_m")
                ))
            }
            if places.isEmpty { warnings.append("\(dayName) has no places.") }
            days.append(DayDraft(name: dayName, date: date, places: places))
        }
        guard days.contains(where: { !$0.places.isEmpty }) else {
            throw ImportError("No places found in any day.")
        }
        for i in days.indices {
            for j in days[i].places.indices where days[i].places[j].providedCoordinate != nil {
                days[i].places[j].resolution = .provided
            }
        }
        return TripDraft(name: tripName, days: days, warnings: warnings)
    }

    /// Pulls the JSON payload out of a chat reply: code fences, leading prose, trailing prose.
    public static func extractJSON(from text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Smart quotes from some keyboards/pasteboards break JSON.
        t = t.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        if let fence = t.range(of: "```") {
            let afterFence = t[fence.upperBound...]
            let bodyStart = afterFence.firstIndex(of: "\n").map { afterFence.index(after: $0) } ?? afterFence.startIndex
            if let close = t[bodyStart...].range(of: "```") {
                t = String(t[bodyStart..<close.lowerBound])
            }
        }
        let starts = [t.firstIndex(of: "{"), t.firstIndex(of: "[")].compactMap { $0 }
        if let start = starts.min() {
            let closer: Character = t[start] == "{" ? "}" : "]"
            if let end = t.lastIndex(of: closer), end > start {
                t = String(t[start...end])
            }
        }
        return t
    }

    static func string(_ d: [String: Any], _ keys: String...) -> String? {
        for k in keys {
            if let s = d[k] as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let list = d[k] as? [String], !list.isEmpty { return list.joined(separator: "; ") }
            if let n = d[k] as? NSNumber, k != "trip" { return n.stringValue }
        }
        return nil
    }

    static func double(_ d: [String: Any], _ keys: String...) -> Double? {
        for k in keys {
            if let n = d[k] as? NSNumber { return n.doubleValue }
            if let s = d[k] as? String, let v = Double(s.trimmingCharacters(in: .whitespaces)) { return v }
        }
        return nil
    }

    static func int(_ d: [String: Any], _ keys: String...) -> Int? {
        for k in keys {
            if let n = d[k] as? NSNumber { return Int(n.doubleValue.rounded()) }
            if let s = d[k] as? String {
                // "45", "45 min", "1h 30m", "1.5 hours"
                let lower = s.lowercased()
                let numbers = lower.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
                guard let first = numbers.first else { continue }
                if lower.contains("h") {
                    let minutes = numbers.count > 1 ? numbers[1] : 0
                    return Int((first * 60 + minutes).rounded())
                }
                return Int(first.rounded())
            }
        }
        return nil
    }

    static func coordinate(_ p: [String: Any]) -> Coordinate? {
        if let lat = double(p, "lat", "latitude"), let lng = double(p, "lng", "lon", "long", "longitude") {
            return Coordinate(latitude: lat, longitude: lng)
        }
        for key in ["coordinates", "location", "coords", "geo", "position"] {
            if let nested = p[key] as? [String: Any], let c = coordinate(nested) { return c }
            if let pair = p[key] as? [NSNumber], pair.count == 2 {
                // [lat, lng] is the documented order.
                return Coordinate(latitude: pair[0].doubleValue, longitude: pair[1].doubleValue)
            }
        }
        return nil
    }

    static func normalizeDate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "dd.MM.yyyy", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: raw) {
                f.dateFormat = "yyyy-MM-dd"
                return f.string(from: d)
            }
        }
        return nil
    }
}

// MARK: - Google Maps directions URLs

/// Parses Google Maps directions links into an ordered list of stops.
///
/// Supported forms:
/// - `https://www.google.com/maps/dir/Place+A/Place+B/@45.46,9.18,15z/data=…`
/// - `https://www.google.com/maps/dir/?api=1&origin=…&destination=…&waypoints=a|b`
/// Short links (`maps.app.goo.gl/…`) must be expanded by following the redirect first;
/// the app does that before calling this.
public enum GoogleMapsURLParser {
    public static func isShortLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "maps.app.goo.gl" || host == "goo.gl"
    }

    public static func parse(_ text: String, tripName: String = "Google Maps route") throws -> TripDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(),
              host.contains("google.") || host.contains("goo.gl") else {
            throw ImportError("That isn't a Google Maps link.")
        }
        if isShortLink(url) { throw ImportError("Short link needs expanding first.") }

        var stops: [PlaceDraft] = []
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }

        if q("api") == "1" {
            let waypoints = (q("waypoints") ?? "").split(separator: "|").map(String.init)
            for raw in [q("origin")].compactMap({ $0 }) + waypoints + [q("destination")].compactMap({ $0 }) {
                stops.append(draft(from: raw))
            }
        } else {
            // Path form: /maps/dir/<stop>/<stop>/@lat,lng,zoom/data=...
            let parts = url.path.split(separator: "/").map(String.init)
            guard let dirIndex = parts.firstIndex(of: "dir") else {
                throw ImportError("Only Google Maps directions links are supported (they contain /maps/dir/).")
            }
            for part in parts[(dirIndex + 1)...] {
                if part.hasPrefix("@") || part.hasPrefix("data=") || part.hasPrefix("am=") { break }
                let decoded = (part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? part)
                    .trimmingCharacters(in: .whitespaces)
                if decoded.isEmpty { continue }
                stops.append(draft(from: decoded))
            }
            // The data blob carries coordinates as !1d<lng>!2d<lat> pairs, in stop order, for
            // stops that were picked as places. Only trust it when counts line up.
            let pairs = dataCoordinates(in: trimmed)
            let named = stops.indices.filter { stops[$0].providedCoordinate == nil }
            if !pairs.isEmpty, pairs.count == named.count {
                for (i, idx) in named.enumerated() {
                    stops[idx].providedCoordinate = pairs[i]
                }
            }
        }
        stops = stops.filter { !$0.name.isEmpty }
        // "Your location" style placeholders aren't real stops.
        stops.removeAll { ["my location", "your location", "current location"].contains($0.name.lowercased()) }
        guard !stops.isEmpty else { throw ImportError("No stops found in that link.") }
        for i in stops.indices where stops[i].providedCoordinate != nil { stops[i].resolution = .provided }
        return TripDraft(name: tripName, days: [DayDraft(name: "Day 1", places: stops)])
    }

    static func draft(from raw: String) -> PlaceDraft {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let lat = Double(parts[0]), let lng = Double(parts[1]) {
            let c = Coordinate(latitude: lat, longitude: lng)
            if c.isValid { return PlaceDraft(name: String(format: "%.5f, %.5f", lat, lng), providedCoordinate: c) }
        }
        // "Pinacoteca di Brera, Via Brera, 28, Milano" → name + address
        if let comma = s.firstIndex(of: ",") {
            let name = String(s[..<comma]).trimmingCharacters(in: .whitespaces)
            let address = String(s[s.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            return PlaceDraft(name: name, address: address.isEmpty ? nil : s)
        }
        return PlaceDraft(name: s)
    }

    static func dataCoordinates(in text: String) -> [Coordinate] {
        var result: [Coordinate] = []
        let scanner = text as NSString
        guard let regex = try? NSRegularExpression(pattern: "!1d(-?\\d+(?:\\.\\d+)?)!2d(-?\\d+(?:\\.\\d+)?)") else { return [] }
        for m in regex.matches(in: text, range: NSRange(location: 0, length: scanner.length)) {
            if let lng = Double(scanner.substring(with: m.range(at: 1))),
               let lat = Double(scanner.substring(with: m.range(at: 2))) {
                result.append(Coordinate(latitude: lat, longitude: lng))
            }
        }
        return result
    }
}

// MARK: - Geocoding resolution

public protocol PlaceGeocoder: Sendable {
    /// Returns candidate matches, best first. `near` biases the search to the trip's area.
    func search(_ query: String, near: Coordinate?) async throws -> [GeocodeCandidate]
}

public struct ResolutionPolicy: Sendable {
    /// Candidates further apart than this are considered genuinely different places.
    public var ambiguityDistance: Double = 400
    /// A geocoded result this far from the supplied coordinates is flagged for review.
    public var conflictDistance: Double = 1_000
    /// A place this far from the rest of the trip is probably the wrong match.
    public var outlierDistance: Double = 40_000

    public init() {}
}

public enum ItineraryResolver {
    /// Geocodes places in the draft. LLM-supplied coordinates are often off by hundreds of
    /// metres, so when an address is present we look it up and prefer Apple's answer, but
    /// flag big disagreements instead of silently picking one.
    public static func resolve(_ draft: TripDraft, using geocoder: PlaceGeocoder, cityHint: String? = nil,
                               policy: ResolutionPolicy = .init()) async -> TripDraft {
        var draft = draft
        var anchor = Geo.median(of: draft.allPlaces.compactMap(\.providedCoordinate))
        for dayIndex in draft.days.indices {
            for placeIndex in draft.days[dayIndex].places.indices {
                let p = draft.days[dayIndex].places[placeIndex]
                guard p.resolution == .pending || (p.resolution == .provided && p.address != nil) else { continue }
                let resolved = await resolvePlace(p, geocoder: geocoder, near: anchor, cityHint: cityHint, policy: policy)
                draft.days[dayIndex].places[placeIndex] = resolved
                if anchor == nil, let c = resolved.resolvedCoordinate { anchor = c }
            }
        }
        // Outlier pass: a match far away from the trip's centre is suspicious.
        if let centre = Geo.median(of: draft.allPlaces.compactMap(\.resolvedCoordinate)) {
            for d in draft.days.indices {
                for i in draft.days[d].places.indices {
                    let p = draft.days[d].places[i]
                    if p.resolution == .resolved, let c = p.resolvedCoordinate,
                       Geo.distance(c, centre) > policy.outlierDistance {
                        draft.days[d].places[i].resolution = .ambiguous
                    }
                }
            }
        }
        return draft
    }

    static func resolvePlace(_ p: PlaceDraft, geocoder: PlaceGeocoder, near: Coordinate?, cityHint: String?,
                             policy: ResolutionPolicy) async -> PlaceDraft {
        var p = p
        var queries: [String] = []
        if let address = p.address {
            queries.append(address.localizedCaseInsensitiveContains(p.name) ? address : "\(p.name), \(address)")
            queries.append(address)
        }
        queries.append(cityHint.map { "\(p.name), \($0)" } ?? p.name)
        if cityHint != nil { queries.append(p.name) }

        var candidates: [GeocodeCandidate] = []
        for query in queries {
            if let found = try? await geocoder.search(query, near: near), !found.isEmpty {
                candidates = found
                break
            }
        }
        guard let best = candidates.first else {
            p.resolution = p.providedCoordinate != nil ? .provided : .unresolved
            return p
        }
        // Keep distinct candidates only (dedupe matches within 50 m).
        var distinct: [GeocodeCandidate] = []
        for c in candidates where !distinct.contains(where: { Geo.distance($0.coordinate, c.coordinate) < 50 }) {
            distinct.append(c)
        }
        p.candidates = Array(distinct.prefix(5))
        p.chosenCoordinate = best.coordinate
        if p.address == nil { p.address = best.address }

        if let provided = p.providedCoordinate, Geo.distance(provided, best.coordinate) > policy.conflictDistance {
            p.resolution = .ambiguous
            p.candidates.append(GeocodeCandidate(name: "Coordinates from the itinerary", coordinate: provided))
        } else if distinct.prefix(3).dropFirst().contains(where: {
            Geo.distance($0.coordinate, best.coordinate) > policy.ambiguityDistance
        }) {
            p.resolution = .ambiguous
        } else {
            p.resolution = .resolved
        }
        return p
    }
}
