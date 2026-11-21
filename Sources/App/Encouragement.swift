import Foundation

/// A corner coach in your ear: pushes you when the pace drops, tells you to breathe when you're
/// redlining. Pure logic (no audio) so it can be tested; WorkoutSession speaks what it returns.
struct EncouragementCoach {
    struct Input {
        var now: TimeInterval
        var bpm: Int
        /// Work part of a round or a work drill (not rest, not warm-up/cool-down).
        var isWork: Bool
        var isRest: Bool
        /// Seconds into the current work or rest phase.
        var phaseElapsed: TimeInterval
        /// Seconds left in the phase, nil if open-ended.
        var phaseRemaining: TimeInterval?
        /// Heart rate the fighter should stay above while working (their own pace), nil = unknown.
        var paceFloor: Int?
        /// Top of Zone 4: above this is the red zone.
        var redLine: Int
        /// Bag hits per minute over the last ~20 s and in round 1 (nil = not counting).
        var hitRate: Double?
        var hitRateRef: Double?
    }

    enum Kind: Equatable { case push, hands, breathe, recover }

    static let minGap: TimeInterval = 45
    private(set) var lastCueAt: TimeInterval = -1_000
    private var lowSince: TimeInterval?
    private var redSince: TimeInterval?
    private var recoverCuedAt: TimeInterval = -1_000
    private var counters: [Kind: Int] = [:]

    static let lines: [Kind: [String]] = [
        .push: ["Pick it up. Stay busy.", "Don't coast. Let your hands go.", "More pressure. Win this round.",
                "You've got more. Go.", "Keep the pace. Work, work."],
        .hands: ["Hands! Keep them busy.", "Double up. Don't wait.", "Throw more. Make it count."],
        .breathe: ["Breathe. Exhale on every shot.", "Relax your shoulders. Breathe out.", "Stay loose. Long exhale."],
        .recover: ["Big breaths. In through the nose.", "Slow it down. Recover now.", "Drop your shoulders. Breathe deep."]
    ]

    /// Returns a line to speak, or nil.
    mutating func evaluate(_ i: Input) -> (kind: Kind, line: String)? {
        guard i.bpm > 0 else { lowSince = nil; redSince = nil; return nil }

        // Red zone streak (any phase).
        if i.bpm > i.redLine {
            if redSince == nil { redSince = i.now }
        } else {
            redSince = nil
        }

        // Low-pace streak while working.
        let late = i.phaseRemaining.map { $0 < 8 } ?? false
        if i.isWork, i.phaseElapsed >= 25, !late, let floor = i.paceFloor, i.bpm < floor {
            if lowSince == nil { lowSince = i.now }
        } else {
            lowSince = nil
        }

        guard i.now - lastCueAt >= Self.minGap else { return nil }

        // 1. Early in a rest and still very high: breathe.
        if i.isRest, i.phaseElapsed >= 12, i.phaseElapsed <= 30, i.bpm > i.redLine,
           i.now - recoverCuedAt > 90 {
            recoverCuedAt = i.now
            return say(.recover, at: i.now)
        }
        // 2. Over a minute redlining while working: take a breather inside the round.
        if let r = redSince, i.now - r >= 60, i.isWork {
            redSince = i.now
            return say(.breathe, at: i.now)
        }
        // 3. Output dropping: hands first (direct measure), then heart rate.
        if i.isWork, i.phaseElapsed >= 30, !late, let rate = i.hitRate, let ref = i.hitRateRef, ref >= 20, rate < ref * 0.6 {
            return say(.hands, at: i.now)
        }
        if let l = lowSince, i.now - l >= 20 {
            lowSince = nil
            return say(.push, at: i.now)
        }
        return nil
    }

    private mutating func say(_ kind: Kind, at now: TimeInterval) -> (kind: Kind, line: String) {
        lastCueAt = now
        let options = Self.lines[kind] ?? [""]
        let n = counters[kind, default: 0]
        counters[kind] = n + 1
        return (kind, options[n % options.count])
    }
}
