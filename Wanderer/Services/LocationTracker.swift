import Foundation
import CoreLocation

/// Thin wrapper around CLLocationManager, built to be gentle on the battery.
///
/// By default GPS only runs while the exploration screen is open in the foreground. When the
/// app goes to the background, updates stop entirely; the pedometer keeps counting steps and
/// distance for free. With "Track in background" on, updates continue with the screen locked
/// (this needs the `location` background mode, already in Info.plist) but at ~10 m accuracy
/// with a 15 m distance filter and automatic pausing when you stand still for a while.
@MainActor
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onLocations: (([CLLocation]) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    /// Compass heading in degrees from true north (magnetic if true north is unavailable).
    var onHeading: ((Double) -> Void)?
    private(set) var isTracking = false

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var isDenied: Bool { manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted }
    var hasReducedAccuracy: Bool { manager.accuracyAuthorization == .reducedAccuracy }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// Precise tracking while the app is on screen.
    func startForeground() {
        requestPermission()
        manager.allowsBackgroundLocationUpdates = false
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
        isTracking = true
    }

    /// Opt-in pocket tracking: cheaper accuracy, larger distance filter, auto-pause.
    func startBackground() {
        requestPermission()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 15
        manager.pausesLocationUpdatesAutomatically = true
        manager.startUpdatingLocation()
        isTracking = true
    }

    /// Compass for the heading beam. Only while the app is on screen.
    func startHeading() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.headingFilter = 4
        manager.headingOrientation = .portrait
        manager.startUpdatingHeading()
    }

    func stopHeading() { manager.stopUpdatingHeading() }

    func stop() {
        manager.stopUpdatingHeading()
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isTracking = false
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { onLocations?(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        MainActor.assumeIsolated { onHeading?(degrees) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { onAuthorizationChange?(manager.authorizationStatus) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; keep going. Denial arrives via the authorization callback.
    }
}
