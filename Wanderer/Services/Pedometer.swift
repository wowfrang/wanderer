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

    /// Total steps across intervals (pauses excluded). nil if any query fails.
    func steps(in intervals: [(Date, Date)]) async -> Int? {
        guard Self.isUsable else { return nil }
        var total = 0
        for (start, end) in intervals {
            let count: Int? = await withCheckedContinuation { continuation in
                pedometer.queryPedometerData(from: start, to: end) { data, error in
                    continuation.resume(returning: error == nil ? data?.numberOfSteps.intValue ?? 0 : nil)
                }
            }
            guard let count else { return nil }
            total += count
        }
        return total
    }

    /// Live cumulative steps since `start` (which may be in the past).
    func startLive(from start: Date, handler: @escaping @MainActor (Int) -> Void) {
        guard Self.isUsable else { return }
        pedometer.startUpdates(from: start) { data, _ in
            guard let steps = data?.numberOfSteps.intValue else { return }
            Task { @MainActor in handler(steps) }
        }
    }

    func stopLive() { pedometer.stopUpdates() }
}
