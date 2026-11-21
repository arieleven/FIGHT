import XCTest

final class EfficiencyAndAlgorithmTests: XCTestCase {

    private func fighter() -> AthleteProfile {
        var p = AthleteProfile()
        p.age = 25
        p.restingHR = 55
        p.useAutoMaxHR = false
        p.maxHR = 195
        p.zoneMethod = .percentMaxHR
        return p
    }

    func testCompactSampleFormatRoundTripsAndReadsOldFiles() throws {
        let p = HeartRatePoint(timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000.25), elapsedSeconds: 12.5,
                               bpm: 151, rrIntervalsMs: [398.4375, 401.367])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(p)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("id"), "no per-sample id on disk")
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(HeartRatePoint.self, from: data)
        XCTAssertEqual(back.bpm, 151)
        XCTAssertEqual(back.elapsedSeconds, 12.5)
        XCTAssertEqual(back.rrIntervalsMs[0], 398.4, accuracy: 0.051)
        XCTAssertEqual(back.timestamp.timeIntervalSinceReferenceDate, 800_000_000.25, accuracy: 0.01)

        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","timestamp":"2026-01-01T10:00:00Z","elapsedSeconds":3,"bpm":120,"rrIntervalsMs":[500]}"#
        let legacy = try dec.decode(HeartRatePoint.self, from: Data(old.utf8))
        XCTAssertEqual(legacy.bpm, 120)
        XCTAssertEqual(legacy.rrIntervalsMs, [500])
    }

    func testTrimpIgnoresSensorDropouts() {
        let p = fighter()
        let steady = (0..<600).map { HeartRatePoint(elapsedSeconds: Double($0), bpm: 150) }
        var gappy = steady
        gappy.append(HeartRatePoint(elapsedSeconds: 1200, bpm: 150))   // 10 min dropout
        let a = FighterAnalytics.calculateTRIMP(samples: steady, profile: p)
        let b = FighterAnalytics.calculateTRIMP(samples: gappy, profile: p)
        XCTAssertLessThan(b - a, a * 0.02, "a dropout adds at most 5 s, not 10 minutes")
    }

    private func intervals(rounds: Int, gapAt: Double? = nil) -> [HeartRatePoint] {
        var out: [HeartRatePoint] = []
        var t = 0.0
        var bpm = 100.0
        func run(_ seconds: Int, to target: Double, tau: Double) {
            for _ in 0..<seconds {
                bpm += (target - bpm) / tau
                if gapAt.map({ t < $0 || t > $0 + 40 }) ?? true {
                    out.append(HeartRatePoint(elapsedSeconds: t, bpm: Int(bpm.rounded())))
                }
                t += 1
            }
        }
        run(300, to: 120, tau: 30)
        for r in 0..<rounds {
            run(180, to: 170 + Double(r) * 3, tau: 15)
            run(60, to: 110, tau: 25)
        }
        return out
    }

    func testAutoRoundsStartWhenTheWorkStartsAndSurviveDropouts() {
        let p = fighter()
        let rounds = AutoRounds.detect(samples: intervals(rounds: 4), profile: p)
        XCTAssertEqual(rounds.count, 4)
        // True round 1 starts at 300 s; heart-rate lag used to push this ~30 s late.
        XCTAssertEqual(rounds[0].startElapsed, 300, accuracy: 12)
        XCTAssertEqual(rounds[1].startElapsed, 540, accuracy: 12)

        let withGap = AutoRounds.detect(samples: intervals(rounds: 4, gapAt: 620), profile: p)
        XCTAssertEqual(withGap.count, 4, "a 40 s dropout inside a round doesn't split or shift it")
        XCTAssertEqual(withGap[2].startElapsed, 780, accuracy: 12)
    }

    func testAutoRoundsUseMovementWhenAvailable() {
        let p = fighter()
        let samples = intervals(rounds: 3)
        var activity: [ActivityPoint] = []
        for t in 0..<samples.count {
            let inRound = t >= 300 && (t - 300) % 240 < 180
            activity.append(ActivityPoint(t: Double(t), n: inRound ? 2 : 0))
        }
        let rounds = AutoRounds.detect(samples: samples, activity: activity, profile: p)
        XCTAssertEqual(rounds.count, 3)
        XCTAssertEqual(rounds[0].startElapsed, 300, accuracy: 8)
        XCTAssertEqual(rounds[0].endElapsed - rounds[0].startElapsed, 180, accuracy: 10)
    }

    func testHRVReadinessUsesWeeklyTrendAndIgnoresSmallWobbles() {
        let now = Date()
        func reading(daysAgo: Double, rmssd: Double) -> ReadinessReading {
            var r = ReadinessReading(durationSeconds: 120, restingHR: 55, rmssd: rmssd, artifactRate: 0, sleepQuality: 4, soreness: 2)
            r.date = now.addingTimeInterval(-daysAgo * 86400)
            return r
        }
        // Normal range: rmssd ~ 60–80 over the last two months.
        let history = (8..<50).map { reading(daysAgo: Double($0), rmssd: $0 % 2 == 0 ? 60 : 80) }
        let wobble = [reading(daysAgo: 0, rmssd: 68)] + (1..<7).map { reading(daysAgo: Double($0), rmssd: 70) } + history
        XCTAssertEqual(CoachEngine.hrvSignal(today: wobble[0], readings: wobble, now: now) ?? 99, 0, accuracy: 0.001,
                       "inside the normal range = no signal")
        let tired = [reading(daysAgo: 0, rmssd: 40)] + (1..<7).map { reading(daysAgo: Double($0), rmssd: 45) } + history
        XCTAssertLessThan(CoachEngine.hrvSignal(today: tired[0], readings: tired, now: now) ?? 0, -1)
    }

    func testCorrectedBeatsKeepTheSequenceLength() {
        let rr: [Double] = [800, 810, 805, 2500, 795, 400, 800, 812, 798, 805]
        let q = HRVMath.correctRR(rr)
        XCTAssertEqual(q.cleanRR.count, rr.count, "bad beats are patched, not deleted")
        XCTAssertFalse(q.cleanRR.contains(2500))
        XCTAssertEqual(q.artifactRate, 0.2, accuracy: 0.001)
    }

    func testBagHitsNeedAMuchBiggerSnapWhileTheAppIsTalking() {
        var samples = [Float](repeating: 0.002, count: 1000)
        for k in 0..<10 { samples[100 + k] = k % 2 == 0 ? 0.2 : -0.2 }   // a modest hit
        var normal = ImpactDetector(sampleRate: 1000)
        XCTAssertEqual(normal.feed(samples), 1)
        var strict = ImpactDetector(sampleRate: 1000)
        strict.strict = true
        XCTAssertEqual(strict.feed(samples), 0, "the coach's own voice can't count as hits")
    }

    func testCaloriesStayNearRestAtLowHeartRate() {
        let p = fighter()
        let low = FighterAnalytics.calculateCalorieBreakdown(bpm: 70, durationSeconds: 60, profile: p)
        XCTAssertLessThan(low.total, p.bmrCaloriesPerMinute * 2.5)
        let hard = FighterAnalytics.calculateCalorieBreakdown(bpm: 170, durationSeconds: 60, profile: p)
        XCTAssertGreaterThan(hard.total, 10)
        XCTAssertLessThan(hard.total, 25)
    }

    func testComboPicksSpreadAcrossTheLibrary() {
        var g = ComboGenerator(prefs: BagPreferences())
        var seen = Set<[Strike]>()
        for _ in 0..<60 { seen.insert(g.next()) }
        XCTAssertGreaterThan(seen.count, 8, "least-recently-used weighting keeps variety high")
    }
}
