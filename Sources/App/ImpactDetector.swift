import Foundation

/// Hears bag hits in microphone audio: a sharp jump in loudness well above the
/// room's background level, at most one hit per 120 ms. Pure, so it can be unit-tested.
struct ImpactDetector {
    var sampleRate: Double = 44100
    private var frame: [Float] = []
    private var baseline: Double = 0.01
    private var sinceLastHit: Double = 1
    private var armed = true

    init(sampleRate: Double = 44100) { self.sampleRate = sampleRate }

    /// Feeds samples; returns how many hits they contained.
    mutating func feed(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        let frameLength = max(64, Int(sampleRate * 0.01))  // 10 ms frames
        var hits = 0
        for i in 0..<count {
            frame.append(samples[i])
            if frame.count == frameLength {
                hits += process()
                frame.removeAll(keepingCapacity: true)
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

    private mutating func process() -> Int {
        let rms = sqrt(Double(frame.reduce(0) { $0 + $1 * $1 }) / Double(frame.count))
        sinceLastHit += 0.01
        let loud = rms > max(0.05, baseline * 5)
        if loud && armed && sinceLastHit >= 0.12 {
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

/// Thread-safe holder so the audio thread can run the detector.
final class ImpactDetectorBox: @unchecked Sendable {
    private var detector = ImpactDetector()
    private let lock = NSLock()

    func reset(sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        detector = ImpactDetector(sampleRate: sampleRate)
    }

    func feed(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return detector.feed(samples, count: count)
    }
}
