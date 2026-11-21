import Foundation
import SwiftUI

// MARK: - Coach Models

struct ReadinessReading: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date = Date()
    var durationSeconds: Int
    var restingHR: Int
    var rmssd: Double?
    var artifactRate: Double?
    var sleepQuality: Int   // 1 (awful) ... 5 (great)
    var soreness: Int       // 1 (fresh) ... 5 (very sore)
    /// nil = strap check; "health" = imported from Apple Health (no HRV or self-ratings).
    var source: String? = nil
    /// The fighter this check belongs to (nil on checks saved before profiles were tracked).
    var profileID: UUID? = nil
    /// Hours asleep last night, from Apple Health.
    var sleepHours: Double? = nil

    var hasSelfRatings: Bool { source == nil }

    var lnRMSSD: Double? {
        guard let r = rmssd, r > 0 else { return nil }
        return log(r)
    }

    /// Familiar 0–100-ish HRV score (ln RMSSD × 20).
    var hrvScore: Int? {
        guard let ln = lnRMSSD else { return nil }
        return Int((ln * 20).rounded())
    }
}

struct MetricScore: Identifiable {
    enum Key: String {
        case readiness, aerobic, anaerobic, stamina, recovery, consistency, loadBalance, intensityMix
    }

    let key: Key
    let title: String
    let icon: String
    let score: Int?          // nil = not enough data yet
    let trend: Int?          // change vs the previous 28 days
    let headline: String     // one-line evidence
    let evidence: [String]   // bullet details shown in the detail sheet
    let howToImprove: String
    let dataHint: String     // what's needed when score is nil

    var id: String { key.rawValue }

    var grade: String {
        guard let s = score else { return "Need Data" }
        switch s {
        case 85...: return "Elite"
        case 70..<85: return "Strong"
        case 55..<70: return "Solid"
        case 40..<55: return "Developing"
        default: return "Needs Work"
        }
    }

    var color: Color { MetricScore.color(for: score) }

    static func color(for score: Int?) -> Color {
        guard let s = score else { return .secondary }
        switch s {
        case 70...: return .green
        case 55..<70: return .mint
        case 40..<55: return .yellow
        default: return .orange
        }
    }
}

struct WorkoutPrescription: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let category: WorkoutCategory
    let drillTag: DrillTag
    let roundTimer: Bool
    let workSeconds: Int
    let restSeconds: Int
    let rounds: Int?
    let durationMinutes: Int
    let useBagCoach: Bool
    let bagTempo: BagTempo
    let targetLowBPM: Int
    let targetHighBPM: Int
    let structure: String
    let rationale: String
    let isRestDay: Bool
}

struct CoachRecommendation: Identifiable {
    enum Kind { case rest, train, focus, test, warning }
    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String

    var icon: String {
        switch kind {
        case .rest: return "bed.double.fill"
        case .train: return "figure.kickboxing"
        case .focus: return "scope"
        case .test: return "waveform.path.ecg"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .rest: return .cyan
        case .train: return .green
        case .focus: return .purple
        case .test: return .blue
        case .warning: return .orange
        }
    }
}

struct TrainingLoadPoint: Identifiable {
    let date: Date
    let load: Double
    let fitness: Double   // CTL — 42-day load average
    let fatigue: Double   // ATL — 7-day load average
    var form: Double { fitness - fatigue }
    var id: Date { date }
}

struct CoachReport {
    let generatedAt: Date
    let workoutCount: Int
    let readiness: MetricScore
    let fightFitness: Int?
    let metrics: [MetricScore]
    let load: [TrainingLoadPoint]
    let nextWorkout: WorkoutPrescription
    let recommendations: [CoachRecommendation]
    let focusAreas: [MetricScore]
    let vt1: HRVMath.VT1Estimate?
    let measuredRestingHR: Int?
    let latestReading: ReadinessReading?
    let rrCoverage: Double?

    var hasEnoughData: Bool { workoutCount >= 3 }

    var currentForm: Double { load.last?.form ?? 0 }
    var acwr: Double? {
        guard let l = load.last, l.fitness >= 5 else { return nil }
        return l.fatigue / l.fitness
    }
}

struct WorkoutReview {
    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let score: Int
        let note: String
    }
    let overall: Int?
    let items: [Item]
    let takeaways: [String]
    let loadComparison: String?
}

// MARK: - Coach Engine

enum CoachEngine {

    // MARK: Scoring helpers

    /// Maps `value` to 0…100 where `worst` → 0 and `best` → 100 (either direction).
    static func scale(_ value: Double, worst: Double, best: Double) -> Double {
        guard worst != best else { return 50 }
        let t = (value - worst) / (best - worst)
        return min(100, max(0, t * 100))
    }

    /// Weighted mean of the components that have data; nil when none do.
    static func blend(_ parts: [(Double?, Double)]) -> Int? {
        var total = 0.0, weight = 0.0
        for (v, w) in parts {
            if let v { total += v * w; weight += w }
        }
        guard weight > 0 else { return nil }
        return Int((total / weight).rounded())
    }

    private static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    private static func sd(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        let v = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
        return sqrt(v)
    }

    private static func zoneShare(_ ws: [SavedWorkout]) -> (low: Double, mid: Double, high: Double)? {
        var z = [Double](repeating: 0, count: 6)
        for w in ws {
            for (k, v) in w.zoneSeconds where k >= 1 && k <= 5 { z[k] += v }
        }
        let total = z[1...5].reduce(0, +)
        guard total > 600 else { return nil }
        return ((z[1] + z[2]) / total, z[3] / total, (z[4] + z[5]) / total)
    }

    private static func isHardSession(_ w: SavedWorkout, profile: AthleteProfile) -> Bool {
        let total = max(1, w.zoneSeconds.values.reduce(0, +))
        let high = w.zoneSeconds[4, default: 0] + w.zoneSeconds[5, default: 0]
        return high / total >= 0.20 || w.effectiveLoad >= 90
    }

    /// Rising average HR across rounds (%) — lower means better fight stamina.
    static func roundCreepPercent(_ rounds: [RoundStat]) -> Double? {
        guard rounds.count >= 4 else { return nil }
        let third = max(1, rounds.count / 3)
        let early = rounds.prefix(third).map { Double($0.avgBPM) }
        let late = rounds.suffix(third).map { Double($0.avgBPM) }
        guard let e = mean(early), let l = mean(late), e > 0 else { return nil }
        return (l - e) / e * 100
    }

    /// Late-round stool recovery relative to early rounds (1.0 = no decline).
    static func recoveryRetention(_ rounds: [RoundStat]) -> Double? {
        let drops = rounds.compactMap(\.stoolDropBPM).map(Double.init)
        guard drops.count >= 4 else { return nil }
        let third = max(1, drops.count / 3)
        guard let e = mean(Array(drops.prefix(third))), let l = mean(Array(drops.suffix(third))), e > 0 else { return nil }
        return l / e
    }

    // MARK: Training load (Banister fitness–fatigue)

    static func trainingLoad(workouts: [SavedWorkout], days: Int = 56, now: Date = Date()) -> [TrainingLoadPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let warmup = 84
        var daily: [Date: Double] = [:]
        for w in workouts {
            daily[cal.startOfDay(for: w.startDate), default: 0] += w.effectiveLoad
        }
        var ctl = 0.0, atl = 0.0
        var points: [TrainingLoadPoint] = []
        for offset in stride(from: warmup + days - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let load = daily[day, default: 0]
            ctl += (load - ctl) / 42.0
            atl += (load - atl) / 7.0
            if offset < days {
                points.append(TrainingLoadPoint(date: day, load: load, fitness: ctl, fatigue: atl))
            }
        }
        return points
    }

    // MARK: Report

    static func buildReport(
        workouts allWorkouts: [SavedWorkout],
        readings allReadings: [ReadinessReading],
        profile: AthleteProfile,
        resolveSamples: (SavedWorkout) -> [HeartRatePoint],
        now: Date = Date()
    ) -> CoachReport {
        let workouts = allWorkouts.filter { $0.profileID == profile.id }.sorted { $0.startDate > $1.startDate }
        let readings = allReadings.sorted { $0.date > $1.date }
        let d28 = now.addingTimeInterval(-28 * 86400)
        let d56 = now.addingTimeInterval(-56 * 86400)
        let recent = workouts.filter { $0.startDate >= d28 }
        let previous = workouts.filter { $0.startDate >= d56 && $0.startDate < d28 }
        let zones = profile.activeZones
        let maxHR = Double(profile.effectiveMaxHR)

        // Sample-level analysis on the most recent sessions only (archives are decompressed on demand).
        var samplesByID: [UUID: [HeartRatePoint]] = [:]
        for w in recent.prefix(8) {
            samplesByID[w.id] = resolveSamples(w)
        }
        var vt1: HRVMath.VT1Estimate?
        var coverages: [Double] = []
        for w in recent.prefix(8) {
            guard let s = samplesByID[w.id], !s.isEmpty else { continue }
            coverages.append(HRVMath.rrCoverage(samples: s).coverage)
            if vt1 == nil, let est = HRVMath.estimateVT1(samples: s) {
                vt1 = est
            }
        }

        let load = trainingLoad(workouts: workouts, now: now)
        let aerobic = aerobicScore(recent: recent, previous: previous, profile: profile, vt1: vt1, readings: readings, maxHR: maxHR)
        let anaerobic = anaerobicScore(recent: recent, previous: previous, zones: zones, maxHR: maxHR, samplesByID: samplesByID)
        let stamina = staminaScore(recent: recent, previous: previous)
        let recovery = recoveryScore(recent: recent, previous: previous, readings: readings, now: now)
        let consistency = consistencyScore(recent: recent, previous: previous, now: now)
        let balance = loadBalanceScore(load: load)
        let mix = intensityMixScore(recent: recent, previous: previous)
        let readiness = readinessScore(load: load, readings: readings, workouts: workouts, profile: profile, now: now)

        let core = [aerobic, anaerobic, stamina, recovery]
        let fightFitness = blend(core.map { ($0.score.map(Double.init), 1.0) })
        let metrics = [aerobic, anaerobic, stamina, recovery, consistency, balance, mix]
        let focus = core.filter { $0.score != nil }.sorted { ($0.score ?? 0) < ($1.score ?? 0) }.prefix(2)

        let measuredRHR: Int? = {
            let last = readings.prefix(7).map(\.restingHR)
            guard last.count >= 3 else { return nil }
            return Int((Double(last.reduce(0, +)) / Double(last.count)).rounded())
        }()

        let next = prescribeNext(
            readiness: readiness, focus: Array(focus), workouts: workouts, load: load,
            profile: profile, vt1: vt1, now: now
        )
        let recs = buildRecommendations(
            readiness: readiness, metrics: metrics, focus: Array(focus), load: load, workouts: workouts,
            readings: readings, profile: profile, measuredRHR: measuredRHR, vt1: vt1, now: now
        )

        return CoachReport(
            generatedAt: now,
            workoutCount: workouts.count,
            readiness: readiness,
            fightFitness: fightFitness,
            metrics: metrics,
            load: load,
            nextWorkout: next,
            recommendations: recs,
            focusAreas: Array(focus),
            vt1: vt1,
            measuredRestingHR: measuredRHR,
            latestReading: readings.first,
            rrCoverage: mean(coverages)
        )
    }

    // MARK: Individual metrics

    private static func aerobicComponents(_ ws: [SavedWorkout], vt1: HRVMath.VT1Estimate?, restHR: Double?, maxHR: Double)
        -> (score: Int?, z12PerWeek: Double, drift: Double?) {
        let z12 = ws.reduce(0.0) { $0 + $1.zoneSeconds[1, default: 0] + $1.zoneSeconds[2, default: 0] } / 60.0 / 4.0
        let steady = ws.filter { w in
            (w.category == .roadwork || w.category == .walk || w.drillTag == .aerobicZ2) && w.duration >= 1200
        }
        let drift = mean(steady.map(\.cardiacDriftPercent))
        let score = blend([
            (ws.isEmpty ? nil : scale(z12, worst: 20, best: 150), 0.40),
            (drift.map { scale($0, worst: 12, best: 3) }, 0.25),
            (vt1.map { scale(Double($0.bpm) / maxHR, worst: 0.65, best: 0.85) }, 0.20),
            (restHR.map { scale($0, worst: 75, best: 45) }, 0.15)
        ])
        return (score, z12, drift)
    }

    private static func aerobicScore(recent: [SavedWorkout], previous: [SavedWorkout], profile: AthleteProfile,
                                     vt1: HRVMath.VT1Estimate?, readings: [ReadinessReading], maxHR: Double) -> MetricScore {
        let rhr = readings.count >= 3 ? mean(readings.prefix(7).map { Double($0.restingHR) }) : nil
        let now = aerobicComponents(recent, vt1: vt1, restHR: rhr, maxHR: maxHR)
        let before = previous.isEmpty ? nil : aerobicComponents(previous, vt1: nil, restHR: nil, maxHR: maxHR).score
        var evidence = ["\(Int(now.z12PerWeek)) min/week in Zones 1–2 (target 150+)"]
        if let d = now.drift { evidence.append(String(format: "%.1f%% cardiac drift on steady sessions (under 5%% is strong)", d)) }
        if let v = vt1 { evidence.append("Aerobic threshold ≈ \(v.bpm) BPM (\(Int(Double(v.bpm) / maxHR * 100))% of max)") }
        if let r = rhr { evidence.append("Morning resting HR averaging \(Int(r)) BPM") }
        return MetricScore(
            key: .aerobic, title: "Aerobic Base", icon: "lungs.fill",
            score: now.score, trend: diff(now.score, before),
            headline: "\(Int(now.z12PerWeek)) min/wk easy cardio",
            evidence: evidence,
            howToImprove: "Add two 35–50 minute runs or skips per week held in Zone 2 (\(profile.activeZones.z1Max + 1)–\(profile.activeZones.z2Max) BPM). You should be able to talk in full sentences. A bigger aerobic engine makes you recover faster between exchanges and rounds.",
            dataHint: "Log a few sessions to build your aerobic profile."
        )
    }

    private static func anaerobicComponents(_ ws: [SavedWorkout], zones: ZoneThresholds, maxHR: Double, surge: Int?) -> (score: Int?, z45: Double, peakPct: Double?, hardRounds: Double) {
        let z45 = ws.reduce(0.0) { $0 + $1.zoneSeconds[4, default: 0] + $1.zoneSeconds[5, default: 0] } / 60.0 / 4.0
        let peak = ws.map(\.maxBPM).max().map { Double($0) / maxHR }
        let hardRounds = Double(ws.flatMap(\.roundStats).filter { $0.peakBPM > zones.z4Max }.count) / 4.0
        let score = blend([
            (ws.isEmpty ? nil : scale(z45, worst: 5, best: 35), 0.35),
            (peak.map { scale($0, worst: 0.85, best: 0.97) }, 0.20),
            (surge.map { scale(Double($0), worst: 15, best: 40) }, 0.25),
            (ws.isEmpty ? nil : scale(hardRounds, worst: 2, best: 15), 0.20)
        ])
        return (score, z45, peak, hardRounds)
    }

    private static func anaerobicScore(recent: [SavedWorkout], previous: [SavedWorkout], zones: ZoneThresholds,
                                       maxHR: Double, samplesByID: [UUID: [HeartRatePoint]]) -> MetricScore {
        let surge = recent.compactMap { w in samplesByID[w.id].flatMap { HRVMath.maxSurge(samples: $0) } }.max()
        let now = anaerobicComponents(recent, zones: zones, maxHR: maxHR, surge: surge)
        let before = previous.isEmpty ? nil : anaerobicComponents(previous, zones: zones, maxHR: maxHR, surge: nil).score
        var evidence = [String(format: "%.0f min/week in Zones 4–5 (target 20–35 in camp)", now.z45)]
        if let p = now.peakPct { evidence.append("Highest HR reached: \(Int(p * 100))% of max") }
        if let s = surge { evidence.append("Fastest surge: +\(s) BPM in 20 s (explosive output)") }
        evidence.append(String(format: "%.1f high-intensity rounds per week", now.hardRounds))
        return MetricScore(
            key: .anaerobic, title: "Anaerobic Power", icon: "bolt.heart.fill",
            score: now.score, trend: diff(now.score, before),
            headline: String(format: "%.0f min/wk at threshold+", now.z45),
            evidence: evidence,
            howToImprove: "Twice a week, do short all-out efforts with full recovery. For example, 10 × 30 s maximal bag combos with 90 s rest, or 6 × 1 min fight-pace pads. Aim to push HR above \(zones.z4Max) BPM on every effort. Keep these sessions separate from hard sparring days.",
            dataHint: "Record a few hard rounds to measure anaerobic output."
        )
    }

    private static func staminaComponents(_ ws: [SavedWorkout]) -> (score: Int?, creep: Double?, drift: Double?, roundsPerSession: Double?) {
        let creep = mean(ws.compactMap { roundCreepPercent($0.roundStats) })
        let long = ws.filter { $0.roundStats.count < 2 && $0.duration >= 1800 }
        let drift = mean(long.map(\.cardiacDriftPercent))
        let roundSessions = ws.filter { $0.roundStats.count >= 2 }
        let rps = roundSessions.isEmpty ? nil : Double(roundSessions.map(\.roundStats.count).reduce(0, +)) / Double(roundSessions.count)
        let score = blend([
            (creep.map { scale($0, worst: 12, best: 1) }, 0.45),
            (drift.map { scale($0, worst: 12, best: 3) }, 0.30),
            (rps.map { scale($0, worst: 3, best: 10) }, 0.25)
        ])
        return (score, creep, drift, rps)
    }

    private static func staminaScore(recent: [SavedWorkout], previous: [SavedWorkout]) -> MetricScore {
        let now = staminaComponents(recent)
        let before = staminaComponents(previous).score
        var evidence: [String] = []
        if let c = now.creep { evidence.append(String(format: "Average HR climbs %.1f%% from early to late rounds (under 4%% is strong)", c)) }
        if let d = now.drift { evidence.append(String(format: "%.1f%% drift in long continuous sessions", d)) }
        if let r = now.roundsPerSession { evidence.append(String(format: "%.1f rounds per round-based session", r)) }
        return MetricScore(
            key: .stamina, title: "Fight Stamina", icon: "figure.martial.arts",
            score: now.score, trend: diff(now.score, before),
            headline: now.creep.map { String(format: "+%.1f%% late-round HR creep", $0) } ?? "Round data needed",
            evidence: evidence,
            howToImprove: "Build round tolerance by adding volume before intensity. Try 6–8 × 3 min rounds with only 30–45 s rest, keeping late rounds as sharp as the first. Over the weeks, extend toward championship distance (5 × 3 min at fight pace).",
            dataHint: "Use the round timer for at least 4 rounds so stamina can be measured."
        )
    }

    private static func recoveryComponents(_ ws: [SavedWorkout], hrvZ: Double?) -> (score: Int?, hrr: Double?, retention: Double?) {
        let drops = ws.flatMap { $0.roundStats.compactMap(\.stoolDropBPM) } + ws.flatMap { $0.autoHRREvents.map(\.dropBPM) }
        let hrr = mean(drops.map(Double.init))
        let retention = mean(ws.compactMap { recoveryRetention($0.roundStats) })
        let score = blend([
            (hrr.map { scale($0, worst: 12, best: 35) }, 0.50),
            (retention.map { scale($0, worst: 0.6, best: 1.0) }, 0.25),
            (hrvZ.map { scale($0, worst: -1.5, best: 0.5) }, 0.25)
        ])
        return (score, hrr, retention)
    }

    private static func hrvTrendZ(readings: [ReadinessReading], now: Date) -> Double? {
        let ln28 = readings.filter { $0.date >= now.addingTimeInterval(-28 * 86400) }.compactMap(\.lnRMSSD)
        let ln7 = readings.filter { $0.date >= now.addingTimeInterval(-7 * 86400) }.compactMap(\.lnRMSSD)
        guard ln28.count >= 5, ln7.count >= 2, let m28 = mean(ln28), let s = sd(ln28), s > 0, let m7 = mean(ln7) else { return nil }
        return (m7 - m28) / s
    }

    private static func recoveryScore(recent: [SavedWorkout], previous: [SavedWorkout], readings: [ReadinessReading], now: Date) -> MetricScore {
        let z = hrvTrendZ(readings: readings, now: now)
        let current = recoveryComponents(recent, hrvZ: z)
        let before = recoveryComponents(previous, hrvZ: nil).score
        var evidence: [String] = []
        if let h = current.hrr { evidence.append(String(format: "Average 60-s heart-rate drop: %.0f BPM (25+ is strong, 35+ elite)", h)) }
        if let r = current.retention { evidence.append(String(format: "Late-round recovery is %.0f%% of early-round recovery", r * 100)) }
        if let z { evidence.append(String(format: "7-day HRV trend: %+.1f SD vs your 28-day baseline", z)) }
        return MetricScore(
            key: .recovery, title: "Recovery Speed", icon: "arrow.down.heart.fill",
            score: current.score, trend: diff(current.score, before),
            headline: current.hrr.map { String(format: "−%.0f BPM in 60 s", $0) } ?? "Rest-period data needed",
            evidence: evidence,
            howToImprove: "Recovery between rounds comes from your aerobic base and your breathing. On the stool, sit tall and take slow nasal breaths: 4 s in, 6 s out. Keep easy days truly easy (Zone 1–2) so the hard days count. Sleep is the biggest lever of all.",
            dataHint: "Use the round timer with rest periods so recovery can be measured."
        )
    }

    private static func consistencyScore(recent: [SavedWorkout], previous: [SavedWorkout], now: Date) -> MetricScore {
        func components(_ ws: [SavedWorkout], end: Date) -> (score: Int?, perWeek: Double, activeWeeks: Int) {
            let perWeek = Double(ws.count) / 4.0
            var active = 0
            for k in 0..<4 {
                let hi = end.addingTimeInterval(-Double(k) * 7 * 86400)
                let lo = hi.addingTimeInterval(-7 * 86400)
                if ws.filter({ $0.startDate >= lo && $0.startDate < hi }).count >= 2 { active += 1 }
            }
            let score = ws.isEmpty ? 0 : blend([
                (scale(perWeek, worst: 1, best: 5), 0.6),
                (scale(Double(active), worst: 1, best: 4), 0.4)
            ])
            return (score, perWeek, active)
        }
        let c = components(recent, end: now)
        let p = components(previous, end: now.addingTimeInterval(-28 * 86400))
        return MetricScore(
            key: .consistency, title: "Consistency", icon: "calendar.badge.checkmark",
            score: c.score, trend: previous.isEmpty ? nil : diff(c.score, p.score),
            headline: String(format: "%.1f sessions/week", c.perWeek),
            evidence: [
                String(format: "%.1f sessions per week over the last 4 weeks", c.perWeek),
                "\(c.activeWeeks) of 4 weeks had 2+ sessions"
            ],
            howToImprove: "Showing up beats occasional heroics. Aim for 4–5 sessions per week, mixing technical, conditioning and easy aerobic work. Missing a week costs more fitness than one hard session builds.",
            dataHint: ""
        )
    }

    private static func loadBalanceScore(load: [TrainingLoadPoint]) -> MetricScore {
        guard let last = load.last, last.fitness >= 5 else {
            return MetricScore(key: .loadBalance, title: "Load Balance", icon: "scalemass.fill", score: nil, trend: nil,
                               headline: "Building baseline", evidence: [],
                               howToImprove: "Train consistently for 2–3 weeks so your chronic load can be established.",
                               dataHint: "About 2 weeks of regular training is needed.")
        }
        let acwr = last.fatigue / last.fitness
        let week = load.suffix(7).map(\.load)
        let monotony: Double? = {
            guard let m = mean(week), let s = sd(week), s > 0 else { return nil }
            return m / s
        }()
        let score = blend([
            (max(0, 100 - abs(acwr - 1.05) * 160), 0.7),
            (monotony.map { scale($0, worst: 2.5, best: 1.2) }, 0.3)
        ])
        var evidence = [String(format: "Acute:chronic ratio %.2f (sweet spot 0.8–1.3)", acwr),
                        String(format: "Form (fitness − fatigue): %+.0f", last.form)]
        if let m = monotony { evidence.append(String(format: "Training monotony %.1f (under 1.5 is healthy variation)", m)) }
        let status: String
        switch acwr {
        case ..<0.8: status = "Under-loaded / tapering"
        case 0.8...1.3: status = "In the sweet spot"
        case 1.3...1.5: status = "Ramping fast"
        default: status = "Spike — injury risk"
        }
        return MetricScore(
            key: .loadBalance, title: "Load Balance", icon: "scalemass.fill",
            score: score, trend: nil, headline: status, evidence: evidence,
            howToImprove: "Increase weekly load by no more than about 10% per week. Alternate hard and easy days so you're never doing the same intensity every day. Plan a lighter deload week every 3–4 weeks.",
            dataHint: ""
        )
    }

    private static func intensityMixScore(recent: [SavedWorkout], previous: [SavedWorkout]) -> MetricScore {
        func score(_ ws: [SavedWorkout]) -> Int? {
            guard let s = zoneShare(ws) else { return nil }
            return blend([(scale(s.mid, worst: 0.45, best: 0.15), 0.6), (scale(s.low, worst: 0.4, best: 0.7), 0.4)])
        }
        let share = zoneShare(recent)
        var evidence: [String] = []
        if let s = share {
            evidence = [
                "Easy (Z1–2): \(Int(s.low * 100))%  •  Tempo (Z3): \(Int(s.mid * 100))%  •  Hard (Z4–5): \(Int(s.high * 100))%",
                "Fighters do best with roughly 70% easy / 10% tempo / 20% hard"
            ]
        }
        return MetricScore(
            key: .intensityMix, title: "Intensity Mix", icon: "chart.pie.fill",
            score: score(recent), trend: diff(score(recent), score(previous)),
            headline: share.map { "\(Int($0.mid * 100))% in the Z3 grey zone" } ?? "More data needed",
            evidence: evidence,
            howToImprove: "Avoid living in Zone 3: it's too hard to recover from and too easy to build top-end power. Make easy sessions easier and hard sessions harder (polarised training).",
            dataHint: "About 10 minutes of recorded training is needed."
        )
    }

    private static func readinessScore(load: [TrainingLoadPoint], readings: [ReadinessReading],
                                       workouts: [SavedWorkout], profile: AthleteProfile, now: Date) -> MetricScore {
        let form = load.last?.form
        let today = readings.first.flatMap { now.timeIntervalSince($0.date) < 18 * 3600 ? $0 : nil }
        let baseline = readings.dropFirst().prefix(14)

        var hrvZ: Double?
        if let ln = today?.lnRMSSD {
            let base = baseline.compactMap(\.lnRMSSD)
            if base.count >= 3, let m = mean(base), let s = sd(base), s > 0 { hrvZ = (ln - m) / s }
        }
        var rhrDelta: Double?
        if let t = today {
            let base = baseline.map { Double($0.restingHR) }
            if base.count >= 3, let m = mean(base) { rhrDelta = Double(t.restingHR) - m }
        }
        let subjective = today.flatMap { $0.hasSelfRatings ? Double($0.sleepQuality + (6 - $0.soreness)) : nil }
        let lastHard = workouts.first { isHardSession($0, profile: profile) }
        let hoursSinceHard = lastHard.map { now.timeIntervalSince($0.endDate) / 3600 }

        let score = blend([
            (form.map { scale($0, worst: -30, best: 10) }, 0.30),
            (hrvZ.map { scale($0, worst: -2, best: 0.5) }, 0.25),
            (rhrDelta.map { scale($0, worst: 8, best: -2) }, 0.15),
            (subjective.map { scale($0, worst: 2, best: 10) }, 0.15),
            (hoursSinceHard.map { scale($0, worst: 12, best: 48) }, 0.15)
        ])

        var evidence: [String] = []
        if let f = form { evidence.append(String(format: "Form %+.0f (negative = carrying fatigue)", f)) }
        if let z = hrvZ { evidence.append(String(format: "HRV today %+.1f SD vs your baseline", z)) }
        if let d = rhrDelta { evidence.append(String(format: "Resting HR %+.0f BPM vs baseline", d)) }
        if let t = today, t.hasSelfRatings { evidence.append("Sleep \(t.sleepQuality)/5 • Soreness \(t.soreness)/5") }
        if let h = hoursSinceHard { evidence.append(String(format: "%.0f h since last hard session", h)) }
        if today == nil { evidence.append("Do a 2-min readiness check for HRV-based readiness") }

        let headline: String
        switch score ?? 60 {
        case 75...: headline = "Primed — go hard"
        case 55..<75: headline = "Good to train"
        case 35..<55: headline = "Go easy today"
        default: headline = "Recover today"
        }
        return MetricScore(
            key: .readiness, title: "Readiness", icon: "battery.100.bolt",
            score: score, trend: nil, headline: headline, evidence: evidence,
            howToImprove: "Readiness reflects recent load, HRV, resting HR, sleep and soreness. Do the 2-minute check each morning before coffee, measured the same way each time, for the most accurate trend.",
            dataHint: "Record a workout or a readiness check."
        )
    }

    private static func diff(_ a: Int?, _ b: Int?) -> Int? {
        guard let a, let b else { return nil }
        return a - b
    }

    // MARK: Prescriptions

    static func prescribeNext(readiness: MetricScore, focus: [MetricScore], workouts: [SavedWorkout],
                              load: [TrainingLoadPoint], profile: AthleteProfile,
                              vt1: HRVMath.VT1Estimate?, now: Date) -> WorkoutPrescription {
        let z = profile.activeZones
        let r = readiness.score ?? 60
        let form = load.last?.form ?? 0
        let acwr: Double = {
            guard let l = load.last, l.fitness >= 5 else { return 1 }
            return l.fatigue / l.fitness
        }()
        let last = workouts.first
        let lastWasHard = last.map { isHardSession($0, profile: profile) } ?? false
        let hoursSinceLast = last.map { now.timeIntervalSince($0.endDate) / 3600 } ?? 999
        let z2Top = vt1.map { min($0.bpm, z.z2Max) } ?? z.z2Max

        if r < 35 || form < -30 {
            return WorkoutPrescription(
                title: "Recovery Day", category: .walk, drillTag: .aerobicZ2, roundTimer: false,
                workSeconds: 180, restSeconds: 60, rounds: nil, durationMinutes: 25, useBagCoach: false, bagTempo: .technical,
                targetLowBPM: max(profile.restingHR + 20, z.z1Max - 25), targetHighBPM: z.z1Max,
                structure: "20–30 min easy walk + 10 min mobility",
                rationale: "Your readiness is low (\(r)) and you're carrying fatigue (form \(Int(form))). Fitness is built during recovery. An easy walk speeds it up without adding stress.",
                isRestDay: true
            )
        }

        if r < 55 || acwr > 1.5 || (lastWasHard && hoursSinceLast < 24) {
            let why = acwr > 1.5 ? "Your load jumped sharply this week (ACWR \(String(format: "%.2f", acwr)))."
                : (lastWasHard && hoursSinceLast < 24) ? "Your last session was hard and less than 24 h ago."
                : "Readiness is moderate (\(r))."
            return WorkoutPrescription(
                title: "Technical Flow Rounds", category: .kickboxing, drillTag: .technical, roundTimer: true,
                workSeconds: 180, restSeconds: 60, rounds: 5, durationMinutes: 20, useBagCoach: false, bagTempo: .technical,
                targetLowBPM: z.z1Max, targetHighBPM: z.z3Max,
                structure: "5 × 3 min shadow / technique at 60–70% effort, 1 min rest",
                rationale: "\(why) Sharpen technique at controlled intensity, staying under \(z.z3Max) BPM.",
                isRestDay: false
            )
        }

        let weakest = focus.first?.key ?? .aerobic
        switch weakest {
        case .anaerobic:
            return WorkoutPrescription(
                title: "Bag Power Intervals", category: .heavyBag, drillTag: .intervals, roundTimer: true,
                workSeconds: 30, restSeconds: 90, rounds: 10, durationMinutes: 22, useBagCoach: true, bagTempo: .burnout,
                targetLowBPM: z.z4Max, targetHighBPM: profile.effectiveMaxHR,
                structure: "10 × 30 s all-out combos, 90 s easy rest",
                rationale: "Anaerobic Power is your lowest area (\(focus.first?.score ?? 0)). Short maximal efforts with full recovery build explosive output without the fatigue of long hard rounds.",
                isRestDay: false
            )
        case .stamina:
            return WorkoutPrescription(
                title: "Short-Rest Endurance Rounds", category: .padWork, drillTag: .bagWork, roundTimer: true,
                workSeconds: 180, restSeconds: 30, rounds: 7, durationMinutes: 25, useBagCoach: true, bagTempo: .variable,
                targetLowBPM: z.z2Max, targetHighBPM: z.z4Max,
                structure: "7 × 3 min steady-hard rounds, only 30 s rest",
                rationale: "Fight Stamina is your lowest area. Short rests train you to keep output high as fatigue builds. Keep round 7 as crisp as round 1.",
                isRestDay: false
            )
        case .recovery:
            return WorkoutPrescription(
                title: "Recovery-Drill Rounds", category: .kickboxing, drillTag: .bagWork, roundTimer: true,
                workSeconds: 180, restSeconds: 60, rounds: 6, durationMinutes: 24, useBagCoach: true, bagTempo: .fightPace,
                targetLowBPM: z.z3Max, targetHighBPM: z.z4Max,
                structure: "6 × 3 min fight pace, 1 min rest with nasal 4-in / 6-out breathing",
                rationale: "Recovery Speed is your lowest area. Practise dropping HR fast on the stool. The coach announces your drop each round, so try to beat it.",
                isRestDay: false
            )
        default:
            return WorkoutPrescription(
                title: "Zone 2 Roadwork", category: .roadwork, drillTag: .aerobicZ2, roundTimer: false,
                workSeconds: 180, restSeconds: 60, rounds: nil, durationMinutes: 40, useBagCoach: false, bagTempo: .steady,
                targetLowBPM: z.z1Max + 1, targetHighBPM: z2Top,
                structure: "40 min continuous easy run (conversational pace)",
                rationale: "Aerobic Base is your lowest area. Zone 2 volume builds the engine that powers recovery between rounds. The audio coach warns you if you drift above \(z2Top) BPM.",
                isRestDay: false
            )
        }
    }

    private static func buildRecommendations(readiness: MetricScore, metrics: [MetricScore], focus: [MetricScore],
                                             load: [TrainingLoadPoint], workouts: [SavedWorkout],
                                             readings: [ReadinessReading], profile: AthleteProfile,
                                             measuredRHR: Int?, vt1: HRVMath.VT1Estimate?, now: Date) -> [CoachRecommendation] {
        var recs: [CoachRecommendation] = []
        let z = profile.activeZones

        if readings.first.map({ now.timeIntervalSince($0.date) > 18 * 3600 }) ?? true {
            recs.append(.init(kind: .test, title: "Take today's readiness check",
                              detail: "Two minutes sitting still with the strap on. It tracks HRV and resting HR so the coach can tell real fatigue from a bad day."))
        }

        if let l = load.last, l.fitness >= 5 {
            let acwr = l.fatigue / l.fitness
            if acwr > 1.5 {
                recs.append(.init(kind: .warning, title: "Load spike detected",
                                  detail: String(format: "This week's load is %.0f%% above your normal. Hold or reduce volume for a few days. Injury risk rises sharply above 1.5.", (acwr - 1) * 100)))
            } else if acwr < 0.75 && workouts.count >= 6 {
                recs.append(.init(kind: .train, title: "You're losing sharpness",
                                  detail: "Training has dropped well below your normal load. Unless you're tapering for a fight, add a session this week."))
            }
        }

        if let mix = metrics.first(where: { $0.key == .intensityMix }), let s = mix.score, s < 50 {
            recs.append(.init(kind: .focus, title: "Too much grey-zone training",
                              detail: "A lot of your time is in Zone 3 (\(z.z2Max + 1)–\(z.z3Max) BPM). Make easy days easier and hard days harder."))
        }

        for area in focus {
            guard let s = area.score, s < 70 else { continue }
            recs.append(.init(kind: .focus, title: "Work on \(area.title) (\(s))", detail: area.howToImprove))
        }

        let lastLTHR = workouts.first { $0.category == .lthrTest }
        if lastLTHR.map({ now.timeIntervalSince($0.startDate) > 42 * 86400 }) ?? (workouts.count >= 5) {
            recs.append(.init(kind: .test, title: "Retest your threshold",
                              detail: "Your zones are only as good as your last test. A 30-min LTHR field test every 6 weeks keeps every metric accurate."))
        }

        let recentMax = workouts.filter { $0.startDate >= now.addingTimeInterval(-90 * 86400) }.map(\.maxBPM).filter { $0 < 240 }.max()
        if let observed = recentMax, observed > profile.effectiveMaxHR + 1 {
            recs.append(.init(kind: .test, title: "New max HR seen: \(observed) BPM",
                              detail: "You reached \(observed) BPM, above your profile max of \(profile.effectiveMaxHR). Unless it was a sensor glitch, set Max HR to \(observed) in the Fighter tab so your zones and ratings stay accurate."))
        }

        if let m = measuredRHR, abs(m - profile.restingHR) >= 4 {
            recs.append(.init(kind: .test, title: "Update resting HR to \(m) BPM",
                              detail: "Your morning checks average \(m) BPM, but your profile says \(profile.restingHR). Update it in the Fighter tab for more accurate zones and calories."))
        }

        if let v = vt1, abs(v.bpm - z.z2Max) >= 6 {
            recs.append(.init(kind: .focus, title: "Aerobic threshold ≈ \(v.bpm) BPM",
                              detail: "Beat-to-beat analysis puts your aerobic threshold at \(v.bpm) BPM, versus your Zone 2 ceiling of \(z.z2Max). Keep easy runs under \(min(v.bpm, z.z2Max)) BPM."))
        }

        if profile.campPhase == .fightWeek {
            recs.insert(.init(kind: .rest, title: "Fight week: stay sharp, stay fresh",
                              detail: "Keep sessions short and snappy: a few rounds at fight pace, with lots of rest. Don't chase fitness now; it's already built."), at: 0)
        }

        return recs
    }

    // MARK: Per-workout review

    static func review(workout w: SavedWorkout, profile: AthleteProfile, history: [SavedWorkout]) -> WorkoutReview {
        var items: [WorkoutReview.Item] = []
        var takeaways: [String] = []
        let total = max(1, w.zoneSeconds.values.reduce(0, +))
        let low = (w.zoneSeconds[1, default: 0] + w.zoneSeconds[2, default: 0]) / total
        let mid = w.zoneSeconds[3, default: 0] / total
        let high = (w.zoneSeconds[4, default: 0] + w.zoneSeconds[5, default: 0]) / total
        let maxHR = Double(profile.effectiveMaxHR)

        // 1. Did intensity match the session's intent?
        var intent: (Int, String)?
        switch w.drillTag {
        case .aerobicZ2:
            intent = (Int(scale(low, worst: 0.5, best: 0.85)), "\(Int(low * 100))% easy (target 80%+)")
            if low < 0.75 { takeaways.append("Slow down on Z2 days. You spent \(Int((1 - low) * 100))% above Zone 2, which turns base work into fatigue.") }
        case .technical:
            let s = blend([(scale(low + mid, worst: 0.4, best: 0.8), 0.7), (scale(high, worst: 0.3, best: 0.05), 0.3)]) ?? 50
            intent = (s, "\(Int((low + mid) * 100))% controlled (target 70%+)")
            if high > 0.2 { takeaways.append("Technical sessions should stay controlled. \(Int(high * 100))% of this one was at threshold or above.") }
        case .bagWork, .intervals:
            intent = (Int(scale(high, worst: 0.05, best: 0.35)), "\(Int(high * 100))% at threshold+ (target 25%+)")
            if high < 0.2 { takeaways.append("Intervals only work if they're hard. Push each effort until HR climbs above \(profile.activeZones.z4Max) BPM.") }
        case .hardSparring, .sharkTank:
            intent = (Int(scale(high, worst: 0.1, best: 0.45)), "\(Int(high * 100))% at threshold+ (target 35%+)")
        case .lthrProtocol:
            intent = nil
        }
        if let intent {
            items.append(.init(title: "Intent Match", icon: "target", score: intent.0, note: intent.1))
        }

        // 2. Round consistency
        if let creep = roundCreepPercent(w.roundStats) {
            let s = Int(scale(creep, worst: 12, best: 1))
            items.append(.init(title: "Round Consistency", icon: "chart.bar.fill", score: s,
                               note: String(format: "HR rose %.1f%% from early to late rounds", creep)))
            if creep > 7 { takeaways.append("HR climbed steadily through the rounds. Pace the opening rounds a little more, or build stamina with short-rest rounds.") }
        }

        // 3. Between-round recovery
        let drops = w.roundStats.compactMap(\.stoolDropBPM) + w.autoHRREvents.map(\.dropBPM)
        if !drops.isEmpty {
            let avg = Double(drops.reduce(0, +)) / Double(drops.count)
            items.append(.init(title: "Recovery", icon: "arrow.down.heart.fill", score: Int(scale(avg, worst: 12, best: 35)),
                               note: String(format: "Average drop %.0f BPM per rest", avg)))
            if let ret = recoveryRetention(w.roundStats), ret < 0.75 {
                takeaways.append(String(format: "Recovery faded to %.0f%% by the late rounds. Practise slow nasal breathing on the stool.", ret * 100))
            }
        }

        // 4. Pacing on continuous efforts
        if w.roundStats.count < 2 && w.duration >= 1200 {
            let s = Int(scale(w.cardiacDriftPercent, worst: 12, best: 3))
            items.append(.init(title: "Pacing", icon: "speedometer", score: s,
                               note: String(format: "%.1f%% cardiac drift", w.cardiacDriftPercent)))
            if w.cardiacDriftPercent > 8 { takeaways.append("High drift: HR kept rising at the same effort. Start slower, hydrate, and build aerobic base.") }
        }

        // 5. Peak output on hard sessions
        let hardTags: [DrillTag] = [.bagWork, .intervals, .hardSparring, .sharkTank]
        if hardTags.contains(w.drillTag) {
            let pct = Double(w.maxBPM) / maxHR
            items.append(.init(title: "Peak Output", icon: "flame.fill", score: Int(scale(pct, worst: 0.82, best: 0.97)),
                               note: "Peaked at \(Int(pct * 100))% of max HR"))
        }

        // Training-plan completion and time in each block's target
        if !w.blockResults.isEmpty {
            let done = w.blockResults.filter(\.completed).count
            let targeted = w.blockResults.compactMap(\.timeInTarget)
            let completion = Double(done) / Double(w.blockResults.count)
            let targetScore = targeted.isEmpty ? nil : targeted.reduce(0, +) / Double(targeted.count)
            let score = blend([(completion * 100, 0.6), (targetScore.map { scale($0, worst: 0.3, best: 0.8) }, 0.4)]) ?? Int(completion * 100)
            items.append(.init(title: "Plan Execution", icon: "list.bullet.rectangle.portrait.fill", score: score,
                               note: "\(done)/\(w.blockResults.count) blocks completed" + (targetScore.map { " • \(Int($0 * 100))% in target" } ?? "")))
            if done < w.blockResults.count {
                takeaways.append("Some blocks were skipped or cut short. If the plan was too long, tell your coach so it can be adjusted.")
            }
        }

        // 6. Coach plan adherence
        if let adherence = w.planAdherence, let lo = w.planTargetLow, let hi = w.planTargetHigh {
            items.append(.init(title: "Plan Adherence", icon: "list.clipboard.fill",
                               score: Int(scale(adherence, worst: 0.3, best: 0.8)),
                               note: "\(Int(adherence * 100))% of the session in \(lo)–\(hi) BPM\(w.planTitle.map { " (\($0))" } ?? "")"))
            if adherence < 0.5 {
                takeaways.append("Under half the session was in the plan's target band. Use the on-screen target and audio alerts to stay in range.")
            }
        }

        // 7. Session load vs normal
        let others = history.filter { $0.id != w.id && $0.profileID == w.profileID && $0.startDate >= w.startDate.addingTimeInterval(-28 * 86400) && $0.startDate < w.startDate }
        var loadText: String?
        if others.count >= 3 {
            let sorted = others.map(\.effectiveLoad).sorted()
            let median = sorted[sorted.count / 2]
            if median > 0 {
                let ratio = w.effectiveLoad / median
                loadText = String(format: "Load %.0f — %.0f%% of your typical session", w.effectiveLoad, ratio * 100)
                if ratio > 1.6 { takeaways.append("This was a big session. Plan an easy day next.") }
            }
        }

        if takeaways.isEmpty && !items.isEmpty {
            takeaways.append("Solid execution. Repeat this structure and progress it next time: add a round, or cut 15 s from the rest.")
        }

        let overall = items.isEmpty ? nil : Int(Double(items.map(\.score).reduce(0, +)) / Double(items.count))
        return WorkoutReview(overall: overall, items: items, takeaways: takeaways, loadComparison: loadText)
    }
}
