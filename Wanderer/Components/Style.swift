import SwiftUI
import MapKit
import WandererCore

extension Color {
    /// The single accent: a muted vermilion, slightly brighter in dark mode.
    static let signal = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.42, blue: 0.24, alpha: 1)
            : UIColor(red: 0.85, green: 0.29, blue: 0.11, alpha: 1)
    })
    static let plannedRoute = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.85, alpha: 0.85)
            : UIColor(white: 0.20, alpha: 0.75)
    })
    static let muted = Color(UIColor.tertiaryLabel)
}

extension Font {
    /// Small uppercase label used above values ("NEXT", "DISTANCE").
    static let eyebrow = Font.system(size: 11, weight: .semibold).width(.condensed)
    static let statValue = Font.system(size: 22, weight: .semibold, design: .default).monospacedDigit()
}

struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.eyebrow)
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

struct Stat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(label)
            Text(value)
                .font(.statValue)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    init(_ c: CLLocationCoordinate2D) { self.init(latitude: c.latitude, longitude: c.longitude) }
}

enum MapFit {
    /// A camera position showing all coordinates with some breathing room.
    static func position(_ coordinates: [Coordinate], minimumSpan: Double = 0.006) -> MapCameraPosition? {
        guard let b = Geo.bounds(of: coordinates) else { return nil }
        let span = MKCoordinateSpan(latitudeDelta: max(b.latitudeSpan * 1.45, minimumSpan),
                                    longitudeDelta: max(b.longitudeSpan * 1.45, minimumSpan))
        return .region(MKCoordinateRegion(center: b.center.cl, span: span))
    }
}

extension Place {
    var subtitle: String? {
        var parts: [String] = []
        if let category, !category.isEmpty { parts.append(category.capitalized) }
        if let visitMinutes { parts.append("\(visitMinutes) min") }
        if coordinate == nil { parts.append("No location") }
        return parts.isEmpty ? address : parts.joined(separator: " · ")
    }
}

extension View {
    /// The app's one primary button style: solid, compact, not pill-shaped.
    func primaryButton() -> some View {
        self.font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.primary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(Color(UIColor.systemBackground))
    }

    func secondaryButton() -> some View {
        self.font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(.primary)
    }
}

enum DayFormat {
    static func title(_ day: Day) -> String? {
        guard let date = day.date, let d = parse(date) else { return nil }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
    static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
    static func string(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

enum PathGaps {
    /// Two-point lines joining the end of each walked segment to the start of the next.
    static func connectors(_ segments: [[Coordinate]]) -> [[Coordinate]] {
        let nonEmpty = segments.filter { !$0.isEmpty }
        guard nonEmpty.count > 1 else { return [] }
        return (1..<nonEmpty.count).compactMap { i in
            guard let a = nonEmpty[i - 1].last, let b = nonEmpty[i].first, Geo.distance(a, b) > 10 else { return nil }
            return [a, b]
        }
    }
}

enum MapLayer {
    static func style(satellite: Bool) -> MapStyle {
        satellite
            ? .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
            : .standard(emphasis: .muted, pointsOfInterest: .excludingAll)
    }

    /// The planned route needs to be light on aerial imagery and dark on the map.
    static func plannedRoute(satellite: Bool) -> Color {
        satellite ? Color.white.opacity(0.9) : Color.plannedRoute
    }
}
