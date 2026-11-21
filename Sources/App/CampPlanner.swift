import Foundation
import SwiftUI

// MARK: - Units

/// Weights are stored in kg; these convert for display/entry when the athlete prefers pounds.
enum WeightUnits {
    static let lbPerKg = 2.20462
    static func value(_ kg: Double, _ imperial: Bool) -> Double { imperial ? kg * lbPerKg : kg }
    static func toKg(_ v: Double, _ imperial: Bool) -> Double { imperial ? v / lbPerKg : v }
    static func unit(_ imperial: Bool) -> String { imperial ? "lb" : "kg" }
    static func number(_ kg: Double, _ imperial: Bool) -> String { String(format: "%.1f", value(kg, imperial)) }
    static func text(_ kg: Double, _ imperial: Bool) -> String { "\(number(kg, imperial)) \(unit(imperial))" }
}

enum HeightUnits {
    static let cmPerInch = 2.54
    /// Feet and whole inches, e.g. (5, 9).
    static func feetInches(_ cm: Double) -> (feet: Int, inches: Int) {
        let total = Int((cm / cmPerInch).rounded())
        return (total / 12, total % 12)
    }
    static func cm(feet: Int, inches: Int) -> Double { Double(feet * 12 + inches) * cmPerInch }
    static func text(_ cm: Double, _ imperial: Bool) -> String {
        guard imperial else { return "\(Int(cm.rounded())) cm" }
        let fi = feetInches(cm)
        return "\(fi.feet)′ \(fi.inches)″"
    }
}

// MARK: - Weigh-ins

struct WeighIn: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var profileID: UUID
    var date: Date = Date()
    var weightKg: Double
    /// Urine colour on the 8-point Armstrong hydration chart (1 = clear, 8 = dark), optional.
    var urineColor: Int?
    var notes: String = ""
}

struct WeightWarning: Identifiable {
    enum Severity: Int { case info, caution, danger }
    let id = UUID()
    let severity: Severity
    let title: String
    let detail: String

    var icon: String {
        switch severity {
        case .info: return "checkmark.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .danger: return "drop.triangle.fill"
        }
    }

    var tint: Color {
        switch severity {
        case .info: return .green
        case .caution: return .yellow
        case .danger: return .red
        }
    }
}

struct WeightCutStatus {
    let latest: WeighIn?
    let currentKg: Double
    let targetKg: Double
    let toGoKg: Double
    let toGoPercent: Double
    let daysToFight: Int?
    let requiredKgPerWeek: Double?
    let trendKgPerWeek: Double?
    let projectedFightWeightKg: Double?
    let warnings: [WeightWarning]
    let series: [WeighIn]

    var isOnTrack: Bool {
        guard let p = projectedFightWeightKg else { return toGoKg <= 0 }
        return p <= targetKg + max(0.5, targetKg * 0.02)
    }
}

// MARK: - Camp plan

enum CampPhaseKind: String, CaseIterable {
    case base = "Base"
    case build = "Build"
    case peak = "Peak"
    case taper = "Taper"

    var color: Color {
        switch self {
        case .base: return .blue
        case .build: return .orange
        case .peak: return .red
        case .taper: return .green
        }
    }

    var profilePhase: CampPhase {
        switch self {
        case .base, .build, .peak: return .fightCamp
        case .taper: return .weightCut
        }
    }
}

struct CampWeek: Identifiable {
    let index: Int            // 1-based
    let start: Date
    let end: Date             // exclusive
    let phase: CampPhaseKind
    let isDeload: Bool
    let isFightWeek: Bool
    let targetLoad: Double
    let targetSessions: Int
    let intensityMix: (low: Int, mid: Int, high: Int)
    let focus: String
    let keySessions: [String]
    var actualLoad: Double
    var actualSessions: Int

    var id: Int { index }

    var completion: Double {
        targetLoad > 0 ? actualLoad / targetLoad : 0
    }

    var title: String {
        isFightWeek ? "Fight Week" : "Week \(index) • \(phase.rawValue)\(isDeload ? " (deload)" : "")"
    }
}

struct CampPlan {
    let fightDate: Date
    let campStart: Date
    let weeks: [CampWeek]
    let baselineWeeklyLoad: Double
    let currentWeekIndex: Int?

    var currentWeek: CampWeek? {
        guard let i = currentWeekIndex else { return nil }
        return weeks.first { $0.index == i }
    }

    var hasStarted: Bool { Date() >= campStart }
    var isOver: Bool { Date() >= fightDate.addingTimeInterval(86400) }
}

// MARK: - Planner

enum CampPlanner {

    // MARK: Weight analysis

    static func weightStatus(
        weighIns allWeighIns: [WeighIn],
        readings: [ReadinessReading],
        profile: AthleteProfile,
        now: Date = Date()
    ) -> WeightCutStatus {
        let series = allWeighIns.filter { $0.profileID == profile.id }.sorted { $0.date < $1.date }
        let latest = series.last
        let current = latest?.weightKg ?? profile.weightKg
        let target = profile.targetFightWeightKg
        let toGo = current - target
        let toGoPct = current > 0 ? toGo / current * 100 : 0
        let imp = profile.useImperial
        let perWeek = "\(WeightUnits.unit(imp))/week"

        let daysToFight: Int? = profile.fightDate.map {
            Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now),
                                            to: Calendar.current.startOfDay(for: $0)).day ?? 0
        }

        // Trend from the last 14 days (kg/week), linear regression on days.
        let recent = series.filter { $0.date >= now.addingTimeInterval(-14 * 86400) }
        var trend: Double?
        if recent.count >= 3, let first = recent.first?.date {
            let x = recent.map { $0.date.timeIntervalSince(first) / 86400 }
            let y = recent.map(\.weightKg)
            if let fit = HRVMath.linearRegression(x, y), (x.last ?? 0) >= 4 {
                trend = fit.slope * 7
            }
        }

        var required: Double?
        var projected: Double?
        if let d = daysToFight, d > 0 {
            required = max(0, toGo) / (Double(d) / 7)
            if let t = trend { projected = current + t * Double(d) / 7 }
        }

        var warnings: [WeightWarning] = []
        let fightWeek = (daysToFight ?? 99) <= 7 && (daysToFight ?? -1) >= 0

        // Rapid day-to-day loss
        if series.count >= 2 {
            let a = series[series.count - 2], b = series[series.count - 1]
            let hours = b.date.timeIntervalSince(a.date) / 3600
            let lossPct = (a.weightKg - b.weightKg) / a.weightKg * 100
            if hours <= 36 && hours > 0 {
                if lossPct >= 2 {
                    warnings.append(.init(severity: .danger, title: "Rapid drop: −\(fmt(lossPct))% in \(Int(hours)) h",
                                          detail: "Losses this fast are mostly water. Rehydrate with fluids and electrolytes, and avoid hard training until it comes back."))
                } else if lossPct >= 1.2 && !fightWeek {
                    warnings.append(.init(severity: .caution, title: "Fast daily loss (−\(fmt(lossPct))%)",
                                          detail: "More than about 1% per day outside fight week usually means dehydration. Check your fluid intake."))
                }
            }
        }

        // Urine colour
        if let u = latest?.urineColor, let l = latest, now.timeIntervalSince(l.date) < 24 * 3600 {
            if u >= 6 {
                warnings.append(.init(severity: .danger, title: "Dark urine (\(u)/8)",
                                      detail: "A strong sign of dehydration. Drink 500–750 ml with electrolytes now, and recheck in 2 hours."))
            } else if u >= 4 {
                warnings.append(.init(severity: .caution, title: "Mildly dehydrated (\(u)/8)",
                                      detail: "Aim for pale straw colour (1–3). Spread your fluids through the day."))
            }
        }

        // Body signals: elevated resting HR / suppressed HRV alongside a weight drop
        let readingToday = readings.sorted { $0.date > $1.date }.first.flatMap { now.timeIntervalSince($0.date) < 18 * 3600 ? $0 : nil }
        let weightDrop48h: Double? = {
            guard let l = latest else { return nil }
            let older = series.last { $0.date <= l.date.addingTimeInterval(-24 * 3600) && $0.date >= l.date.addingTimeInterval(-72 * 3600) }
            guard let o = older else { return nil }
            return (o.weightKg - l.weightKg) / o.weightKg * 100
        }()
        if let r = readingToday {
            let base = readings.filter { $0.id != r.id }.sorted { $0.date > $1.date }.prefix(14)
            if base.count >= 3 {
                let baseRHR = Double(base.map(\.restingHR).reduce(0, +)) / Double(base.count)
                let rhrUp = Double(r.restingHR) - baseRHR
                let lnBase = base.compactMap(\.lnRMSSD)
                var hrvZ: Double?
                if let ln = r.lnRMSSD, lnBase.count >= 3 {
                    let m = lnBase.reduce(0, +) / Double(lnBase.count)
                    let sd = sqrt(lnBase.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(lnBase.count - 1))
                    if sd > 0 { hrvZ = (ln - m) / sd }
                }
                let dropping = (weightDrop48h ?? 0) >= 1.0
                if rhrUp >= 6 && dropping {
                    warnings.append(.init(severity: .danger, title: "Dehydration signs: resting HR +\(Int(rhrUp)) BPM",
                                          detail: "Your resting heart rate is up while your weight is dropping fast, which is classic dehydration. Lower blood volume makes the heart work harder. Rehydrate before training."))
                } else if rhrUp >= 6 {
                    warnings.append(.init(severity: .caution, title: "Resting HR elevated +\(Int(rhrUp)) BPM",
                                      detail: "This can be fatigue, illness or poor hydration. Go easier today."))
                }
                if let z = hrvZ, z <= -1.5 {
                    warnings.append(.init(severity: dropping ? .danger : .caution, title: "HRV suppressed (\(String(format: "%.1f", z)) SD)",
                                          detail: dropping ? "Low HRV during rapid weight loss points to stress from the cut. Ease the deficit, and prioritise sleep and fluids."
                                                           : "Your nervous system is under stress. Keep today's session light."))
                }
            }
        }

        // Rate of loss
        if let t = trend, -t / current * 100 > 1.5, !fightWeek {
            warnings.append(.init(severity: .caution, title: "Losing \(WeightUnits.number(-t, imp)) \(perWeek)",
                                  detail: "Losing more than 1–1.5% of body weight per week costs muscle and power. Slow the diet down a little."))
        }

        if let d = daysToFight, d > 0, toGo > 0 {
            let reqPct = (required ?? 0) / current * 100
            if d <= 7 && toGoPct > 5 {
                warnings.append(.init(severity: .danger, title: "\(fmt(toGoPct))% still to cut in fight week",
                                      detail: "Water cuts above about 5% seriously impair performance and are dangerous. Talk to your coach about moving up a weight class or a safer plan."))
            } else if d > 7 && reqPct > 1.5 {
                warnings.append(.init(severity: .danger, title: "Target needs \(WeightUnits.number(required ?? 0, imp)) \(perWeek)",
                                      detail: "That's over 1.5% of body weight per week. The target is likely unrealistic without a harmful water cut."))
            } else if d > 7 && reqPct > 1.0 {
                warnings.append(.init(severity: .caution, title: "Aggressive pace: \(WeightUnits.number(required ?? 0, imp)) \(perWeek)",
                                      detail: "Doable, but leave no slack. Keep protein high (2 g/kg) to protect muscle."))
            }
        }

        if warnings.isEmpty && latest != nil {
            if toGo <= 0 {
                warnings.append(.init(severity: .info, title: "On weight", detail: "You're at or under your fight weight. Focus on staying hydrated and fuelled."))
            } else {
                warnings.append(.init(severity: .info, title: "Cut is on track", detail: "Steady loss with no warning signs from weight, HR or HRV."))
            }
        }

        return WeightCutStatus(
            latest: latest, currentKg: current, targetKg: target, toGoKg: toGo, toGoPercent: toGoPct,
            daysToFight: daysToFight, requiredKgPerWeek: required, trendKgPerWeek: trend,
            projectedFightWeightKg: projected,
            warnings: warnings.sorted { $0.severity.rawValue > $1.severity.rawValue },
            series: series
        )
    }

    static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    // MARK: Periodization

    static func buildPlan(profile: AthleteProfile, workouts allWorkouts: [SavedWorkout], now: Date = Date()) -> CampPlan? {
        guard let fight = profile.fightDate else { return nil }
        let cal = Calendar.current
        let n = min(max(profile.campLengthWeeks, 4), 16)
        let fightDayEnd = cal.startOfDay(for: fight).addingTimeInterval(86400)
        let campStart = fightDayEnd.addingTimeInterval(-Double(n) * 7 * 86400)
        let workouts = allWorkouts.filter { $0.profileID == profile.id }

        // Baseline = chronic load (fitness) at camp start, as a weekly figure.
        let refDate = min(now, campStart)
        let fitnessAtStart = CoachEngine.trainingLoad(workouts: workouts, days: 1, now: refDate).last?.fitness ?? 0
        let baseline = max(250, fitnessAtStart * 7)

        let taperWeeks = n >= 10 ? 2 : 1
        let peakWeeks = n >= 8 ? 2 : 1
        let buildWeeks = Int((Double(n - taperWeeks - peakWeeks) * 0.5).rounded())
        let baseWeeks = max(0, n - taperWeeks - peakWeeks - buildWeeks)

        var weeks: [CampWeek] = []
        var level = baseline
        for i in 1...n {
            let start = campStart.addingTimeInterval(Double(i - 1) * 7 * 86400)
            let end = start.addingTimeInterval(7 * 86400)
            let phase: CampPhaseKind
            if i <= baseWeeks { phase = .base }
            else if i <= baseWeeks + buildWeeks { phase = .build }
            else if i <= baseWeeks + buildWeeks + peakWeeks { phase = .peak }
            else { phase = .taper }
            let isFightWeek = i == n
            let deload = (phase == .base || phase == .build) && i % 4 == 0

            var target: Double
            switch phase {
            case .base:
                if i > 1 { level *= 1.08 }
                target = level
            case .build:
                level *= 1.05
                target = level
            case .peak:
                let peakIndex = i - baseWeeks - buildWeeks
                target = level * (peakIndex == 1 ? 1.0 : 0.9)
            case .taper:
                let taperIndex = i - baseWeeks - buildWeeks - peakWeeks
                target = level * (isFightWeek ? 0.4 : (taperIndex == 1 ? 0.65 : 0.5))
            }
            if deload { target *= 0.7 }

            let content = weekContent(phase: phase, isFightWeek: isFightWeek, deload: deload, profile: profile)
            let inWeek = workouts.filter { $0.startDate >= start && $0.startDate < end }
            weeks.append(CampWeek(
                index: i, start: start, end: end, phase: phase, isDeload: deload, isFightWeek: isFightWeek,
                targetLoad: target.rounded(), targetSessions: content.sessions, intensityMix: content.mix,
                focus: content.focus, keySessions: content.keys,
                actualLoad: inWeek.reduce(0) { $0 + $1.effectiveLoad }, actualSessions: inWeek.count
            ))
        }

        let current = weeks.first { now >= $0.start && now < $0.end }?.index
        return CampPlan(fightDate: fight, campStart: campStart, weeks: weeks, baselineWeeklyLoad: baseline, currentWeekIndex: current)
    }

    private static func weekContent(phase: CampPhaseKind, isFightWeek: Bool, deload: Bool, profile: AthleteProfile)
        -> (sessions: Int, mix: (low: Int, mid: Int, high: Int), focus: String, keys: [String]) {
        let z = profile.activeZones
        if isFightWeek {
            return (3, (75, 5, 20), "Stay sharp, make weight safely, arrive fresh.",
                    ["2 short pad sessions: 3–4 × 2 min at fight pace, full rest",
                     "Light shadowboxing and visualisation",
                     "Follow your weight-cut plan, then rehydrate after weigh-ins"])
        }
        if deload {
            return (3, (80, 10, 10), "Absorb the training. Reduce volume by about 30% while keeping some sharpness.",
                    ["2 technical sessions in Zone 2–3", "1 short Zone 2 run", "Extra sleep and mobility"])
        }
        switch phase {
        case .base:
            return (5, (80, 10, 10), "Build the aerobic engine and technical volume.",
                    ["2 × Zone 2 roadwork, 40–50 min (under \(z.z2Max) BPM)",
                     "2 × technical rounds (6 × 3 min, controlled)",
                     "1–2 strength sessions"])
        case .build:
            return (5, (70, 10, 20), "Raise threshold and round tolerance.",
                    ["2 × fight-pace rounds (5–6 × 3 min, 1 min rest)",
                     "1 × bag power intervals (10 × 30 s all-out)",
                     "1 × Zone 2 run, 35–45 min",
                     "1 × controlled sparring"])
        case .peak:
            return (5, (65, 10, 25), "Fight-specific intensity. Hardest sparring of camp.",
                    ["2 × hard sparring or shark tank",
                     "1 × fight simulation (3–5 × 3 min, 1 min rest)",
                     "1 × short-rest endurance rounds (7 × 3 min, 30 s rest)",
                     "1 × easy 25-min Zone 1–2 flush"])
        case .taper:
            return (4, (75, 5, 20), "Cut volume and keep intensity. Freshness is the goal.",
                    ["2 × short sharp pad rounds at fight pace",
                     "1 × light technical sparring",
                     "1 × easy Zone 2 session"])
        }
    }
}
