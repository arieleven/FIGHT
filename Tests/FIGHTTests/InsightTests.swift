import XCTest

private func workout(_ profile: AthleteProfile, daysAgo: Double, hour: Int? = nil, load: Double = 80,
                     rounds: [RoundStat] = [], samples: [HeartRatePoint] = [], combos: [ComboEvent] = [],
                     category: WorkoutCategory = .kickboxing, planID: UUID? = nil, breathing: Bool = false) -> SavedWorkout {
    var start = Date().addingTimeInterval(-daysAgo * 86400)
    if let hour {
        start = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: start) ?? start
    }
    let duration: TimeInterval = 3000
    return SavedWorkout(
        id: UUID(), profileID: profile.id, profileName: profile.name, category: category, drillTag: .technical,
        rpe: 6, notes: "", startDate: start, endDate: start.addingTimeInterval(duration), duration: duration,
        averageBPM: 150, maxBPM: 185, minBPM: 90, activeCalories: 500, bmrCalories: 80, calories: 580,
        epocBonusCalories: 20, trimpScore: load, cardiacDriftPercent: 4, hrr60Drop: 25, autoHRREvents: [],
        rmssdMs: nil, strikesCuedCount: combos.reduce(0) { $0 + $1.strikes.count }, ghostBaselineName: nil,
        ghostAvgDeltaBPM: nil, zoneSeconds: [1: 600, 2: 1200, 3: 600, 4: 400, 5: 200],
        roundStats: rounds, pointsOfInterest: [], samples: samples, isCompressedArchive: false, archiveFileName: nil,
        trainingPlanID: planID, comboEvents: combos, breathingGuided: breathing
    )
}

/// Rounds of 3 min with 1 min rest; HR starts at `first` and climbs `creep` per round.
private func rounds(_ n: Int, first: Int, creep: Int, drops: [Int]? = nil) -> [RoundStat] {
    (0..<n).map { i in
        RoundStat(roundNumber: i + 1, startElapsed: Double(i) * 240, endElapsed: Double(i) * 240 + 180,
                  avgBPM: first + creep * i, peakBPM: first + creep * i + 8,
                  stoolDropBPM: drops.map { $0[min(i, $0.count - 1)] } ?? 30)
    }
}

private func fighter() -> AthleteProfile {
    var p = AthleteProfile()
    p.name = "Test"
    p.age = 25
    p.restingHR = 55
    p.useAutoMaxHR = false
    p.maxHR = 195
    p.zoneMethod = .percentMaxHR
    return p
}

final class GasTankTests: XCTestCase {

    func testFlatHeartRateIsReadyForEveryFormat() throws {
        var p = fighter()
        p.formatRounds = 5
        let ws = (0..<3).map { workout(p, daysAgo: Double($0 * 3 + 1), rounds: rounds(5, first: 160, creep: 1)) }
        let r = try XCTUnwrap(GasTank.evaluate(workouts: ws, profile: p))
        XCTAssertTrue(r.formats.allSatisfy(\.isReady), "\(r.formats.map(\.percent))")
        XCTAssertEqual(r.headline, "Ready for 5×3")
    }

    func testSteepCreepFindsTheRedlineRound() throws {
        let p = fighter()
        let ws = (0..<3).map { workout(p, daysAgo: Double($0 * 3 + 1), rounds: rounds(4, first: 165, creep: 8)) }
        let r = try XCTUnwrap(GasTank.evaluate(workouts: ws, profile: p))
        let fiveByThree = try XCTUnwrap(r.formats.first { $0.format.rounds == 5 })
        XCTAssertFalse(fiveByThree.isReady)
        XCTAssertNotNil(fiveByThree.limitRound)
        XCTAssertLessThanOrEqual(fiveByThree.limitRound ?? 99, 4)
        XCTAssertGreaterThanOrEqual(r.formats[0].percent, fiveByThree.percent, "shorter fights are easier")
    }

    func testCollapsingRecoveryLimitsTheTank() throws {
        let p = fighter()
        let ws = (0..<3).map { workout(p, daysAgo: Double($0 * 3 + 1), rounds: rounds(4, first: 150, creep: 1, drops: [30, 22, 15, 8])) }
        let r = try XCTUnwrap(GasTank.evaluate(workouts: ws, profile: p))
        XCTAssertFalse(r.formats.first { $0.format.rounds == 5 }?.isReady ?? true)
    }

    func testNeedsRoundData() {
        let p = fighter()
        XCTAssertNil(GasTank.evaluate(workouts: [workout(p, daysAgo: 1)], profile: p))
    }
}

final class ComboCostTests: XCTestCase {

    func testKicksCostMoreThanPunches() throws {
        let p = fighter()
        var samples: [HeartRatePoint] = []
        var events: [ComboEvent] = []
        var bpm = 140
        // 40 combos, 15 s apart. Kick combos raise HR by 9, punch combos by 3, then it settles back.
        for i in 0..<40 {
            let t = Double(i) * 15
            let kick = i % 2 == 0
            events.append(ComboEvent(t: t, strikes: kick ? [.jab, .rearMidKick] : [.jab, .cross]))
            for s in 0..<15 {
                let rise = kick ? 9 : 3
                bpm = 140 + (s >= 2 && s <= 10 ? rise * min(s - 1, 3) / 3 : 0)
                samples.append(HeartRatePoint(elapsedSeconds: t + Double(s), bpm: bpm))
            }
        }
        let w = workout(p, daysAgo: 1, samples: samples, combos: events)
        let r = try XCTUnwrap(ComboCost.analyze(workouts: [w], stance: .orthodox, resolveSamples: { $0.samples }))
        let ratio = try XCTUnwrap(r.kickToPunchRatio)
        XCTAssertGreaterThan(ratio, 2)
        XCTAssertEqual(r.byType.first?.label, "With kicks")
        XCTAssertEqual(r.combosAnalysed, 40)
    }

    func testTooFewCombosGivesNothing() {
        let p = fighter()
        let w = workout(p, daysAgo: 1, combos: [ComboEvent(t: 1, strikes: [.jab])])
        XCTAssertNil(ComboCost.analyze(workouts: [w], stance: .orthodox, resolveSamples: { $0.samples }))
    }
}

final class BenchmarkTests: XCTestCase {

    func testTemplatesHaveStableIDs() {
        XCTAssertEqual(PlanTemplates.benchmark.id, PlanTemplates.benchmarkID)
        XCTAssertEqual(PlanTemplates.fightPace.id, PlanTemplates.fightPace.id, "same id on every access")
        XCTAssertEqual(PlanTemplates.fightPace.blocks.map(\.id), PlanTemplates.fightPace.blocks.map(\.id))
        XCTAssertEqual(Set(PlanTemplates.all.map(\.id)).count, PlanTemplates.all.count, "ids are unique")
    }

    func testProgressAcrossAttempts() throws {
        let p = fighter()
        let first = workout(p, daysAgo: 40, rounds: rounds(5, first: 170, creep: 3, drops: [25]), planID: PlanTemplates.benchmarkID)
        let latest = workout(p, daysAgo: 5, rounds: rounds(5, first: 160, creep: 3, drops: [33]), planID: PlanTemplates.benchmarkID)
        let other = workout(p, daysAgo: 3, rounds: rounds(5, first: 150, creep: 3))
        let attempts = Benchmark.attempts([latest, other, first])
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first?.id, first.id, "oldest first")
        let summary = try XCTUnwrap(Benchmark.progressSummary(attempts))
        XCTAssertTrue(summary.contains("10 BPM lower"), summary)
        XCTAssertTrue(summary.contains("+8"), summary)
        XCTAssertFalse(Benchmark.isDue([latest, first]))
        XCTAssertTrue(Benchmark.isDue([first]))
    }

    func testFightNightWarmUpEndsSettled() {
        let plan = PlanTemplates.fightNightWarmUp
        XCTAssertEqual(plan.blocks.last?.kind, .rest)
        XCTAssertTrue((20 * 60...35 * 60).contains(plan.plannedSeconds), "\(plan.plannedSeconds)")
    }
}

final class RecordsAndBadgesTests: XCTestCase {

    func testNewRecordOnlyWhenBeatingEarlierSessions() {
        let p = fighter()
        let old = workout(p, daysAgo: 10, rounds: rounds(3, first: 150, creep: 2, drops: [28]))
        let better = workout(p, daysAgo: 1, rounds: rounds(3, first: 150, creep: 2, drops: [35]))
        let worse = workout(p, daysAgo: 0.5, rounds: rounds(3, first: 150, creep: 2, drops: [20]))
        let all = [old, better, worse]
        XCTAssertTrue(Records.newRecords(in: better, workouts: all, profile: p).contains { $0.kind == .bestRecovery })
        XCTAssertFalse(Records.newRecords(in: worse, workouts: all, profile: p).contains { $0.kind == .bestRecovery })
        XCTAssertTrue(Records.newRecords(in: old, workouts: all, profile: p).isEmpty, "the first session sets no records")
        XCTAssertEqual(Records.bestRecovery(workouts: all, profileID: p.id), 35)
    }

    func testBadgeProgress() {
        let p = fighter()
        let ws = (0..<5).map { workout(p, daysAgo: Double($0), rounds: rounds(3, first: 150, creep: 2)) }
        let badges = Badges.all(workouts: ws, readings: [], profile: p)
        XCTAssertTrue(badges.first { $0.id == "first" }?.earned ?? false)
        XCTAssertTrue(badges.first { $0.id == "ironweek" }?.earned ?? false)
        XCTAssertEqual(badges.first { $0.id == "ten" }?.progress ?? 0, 0.5, accuracy: 0.001)
    }
}

final class DriversAndBodyTests: XCTestCase {

    func testBackToBackHardDaysHurtRecovery() {
        let p = fighter()
        var ws: [SavedWorkout] = []
        // Fresh sessions recover well; sessions the day after a hard one recover worse.
        for i in 0..<6 {
            let base = Double(i * 4 + 2)
            ws.append(workout(p, daysAgo: base + 1, load: 150, rounds: rounds(3, first: 160, creep: 2, drops: [32])))
            ws.append(workout(p, daysAgo: base, load: 60, rounds: rounds(3, first: 160, creep: 2, drops: [20])))
        }
        let insights = PerformanceDrivers.analyze(workouts: ws, readings: [], profile: p)
        XCTAssertTrue(insights.contains { $0.title.contains("between hard sessions") || $0.title.contains("Space out") },
                      insights.map(\.title).joined(separator: ", "))
    }

    func testShinSorenessLinkedToKicking() {
        let p = fighter()
        var ws: [SavedWorkout] = []
        var logs: [SorenessEntry] = []
        for k in 0..<3 {
            let day = Double(k * 10 + 3)
            ws.append(workout(p, daysAgo: day + 2, category: .muayThai))
            ws.append(workout(p, daysAgo: day + 1, category: .muayThai))
            logs.append(SorenessEntry(profileID: p.id, date: Date().addingTimeInterval(-day * 86400), region: .shin, severity: 2))
        }
        let patterns = SorenessInsights.patterns(logs, workouts: ws, profileID: p.id)
        XCTAssertEqual(patterns.first?.title, "Shin soreness follows kicking volume")
    }

    func testActiveSorenessUsesLatestEntryPerRegion() {
        let p = fighter()
        let logs = [
            SorenessEntry(profileID: p.id, date: Date().addingTimeInterval(-3600), region: .shin, severity: 1),
            SorenessEntry(profileID: p.id, date: Date().addingTimeInterval(-86400), region: .shin, severity: 3),
            SorenessEntry(profileID: p.id, date: Date().addingTimeInterval(-7200), region: .wrist, severity: 2),
            SorenessEntry(profileID: p.id, date: Date().addingTimeInterval(-6 * 86400), region: .knee, severity: 3)
        ]
        let active = SorenessInsights.active(logs, profileID: p.id)
        XCTAssertEqual(active.map(\.region), [.wrist], "shin is now only a niggle, knee is too old")
        XCTAssertNotNil(SorenessInsights.recommendation(for: active))
    }

    func testCampArchivedWhenNextFightIsSet() {
        var old = fighter()
        old.fightDate = Date().addingTimeInterval(-5 * 86400)
        old.campLengthWeeks = 8
        var new = old
        new.fightDate = Date().addingTimeInterval(60 * 86400)
        CampCompare.archiveFinishedCamp(old: old, new: &new)
        XCTAssertEqual(new.campHistory.count, 1)
        XCTAssertEqual(new.campHistory.first?.campLengthWeeks, 8)

        // Rescheduling an upcoming fight doesn't archive anything.
        var upcoming = fighter()
        upcoming.fightDate = Date().addingTimeInterval(20 * 86400)
        var moved = upcoming
        moved.fightDate = Date().addingTimeInterval(27 * 86400)
        CampCompare.archiveFinishedCamp(old: upcoming, new: &moved)
        XCTAssertTrue(moved.campHistory.isEmpty)
    }

    func testBreathingCoherenceRewardsBigSwings() throws {
        let flat = Array(repeating: 800.0, count: 60)
        let swinging = (0..<60).map { 800 + 120 * sin(Double($0) / 10 * 2 * .pi) }
        XCTAssertEqual(BreathingEffect.coherence(rrMs: flat), 0)
        XCTAssertGreaterThan(try XCTUnwrap(BreathingEffect.coherence(rrMs: swinging)), 60)
    }

    func testHeadMovementDetectorDebounces() {
        var above = false
        var last: TimeInterval = 0
        var count = 0
        // A 3 rad/s spike lasting 0.2 s counts once; a second spike 0.1 s later is ignored; one 1 s later counts.
        let stream: [(Double, Double)] = [(100.00, 0.5), (100.05, 3.0), (100.10, 3.2), (100.20, 0.4),
                                          (100.30, 3.1), (100.35, 0.3), (101.30, 2.9), (101.40, 0.2)]
        for (t, m) in stream {
            if HeadMotionTracker.detect(magnitude: m, timestamp: t, above: &above, lastMove: &last) { count += 1 }
        }
        XCTAssertEqual(count, 2)
    }
}

final class UnitTests: XCTestCase {

    func testHeightFeetInchesRoundTrip() {
        let fi = HeightUnits.feetInches(178)
        XCTAssertEqual(fi.feet, 5)
        XCTAssertEqual(fi.inches, 10)
        XCTAssertEqual(HeightUnits.cm(feet: 5, inches: 10), 177.8, accuracy: 0.01)
        XCTAssertEqual(HeightUnits.text(178, true), "5′ 10″")
        XCTAssertEqual(HeightUnits.text(178.4, false), "178 cm")
    }

    func testWeightConversionIsLossless() {
        let kg = 72.4
        let lb = WeightUnits.value(kg, true)
        XCTAssertEqual(WeightUnits.toKg(lb, true), kg, accuracy: 1e-9)
        XCTAssertEqual(WeightUnits.text(70, true), "154.3 lb")
    }

    func testOldProfilesKeepTheirWeightUnitForHeight() throws {
        let json = #"{"name":"Old","useImperial":true}"#
        let p = try JSONDecoder().decode(AthleteProfile.self, from: Data(json.utf8))
        XCTAssertTrue(p.useImperial)
        XCTAssertTrue(p.heightImperial, "people who chose pounds get feet too")
    }
}

final class FighterBioTests: XCTestCase {

    func testFlagFromRegionCode() {
        XCTAssertEqual(FighterBio.flag("il"), "🇮🇱")
        XCTAssertEqual(FighterBio.flag("GB"), "🇬🇧")
        XCTAssertEqual(FighterBio.flag(""), "")
        XCTAssertEqual(FighterBio.flag("123"), "")
    }

    func testDivisionsFollowEachSportsStandard() {
        typealias R = FighterBio.WeightRules
        XCTAssertEqual(R.mma.suggested(forKg: 70.0).name, "Lightweight")
        XCTAssertEqual(R.mma.suggested(forKg: 72).name, "Welterweight")
        XCTAssertEqual(R.mma.suggested(forKg: 150).name, "Heavyweight")
        // Same 75 kg fighter, different standards.
        XCTAssertEqual(R.k1.suggested(forKg: 75).name, "Middleweight")
        XCTAssertEqual(R.mma.suggested(forKg: 75).name, "Welterweight")
        XCTAssertEqual(R.boxing.suggested(forKg: 75).name, "Super Middleweight")
        XCTAssertEqual(R.glory.suggested(forKg: 75).name, "Welterweight")
        XCTAssertEqual(R.k1.suggested(forKg: 120).name, "Heavyweight")
        XCTAssertNil(R.k1.suggested(forKg: 120).limitKg)
        XCTAssertEqual(R.k1.limitText(R.k1.suggested(forKg: 120), imperial: false), "+90.0 kg")
        XCTAssertEqual(R.forDiscipline("Muay Thai"), .muayThai)
        XCTAssertEqual(R.forDiscipline("MMA"), .mma)
    }

    func testChosenDivisionResetsToAutoUnderAnotherStandard() {
        var bio = FighterBio()
        bio.discipline = "K-1"
        bio.divisionName = "Super Welterweight"
        XCTAssertEqual(bio.weightClass(fightWeightKg: 80).name, "Super Welterweight")
        bio.rules = .mma
        XCTAssertEqual(bio.weightClass(fightWeightKg: 80).name, "Middleweight", "no MMA super welterweight, so it falls back to the suggestion")
    }

    func testRecordAndOldProfilesWithoutBio() throws {
        var bio = FighterBio()
        bio.wins = 12; bio.losses = 3; bio.finishes = 5
        XCTAssertEqual(bio.record, "12-3-0")
        XCTAssertEqual(bio.finishesText, "5 by KO / TKO")
        let p = try JSONDecoder().decode(AthleteProfile.self, from: Data(#"{"name":"Old"}"#.utf8))
        XCTAssertEqual(p.bio, FighterBio())
        let round = try JSONDecoder().decode(AthleteProfile.self, from: JSONEncoder().encode({ var x = p; x.bio = bio; return x }()))
        XCTAssertEqual(round.bio.record, "12-3-0")
    }
}
