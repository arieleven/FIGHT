import Foundation
import CoreMotion

/// Reads AirPods motion: head movements (slips, rolls, pulls), chin position,
/// footwork bounce and nods. Works automatically with supported AirPods; does nothing otherwise.
@MainActor
final class HeadMotionTracker: ObservableObject {
    @Published private(set) var isReceiving = false
    @Published private(set) var totalMoves = 0
    @Published private(set) var totalBounces = 0
    /// Seconds spent with the chin lifted above the fighter's normal guard position.
    @Published private(set) var chinUpSeconds: Double = 0

    /// Called with the estimated height (cm) of each jump, from the time in the air.
    var onJump: (@MainActor (Double) -> Void)?
    /// Called when the fighter nods (down-up), used to start the next round hands-free.
    var onNod: (@MainActor () -> Void)?
    /// Raw samples for drills: (timestamp, rotation rate x/y/z, roll, pitch).
    var onSample: (@MainActor (TimeInterval, Double, Double, Double, Double, Double) -> Void)?

    private let manager = CMHeadphoneMotionManager()
    private var lastMoveTime: TimeInterval = 0
    private var aboveThreshold = false
    private var lastBounce: TimeInterval = 0
    private var bounceArmed = true
    private var lastTimestamp: TimeInterval?
    private var nodState = NodDetector()
    private var jumpState = JumpDetector()

    /// Chin baseline: the median pitch while the fighter is in their stance.
    private var pitchBaseline: Double?
    private var recentPitch: [Double] = []
    /// Whether chin time counts right now (only during work).
    var trackingChin = false

    nonisolated static let threshold = 2.2
    nonisolated static let refractory = 0.35
    /// Head tilt above the baseline (radians, about 11°) that counts as "chin up".
    nonisolated static let chinLift = 0.2

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    /// Current pitch relative to baseline, smoothed over the last second (radians, + = chin up).
    var chinLiftNow: Double {
        guard let b = pitchBaseline, !recentPitch.isEmpty else { return 0 }
        return recentPitch.reduce(0, +) / Double(recentPitch.count) - b
    }

    func start() {
        stop()
        totalMoves = 0
        totalBounces = 0
        chinUpSeconds = 0
        pitchBaseline = nil
        recentPitch = []
        guard manager.isDeviceMotionAvailable else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let r = motion.rotationRate
            let a = motion.userAcceleration
            let g = motion.gravity
            let att = motion.attitude
            let ts = motion.timestamp
            // Vertical acceleration: user acceleration projected on gravity (in g).
            let vertical = -(a.x * g.x + a.y * g.y + a.z * g.z)
            let roll = att.roll, pitch = att.pitch
            Task { @MainActor in
                self?.process(ts: ts, rx: r.x, ry: r.y, rz: r.z, vertical: vertical, roll: roll, pitch: pitch)
            }
        }
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        isReceiving = false
        aboveThreshold = false
        lastTimestamp = nil
    }

    /// Takes the current head angle as the fighter's normal guard position.
    func setChinBaseline() {
        guard !recentPitch.isEmpty else { return }
        pitchBaseline = recentPitch.sorted()[recentPitch.count / 2]
    }

    private func process(ts: TimeInterval, rx: Double, ry: Double, rz: Double, vertical: Double, roll: Double, pitch: Double) {
        isReceiving = true
        let dt = lastTimestamp.map { min(0.2, max(0, ts - $0)) } ?? 0
        lastTimestamp = ts

        if HeadMotionTracker.detect(magnitude: (rx * rx + ry * ry + rz * rz).squareRoot(), timestamp: ts,
                                    above: &aboveThreshold, lastMove: &lastMoveTime) {
            totalMoves += 1
        }

        // Footwork bounce: a vertical push of about 0.3 g, at most ~4 per second.
        if vertical > 0.3, bounceArmed, ts - lastBounce > 0.22 {
            totalBounces += 1
            lastBounce = ts
            bounceArmed = false
        } else if vertical < 0.1 {
            bounceArmed = true
        }

        recentPitch.append(pitch)
        if recentPitch.count > 25 { recentPitch.removeFirst(recentPitch.count - 25) }
        if pitchBaseline == nil, recentPitch.count == 25 { setChinBaseline() }
        if trackingChin, chinLiftNow > Self.chinLift { chinUpSeconds += dt }

        if let cm = jumpState.feed(vertical: vertical, ts: ts) { onJump?(cm) }
        if nodState.feed(pitchRate: rx, otherRate: max(abs(ry), abs(rz)), ts: ts) { onNod?() }
        onSample?(ts, rx, ry, rz, roll, pitch)
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

/// A nod is a quick nose-down then nose-up (or the reverse) within 0.7 s,
/// with little sideways rotation, at most one per 1.5 s.
struct NodDetector {
    private var firstSign: Double = 0
    private var firstTime: TimeInterval = 0
    private var lastNod: TimeInterval = -10

    mutating func feed(pitchRate: Double, otherRate: Double, ts: TimeInterval) -> Bool {
        guard abs(pitchRate) > 1.5, otherRate < abs(pitchRate) * 0.5 else { return false }
        let sign: Double = pitchRate > 0 ? 1 : -1
        if firstSign != 0, sign == -firstSign, ts - firstTime < 0.7 {
            firstSign = 0
            guard ts - lastNod > 1.5 else { return false }
            lastNod = ts
            return true
        }
        if firstSign == 0 || ts - firstTime >= 0.7 || sign == firstSign {
            firstSign = sign
            firstTime = ts
        }
        return false
    }
}

/// Jump height from flight time. In the air the head is in free fall (about -1 g of user
/// acceleration along gravity); height = g·t²/8. Flights under 0.2 s (rope skips, bounces) are ignored.
struct JumpDetector {
    static let fallThreshold = -0.6
    static let landThreshold = -0.3
    private var fallStart: TimeInterval?

    static func heightCm(flight t: Double) -> Double { 9.81 * t * t / 8 * 100 }

    mutating func feed(vertical: Double, ts: TimeInterval) -> Double? {
        if let start = fallStart {
            if vertical > Self.landThreshold {
                fallStart = nil
                let t = ts - start
                guard t >= 0.2, t <= 1.0 else { return nil }
                return Self.heightCm(flight: t)
            }
            if ts - start > 1.2 { fallStart = nil }
        } else if vertical < Self.fallThreshold {
            fallStart = ts
        }
        return nil
    }
}
