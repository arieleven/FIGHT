import XCTest

/// Deterministic pseudo-random numbers so tests never flake.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func gaussian() -> Double {
        let u1 = max(next(), 1e-12), u2 = next()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

private func makeWorkout(
    profile: AthleteProfile,
    daysAgo: Double,
    duration: TimeInterval = 3600,
    trimp: Double = 100,
    zones: [Int: TimeInterval] = [1: 600, 2: 1800, 3: 600, 4: 400, 5: 200],
    drill: DrillTag = .technical,
    category: WorkoutCategory = .kickboxing,
    rounds: [RoundStat] = [],
    maxBPM: Int = 180,
    rpe: Int = 5,
    rated: Bool = false
) -> SavedWorkout {
    let start = Date().addingTimeInterval(-daysAgo * 86400)
    return SavedWorkout(
        id: UUID(), profileID: profile.id, profileName: profile.name, category: category, drillTag: drill,
        rpe: rpe, notes: "", startDate: start, endDate: start.addingTimeInterval(duration), duration: duration,
        averageBPM: 150, maxBPM: maxBPM, minBPM: 90, activeCalories: 500, bmrCalories: 80, calories: 580,
        epocBonusCalories: 20, trimpScore: trimp, cardiacDriftPercent: 4, hrr60Drop: 25, autoHRREvents: [],
        rmssdMs: nil, strikesCuedCount: 0, ghostBaselineName: nil, ghostAvgDeltaBPM: nil, zoneSeconds: zones,
        roundStats: rounds, pointsOfInterest: [], samples: [], isCompressedArchive: false, archiveFileName: nil,
        rpeRated: rated
    )
}

final class HRVMathTests: XCTestCase {

    func testCleanRRRejectsOutliersAndOutOfRange() {
        let rr: [Double] = [800, 810, 805, 2500, 795, 400, 800, 812, 798, 805]
        let q = HRVMath.cleanRR(rr)
        XCTAssertFalse(q.cleanRR.contains(2500))
        XCTAssertFalse(q.cleanRR.contains(400), "a 50% short beat is an artifact")
        XCTAssertEqual(q.artifactRate, 0.2, accuracy: 0.001)
    }

    func testRMSSDKnownValue() {
        // Alternating ±10 ms → successive differences of 20 ms → RMSSD 20.
        let rr = (0..<40).map { $0 % 2 == 0 ? 800.0 : 820.0 }
        XCTAssertEqual(HRVMath.rmssd(rr) ?? 0, 20, accuracy: 0.001)
    }

    func testLinearRegressionExactLine() throws {
        let x: [Double] = [0, 1, 2, 3, 4]
        let y = x.map { 3 * $0 + 2 }
        let fit = try XCTUnwrap(HRVMath.linearRegression(x, y))
        XCTAssertEqual(fit.slope, 3, accuracy: 1e-9)
        XCTAssertEqual(fit.intercept, 2, accuracy: 1e-9)
        XCTAssertEqual(fit.r2, 1, accuracy: 1e-9)
    }

    func testDFAAlpha1SeparatesWhiteNoiseFromCorrelatedSignal() throws {
        var rng = SeededRandom(seed: 42)
        let white = (0..<600).map { _ in 800 + 20 * rng.gaussian() }
        var walk: [Double] = []
        var v = 800.0
        for _ in 0..<600 {
            v += 4 * rng.gaussian()
            walk.append(v)
        }
        let aWhite = try XCTUnwrap(HRVMath.dfaAlpha1(white))
        let aWalk = try XCTUnwrap(HRVMath.dfaAlpha1(walk))
        XCTAssertEqual(aWhite, 0.5, accuracy: 0.2, "uncorrelated beats → α1 ≈ 0.5")
        XCTAssertGreaterThan(aWalk, 1.2, "strongly correlated beats → α1 well above 1")
    }

    func testMaxSurge() {
        let samples = (0..<40).map { i in
            HeartRatePoint(elapsedSeconds: TimeInterval(i), bpm: i < 20 ? 120 : 150)
        }
        XCTAssertEqual(HRVMath.maxSurge(samples: samples), 30)
    }
}

final class CoachEngineTests: XCTestCase {

    func testScaleAndBlend() {
        XCTAssertEqual(CoachEngine.scale(5, worst: 0, best: 10), 50)
        XCTAssertEqual(CoachEngine.scale(-5, worst: 0, best: 10), 0)
        XCTAssertEqual(CoachEngine.scale(3, worst: 12, best: 3), 100, "works when lower is better")
        XCTAssertEqual(CoachEngine.blend([(80, 1), (nil, 5), (40, 1)]), 60, "missing components are skipped")
        XCTAssertNil(CoachEngine.blend([(nil, 1)]))
    }

    func testTrainingLoadConvergesToSteadyDailyLoad() throws {
        let profile = AthleteProfile()
        let workouts = (1...200).map { makeWorkout(profile: profile, daysAgo: Double($0), trimp: 100) }
        let last = try XCTUnwrap(CoachEngine.trainingLoad(workouts: workouts).last)
        XCTAssertGreaterThan(last.fitness, 90)
        XCTAssertEqual(last.fatigue, 100, accuracy: 20)
    }

    func testRoundCreep() throws {
        let rounds = (1...6).map { r in
            RoundStat(roundNumber: r, startElapsed: 0, endElapsed: 0, avgBPM: r <= 2 ? 150 : (r >= 5 ? 165 : 158), peakBPM: 175, stoolDropBPM: 25)
        }
        XCTAssertEqual(try XCTUnwrap(CoachEngine.roundCreepPercent(rounds)), 10, accuracy: 0.01)
        XCTAssertNil(CoachEngine.roundCreepPercent(Array(rounds.prefix(3))), "needs 4+ rounds")
    }

    func testReviewRewardsTrueZone2Session() throws {
        let profile = AthleteProfile()
        let w = makeWorkout(profile: profile, daysAgo: 0, zones: [1: 600, 2: 3000], drill: .aerobicZ2, category: .roadwork)
        let review = CoachEngine.review(workout: w, profile: profile, history: [])
        let intent = try XCTUnwrap(review.items.first { $0.title == "Intent Match" })
        XCTAssertEqual(intent.score, 100)
    }

    func testEffectiveLoadBlendsSessionRPEOnlyWhenRated() {
        let profile = AthleteProfile()
        let unrated = makeWorkout(profile: profile, daysAgo: 0, duration: 3600, trimp: 80, rpe: 8, rated: false)
        let rated = makeWorkout(profile: profile, daysAgo: 0, duration: 3600, trimp: 80, rpe: 8, rated: true)
        XCTAssertEqual(unrated.effectiveLoad, 80)
        // sRPE = 8 × 60 min × 0.25 = 120 → blended (80 + 120) / 2 = 100
        XCTAssertEqual(rated.effectiveLoad, 100, accuracy: 0.001)
    }

    func testRecommendsUpdatingMaxHRWhenExceeded() {
        let profile = AthleteProfile()
        let workouts = (0..<4).map { makeWorkout(profile: profile, daysAgo: Double($0 * 2), maxBPM: profile.effectiveMaxHR + 8) }
        let report = CoachEngine.buildReport(workouts: workouts, readings: [], profile: profile, resolveSamples: { _ in [] })
        XCTAssertTrue(report.recommendations.contains { $0.title.contains("New max HR") })
    }
}

final class CampPlannerTests: XCTestCase {

    func testEightWeekCampStructure() throws {
        var profile = AthleteProfile()
        profile.campLengthWeeks = 8
        profile.fightDate = Date().addingTimeInterval(56 * 86400)
        let plan = try XCTUnwrap(CampPlanner.buildPlan(profile: profile, workouts: []))
        XCTAssertEqual(plan.weeks.count, 8)
        XCTAssertEqual(plan.weeks.last?.phase, .taper)
        XCTAssertTrue(plan.weeks.last?.isFightWeek ?? false)
        XCTAssertEqual(plan.weeks.filter { $0.phase == .peak }.count, 2)
        let peakLoad = try XCTUnwrap(plan.weeks.first { $0.phase == .peak }?.targetLoad)
        XCTAssertLessThan(try XCTUnwrap(plan.weeks.last?.targetLoad), peakLoad * 0.5)
        XCTAssertTrue(plan.weeks.contains { $0.isDeload }, "week 4 is a deload")
    }

    func testRapidWeightDropIsFlaggedAsDehydration() {
        let profile = AthleteProfile()
        let now = Date()
        let weighIns = [
            WeighIn(profileID: profile.id, date: now.addingTimeInterval(-24 * 3600), weightKg: 80),
            WeighIn(profileID: profile.id, date: now, weightKg: 78)
        ]
        let status = CampPlanner.weightStatus(weighIns: weighIns, readings: [], profile: profile, now: now)
        XCTAssertTrue(status.warnings.contains { $0.severity == .danger && $0.title.contains("Rapid drop") })
    }

    func testWeightUnitsRoundTrip() {
        XCTAssertEqual(WeightUnits.toKg(WeightUnits.value(84, true), true), 84, accuracy: 1e-9)
        XCTAssertEqual(WeightUnits.text(100, true), "220.5 lb")
    }
}

final class ComboGeneratorTests: XCTestCase {

    func testRespectsDisabledStrikeTypes() {
        var prefs = BagPreferences()
        prefs.includeKicks = false
        prefs.includeKneesElbows = false
        prefs.includeDefense = false
        var gen = ComboGenerator(prefs: prefs)
        for _ in 0..<200 {
            XCTAssertTrue(gen.next().allSatisfy { $0.kind == .punch })
        }
    }

    func testComboLengthFollowsDifficultyAndBurnoutCap() {
        var prefs = BagPreferences()
        prefs.difficulty = .pro
        prefs.tempo = .burnout
        prefs.dutchFinish = false
        var gen = ComboGenerator(prefs: prefs)
        for _ in 0..<200 {
            XCTAssertTrue((3...3).contains(gen.next().count), "pro + burnout → exactly 3 strikes")
        }
    }

    func testNoImmediateRepeats() {
        var gen = ComboGenerator(prefs: BagPreferences())
        var previous: [Strike] = []
        for _ in 0..<200 {
            let combo = gen.next()
            XCTAssertNotEqual(combo, previous)
            previous = combo
        }
    }

    func testCustomOnlyUsesSavedCombos() {
        var prefs = BagPreferences()
        prefs.customCombos = [[.jab, .cross, .rearLowKick], [.leadTeep]]
        prefs.customOnly = true
        var gen = ComboGenerator(prefs: prefs)
        for _ in 0..<50 {
            XCTAssertTrue(prefs.customCombos.contains(gen.next()))
        }
    }

    func testStanceAndNumberCallouts() {
        XCTAssertEqual(Strike.leadHook.callout(stance: .orthodox, numbers: false), "Left hook!")
        XCTAssertEqual(Strike.leadHook.callout(stance: .southpaw, numbers: false), "Right hook!")
        XCTAssertEqual(Strike.cross.callout(stance: .orthodox, numbers: true), "Two!")
        XCTAssertEqual(Strike.rearLowKick.callout(stance: .orthodox, numbers: false), "Right low kick!")
    }

    func testPreferencesDecodeFromOlderData() throws {
        let json = #"{"tempo":"Burnout (2.5–4.5s)","stance":"Southpaw"}"#.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(BagPreferences.self, from: json)
        XCTAssertEqual(prefs.tempo, .burnout)
        XCTAssertEqual(prefs.stance, .southpaw)
        XCTAssertEqual(prefs.difficulty, .intermediate, "missing keys fall back to defaults")
    }
}

final class GhostTests: XCTestCase {
    func testInterpolationUsesBinarySearchCorrectly() {
        let samples = (0...100).map { i in HeartRatePoint(elapsedSeconds: TimeInterval(i * 10), bpm: 100 + i) }
        let ghost = GhostSession(id: UUID(), title: "g", subtitle: "", samples: samples, roundStats: [], avgBPM: 150, peakBPM: 200)
        XCTAssertEqual(ghost.interpolatedBPM(at: 0), 100)
        XCTAssertEqual(ghost.interpolatedBPM(at: 55), 106, "105.5 rounds half away from zero")
        XCTAssertEqual(ghost.interpolatedBPM(at: 500), 150)
        XCTAssertNil(ghost.interpolatedBPM(at: 5000), "past the end of the ghost")
    }
}
