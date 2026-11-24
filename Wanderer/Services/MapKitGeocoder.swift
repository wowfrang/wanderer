import Foundation
import MapKit
import WandererCore

/// Geocoding and place search via MKLocalSearch (free, no key, Apple Maps data).
struct MapKitGeocoder: PlaceGeocoder {
    func search(_ query: String, near: Coordinate?) async throws -> [GeocodeCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let near {
            request.region = MKCoordinateRegion(center: near.cl, latitudinalMeters: 15_000, longitudinalMeters: 15_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.map(GeocodeCandidate.init(mapItem:))
    }
}

extension GeocodeCandidate {
    init(mapItem item: MKMapItem) {
        let placemark = item.placemark
        self.init(name: item.name ?? placemark.name ?? "Unnamed place",
                  address: Self.address(placemark),
                  coordinate: Coordinate(placemark.coordinate))
    }

    static func address(_ p: MKPlacemark) -> String? {
        let street = [p.thoroughfare, p.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        let parts = [street.isEmpty ? nil : street, p.locality].compactMap { $0 }
        return parts.isEmpty ? p.title : parts.joined(separator: ", ")
    }
}

extension MKMapItem {
    var categoryName: String? {
        guard let c = pointOfInterestCategory else { return nil }
        return c.rawValue
            .replacingOccurrences(of: "MKPOICategory", with: "")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .lowercased()
    }
}

/// Expands maps.app.goo.gl short links by following the redirect. In the EU Google may send
/// you through consent.google.com first; the real URL is in its `continue` parameter.
enum ShortLinkExpander {
    static func expand(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard var final = response.url else { return url }
        if final.host?.contains("consent.google") == true,
           let cont = URLComponents(url: final, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "continue" })?.value,
           let real = URL(string: cont) {
            final = real
        }
        return final
    }
}
