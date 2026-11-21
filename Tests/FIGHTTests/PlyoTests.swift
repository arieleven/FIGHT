import XCTest

private func session(daysAgo: Double, category: WorkoutCategory = .kickboxing, planID: UUID? = nil,
                     hardMinutes: Double = 3) -> SavedWorkout {
    let start = Date().addingTimeInterval(-daysAgo * 86400)
    return SavedWorkout(
        id: UUID(), profileID: UUID(), profileName: "Test", category: category, drillTag: .technical,
        rpe: 6, notes: "", startDate: start, endDate: start.addingTimeInterval(1800), duration: 1800,
        averageBPM: 150, maxBPM: 185, minBPM: 90, activeCalories: 300, bmrCalories: 40, calories: 340,
        epocBonusCalories: 10, trimpScore: 60, cardiacDriftPercent: 4, hrr60Drop: 25, autoHRREvents: [],
        rmssdMs: nil, strikesCuedCount: 0, ghostBaselineName: nil, ghostAvgDeltaBPM: nil,
        zoneSeconds: [1: 300, 2: 600, 3: 600, 4: hardMinutes * 30, 5: hardMinutes * 30],
        roundStats: [], pointsOfInterest: [], samples: [], isCompressedArchive: false, archiveFileName: nil,
        trainingPlanID: planID
    )
}

final class PlyoTests: XCTestCase {
    private let format = FightFormat(rounds: 3, minutes: 3)

    func testEveryVariantStaysUnderTheFootContactCap() {
        for level in PlyoLevel.allCases {
            for v in PlyoVariant.allCases {
                for gear in [Set<Equipment>(), Set(Equipment.allCases)] {
                    let plan = PlyoLibrary.plan(v, gear: gear, level: level, format: format)
                    XCTAssertLessThanOrEqual(PlyoLibrary.contacts(plan), level.maxContacts, "\(v) \(level)")
                    XCTAssertGreaterThan(plan.blocks.count, 3)
                }
            }
        }
    }

    func testGearSubstitutions() {
        let noBox = PlyoLibrary.plan(.power, gear: [], level: .intermediate, format: format)
        XCTAssertTrue(noBox.blocks.contains { $0.title.hasPrefix("Squat jumps") })
        XCTAssertFalse(noBox.blocks.contains { $0.title.hasPrefix("Box jumps") })
        let box = PlyoLibrary.plan(.power, gear: [.plyoBox], level: .intermediate, format: format)
        XCTAssertTrue(box.blocks.contains { $0.title.hasPrefix("Box jumps") })

        let noBall = PlyoLibrary.plan(.punch, gear: [], level: .intermediate, format: format)
        XCTAssertTrue(noBall.blocks.contains { $0.title.hasPrefix("Explosive push-ups") })
        XCTAssertTrue(noBall.blocks.contains { $0.title.hasPrefix("All-out shadow punches") })
        let ball = PlyoLibrary.plan(.punch, gear: [.medBall, .heavyBag], level: .intermediate, format: format)
        XCTAssertTrue(ball.blocks.contains { $0.title.hasPrefix("Med-ball chest pass") })
        XCTAssertTrue(ball.blocks.contains { $0.title.hasPrefix("All-out bag punches") })
    }

    func testRestsWaitForRecoveryAndReactionGameHasCalls() {
        let feet = PlyoLibrary.plan(.feet, gear: [.jumpRope], level: .intermediate, format: format)
        XCTAssertTrue(feet.blocks.filter { $0.kind == .rest }.allSatisfy(\.untilRecovered))
        XCTAssertTrue(feet.blocks.contains { !$0.calls.isEmpty })
        XCTAssertEqual(feet.id, PlyoVariant.feet.planID, "stable id so history can recognise plyo sessions")
    }

    func testPlyoRoundsFollowTheFightFormat() {
        let five = PlyoLibrary.plan(.rounds, gear: [.heavyBag], level: .advanced, format: FightFormat(rounds: 5, minutes: 3))
        XCTAssertEqual(five.blocks.filter { $0.kind == .intervals }.count, 5)
    }

    func testMixEmbedsPlyoWithoutItsOwnWarmUp() {
        var p = AthleteProfile()
        p.formatMinutes = 3
        let mix = MixBuilder.plan([MixItem(.rope, 10), MixItem(.plyoPower), MixItem(.bag, 30), MixItem(.cooldown, 5)],
                                  profile: p, gear: [])
        XCTAssertEqual(mix.blocks.first?.title, "Jump rope")
        XCTAssertEqual(mix.blocks.last?.title, "Cool-down")
        XCTAssertFalse(mix.blocks.contains { $0.title.hasPrefix("Warm-up") })
        let bag = mix.blocks.first { $0.kind == .bagRounds }
        XCTAssertEqual(bag?.rounds, 7, "30 min of 3+1 rounds")
    }

    func testDisciplinesShapeWorkoutsAndCombos() {
        XCTAssertFalse(DisciplineRules.categories(for: ["Boxing"]).contains(.muayThai))
        XCTAssertFalse(DisciplineRules.categories(for: ["Boxing"]).contains(.bjj))
        XCTAssertTrue(DisciplineRules.categories(for: ["MMA"]).contains(.bjj))
        XCTAssertEqual(DisciplineRules.strikes(for: ["Boxing"]).kicks, false)
        var p = AthleteProfile()
        p.setDisciplines(["Muay Thai", "Boxing"])
        XCTAssertEqual(p.bio.discipline, "Muay Thai")
        XCTAssertTrue(p.bagPreferences.includeKneesElbows)
        p.setDisciplines(["Boxing"])
        XCTAssertFalse(p.bagPreferences.includeKicks)
    }

    func testJumpHeightFromFlightTime() {
        XCTAssertEqual(JumpDetector.heightCm(flight: 0.5), 30.7, accuracy: 0.1)
        var d = JumpDetector()
        XCTAssertNil(d.feed(vertical: 0.8, ts: 0))     // push-off
        XCTAssertNil(d.feed(vertical: -0.95, ts: 0.1)) // in the air
        XCTAssertNil(d.feed(vertical: -0.95, ts: 0.4))
        let h = d.feed(vertical: 2.0, ts: 0.6)          // landing
        XCTAssertEqual(h ?? 0, JumpDetector.heightCm(flight: 0.5), accuracy: 0.1)
        // Rope skips are too short to count.
        XCTAssertNil(d.feed(vertical: -0.9, ts: 1.0))
        XCTAssertNil(d.feed(vertical: 1.0, ts: 1.12))
    }

    func testSchedulerSpacingAndTaper() {
        var p = AthleteProfile()
        let now = Date()
        XCTAssertNotNil(PlyoScheduler.suggest(workouts: [], readings: [], profile: p, now: now))
        let recent = session(daysAgo: 1, category: .conditioning, planID: PlyoVariant.power.planID)
        XCTAssertNil(PlyoScheduler.suggest(workouts: [recent], readings: [], profile: p, now: now), "48 h between plyo days")
        let older = session(daysAgo: 3, category: .conditioning, planID: PlyoVariant.power.planID)
        XCTAssertEqual(PlyoScheduler.suggest(workouts: [older], readings: [], profile: p, now: now), .punch, "rotates")
        let sparring = session(daysAgo: 1, category: .sparring, hardMinutes: 12)
        XCTAssertNil(PlyoScheduler.suggest(workouts: [sparring], readings: [], profile: p, now: now), "not after hard sparring")
        p.fightDate = now.addingTimeInterval(4 * 86400)
        XCTAssertNil(PlyoScheduler.suggest(workouts: [], readings: [], profile: p, now: now), "fight week")
        p.fightDate = now.addingTimeInterval(10 * 86400)
        XCTAssertEqual(PlyoScheduler.suggest(workouts: [], readings: [], profile: p, now: now), .feet, "taper")
    }

    func testEncouragementPushesThenRestsBetweenCues() {
        var coach = EncouragementCoach()
        func input(_ t: Double, bpm: Int, work: Bool = true, rest: Bool = false, phase: Double = 60) -> EncouragementCoach.Input {
            .init(now: t, bpm: bpm, isWork: work, isRest: rest, phaseElapsed: phase, phaseRemaining: 100,
                  paceFloor: 160, redLine: 180, hitRate: nil, hitRateRef: nil)
        }
        XCTAssertNil(coach.evaluate(input(100, bpm: 150)))
        XCTAssertNil(coach.evaluate(input(110, bpm: 150)))
        XCTAssertEqual(coach.evaluate(input(121, bpm: 150))?.kind, .push, "20 s under your pace")
        XCTAssertNil(coach.evaluate(input(150, bpm: 150)), "at most one cue per 45 s")
        XCTAssertEqual(coach.evaluate(input(200, bpm: 190, work: false, rest: true, phase: 15))?.kind, .recover)
    }
}
