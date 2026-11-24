import Foundation
import Observation
import WandererCore

enum MapsApp: String, CaseIterable, Identifiable {
    case apple, google
    var id: String { rawValue }
    var title: String { self == .apple ? "Apple Maps" : "Google Maps" }
}

/// User-tunable settings persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var detection: VisitDetectionConfig {
        didSet { save(detection, key: "detection") }
    }
    /// Metres per second used for walking-time estimates.
    var walkingSpeed: Double {
        didSet { defaults.set(walkingSpeed, forKey: "walkingSpeed") }
    }
    var mapsApp: MapsApp {
        didSet { defaults.set(mapsApp.rawValue, forKey: "mapsApp") }
    }
    /// Keep GPS on with the screen locked. Off by default to save battery: steps and
    /// distance still count via the pedometer, and the path resumes when you open the app.
    var backgroundTracking: Bool {
        didSet { defaults.set(backgroundTracking, forKey: "backgroundTracking") }
    }
    /// Satellite imagery with labels instead of the standard map.
    var satellite: Bool {
        didSet { defaults.set(satellite, forKey: "satellite") }
    }
    var notifyOnVisit: Bool {
        didSet { defaults.set(notifyOnVisit, forKey: "notifyOnVisit") }
    }

    init() {
        if let data = defaults.data(forKey: "detection"),
           let config = try? JSONDecoder().decode(VisitDetectionConfig.self, from: data) {
            detection = config
        } else {
            detection = .default
        }
        let speed = defaults.double(forKey: "walkingSpeed")
        walkingSpeed = speed > 0 ? speed : 1.3
        mapsApp = MapsApp(rawValue: defaults.string(forKey: "mapsApp") ?? "") ?? .apple
        notifyOnVisit = defaults.object(forKey: "notifyOnVisit") as? Bool ?? true
        backgroundTracking = defaults.bool(forKey: "backgroundTracking")
        satellite = defaults.bool(forKey: "satellite")
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
