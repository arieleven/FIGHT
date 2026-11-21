import Foundation

/// A sample fighter with three realistic sessions, so every coach feature has data to show.
/// Lives in its own profile; deleting that profile removes all of it.
enum SampleData {
    static let profileName = "Sample Fighter"

    struct Bundle {
        let profile: AthleteProfile
        let workouts: [SavedWorkout]
        let readings: [ReadinessReading]
        let weighIns: [WeighIn]
    }

    private struct RNG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func noise(_ amp: Double) -> Double { (next() * 2 - 1) * amp }
    }

    static func make(now: Date = Date()) -> Bundle {
        var p = AthleteProfile()
        p.name = profileName
        p.age = 26
        p.sex = .male
        p.weightKg = 72.4
        p.heightCm = 178
        p.targetFightWeightKg = 70.0
        p.restingHR = 52
        p.campPhase = .fightCamp
        p.campLengthWeeks = 8
        p.bio.nickname = "The Engine"
        p.bio.wins = 7
        p.bio.losses = 2
        p.bio.finishes = 4
        p.bio.discipline = "Muay Thai"
        p.bio.reachCm = 183
        let cal = Calendar.current
        p.fightDate = cal.date(bySettingHour: 20, minute: 0, second: 0, of: now.addingTimeInterval(33 * 86400))
        p.sanitize()

        var rng = RNG(state: 0xF16A7)
        let workouts = [
            benchmarkSession(p, start: day(now, -6, hour: 18, minute: 30), rng: &rng),
            sparringSession(p, start: day(now, -3, hour: 19, minute: 0), rng: &rng),
            roadwork(p, start: day(now, -1, hour: 7, minute: 15), rng: &rng)
        ]
        return Bundle(profile: p, workouts: workouts, readings: readings(p, now: now, rng: &rng),
                      weighIns: weighIns(p, now: now, rng: &rng))
    }

    private static func day(_ now: Date, _ offset: Int, hour: Int, minute: Int) -> Date {
        let d = now.addingTimeInterval(Double(offset) * 86400)
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: d) ?? d
    }

    // MARK: Heart-rate simulator

    /// Moves heart rate toward a target, faster going up than coming down, like a real heart.
    private struct Heart {
        var bpm: Double
        mutating func step(toward target: Double, riseTau: Double = 22, fallTau: Double) {
            let tau = target > bpm ? riseTau : fallTau
            bpm += (target - bpm) / tau
        }
    }

    private struct Recorder {
        let start: Date
        var samples: [HeartRatePoint] = []
        var t: TimeInterval = 0
        var withRR = false
        mutating func record(_ bpm: Double, rng: inout RNG) {
            let b = Int((bpm + rng.noise(1.5)).rounded())
            var rr: [Double] = []
            if withRR {
                let base = 60000 / Double(b)
                rr = [base + rng.noise(base * 0.03)]
            }
            samples.append(HeartRatePoint(timestamp: start.addingTimeInterval(t), elapsedSeconds: t, bpm: b, rrIntervalsMs: rr))
            t += 1
        }
    }

    private static func roundsWork(heart: inout Heart, rec: inout Recorder, rng: inout RNG, profile: AthleteProfile,
                                   rounds: Int, firstTarget: Double, creep: Double, cap: Double, restFallTaus: [Double],
                                   combos: [[Strike]]?, comboEvents: inout [ComboEvent], headMoves: [Int]?) -> [RoundStat] {
        var stats: [RoundStat] = []
        var comboIndex = 0
        for r in 0..<rounds {
            let startT = rec.t
            var bump = 0.0
            var nextCombo = startT + 4
            var strikes = 0
            var roundBPMs: [Int] = []
            let target = min(cap, firstTarget + creep * Double(r))
            for _ in 0..<180 {
                if let combos, rec.t >= nextCombo {
                    let c = combos[comboIndex % combos.count]
                    comboIndex += 1
                    comboEvents.append(ComboEvent(t: rec.t, strikes: c))
                    strikes += c.count
                    let kicks = c.contains { $0.kind == .kick || $0.kind == .knee }
                    bump = kicks ? 9 : 3
                    nextCombo = rec.t + 5 + rng.next() * 3
                }
                bump *= 0.9
                heart.step(toward: target + bump + rng.noise(2), riseTau: 18, fallTau: 25)
                rec.record(heart.bpm, rng: &rng)
                roundBPMs.append(rec.samples.last?.bpm ?? 0)
            }
            let endT = rec.t
            let bell = rec.samples.last?.bpm ?? Int(heart.bpm)
            let fall = restFallTaus[min(r, restFallTaus.count - 1)]
            for _ in 0..<60 {
                heart.step(toward: Double(profile.restingHR) + 50, fallTau: fall)
                rec.record(heart.bpm, rng: &rng)
            }
            let after = rec.samples.last?.bpm ?? bell
            stats.append(RoundStat(roundNumber: r + 1, startElapsed: startT, endElapsed: endT,
                                   avgBPM: roundBPMs.reduce(0, +) / max(1, roundBPMs.count),
                                   peakBPM: roundBPMs.max() ?? bell, stoolDropBPM: bell - after,
                                   strikesCued: strikes, headMoves: headMoves.map { $0[min(r, $0.count - 1)] }))
        }
        return stats
    }

    private static func steady(_ seconds: Int, target: Double, heart: inout Heart, rec: inout Recorder, rng: inout RNG,
                               drift: Double = 0, fallTau: Double = 30) {
        for i in 0..<seconds {
            heart.step(toward: target + drift * Double(i) / Double(max(1, seconds)) + rng.noise(2.5), fallTau: fallTau)
            rec.record(heart.bpm, rng: &rng)
        }
    }

    private static func finish(_ rec: Recorder, profile: AthleteProfile, category: WorkoutCategory, drill: DrillTag,
                               notes: String, rounds: [RoundStat], combos: [ComboEvent], planID: UUID?, planTitle: String?,
                               headMovesPerMinute: Double?, rpe: Int) -> SavedWorkout {
        var zones: [Int: TimeInterval] = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
        var active = 0.0
        for s in rec.samples {
            zones[profile.zone(for: s.bpm).number, default: 0] += 1
            // Keytel et al. (2005), male: kcal per minute from heart rate.
            let kcalMin = (-55.0969 + 0.6309 * Double(s.bpm) + 0.1988 * profile.weightKg + 0.2017 * Double(profile.age)) / 4.184
            active += max(0, kcalMin) / 60
        }
        let draft = WorkoutDraft(
            id: UUID(), profileID: profile.id, startTime: rec.start, lastUpdate: rec.start.addingTimeInterval(rec.t),
            elapsedSeconds: rec.t, category: category, drillTag: drill, notes: notes, samples: rec.samples,
            zoneSeconds: zones, activeCalories: active, bmrCalories: rec.t / 86400 * 1700, rounds: rounds,
            autoHRREvents: [], strikesCued: combos.reduce(0) { $0 + $1.strikes.count }, ghostTitle: nil,
            planTitle: nil, planTargetLow: nil, planTargetHigh: nil, trainingPlanID: planID, trainingPlanTitle: planTitle,
            blockResults: nil, comboEvents: combos, headMovesPerMinute: headMovesPerMinute, breathingGuided: false
        )
        var w = WorkoutFinalizer.makeWorkout(from: draft, profile: profile, ghost: nil, end: rec.start.addingTimeInterval(rec.t))
        w.rpe = rpe
        w.rpeRated = true
        return w
    }

    // MARK: Sessions

    /// FIGHT Benchmark on the bag: rope, 5 × 3 min at fight pace with called combos, cool-down.
    private static func benchmarkSession(_ p: AthleteProfile, start: Date, rng: inout RNG) -> SavedWorkout {
        var heart = Heart(bpm: 82)
        var rec = Recorder(start: start)
        var events: [ComboEvent] = []
        steady(300, target: 142, heart: &heart, rec: &rec, rng: &rng)
        steady(90, target: 118, heart: &heart, rec: &rec, rng: &rng)
        let combos = PlanTemplates.benchmark.blocks.first { $0.kind == .bagRounds }?.combos ?? [[.jab, .cross]]
        let rounds = roundsWork(heart: &heart, rec: &rec, rng: &rng, profile: p, rounds: 5, firstTarget: 164, creep: 4,
                                cap: 186, restFallTaus: [90, 105, 125, 150, 175], combos: combos, comboEvents: &events,
                                headMoves: nil)
        steady(180, target: 105, heart: &heart, rec: &rec, rng: &rng, fallTau: 20)
        return finish(rec, profile: p, category: .heavyBag, drill: .bagWork,
                      notes: "First benchmark. Legs heavy in round 4.", rounds: rounds, combos: events,
                      planID: PlanTemplates.benchmarkID, planTitle: "FIGHT Benchmark", headMovesPerMinute: nil, rpe: 7)
    }

    /// Hard sparring: warm-up, 5 × 3 min rounds that climb toward max, cool-down.
    private static func sparringSession(_ p: AthleteProfile, start: Date, rng: inout RNG) -> SavedWorkout {
        var heart = Heart(bpm: 85)
        var rec = Recorder(start: start)
        var events: [ComboEvent] = []
        steady(480, target: 132, heart: &heart, rec: &rec, rng: &rng)
        steady(120, target: 115, heart: &heart, rec: &rec, rng: &rng)
        let moves = [41, 37, 32, 26, 22]
        let rounds = roundsWork(heart: &heart, rec: &rec, rng: &rng, profile: p, rounds: 5, firstTarget: 171, creep: 4.5,
                                cap: 188, restFallTaus: [100, 120, 145, 170, 200], combos: nil, comboEvents: &events,
                                headMoves: moves)
        steady(300, target: 102, heart: &heart, rec: &rec, rng: &rng, fallTau: 22)
        return finish(rec, profile: p, category: .sparring, drill: .hardSparring,
                      notes: "Hard rounds with Dani. Gassed in the 5th, stopped moving my head.", rounds: rounds,
                      combos: events, planID: nil, planTitle: nil,
                      headMovesPerMinute: Double(moves.reduce(0, +)) / 15, rpe: 8)
    }

    /// Easy Zone 2 roadwork with slight cardiac drift.
    private static func roadwork(_ p: AthleteProfile, start: Date, rng: inout RNG) -> SavedWorkout {
        var heart = Heart(bpm: 78)
        var rec = Recorder(start: start)
        rec.withRR = true
        steady(300, target: 128, heart: &heart, rec: &rec, rng: &rng)
        steady(1800, target: 141, heart: &heart, rec: &rec, rng: &rng, drift: 6)
        steady(300, target: 112, heart: &heart, rec: &rec, rng: &rng, fallTau: 25)
        return finish(rec, profile: p, category: .roadwork, drill: .aerobicZ2,
                      notes: "Easy 40 min, nasal breathing.", rounds: [], combos: [], planID: nil, planTitle: nil,
                      headMovesPerMinute: nil, rpe: 4)
    }

    // MARK: Mornings and weight

    private static func readings(_ p: AthleteProfile, now: Date, rng: inout RNG) -> [ReadinessReading] {
        // days ago: (resting HR, RMSSD ms, sleep 1–5, soreness 1–5)
        let days: [(Int, Int, Double, Int, Int)] = [
            (7, 53, 78, 4, 2), (6, 52, 82, 4, 2), (5, 55, 66, 3, 3), (4, 53, 74, 4, 2),
            (2, 57, 58, 3, 4), (1, 53, 76, 4, 2), (0, 51, 86, 5, 2)
        ]
        return days.map { d in
            var r = ReadinessReading(date: day(now, -d.0, hour: 7, minute: 5), durationSeconds: 120, restingHR: d.1,
                                     rmssd: d.2 + rng.noise(2), artifactRate: 0.01, sleepQuality: d.3, soreness: d.4)
            r.profileID = p.id
            return r
        }
    }

    private static func weighIns(_ p: AthleteProfile, now: Date, rng: inout RNG) -> [WeighIn] {
        (0..<14).map { i in
            let daysAgo = 13 - i
            let kg = 74.4 - 0.15 * Double(i) + rng.noise(0.2)
            return WeighIn(profileID: p.id, date: day(now, -daysAgo, hour: 7, minute: 0),
                           weightKg: (kg * 10).rounded() / 10, urineColor: i % 3 == 0 ? 3 : nil)
        }
    }
}
