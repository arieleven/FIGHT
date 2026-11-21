import Foundation

/// Beat-to-beat (RR interval) analysis: artifact correction, HRV and
/// DFA-alpha1 aerobic-threshold detection.
///
/// Optical armbands produce usable RR at rest but noisy
/// RR during hard exercise, so every function reports or gates on data quality.
enum HRVMath {

    struct RRQuality {
        let cleanRR: [Double]
        let artifactRate: Double
        var isUsableForHRV: Bool { cleanRR.count >= 60 && artifactRate <= 0.10 }
        /// DFA α1 is biased by more than ~3% artifacts (Rogers et al.), even after correction.
        var isUsableForDFA: Bool { cleanRR.count >= 100 && artifactRate <= 0.03 }
    }

    struct VT1Estimate: Equatable {
        let bpm: Int
        let r2: Double
        let windows: Int
    }

    /// Removes out-of-range beats and beats deviating >20% from the local median
    /// (a standard ectopic / missed-beat filter).
    static func cleanRR(_ rr: [Double]) -> RRQuality {
        guard !rr.isEmpty else { return RRQuality(cleanRR: [], artifactRate: 0) }
        var clean: [Double] = []
        clean.reserveCapacity(rr.count)
        var artifacts = 0

        for i in rr.indices {
            let v = rr[i]
            guard v >= 300, v <= 2000 else {
                artifacts += 1
                continue
            }
            let lo = max(0, i - 5)
            let hi = min(rr.count - 1, i + 5)
            var neighbours: [Double] = []
            for j in lo...hi where j != i {
                let n = rr[j]
                if n >= 300 && n <= 2000 { neighbours.append(n) }
            }
            if neighbours.count >= 3 {
                let sorted = neighbours.sorted()
                let median = sorted[sorted.count / 2]
                if abs(v - median) / median > 0.20 {
                    artifacts += 1
                    continue
                }
            }
            clean.append(v)
        }
        return RRQuality(cleanRR: clean, artifactRate: Double(artifacts) / Double(rr.count))
    }

    /// Like `cleanRR`, but replaces each bad beat with the local median instead of deleting it,
    /// so the beat sequence keeps its timing. DFA integrates the series, and deleted beats
    /// distort that; corrected beats barely do.
    static func correctRR(_ rr: [Double]) -> RRQuality {
        guard !rr.isEmpty else { return RRQuality(cleanRR: [], artifactRate: 0) }
        var out: [Double] = []
        out.reserveCapacity(rr.count)
        var artifacts = 0
        var window: [Double] = []
        window.reserveCapacity(10)
        for i in rr.indices {
            window.removeAll(keepingCapacity: true)
            for j in max(0, i - 5)...min(rr.count - 1, i + 5) where j != i && rr[j] >= 300 && rr[j] <= 2000 {
                window.append(rr[j])
            }
            window.sort()
            let median = window.isEmpty ? nil : window[window.count / 2]
            let v = rr[i]
            let bad = v < 300 || v > 2000 || (window.count >= 3 && median.map { abs(v - $0) / $0 > 0.20 } == true)
            if bad {
                artifacts += 1
                if let m = median { out.append(m) }   // nothing to patch with: drop it
            } else {
                out.append(v)
            }
        }
        return RRQuality(cleanRR: out, artifactRate: Double(artifacts) / Double(rr.count))
    }

    static func rmssd(_ clean: [Double]) -> Double? {
        guard clean.count >= 10 else { return nil }
        var sum = 0.0
        for i in 1..<clean.count {
            let d = clean[i] - clean[i - 1]
            sum += d * d
        }
        return sqrt(sum / Double(clean.count - 1))
    }

    static func meanHR(fromRR clean: [Double]) -> Double? {
        guard !clean.isEmpty else { return nil }
        let mean = clean.reduce(0, +) / Double(clean.count)
        return mean > 0 ? 60000.0 / mean : nil
    }

    /// Short-term detrended fluctuation analysis exponent (box sizes 4–16 beats).
    /// ~1.0 at easy intensity, ~0.75 at the aerobic threshold (VT1), ~0.5 above VT2.
    static func dfaAlpha1(_ rr: [Double]) -> Double? {
        guard rr.count >= 64 else { return nil }
        let mean = rr.reduce(0, +) / Double(rr.count)
        var y = [Double](repeating: 0, count: rr.count)
        var acc = 0.0
        for i in rr.indices {
            acc += rr[i] - mean
            y[i] = acc
        }

        var logN: [Double] = []
        var logF: [Double] = []
        for n in 4...16 {
            let boxes = y.count / n
            guard boxes >= 4 else { continue }
            let nD = Double(n)
            let xMean = (nD - 1) / 2
            var sxx = 0.0
            for k in 0..<n {
                let dx = Double(k) - xMean
                sxx += dx * dx
            }
            var sumSq = 0.0
            // Boxes laid from the start and again from the end, so no beats are left unused.
            let offset = y.count - boxes * n
            let starts = (0..<boxes).map { $0 * n } + (offset > 0 ? (0..<boxes).map { offset + $0 * n } : [])
            for start in starts {
                var yMean = 0.0
                for k in 0..<n { yMean += y[start + k] }
                yMean /= nD
                var sxy = 0.0
                for k in 0..<n { sxy += (Double(k) - xMean) * (y[start + k] - yMean) }
                let slope = sxy / sxx
                for k in 0..<n {
                    let fit = yMean + slope * (Double(k) - xMean)
                    let r = y[start + k] - fit
                    sumSq += r * r
                }
            }
            let f = sqrt(sumSq / Double(starts.count * n))
            guard f > 0 else { continue }
            logN.append(log(nD))
            logF.append(log(f))
        }
        guard logN.count >= 5 else { return nil }
        return linearRegression(logN, logF)?.slope
    }

    static func linearRegression(_ x: [Double], _ y: [Double]) -> (slope: Double, intercept: Double, r2: Double)? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in x.indices {
            let dx = x[i] - mx
            let dy = y[i] - my
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 0
        return (slope, my - slope * mx, r2)
    }

    /// Flattens a workout's RR intervals, each tagged with its sample time.
    static func timedRR(from samples: [HeartRatePoint]) -> [(t: TimeInterval, rr: Double)] {
        var out: [(t: TimeInterval, rr: Double)] = []
        for s in samples {
            for v in s.rrIntervalsMs {
                out.append((s.elapsedSeconds, v))
            }
        }
        return out
    }

    /// Fraction of HR samples that carried RR data, plus overall artifact rate.
    static func rrCoverage(samples: [HeartRatePoint]) -> (coverage: Double, artifactRate: Double) {
        guard !samples.isEmpty else { return (0, 0) }
        let withRR = samples.filter { !$0.rrIntervalsMs.isEmpty }.count
        let quality = cleanRR(samples.flatMap(\.rrIntervalsMs))
        return (Double(withRR) / Double(samples.count), quality.artifactRate)
    }

    /// Estimates the aerobic-threshold heart rate (VT1) as the HR where DFA-alpha1
    /// crosses 0.75, using sliding 2-minute windows. Returns nil when RR data is
    /// too sparse or noisy, or the session didn't span enough intensities.
    static func estimateVT1(samples: [HeartRatePoint]) -> VT1Estimate? {
        let timed = timedRR(from: samples)
        guard timed.count >= 300, let lastT = timed.last?.t else { return nil }

        var hrs: [Double] = []
        var alphas: [Double] = []
        var windowStart: TimeInterval = timed.first?.t ?? 0
        var startIdx = 0

        while windowStart + 120 <= lastT {
            while startIdx < timed.count && timed[startIdx].t < windowStart { startIdx += 1 }
            var endIdx = startIdx
            while endIdx < timed.count && timed[endIdx].t < windowStart + 120 { endIdx += 1 }
            let window = timed[startIdx..<endIdx].map { $0.rr }
            let q = correctRR(window)
            // Only steady windows: while HR is still climbing or falling, α1 reflects the change, not the intensity.
            let third = q.cleanRR.count / 3
            let drift: Double = third >= 20
                ? abs((meanHR(fromRR: Array(q.cleanRR.prefix(third))) ?? 0) - (meanHR(fromRR: Array(q.cleanRR.suffix(third))) ?? 0))
                : 99
            if q.isUsableForDFA, drift <= 8, let a = dfaAlpha1(q.cleanRR), let hr = meanHR(fromRR: q.cleanRR),
               a > 0.3, a < 1.5 {
                hrs.append(hr)
                alphas.append(a)
            }
            windowStart += 30
        }

        guard hrs.count >= 6,
              let minHR = hrs.min(), let maxHR = hrs.max(), maxHR - minHR >= 15,
              let fit = linearRegression(hrs, alphas),
              fit.slope < 0, fit.r2 >= 0.25 else {
            return nil
        }
        let vt1 = (0.75 - fit.intercept) / fit.slope
        guard vt1 >= minHR - 10, vt1 <= maxHR + 10, vt1 > 80, vt1 < 210 else { return nil }
        return VT1Estimate(bpm: Int(vt1.rounded()), r2: fit.r2, windows: hrs.count)
    }

    /// Live alpha1 over the most recent ~2 minutes of beats, or nil if unreliable.
    static func liveAlpha1(recentSamples: [HeartRatePoint]) -> Double? {
        // The last 2 minutes of beats (the window the research used), however fast the heart is.
        let all = recentSamples.flatMap(\.rrIntervalsMs)
        var total = 0.0
        var count = 0
        for v in all.reversed() {
            total += v
            count += 1
            if total >= 120_000 { break }
        }
        let q = correctRR(Array(all.suffix(count)))
        guard q.isUsableForDFA else { return nil }
        return dfaAlpha1(q.cleanRR)
    }

    /// Largest heart-rate rise over any ~20-second span (HR on-kinetics / explosiveness).
    /// Sliding-window maximum with a monotonic queue: one pass, no copies.
    static func maxSurge(samples: [HeartRatePoint], windowSeconds: TimeInterval = 20) -> Int? {
        guard samples.count >= 10 else { return nil }
        var best = 0
        var queue: [Int] = []      // indices, bpm decreasing
        var head = 0
        var j = 0
        for i in samples.indices {
            while j < samples.count && samples[j].elapsedSeconds - samples[i].elapsedSeconds <= windowSeconds {
                while queue.count > head, let lastIdx = queue.last, samples[lastIdx].bpm <= samples[j].bpm { queue.removeLast() }
                queue.append(j)
                j += 1
            }
            while head < queue.count && queue[head] < i { head += 1 }
            if head < queue.count { best = max(best, samples[queue[head]].bpm - samples[i].bpm) }
        }
        return best
    }
}
