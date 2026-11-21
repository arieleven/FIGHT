import Foundation
import os
import Accelerate

/// Hears bag hits in microphone audio: a sharp jump in loudness well above the
/// room's background level, at most one hit per 120 ms. Pure, so it can be unit-tested.
struct ImpactDetector {
    var sampleRate: Double = 44100
    private var frameLength: Int
    private var pending = 0            // samples gathered into the current 10 ms frame
    private var pendingSumSq: Float = 0
    private var baseline = 0.01
    private var previousRMS = 0.01
    private var sinceLastHit: Double = 1
    private var armed = true
    /// While the app itself is making sound (voice, bells), a hit must be much louder to count.
    var strict = false

    init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
        frameLength = max(64, Int(sampleRate * 0.01))  // 10 ms frames
    }

    /// Feeds samples; returns how many hits they contained. No copying or allocation, so it is
    /// safe on the real-time audio thread; the sum of squares uses Accelerate.
    mutating func feed(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        var hits = 0
        var i = 0
        while i < count {
            let take = min(frameLength - pending, count - i)
            var sumSq: Float = 0
            vDSP_svesq(samples + i, 1, &sumSq, vDSP_Length(take))
            pendingSumSq += sumSq
            pending += take
            i += take
            if pending == frameLength {
                hits += process(rms: Double((pendingSumSq / Float(frameLength)).squareRoot()),
                                seconds: Double(frameLength) / sampleRate)
                pending = 0
                pendingSumSq = 0
            }
        }
        return hits
    }

    mutating func feed(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return 0 }
            return feed(base, count: buf.count)
        }
    }

    /// A hit is loud compared with the room AND a sudden jump from the frame before (a sharp
    /// attack). Speech and music are loud too, but they swell rather than snap.
    private mutating func process(rms: Double, seconds: Double) -> Int {
        sinceLastHit += seconds
        let factor = strict ? 12.0 : 5.0
        let loud = rms > max(strict ? 0.12 : 0.05, baseline * factor)
        let sharp = rms > previousRMS * 2.5
        previousRMS = max(rms, 0.0005)
        if loud && sharp && armed && sinceLastHit >= 0.12 {
            sinceLastHit = 0
            armed = false
            return 1
        }
        if !loud {
            armed = true
            baseline = baseline * 0.98 + rms * 0.02
        }
        return 0
    }
}

/// Holder so the audio thread can run the detector. Uses an unfair lock (cheap, no thread
/// hops) and knows when the app's own voice or bells are playing.
final class ImpactDetectorBox: @unchecked Sendable {
    private var detector = ImpactDetector()
    private var lock = os_unfair_lock()
    private var ownSoundUntil: CFAbsoluteTime = 0

    func reset(sampleRate: Double) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        detector = ImpactDetector(sampleRate: sampleRate)
    }

    /// The app is about to play `seconds` of its own sound.
    func noteOwnSound(seconds: Double) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        ownSoundUntil = max(ownSoundUntil, CFAbsoluteTimeGetCurrent() + seconds + 0.15)
    }

    func feed(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        detector.strict = CFAbsoluteTimeGetCurrent() < ownSoundUntil
        return detector.feed(samples, count: count)
    }
}
