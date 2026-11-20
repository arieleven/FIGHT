import Foundation
import CoreMotion

/// Counts head movements (slips, rolls, pulls) from AirPods motion sensors.
/// Works automatically when supported AirPods are connected; silently does nothing otherwise.
@MainActor
final class HeadMotionTracker: ObservableObject {
    @Published private(set) var isReceiving = false
    @Published private(set) var totalMoves = 0

    private let manager = CMHeadphoneMotionManager()
    private var lastMoveTime: TimeInterval = 0
    private var aboveThreshold = false

    /// Rotation speed (rad/s) that counts as a deliberate head movement, not a breath or a nod.
    static let threshold = 2.2
    /// Minimum time between two counted movements.
    static let refractory = 0.35

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        stop()
        totalMoves = 0
        guard manager.isDeviceMotionAvailable else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let r = motion.rotationRate
            let ts = motion.timestamp
            Task { @MainActor in self?.process(x: r.x, y: r.y, z: r.z, timestamp: ts) }
        }
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        isReceiving = false
        aboveThreshold = false
    }

    private func process(x: Double, y: Double, z: Double, timestamp: TimeInterval) {
        isReceiving = true
        let count = HeadMotionTracker.detect(magnitude: (x * x + y * y + z * z).squareRoot(), timestamp: timestamp,
                                             above: &aboveThreshold, lastMove: &lastMoveTime)
        if count { totalMoves += 1 }
    }

    /// Peak detector: counts one movement each time rotation speed crosses the
    /// threshold, at most once per refractory window. Pure, so it can be unit-tested.
    nonisolated static func detect(magnitude: Double, timestamp: TimeInterval, above: inout Bool, lastMove: inout TimeInterval) -> Bool {
        if magnitude >= threshold {
            if !above && timestamp - lastMove >= refractory {
                above = true
                lastMove = timestamp
                return true
            }
            above = true
        } else if magnitude < threshold * 0.6 {
            above = false
        }
        return false
    }
}
