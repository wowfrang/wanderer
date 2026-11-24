import Foundation
import CoreLocation

/// Thin wrapper around CLLocationManager configured for walking with the phone in a pocket.
///
/// "When In Use" permission is enough: because tracking starts while the app is in the
/// foreground and `allowsBackgroundLocationUpdates` is on (with the `location` background
/// mode), iOS keeps delivering fixes when the screen is locked and shows the blue location
/// indicator. If iOS terminates the app, tracking stops until it is reopened; the session
/// resumes then with a gap in the path.
@MainActor
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onLocations: (([CLLocation]) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    private(set) var isTracking = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.distanceFilter = 4
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var isDenied: Bool { [.denied, .restricted].contains(manager.authorizationStatus) }
    var hasReducedAccuracy: Bool { manager.accuracyAuthorization == .reducedAccuracy }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func start() {
        requestPermission()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        isTracking = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isTracking = false
    }

    /// Foreground-only updates for showing the blue dot while planning.
    func startPreview() {
        requestPermission()
        manager.startUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { onLocations?(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { onAuthorizationChange?(manager.authorizationStatus) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; keep going. Denial arrives via the authorization callback.
    }
}
