import Foundation

// Pure analysis engines for FIGHT's signature features. No UI, fully unit-testable.

private func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

private func mean(_ xs: [Double]) -> Double? {
    xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
}

// MARK: - Gas Tank

struct FightFormat: Identifiable, Hashable {
    let rounds: Int
    let minutes: Int
    var id: String { label }
    var label: String { "\(rounds)×\(minutes)" }

    static let common = [FightFormat(rounds: 3, minutes: 2), FightFormat(rounds: 3, minutes: 3), FightFormat(rounds: 5, minutes: 3)]
}

struct GasTankResult {
    struct FormatReadiness: Identifiable {
        let format: FightFormat
        let percent: Int
        /// First round where projected HR crosses redline or recovery collapses (nil = never).
        let limitRound: Int?
        var id: String { format.id }
        var isReady: Bool { percent >= 90 }
    }

    let formats: [FormatReadiness]
    let sessionsUsed: Int
    let creepPerRound: Double
    let firstRoundBPM: Int
    let redlineBPM: Int
    let intenseEnough: Bool

    var headline: String {
        guard intenseEnough else { return "Train some rounds at fight pace to measure" }
        if let best = formats.last(where: \.isReady) {
            return "Ready for \(best.format.label)"
        }
        let first = formats.first
        return "Building: \(first?.format.label ?? "3×2") at \(first?.percent ?? 0)%"
    }

    /// The next format to work towards, e.g. "5×3: 60% (limit round 4)".
    var nextGoal: FormatReadiness? {
        formats.first { !$0.isReady }
    }
}

/// Projects how many rounds at fight pace you can sustain before heart rate
/// redlines or between-round recovery collapses, from your recent round data.
enum GasTank {
    static func evaluate(workouts: [SavedWorkout], profile: AthleteProfile, now: Date = Date()) -> GasTankResult? {
        let since = now.addingTimeInterval(-42 * 86400)
        let zones = profile.activeZones
        let maxHR = Double(profile.effectiveMaxHR)
        let redline = Double(zones.z4Max) + (maxHR - Double(zones.z4Max)) * 0.5

        var slopes: [Double] = []
        var firsts: [Double] = []
        var workDurations: [Double] = []
        var firstDrops: [Double] = []
        var fades: [Double] = []

        for w in workouts where w.profileID == profile.id && w.startDate >= since {
            let rounds = w.roundStats.sorted { $0.roundNumber < $1.roundNumber }
            guard rounds.count >= 3 else { continue }
            let avgWork = rounds.map { $0.endElapsed - $0.startElapsed }.reduce(0, +) / Double(rounds.count)
            guard avgWork >= 75 else { continue }
            let x = rounds.indices.map(Double.init)
            let y = rounds.map { Double($0.avgBPM) }
            guard let fit = HRVMath.linearRegression(x, y) else { continue }
            slopes.append(fit.slope)
            firsts.append(fit.intercept)
            workDurations.append(avgWork)
            let drops = rounds.compactMap(\.stoolDropBPM).map(Double.init)
            if let d0 = drops.first { firstDrops.append(d0) }
            if drops.count >= 3, let f = HRVMath.linearRegression(drops.indices.map(Double.init), drops) {
                fades.append(f.slope)
            }
        }

        guard slopes.count >= 2,
              let slopeMed = median(slopes), let first = median(firsts), let work = median(workDurations) else { return nil }
        let slope = max(0.3, slopeMed)
        let baseRecovery = median(firstDrops)
        let fade = median(fades).map { min(0, $0) }
        let intense = first >= Double(zones.z2Max)

        let formats = FightFormat.common.map { format -> GasTankResult.FormatReadiness in
            // Longer rounds creep more; scale the per-round creep by duration.
            let durationFactor = sqrt(Double(format.minutes * 60) / max(60, work))
            var limit: Int?
            for k in 1...format.rounds {
                let projected = first + slope * durationFactor * Double(k - 1)
                var recoveryCollapsed = false
                if let base = baseRecovery, let fade, k > 1 {
                    recoveryCollapsed = base + fade * Double(k - 1) < 10
                }
                if projected >= redline || recoveryCollapsed {
                    limit = k
                    break
                }
            }
            let percent = limit.map { Int(Double($0 - 1) / Double(format.rounds) * 100) } ?? 100
            return .init(format: format, percent: percent, limitRound: limit)
        }

        return GasTankResult(
            formats: formats, sessionsUsed: slopes.count, creepPerRound: slope,
            firstRoundBPM: Int(first.rounded()), redlineBPM: Int(redline.rounded()), intenseEnough: intense
        )
    }
}

// MARK: - Combo cost

struct ComboCostResult {
    struct Entry: Identifiable {
        let label: String
        let averageRise: Double
        let count: Int
        var id: String { label }
    }
    let byType: [Entry]
    let mostExpensive: [Entry]
    let kickToPunchRatio: Double?
    let combosAnalysed: Int

    var headline: String? {
        if let r = kickToPunchRatio, r > 1.15 {
            return String(format: "Kicks cost you %.1f× the heart rate of punch combos", r)
        }
        if let top = mostExpensive.first {
            return "Most expensive: \(top.label) (+\(Int(top.averageRise)) BPM)"
        }
        return nil
    }
}

/// Measures the heart-rate "price" of each combination the bag coach called.
enum ComboCost {
    /// HR rise in the 2–12 s after each combo, relative to HR when it was called.
    static func rises(events: [ComboEvent], samples: [HeartRatePoint]) -> [(event: ComboEvent, rise: Double)] {
        guard samples.count >= 10 else { return [] }
        let sorted = samples.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        func index(atOrBefore t: TimeInterval) -> Int? {
            var lo = 0, hi = sorted.count - 1, ans: Int?
            while lo <= hi {
                let mid = (lo + hi) / 2
                if sorted[mid].elapsedSeconds <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            return ans
        }
        var out: [(event: ComboEvent, rise: Double)] = []
        for e in events {
            guard let i = index(atOrBefore: e.t) else { continue }
            let base = sorted[i].bpm
            var peak = base
            var j = i + 1
            while j < sorted.count && sorted[j].elapsedSeconds <= e.t + 12 {
                if sorted[j].elapsedSeconds >= e.t + 2 { peak = max(peak, sorted[j].bpm) }
                j += 1
            }
            out.append((e, Double(max(0, peak - base))))
        }
        return out
    }

    static func typeLabel(_ strikes: [Strike]) -> String {
        let kinds = Set(strikes.map(\.kind))
        if kinds.contains(.kick) { return "With kicks" }
        if kinds.contains(.knee) || kinds.contains(.elbow) { return "Knees & elbows" }
        if kinds.contains(.defense) { return "Defence & counters" }
        return "Punches only"
    }

    static func analyze(workouts: [SavedWorkout], stance: Stance, resolveSamples: (SavedWorkout) -> [HeartRatePoint]) -> ComboCostResult? {
        var byType: [String: [Double]] = [:]
        var byCombo: [String: [Double]] = [:]
        var total = 0
        for w in workouts where !w.comboEvents.isEmpty {
            let samples = resolveSamples(w)
            for r in rises(events: w.comboEvents, samples: samples) {
                total += 1
                byType[typeLabel(r.event.strikes), default: []].append(r.rise)
                let label = r.event.strikes.map { $0.shortLabel(stance: stance) }.joined(separator: "-")
                byCombo[label, default: []].append(r.rise)
            }
        }
        guard total >= 15 else { return nil }
        let types = byType.compactMap { k, v -> ComboCostResult.Entry? in
            guard v.count >= 3, let m = mean(v) else { return nil }
            return .init(label: k, averageRise: m, count: v.count)
        }.sorted { $0.averageRise > $1.averageRise }
        let combos = byCombo.compactMap { k, v -> ComboCostResult.Entry? in
            guard v.count >= 3, let m = mean(v) else { return nil }
            return .init(label: k, averageRise: m, count: v.count)
        }.sorted { $0.averageRise > $1.averageRise }
        var ratio: Double?
        if let kick = types.first(where: { $0.label == "With kicks" }),
           let punch = types.first(where: { $0.label == "Punches only" }), punch.averageRise > 0.5 {
            ratio = kick.averageRise / punch.averageRise
        }
        return ComboCostResult(byType: types, mostExpensive: Array(combos.prefix(5)), kickToPunchRatio: ratio, combosAnalysed: total)
    }
}

// MARK: - Benchmark

enum Benchmark {
    static let planID = PlanTemplates.benchmarkID

    struct Attempt: Identifiable {
        let id: UUID
        let date: Date
        let roundAverages: [Int]
        let averageWorkHR: Int
        let averageRecovery: Int?
        let completed: Bool
    }

    static func attempts(_ workouts: [SavedWorkout]) -> [Attempt] {
        workouts.filter { $0.trainingPlanID == planID }
            .sorted { $0.startDate < $1.startDate }
            .compactMap { w in
                let rounds = w.roundStats.sorted { $0.roundNumber < $1.roundNumber }
                guard rounds.count >= 2 else { return nil }
                let avgs = rounds.map(\.avgBPM)
                let drops = rounds.compactMap(\.stoolDropBPM)
                return Attempt(
                    id: w.id, date: w.startDate, roundAverages: avgs,
                    averageWorkHR: avgs.reduce(0, +) / avgs.count,
                    averageRecovery: drops.isEmpty ? nil : drops.reduce(0, +) / drops.count,
                    completed: w.blockResults.allSatisfy(\.completed)
                )
            }
    }

    /// e.g. "Same work, 9 BPM lower • recovery +11 BPM vs your first test"
    static func progressSummary(_ attempts: [Attempt]) -> String? {
        guard attempts.count >= 2, let first = attempts.first, let last = attempts.last else { return nil }
        let hr = last.averageWorkHR - first.averageWorkHR
        var parts: [String] = []
        if hr < 0 {
            parts.append("Same work, \(-hr) BPM lower")
        } else if hr > 0 {
            parts.append("Same work, \(hr) BPM higher")
        } else {
            parts.append("Same heart rate")
        }
        if let r0 = first.averageRecovery, let r1 = last.averageRecovery {
            parts.append(String(format: "recovery %+d BPM", r1 - r0))
        }
        return parts.joined(separator: " • ") + " vs your first test"
    }

    static func isDue(_ workouts: [SavedWorkout], now: Date = Date()) -> Bool {
        let all = attempts(workouts)
        if let last = all.last { return now.timeIntervalSince(last.date) >= 28 * 86400 }
        return workouts.count >= 5
    }
}

// MARK: - Performance drivers

struct DriverInsight: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    let strength: Double
}

/// Finds what predicts *your* good and bad sessions, from your own data.
enum PerformanceDrivers {
    private struct Point {
        let workout: SavedWorkout
        let score: Double?
        let recovery: Double?
        let reading: ReadinessReading?
        let hardBefore: Bool
    }

    static func analyze(workouts allWorkouts: [SavedWorkout], readings: [ReadinessReading], profile: AthleteProfile,
                        now: Date = Date()) -> [DriverInsight] {
        let workouts = allWorkouts
            .filter { $0.profileID == profile.id && $0.startDate >= now.addingTimeInterval(-120 * 86400) }
            .sorted { $0.startDate < $1.startDate }
        guard workouts.count >= 6 else { return [] }
        let sortedReadings = readings.sorted { $0.date < $1.date }

        let points: [Point] = workouts.map { w in
            let review = CoachEngine.review(workout: w, profile: profile, history: allWorkouts)
            let drops = w.roundStats.compactMap(\.stoolDropBPM) + w.autoHRREvents.map(\.dropBPM)
            let reading = sortedReadings.last { $0.date <= w.startDate && w.startDate.timeIntervalSince($0.date) < 14 * 3600 }
            let hardBefore = workouts.contains { other in
                other.id != w.id && other.startDate < w.startDate &&
                w.startDate.timeIntervalSince(other.endDate) < 30 * 3600 &&
                (other.effectiveLoad >= 90 || (other.zoneSeconds[4, default: 0] + other.zoneSeconds[5, default: 0]) >= 600)
            }
            return Point(workout: w, score: review.overall.map(Double.init),
                         recovery: drops.isEmpty ? nil : Double(drops.reduce(0, +)) / Double(drops.count),
                         reading: reading, hardBefore: hardBefore)
        }

        var insights: [DriverInsight] = []

        func compare(_ a: [Point], _ b: [Point], _ metric: (Point) -> Double?) -> (Double, Double)? {
            let va = a.compactMap(metric), vb = b.compactMap(metric)
            guard va.count >= 3, vb.count >= 3, let ma = mean(va), let mb = mean(vb) else { return nil }
            return (ma, mb)
        }

        // Sleep
        let goodSleep = points.filter { ($0.reading?.hasSelfRatings ?? false) && ($0.reading?.sleepQuality ?? 0) >= 4 }
        let poorSleep = points.filter { ($0.reading?.hasSelfRatings ?? false) && ($0.reading?.sleepQuality ?? 5) <= 2 }
        if let (g, p) = compare(goodSleep, poorSleep, { $0.score }), g - p >= 5 {
            insights.append(.init(icon: "bed.double.fill", title: "Sleep is your edge",
                                  detail: "After good nights your sessions score \(Int(g - p)) points higher (\(Int(g)) vs \(Int(p))).",
                                  strength: g - p))
        }

        // HRV vs personal baseline
        let lns = sortedReadings.compactMap(\.lnRMSSD)
        if let baseline = mean(lns), lns.count >= 5 {
            let high = points.filter { ($0.reading?.lnRMSSD ?? -1) >= baseline }
            let low = points.filter { ($0.reading?.lnRMSSD).map { $0 < baseline } ?? false }
            if let (h, l) = compare(high, low, { $0.recovery }), h - l >= 3 {
                insights.append(.init(icon: "waveform.path.ecg", title: "High HRV days = faster recovery",
                                      detail: "When your morning HRV is above normal, you recover \(Int(h - l)) BPM more between rounds.",
                                      strength: (h - l) * 2))
            } else if let (h, l) = compare(high, low, { $0.score }), h - l >= 5 {
                insights.append(.init(icon: "waveform.path.ecg", title: "Trust your HRV",
                                      detail: "Sessions on above-normal HRV days score \(Int(h - l)) points higher.",
                                      strength: h - l))
            }
        }

        // Elevated resting HR
        let rhrs = sortedReadings.map { Double($0.restingHR) }
        if let baseRHR = mean(rhrs), rhrs.count >= 5 {
            let elevated = points.filter { ($0.reading.map { Double($0.restingHR) - baseRHR } ?? -99) >= 5 }
            let normal = points.filter { ($0.reading.map { Double($0.restingHR) - baseRHR } ?? 99) < 3 }
            if let (n, e) = compare(normal, elevated, { $0.score }), n - e >= 5 {
                insights.append(.init(icon: "heart.fill", title: "Watch your morning heart rate",
                                      detail: "When resting HR is 5+ BPM above normal, your sessions score \(Int(n - e)) points lower. Go lighter on those days.",
                                      strength: n - e))
            }
        }

        // Back-to-back hard days
        let afterHard = points.filter(\.hardBefore)
        let fresh = points.filter { !$0.hardBefore }
        if let (f, a) = compare(fresh, afterHard, { $0.recovery }), f - a >= 3 {
            insights.append(.init(icon: "arrow.triangle.2.circlepath", title: "You need a day between hard sessions",
                                  detail: "The day after a hard session, your between-round recovery is \(Int(f - a)) BPM worse.",
                                  strength: (f - a) * 2))
        } else if let (f, a) = compare(fresh, afterHard, { $0.score }), f - a >= 5 {
            insights.append(.init(icon: "arrow.triangle.2.circlepath", title: "Space out hard sessions",
                                  detail: "Sessions within 30 h of a hard one score \(Int(f - a)) points lower.",
                                  strength: f - a))
        }

        // Time of day
        let cal = Calendar.current
        let morning = points.filter { cal.component(.hour, from: $0.workout.startDate) < 12 }
        let evening = points.filter { cal.component(.hour, from: $0.workout.startDate) >= 16 }
        if let (m, e) = compare(morning, evening, { $0.score }), abs(m - e) >= 6 {
            let better = m > e ? "mornings" : "evenings"
            insights.append(.init(icon: m > e ? "sunrise.fill" : "moon.stars.fill", title: "You train best in the \(better)",
                                  detail: "Your \(better) sessions score \(Int(abs(m - e))) points higher on average.",
                                  strength: abs(m - e)))
        }

        return insights.sorted { $0.strength > $1.strength }
    }
}

// MARK: - Camp vs camp

struct CampComparison {
    struct Week: Identifiable {
        let index: Int
        let currentLoad: Double?
        let previousLoad: Double
        let currentWeightKg: Double?
        let previousWeightKg: Double?
        var id: Int { index }
    }
    let weeks: [Week]
    let previousFight: Date
    let summary: String
}

enum CampCompare {
    /// When a fighter sets a new fight date after a fight has passed, keep the
    /// finished camp so the next one can be compared against it.
    static func archiveFinishedCamp(old: AthleteProfile, new: inout AthleteProfile, now: Date = Date()) {
        guard let oldFight = old.fightDate, oldFight < now, new.fightDate != oldFight else { return }
        let record = CampRecord(fightDate: oldFight, campLengthWeeks: old.campLengthWeeks)
        if !new.campHistory.contains(record) {
            new.campHistory.append(record)
            new.campHistory.sort { $0.fightDate < $1.fightDate }
            if new.campHistory.count > 10 { new.campHistory.removeFirst(new.campHistory.count - 10) }
        }
    }

    static func compare(profile: AthleteProfile, workouts: [SavedWorkout], weighIns: [WeighIn], now: Date = Date()) -> CampComparison? {
        guard let previous = profile.campHistory.last,
              let current = CampPlanner.buildPlan(profile: profile, workouts: workouts, now: now) else { return nil }
        var past = profile
        past.fightDate = previous.fightDate
        past.campLengthWeeks = previous.campLengthWeeks
        guard let pastPlan = CampPlanner.buildPlan(profile: past, workouts: workouts, now: previous.fightDate.addingTimeInterval(86400)) else { return nil }

        let mine = weighIns.filter { $0.profileID == profile.id }
        func weight(in start: Date, _ end: Date) -> Double? {
            mean(mine.filter { $0.date >= start && $0.date < end }.map(\.weightKg))
        }

        // Align both camps by weeks-to-fight, so "fight week" lines up with "fight week".
        let n = min(current.weeks.count, pastPlan.weeks.count)
        let curTail = Array(current.weeks.suffix(n))
        let pastTail = Array(pastPlan.weeks.suffix(n))
        var weeks: [CampComparison.Week] = []
        for i in 0..<n {
            let c = curTail[i], p = pastTail[i]
            let started = c.start <= now
            weeks.append(.init(
                index: i + 1,
                currentLoad: started ? c.actualLoad : nil,
                previousLoad: p.actualLoad,
                currentWeightKg: started ? weight(in: c.start, c.end) : nil,
                previousWeightKg: weight(in: p.start, p.end)
            ))
        }

        let done = weeks.filter { $0.currentLoad != nil }
        let curSum = done.compactMap(\.currentLoad).reduce(0, +)
        let pastSum = done.map(\.previousLoad).reduce(0, +)
        var summary = "Your next weeks will be compared to your last camp."
        if !done.isEmpty, pastSum > 0 {
            let pct = Int(((curSum - pastSum) / pastSum * 100).rounded())
            summary = pct >= 0 ? "\(pct)% more training than last camp at this point" : "\(-pct)% less training than last camp at this point"
            if let cw = done.last?.currentWeightKg, let pw = done.last?.previousWeightKg {
                let diff = cw - pw
                summary += String(format: " • %@%.1f kg vs last camp", diff >= 0 ? "+" : "", diff)
            }
        }
        return CampComparison(weeks: weeks, previousFight: previous.fightDate, summary: summary)
    }
}

// MARK: - Records & badges

struct PersonalRecord: Identifiable {
    enum Kind: String, CaseIterable {
        case bestRecovery, mostHardRounds, longestZone2, mostStrikes, biggestSession, mostHeadMovement
    }
    let kind: Kind
    let value: Double
    let workoutID: UUID
    let date: Date
    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .bestRecovery: return "Best recovery"
        case .mostHardRounds: return "Most hard rounds"
        case .longestZone2: return "Longest Zone 2"
        case .mostStrikes: return "Most strikes called"
        case .biggestSession: return "Biggest session load"
        case .mostHeadMovement: return "Most head movement"
        }
    }

    var icon: String {
        switch kind {
        case .bestRecovery: return "arrow.down.heart.fill"
        case .mostHardRounds: return "flame.fill"
        case .longestZone2: return "lungs.fill"
        case .mostStrikes: return "figure.boxing"
        case .biggestSession: return "scalemass.fill"
        case .mostHeadMovement: return "airpodspro"
        }
    }

    var valueText: String {
        switch kind {
        case .bestRecovery: return "−\(Int(value)) BPM in 60 s"
        case .mostHardRounds: return "\(Int(value)) rounds"
        case .longestZone2: return "\(Int(value)) min"
        case .mostStrikes: return "\(Int(value))"
        case .biggestSession: return "\(Int(value)) load"
        case .mostHeadMovement: return String(format: "%.0f moves/min", value)
        }
    }
}

enum Records {
    static func value(_ kind: PersonalRecord.Kind, _ w: SavedWorkout, profile: AthleteProfile) -> Double? {
        switch kind {
        case .bestRecovery:
            let drops = w.roundStats.compactMap(\.stoolDropBPM) + w.autoHRREvents.map(\.dropBPM)
            return drops.max().map(Double.init)
        case .mostHardRounds:
            let n = w.roundStats.filter { $0.peakBPM > profile.activeZones.z4Max }.count
            return n > 0 ? Double(n) : nil
        case .longestZone2:
            let m = w.zoneSeconds[2, default: 0] / 60
            return m >= 5 ? m : nil
        case .mostStrikes:
            return w.strikesCuedCount > 0 ? Double(w.strikesCuedCount) : nil
        case .biggestSession:
            return w.effectiveLoad > 0 ? w.effectiveLoad : nil
        case .mostHeadMovement:
            return w.headMovesPerMinute
        }
    }

    static func all(workouts: [SavedWorkout], profile: AthleteProfile) -> [PersonalRecord] {
        let mine = workouts.filter { $0.profileID == profile.id }
        return PersonalRecord.Kind.allCases.compactMap { kind in
            let best = mine.compactMap { w in value(kind, w, profile: profile).map { (w, $0) } }.max { $0.1 < $1.1 }
            return best.map { PersonalRecord(kind: kind, value: $0.1, workoutID: $0.0.id, date: $0.0.startDate) }
        }
    }

    /// Records this workout set (beating every earlier workout for this fighter).
    static func newRecords(in w: SavedWorkout, workouts: [SavedWorkout], profile: AthleteProfile) -> [PersonalRecord] {
        let earlier = workouts.filter { $0.profileID == w.profileID && $0.startDate < w.startDate }
        guard !earlier.isEmpty else { return [] }
        return PersonalRecord.Kind.allCases.compactMap { kind in
            guard let v = value(kind, w, profile: profile) else { return nil }
            let previousBest = earlier.compactMap { value(kind, $0, profile: profile) }.max() ?? 0
            return v > previousBest ? PersonalRecord(kind: kind, value: v, workoutID: w.id, date: w.startDate) : nil
        }
    }

    static func bestRecovery(workouts: [SavedWorkout], profileID: UUID) -> Int {
        workouts.filter { $0.profileID == profileID }
            .flatMap { $0.roundStats.compactMap(\.stoolDropBPM) + $0.autoHRREvents.map(\.dropBPM) }
            .max() ?? 0
    }
}

struct Badge: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let progress: Double
    var earned: Bool { progress >= 1 }
}

enum Badges {
    static func all(workouts allWorkouts: [SavedWorkout], readings: [ReadinessReading], profile: AthleteProfile) -> [Badge] {
        let w = allWorkouts.filter { $0.profileID == profile.id }
        let rounds = w.reduce(0) { $0 + $1.roundStats.count }
        let strikes = w.reduce(0) { $0 + $1.strikesCuedCount }
        let z2Hours = w.reduce(0.0) { $0 + $1.zoneSeconds[2, default: 0] } / 3600
        let bestRecovery = Double(Records.bestRecovery(workouts: w, profileID: profile.id))
        let plansFinished = w.filter { !$0.blockResults.isEmpty && $0.blockResults.allSatisfy(\.completed) }.count
        let benchmarks = Benchmark.attempts(w).count

        // Best 7-day session count
        let dates = w.map(\.startDate).sorted()
        var bestWeek = 0
        for (i, d) in dates.enumerated() {
            let n = dates[i...].prefix { $0.timeIntervalSince(d) < 7 * 86400 }.count
            bestWeek = max(bestWeek, n)
        }

        func b(_ id: String, _ title: String, _ detail: String, _ icon: String, _ value: Double, _ goal: Double) -> Badge {
            Badge(id: id, title: title, detail: detail, icon: icon, progress: min(1, value / goal))
        }
        return [
            b("first", "First Bell", "Record your first session", "bell.fill", Double(w.count), 1),
            b("ten", "Regular", "10 sessions", "10.circle.fill", Double(w.count), 10),
            b("fifty", "Lifer", "50 sessions", "50.circle.fill", Double(w.count), 50),
            b("rounds100", "Centurion", "100 rounds", "timer", Double(rounds), 100),
            b("strikes1k", "Thousand Strikes", "1,000 strikes called on the bag", "figure.boxing", Double(strikes), 1000),
            b("ironweek", "Iron Week", "5 sessions in 7 days", "calendar.badge.checkmark", Double(bestWeek), 5),
            b("zone2", "Zone 2 Monk", "5 hours in Zone 2", "lungs.fill", z2Hours, 5),
            b("recovery", "Recovery Machine", "Drop 35 BPM in 60 s", "arrow.down.heart.fill", bestRecovery, 35),
            b("morning", "Morning Ritual", "7 readiness checks", "sunrise.fill", Double(readings.count), 7),
            b("plan", "Plan Finisher", "Complete every block of a plan", "list.bullet.rectangle.portrait.fill", Double(plansFinished), 1),
            b("benchmark", "Benchmarked", "Complete a FIGHT Benchmark", "chart.line.uptrend.xyaxis", Double(benchmarks), 1)
        ]
    }
}

// MARK: - Soreness

enum SorenessInsights {
    /// Sore spots logged in the last 3 days (latest entry per region, severity 2+).
    static func active(_ entries: [SorenessEntry], profileID: UUID, now: Date = Date()) -> [SorenessEntry] {
        let recent = entries
            .filter { $0.profileID == profileID && now.timeIntervalSince($0.date) < 3 * 86400 }
            .sorted { $0.date > $1.date }
        var seen = Set<BodyRegion>()
        return recent.filter { seen.insert($0.region).inserted && $0.severity >= 2 }
    }

    private static func isKickingSession(_ w: SavedWorkout) -> Bool {
        if w.comboEvents.contains(where: { $0.strikes.contains { $0.kind == .kick } }) { return true }
        return w.category == .muayThai || w.category == .kickboxing || w.category == .sparring
    }

    static func patterns(_ entries: [SorenessEntry], workouts: [SavedWorkout], profileID: UUID) -> [DriverInsight] {
        let mine = entries.filter { $0.profileID == profileID }
        let ws = workouts.filter { $0.profileID == profileID }
        let typical3Day = ws.isEmpty ? 0 : ws.reduce(0) { $0 + $1.effectiveLoad } / max(1, Double(ws.count)) * 2
        var out: [DriverInsight] = []
        for region in BodyRegion.allCases {
            let logs = mine.filter { $0.region == region }
            guard logs.count >= 2 else { continue }
            var afterKicking = 0, afterSpike = 0
            for log in logs {
                let before = ws.filter { $0.startDate < log.date && log.date.timeIntervalSince($0.startDate) < 72 * 3600 }
                if before.filter(isKickingSession).count >= 2 { afterKicking += 1 }
                if typical3Day > 0 && before.reduce(0, { $0 + $1.effectiveLoad }) > typical3Day * 1.5 { afterSpike += 1 }
            }
            let n = Double(logs.count)
            if region.isKickingArea && Double(afterKicking) / n >= 0.6 {
                out.append(.init(icon: "figure.kickboxing", title: "\(region.rawValue) soreness follows kicking volume",
                                 detail: "\(afterKicking) of \(logs.count) times it came after 2+ kicking sessions in 3 days. Space kicking days out, and condition gradually.",
                                 strength: Double(afterKicking)))
            } else if Double(afterSpike) / n >= 0.6 {
                out.append(.init(icon: "exclamationmark.triangle.fill", title: "\(region.rawValue) soreness follows load spikes",
                                 detail: "\(afterSpike) of \(logs.count) times it followed a 3-day load well above your normal. Build up more gradually.",
                                 strength: Double(afterSpike)))
            } else {
                out.append(.init(icon: "bandage.fill", title: "Recurring \(region.rawValue.lowercased()) soreness",
                                 detail: "Logged \(logs.count) times. If it keeps coming back, get it checked by a physio.",
                                 strength: 0.5))
            }
        }
        return out.sorted { $0.strength > $1.strength }
    }

    static func recommendation(for active: [SorenessEntry]) -> CoachRecommendation? {
        guard let worst = active.max(by: { $0.severity < $1.severity }) else { return nil }
        let advice: String
        if worst.region.isKickingArea {
            advice = "Swap kicking and running for upper-body bag work, technique and mobility until it settles."
        } else if worst.region.isPunchingArea {
            advice = "Rest the hands: do footwork, kicks (if pain-free), cardio and core instead of punching."
        } else {
            advice = "Keep today light and avoid anything that aggravates it."
        }
        return CoachRecommendation(kind: .warning, title: "Protect your \(worst.region.rawValue.lowercased())",
                                   detail: "You logged it as \(worst.severity >= 3 ? "painful" : "sore"). \(advice) See a physio if it's sharp or lasts beyond a week.")
    }
}

// MARK: - Breathing effect

enum BreathingEffect {
    /// Average between-round recovery with stool breathing tones vs without.
    static func compare(_ workouts: [SavedWorkout], profileID: UUID) -> (with: Double, without: Double, sessions: Int)? {
        let mine = workouts.filter { $0.profileID == profileID }
        let with = mine.filter(\.breathingGuided).compactMap(\.avgInterRoundDrop).map(Double.init)
        let without = mine.filter { !$0.breathingGuided }.compactMap(\.avgInterRoundDrop).map(Double.init)
        guard with.count >= 2, without.count >= 3, let a = mean(with), let b = mean(without) else { return nil }
        return (a, b, with.count)
    }

    /// Coherence 0–100 from the swing in beat-to-beat heart rate. Slow, paced
    /// breathing makes heart rate rise and fall with each breath; a bigger, steadier
    /// swing means you're breathing in sync with your heart (more parasympathetic).
    static func coherence(rrMs: [Double]) -> Int? {
        let clean = rrMs.filter { $0 > 300 && $0 < 2000 }
        guard clean.count >= 15 else { return nil }
        let hr = clean.map { 60000 / $0 }.sorted()
        let p10 = hr[Int(Double(hr.count - 1) * 0.1)]
        let p90 = hr[Int(Double(hr.count - 1) * 0.9)]
        let swing = p90 - p10
        return Int(min(100, max(0, (swing - 3) / 12 * 100)).rounded())
    }
}

// MARK: - Automatic rounds

/// Finds rounds from the heart-rate pattern when no round timer was used
/// (sparring, pads, class): sustained work blocks separated by recovery dips.
enum AutoRounds {
    static func detect(samples: [HeartRatePoint], profile: AthleteProfile) -> [RoundStat] {
        let pts = samples.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        guard pts.count >= 360 else { return [] }
        // 1 Hz series, smoothed over 15 s.
        let raw = pts.map { Double($0.bpm) }
        var smooth = [Double](repeating: 0, count: raw.count)
        var run = 0.0
        for i in raw.indices {
            run += raw[i]
            if i >= 15 { run -= raw[i - 15] }
            smooth[i] = run / Double(min(i + 1, 15))
        }
        let sorted = smooth.sorted()
        let p20 = sorted[sorted.count / 5], p90 = sorted[sorted.count * 9 / 10]
        guard p90 - p20 >= 20 else { return [] }   // no clear work/rest rhythm
        let threshold = max(Double(profile.activeZones.z2Max), p20 + (p90 - p20) * 0.55)

        // Work blocks above threshold, bridging dips shorter than 20 s.
        var blocks: [(start: Int, end: Int)] = []
        var start: Int?
        var below = 0
        for i in smooth.indices {
            if smooth[i] >= threshold {
                if start == nil { start = i }
                below = 0
            } else if let s = start {
                below += 1
                if below > 20 {
                    blocks.append((s, i - below))
                    start = nil
                    below = 0
                }
            }
        }
        if let s = start { blocks.append((s, smooth.count - 1 - below)) }
        let rounds = blocks.filter { $0.end - $0.start >= 60 && $0.end - $0.start <= 600 }
        guard rounds.count >= 2 else { return [] }

        return rounds.enumerated().map { n, b in
            let slice = pts[b.start...b.end].map(\.bpm)
            let endBPM = pts[b.end].bpm
            let after = min(pts.count - 1, b.end + 60)
            let nextStart = n + 1 < rounds.count ? rounds[n + 1].start : Int.max
            let drop: Int? = after < nextStart && after - b.end >= 50 ? max(0, endBPM - pts[after].bpm) : nil
            return RoundStat(roundNumber: n + 1, startElapsed: pts[b.start].elapsedSeconds, endElapsed: pts[b.end].elapsedSeconds,
                             avgBPM: slice.reduce(0, +) / slice.count, peakBPM: slice.max() ?? endBPM, stoolDropBPM: drop)
        }
    }
}

// MARK: - Defensive redline (AirPods + heart rate)

struct DefensiveRedline {
    let redlineBPM: Int
    let freshPerMinute: Double
    let tiredPerMinute: Double
    let rounds: Int
    var dropPercent: Int { Int(((1 - tiredPerMinute / max(freshPerMinute, 0.1)) * 100).rounded()) }

    /// The heart rate above which head movement falls to 60% or less of your fresh level.
    static func evaluate(workouts: [SavedWorkout], profileID: UUID, now: Date = Date()) -> DefensiveRedline? {
        let rounds = workouts
            .filter { $0.profileID == profileID && now.timeIntervalSince($0.startDate) < 90 * 86400 }
            .flatMap(\.roundStats)
            .compactMap { r -> (bpm: Int, perMin: Double)? in
                guard let m = r.headMoves, r.endElapsed - r.startElapsed >= 60 else { return nil }
                return (r.avgBPM, Double(m) / (r.endElapsed - r.startElapsed) * 60)
            }
            .sorted { $0.bpm < $1.bpm }
        guard rounds.count >= 6 else { return nil }
        let freshCount = max(2, rounds.count / 3)
        guard let fresh = mean(rounds.prefix(freshCount).map { $0.perMin }), fresh > 1 else { return nil }
        // Walk up through the harder rounds in groups of 3 until movement collapses.
        var i = freshCount
        while i + 2 < rounds.count + 1 {
            let group = Array(rounds[i..<min(rounds.count, i + 3)])
            if let m = mean(group.map { $0.perMin }), m <= fresh * 0.6 {
                return DefensiveRedline(redlineBPM: group[0].bpm, freshPerMinute: fresh, tiredPerMinute: m, rounds: rounds.count)
            }
            i += 1
        }
        return nil
    }

    var headline: String { "Above \(redlineBPM) BPM your head movement drops \(dropPercent)%" }
}

// MARK: - Sparring partners, round results and technique log

enum SparringInsights {
    static func analyze(_ workouts: [SavedWorkout], profileID: UUID) -> [DriverInsight] {
        let mine = workouts.filter { $0.profileID == profileID }
        var out: [DriverInsight] = []

        // Heart-rate cost by partner.
        let byPartner = Dictionary(grouping: mine.filter { ($0.partner ?? "").isEmpty == false }) { $0.partner! }
        let costs = byPartner.compactMap { name, ws -> (String, Double, Int)? in
            let hr = ws.flatMap(\.roundStats).map { Double($0.avgBPM) }
            guard hr.count >= 3, let m = mean(hr) else { return nil }
            return (name, m, ws.count)
        }.sorted { $0.1 > $1.1 }
        if costs.count >= 2, let hardest = costs.first, let easiest = costs.last, hardest.1 - easiest.1 >= 4 {
            out.append(DriverInsight(icon: "person.2.fill", title: "\(hardest.0) pushes you hardest",
                                     detail: "Your rounds with \(hardest.0) average \(Int(hardest.1)) BPM, \(Int(hardest.1 - easiest.1)) more than with \(easiest.0).",
                                     strength: hardest.1 - easiest.1))
        }

        // Rounds you lose: is it the gas tank?
        var won: [Double] = [], lost: [Double] = []
        for w in mine where !w.roundResults.isEmpty {
            for (i, r) in w.roundStats.sorted(by: { $0.roundNumber < $1.roundNumber }).enumerated() where i < w.roundResults.count {
                if w.roundResults[i] == "W" { won.append(Double(r.avgBPM)) }
                if w.roundResults[i] == "L" { lost.append(Double(r.avgBPM)) }
            }
        }
        if won.count >= 3, lost.count >= 3, let mw = mean(won), let ml = mean(lost) {
            if ml - mw >= 4 {
                out.append(DriverInsight(icon: "flame.fill", title: "You lose rounds when you redline",
                                         detail: "Rounds you lost averaged \(Int(ml)) BPM vs \(Int(mw)) in rounds you won. Conditioning will win you rounds.",
                                         strength: ml - mw))
            } else {
                out.append(DriverInsight(icon: "target", title: "Lost rounds aren't about fitness",
                                         detail: "Your heart rate is about the same in rounds you win and lose. Work on the technical gaps instead.",
                                         strength: 2))
            }
        }
        return out
    }

    static let focusOptions = ["Jab", "Cross", "Hooks", "Uppercuts", "Body shots", "Low kicks", "Body kicks",
                               "Head kicks", "Teeps", "Knees", "Elbows", "Clinch", "Defence", "Footwork", "Counters", "Ground"]

    /// The technique you've gone longest without, among those you've worked on before.
    static func neglected(_ workouts: [SavedWorkout], profileID: UUID, now: Date = Date()) -> (tag: String, days: Int)? {
        var last: [String: Date] = [:]
        for w in workouts where w.profileID == profileID {
            for t in w.focusTags where (last[t] ?? .distantPast) < w.startDate { last[t] = w.startDate }
        }
        guard let oldest = last.min(by: { $0.value < $1.value }) else { return nil }
        let days = Int(now.timeIntervalSince(oldest.value) / 86400)
        return days >= 10 ? (oldest.key, days) : nil
    }
}

// MARK: - Sleep, daily insight, debrief

enum SleepScore {
    /// 1–5 sleep rating from hours asleep.
    static func quality(hours: Double) -> Int {
        switch hours {
        case 8...: return 5
        case 7..<8: return 4
        case 6..<7: return 3
        case 5..<6: return 2
        default: return 1
        }
    }
}

enum DailyInsight {
    /// One insight a day, rotating through what's available.
    static func pick(_ candidates: [String], date: Date = Date()) -> String? {
        guard !candidates.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        return candidates[day % candidates.count]
    }
}

enum SessionDebrief {
    /// A short spoken summary for the end of a session.
    static func text(for w: SavedWorkout, history: [SavedWorkout], profile: AthleteProfile) -> String {
        var parts: [String] = ["Session saved. \(Int(w.duration / 60)) minutes."]
        let rounds = w.roundStats.sorted { $0.roundNumber < $1.roundNumber }
        if rounds.count >= 2, let hardest = rounds.max(by: { $0.avgBPM < $1.avgBPM }) {
            parts.append("Round \(hardest.roundNumber) was your hardest, at \(hardest.avgBPM) beats.")
        }
        if let rec = Records.newRecords(in: w, workouts: history, profile: profile).first {
            parts.append("New record: \(rec.title.lowercased()).")
        } else if let best = rounds.compactMap(\.stoolDropBPM).max() {
            let monthBest = history.filter { $0.profileID == w.profileID && $0.id != w.id && w.startDate.timeIntervalSince($0.startDate) < 30 * 86400 && w.startDate > $0.startDate }
                .flatMap(\.roundStats).compactMap(\.stoolDropBPM).max() ?? 0
            if best > monthBest && monthBest > 0 { parts.append("Best recovery this month: \(best) beats.") }
        }
        let typical = mean(history.filter { $0.profileID == w.profileID && $0.id != w.id }.suffix(20).map(\.effectiveLoad)) ?? w.effectiveLoad
        if w.effectiveLoad > typical * 1.3 {
            parts.append("Big session. Go easy or rest tomorrow.")
        } else if w.effectiveLoad < typical * 0.6 {
            parts.append("Light day. You're fresh for a hard one tomorrow.")
        }
        return parts.joined(separator: " ")
    }
}
