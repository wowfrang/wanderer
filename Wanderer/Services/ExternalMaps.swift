import UIKit
import MapKit
import WandererCore

/// Hands off to a real navigation app; Wanderer never does turn-by-turn itself.
enum ExternalMaps {
    @MainActor
    static func openDirections(to place: Place, using app: MapsApp) {
        guard let c = place.coordinate else { return }
        switch app {
        case .apple:
            let item = MKMapItem(placemark: MKPlacemark(coordinate: c.cl))
            item.name = place.name
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
        case .google:
            let ll = "\(c.latitude),\(c.longitude)"
            if let app = URL(string: "comgooglemaps://?daddr=\(ll)&directionsmode=walking"),
               UIApplication.shared.canOpenURL(app) {
                UIApplication.shared.open(app)
            } else if let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(ll)&travelmode=walking") {
                UIApplication.shared.open(web)
            }
        }
    }
}
