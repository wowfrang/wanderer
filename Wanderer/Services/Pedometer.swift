import Foundation
import CoreMotion

/// Step counts from the motion coprocessor. Steps are only ever what CMPedometer reports;
/// when it is unavailable or permission is denied we show nothing rather than estimating.
@MainActor
final class Pedometer {
    private let pedometer = CMPedometer()

    static var isSupported: Bool { CMPedometer.isStepCountingAvailable() }
    static var isDenied: Bool { [.denied, .restricted].contains(CMPedometer.authorizationStatus()) }
    static var isUsable: Bool { isSupported && !isDenied }

    struct Reading {
        var steps: Int
        /// Metres, as estimated by the motion coprocessor (calibrated by iOS over time).
        var distance: Double?
    }

    /// Totals across intervals (pauses excluded). nil if any query fails.
    func reading(in intervals: [(Date, Date)]) async -> Reading? {
        guard Self.isUsable else { return nil }
        var total = Reading(steps: 0, distance: nil)
        for (start, end) in intervals {
            let r: Reading? = await withCheckedContinuation { continuation in
                pedometer.queryPedometerData(from: start, to: end) { data, error in
                    guard error == nil else { return continuation.resume(returning: nil) }
                    continuation.resume(returning: Reading(steps: data?.numberOfSteps.intValue ?? 0,
                                                           distance: data?.distance?.doubleValue))
                }
            }
            guard let r else { return nil }
            total.steps += r.steps
            if let d = r.distance { total.distance = (total.distance ?? 0) + d }
        }
        return total
    }

    /// Live cumulative steps since `start` (which may be in the past).
    func startLive(from start: Date, handler: @escaping @MainActor (Reading) -> Void) {
        guard Self.isUsable else { return }
        pedometer.startUpdates(from: start) { data, _ in
            guard let data else { return }
            let reading = Reading(steps: data.numberOfSteps.intValue, distance: data.distance?.doubleValue)
            Task { @MainActor in handler(reading) }
        }
    }

    func stopLive() { pedometer.stopUpdates() }
}
