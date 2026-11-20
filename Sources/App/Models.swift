import Foundation
import SwiftUI

// MARK: - Biometrics & Fight Camp Models

enum BiologicalSex: String, Codable, CaseIterable, Identifiable {
    case male = "Male"
    case female = "Female"
    var id: String { rawValue }
}

enum CampPhase: String, Codable, CaseIterable, Identifiable {
    case offCamp = "Off-Camp / Base"
    case fightCamp = "Fight Camp (8-Wk)"
    case weightCut = "Weight Cut / Taper"
    case fightWeek = "Fight Week"

    var id: String { rawValue }

    var calorieAdjustment: Double {
        switch self {
        case .offCamp: return 0
        case .fightCamp: return -300
        case .weightCut: return -550
        case .fightWeek: return -750
        }
    }

    var adviceTag: String {
        switch self {
        case .offCamp: return "Build Z2 aerobic engine & strength"
        case .fightCamp: return "High glycolytic threshold & sparring"
        case .weightCut: return "Preserve power, gradual deficit"
        case .fightWeek: return "Glycogen taper & acute recovery"
        }
    }
}

enum ZoneCalculationMethod: String, Codable, CaseIterable, Identifiable {
    case karvonenHRR = "Karvonen (Heart Rate Reserve)"
    case lactateThreshold = "Lactate Threshold (LTHR %)"
    case percentMaxHR = "Standard % Max HR"
    case manual = "Custom Manual Ceilings"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .karvonenHRR: return "Uses Resting + Max HR (best for conditioned fighters)"
        case .lactateThreshold: return "Anchors Z4/Z5 directly to your 20-min LTHR test"
        case .percentMaxHR: return "Classic 60/70/80/90% of Max HR"
        case .manual: return "Set exact BPM ceilings yourself"
        }
    }
}

struct ZoneThresholds: Codable, Equatable {
    var z1Max: Int
    var z2Max: Int
    var z3Max: Int
    var z4Max: Int
}

struct HeartRateZoneInfo {
    let number: Int
    let name: String
    let shortName: String
    let color: Color
    let metValue: Double
}

struct AudioCoachSettings: Codable, Equatable {
    var masterEnabled: Bool = true
    var announceZoneCrossings: Bool = true
    var zone2CeilingAlert: Bool = true
    var announceRoundWarnings: Bool = true
    var announceStoolRecovery: Bool = true
    var periodicMinutes: Int = 2 // 0 = Off, 1, 2, 3, 5
    var announceRedlineWarning: Bool = true
    var announceGhostDelta: Bool = true
}

struct AthleteProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "Fighter"
    var sex: BiologicalSex = .male
    var age: Int = 20
    var weightKg: Double = 90.0
    var heightCm: Double = 184.0
    var targetFightWeightKg: Double = 84.0
    var restingHR: Int = 56
    var useAutoMaxHR: Bool = true
    var maxHR: Int = 194
    var lactateThresholdHR: Int = 174
    var zoneMethod: ZoneCalculationMethod = .karvonenHRR
    var manualZones: ZoneThresholds = ZoneThresholds(z1Max: 125, z2Max: 145, z3Max: 162, z4Max: 178)
    var campPhase: CampPhase = .fightCamp
    var audioCoach: AudioCoachSettings = AudioCoachSettings()

    enum CodingKeys: String, CodingKey {
        case id, name, sex, age, weightKg, heightCm, targetFightWeightKg
        case restingHR, useAutoMaxHR, maxHR, lactateThresholdHR, zoneMethod
        case manualZones, campPhase, audioCoach
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Fighter"
        sex = try c.decodeIfPresent(BiologicalSex.self, forKey: .sex) ?? .male
        age = try c.decodeIfPresent(Int.self, forKey: .age) ?? 20
        weightKg = try c.decodeIfPresent(Double.self, forKey: .weightKg) ?? 90.0
        heightCm = try c.decodeIfPresent(Double.self, forKey: .heightCm) ?? 184.0
        targetFightWeightKg = try c.decodeIfPresent(Double.self, forKey: .targetFightWeightKg) ?? 84.0
        restingHR = try c.decodeIfPresent(Int.self, forKey: .restingHR) ?? 56
        useAutoMaxHR = try c.decodeIfPresent(Bool.self, forKey: .useAutoMaxHR) ?? true
        maxHR = try c.decodeIfPresent(Int.self, forKey: .maxHR) ?? 194
        lactateThresholdHR = try c.decodeIfPresent(Int.self, forKey: .lactateThresholdHR) ?? 174
        zoneMethod = try c.decodeIfPresent(ZoneCalculationMethod.self, forKey: .zoneMethod) ?? .karvonenHRR
        manualZones = try c.decodeIfPresent(ZoneThresholds.self, forKey: .manualZones) ?? ZoneThresholds(z1Max: 125, z2Max: 145, z3Max: 162, z4Max: 178)
        campPhase = try c.decodeIfPresent(CampPhase.self, forKey: .campPhase) ?? .fightCamp
        audioCoach = try c.decodeIfPresent(AudioCoachSettings.self, forKey: .audioCoach) ?? AudioCoachSettings()
    }

    mutating func sanitize() {
        age = min(max(age, 13), 85)
        weightKg = min(max(weightKg, 35.0), 200.0)
        heightCm = min(max(heightCm, 120.0), 240.0)
        targetFightWeightKg = min(max(targetFightWeightKg, 35.0), 200.0)
        restingHR = min(max(restingHR, 30), 110)
        let tanaka = Int(round(208.0 - 0.7 * Double(age)))
        if useAutoMaxHR {
            maxHR = tanaka
        } else {
            maxHR = min(max(maxHR, restingHR + 35), 230)
        }
        lactateThresholdHR = min(max(lactateThresholdHR, restingHR + 25), max(restingHR + 25, maxHR - 3))
        manualZones.z1Max = min(max(manualZones.z1Max, 80), maxHR - 35)
        manualZones.z2Max = min(max(manualZones.z2Max, manualZones.z1Max + 5), maxHR - 25)
        manualZones.z3Max = min(max(manualZones.z3Max, manualZones.z2Max + 5), maxHR - 15)
        manualZones.z4Max = min(max(manualZones.z4Max, manualZones.z3Max + 5), maxHR - 5)
    }

    var effectiveMaxHR: Int {
        if useAutoMaxHR {
            return Int(round(208.0 - 0.7 * Double(age)))
        }
        return max(restingHR + 35, maxHR)
    }

    var activeZones: ZoneThresholds {
        let maxH = Double(effectiveMaxHR)
        let restH = Double(restingHR)
        let hrr = max(35.0, maxH - restH)

        switch zoneMethod {
        case .karvonenHRR:
            return ZoneThresholds(
                z1Max: Int(round(restH + hrr * 0.60)),
                z2Max: Int(round(restH + hrr * 0.70)),
                z3Max: Int(round(restH + hrr * 0.80)),
                z4Max: Int(round(restH + hrr * 0.90))
            )
        case .lactateThreshold:
            let lt = Double(lactateThresholdHR)
            return ZoneThresholds(
                z1Max: Int(round(lt * 0.81)),
                z2Max: Int(round(lt * 0.89)),
                z3Max: Int(round(lt * 0.95)),
                z4Max: Int(round(lt * 1.00))
            )
        case .percentMaxHR:
            return ZoneThresholds(
                z1Max: Int(round(maxH * 0.60)),
                z2Max: Int(round(maxH * 0.70)),
                z3Max: Int(round(maxH * 0.80)),
                z4Max: Int(round(maxH * 0.90))
            )
        case .manual:
            return manualZones
        }
    }

    func zone(for bpm: Int) -> HeartRateZoneInfo {
        let z = activeZones
        if bpm <= z.z1Max {
            return HeartRateZoneInfo(number: 1, name: "Zone 1 • Recovery", shortName: "Z1", color: .blue, metValue: 3.5)
        } else if bpm <= z.z2Max {
            return HeartRateZoneInfo(number: 2, name: "Zone 2 • Aerobic Base", shortName: "Z2", color: .green, metValue: 6.5)
        } else if bpm <= z.z3Max {
            return HeartRateZoneInfo(number: 3, name: "Zone 3 • Tempo", shortName: "Z3", color: .yellow, metValue: 8.8)
        } else if bpm <= z.z4Max {
            return HeartRateZoneInfo(number: 4, name: "Zone 4 • Threshold", shortName: "Z4", color: .orange, metValue: 11.2)
        } else {
            return HeartRateZoneInfo(number: 5, name: "Zone 5 • Anaerobic Peak", shortName: "Z5", color: .red, metValue: 13.5)
        }
    }

    var bmrCaloriesPerDay: Double {
        let base = (10.0 * weightKg) + (6.25 * heightCm) - (5.0 * Double(age))
        return sex == .male ? (base + 5.0) : (base - 161.0)
    }

    var bmrCaloriesPerMinute: Double {
        max(0.8, bmrCaloriesPerDay / 1440.0)
    }

    var dailyCalorieTarget: Int {
        let maintenance = bmrCaloriesPerDay * 1.55
        return max(1400, Int(round(maintenance + campPhase.calorieAdjustment)))
    }

    var weightDeltaKg: Double {
        weightKg - targetFightWeightKg
    }
}

// MARK: - Workout Disciplines & Drills

enum WorkoutCategory: String, Codable, CaseIterable, Identifiable {
    case muayThai = "Muay Thai"
    case kickboxing = "Kickboxing"
    case heavyBag = "Heavy Bag"
    case padWork = "Pad Work"
    case sparring = "Sparring"
    case bjj = "BJJ / Grappling"
    case roadwork = "Roadwork / Run"
    case walk = "Walk / Active Recovery"
    case conditioning = "S&C / Conditioning"
    case lthrTest = "20-Min LTHR Field Test"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .muayThai: return "figure.kickboxing"
        case .kickboxing: return "figure.martial.arts"
        case .heavyBag: return "figure.boxing"
        case .padWork: return "hand.raised.fingers.spread.fill"
        case .sparring: return "shield.lefthalf.filled"
        case .bjj: return "figure.wrestling"
        case .roadwork: return "figure.run"
        case .walk: return "figure.walk"
        case .conditioning: return "dumbbell.fill"
        case .lthrTest: return "waveform.path.ecg"
        }
    }

    /// True for combat round-based disciplines; false for continuous walks/runs/tests.
    var usesRoundTimerByDefault: Bool {
        switch self {
        case .muayThai, .kickboxing, .heavyBag, .padWork, .sparring, .bjj:
            return true
        case .roadwork, .walk, .conditioning, .lthrTest:
            return false
        }
    }

    var defaultWorkSeconds: Int {
        switch self {
        case .bjj: return 300
        case .muayThai, .kickboxing, .heavyBag, .padWork, .sparring: return 180
        case .conditioning: return 45
        case .roadwork, .walk, .lthrTest: return 180
        }
    }

    var defaultRestSeconds: Int {
        switch self {
        case .conditioning: return 15
        default: return 60
        }
    }

    var timerModeHint: String {
        switch self {
        case .walk, .roadwork:
            return "Continuous tracking (optional intervals)"
        case .lthrTest:
            return "10m Warm-Up + 20m All-Out LTHR Trial"
        case .bjj:
            return "Default 5:00 roll × 1:00 rest"
        default:
            return "Default 3:00 round × 1:00 stool rest"
        }
    }
}

enum DrillTag: String, Codable, CaseIterable, Identifiable {
    case technical = "Technical"
    case aerobicZ2 = "Aerobic Z2"
    case bagWork = "Bag Work"
    case intervals = "HIIT / Tabata"
    case hardSparring = "Hard Sparring"
    case sharkTank = "Shark Tank"
    case lthrProtocol = "LTHR Protocol"

    var id: String { rawValue }
}

// MARK: - Bag Coach & Combination Metronome Config

enum BagCoachMode: String, Codable, CaseIterable, Identifiable {
    case voiceCombos = "Voice Callouts"
    case cadenceBeep = "Strike-Cue Beep"
    case hybrid = "Voice + Cue Beep"

    var id: String { rawValue }
}

enum BagTempo: String, Codable, CaseIterable, Identifiable {
    case technical = "Technical (9–12s)"
    case steady = "Steady Tempo (6–9s)"
    case fightPace = "Fight Pace (4–7s)"
    case burnout = "Burnout (2.5–4.5s)"
    case variable = "Variable Fight Flow"

    var id: String { rawValue }

    func pauseRange(roundProgress: Double) -> ClosedRange<Double> {
        switch self {
        case .technical:
            return 8.5...11.5
        case .steady:
            return 5.5...8.5
        case .fightPace:
            return 3.8...6.5
        case .burnout:
            return 2.2...4.0
        case .variable:
            // Starts technical in first 35%, ramps to fight pace, finishes with last-30s burnout
            if roundProgress < 0.35 {
                return 7.0...9.5
            } else if roundProgress < 0.80 {
                return 4.0...6.2
            } else {
                return 2.2...3.5
            }
        }
    }
}

struct BagCoachConfig: Equatable {
    var enabled: Bool = false
    var mode: BagCoachMode = .voiceCombos
    var totalMinutes: Int = 30
    var workSeconds: Int = 180
    var restSeconds: Int = 60
    var tempo: BagTempo = .steady
    var includeKicks: Bool = true
    var includeKneesElbows: Bool = true
    var includeDefense: Bool = true

    var estimatedTotalRounds: Int {
        let cycle = max(30, workSeconds + restSeconds)
        return max(1, (totalMinutes * 60) / cycle)
    }
}

// MARK: - Telemetry & Analytics Models

struct HeartRatePoint: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let elapsedSeconds: TimeInterval
    let bpm: Int
    let rrIntervalsMs: [Double]

    init(id: UUID = UUID(), timestamp: Date = Date(), elapsedSeconds: TimeInterval, bpm: Int, rrIntervalsMs: [Double] = []) {
        self.id = id
        self.timestamp = timestamp
        self.elapsedSeconds = elapsedSeconds
        self.bpm = bpm
        self.rrIntervalsMs = rrIntervalsMs
    }
}

struct RoundStat: Codable, Identifiable, Equatable {
    let id: UUID
    let roundNumber: Int
    let startElapsed: TimeInterval
    let endElapsed: TimeInterval
    let avgBPM: Int
    let peakBPM: Int
    let stoolDropBPM: Int?
    let strikesCued: Int

    enum CodingKeys: String, CodingKey {
        case id, roundNumber, startElapsed, endElapsed, avgBPM, peakBPM, stoolDropBPM, strikesCued
    }

    init(id: UUID = UUID(), roundNumber: Int, startElapsed: TimeInterval, endElapsed: TimeInterval, avgBPM: Int, peakBPM: Int, stoolDropBPM: Int?, strikesCued: Int = 0) {
        self.id = id
        self.roundNumber = roundNumber
        self.startElapsed = startElapsed
        self.endElapsed = endElapsed
        self.avgBPM = avgBPM
        self.peakBPM = peakBPM
        self.stoolDropBPM = stoolDropBPM
        self.strikesCued = strikesCued
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        roundNumber = try c.decode(Int.self, forKey: .roundNumber)
        startElapsed = try c.decode(TimeInterval.self, forKey: .startElapsed)
        endElapsed = try c.decode(TimeInterval.self, forKey: .endElapsed)
        avgBPM = try c.decode(Int.self, forKey: .avgBPM)
        peakBPM = try c.decode(Int.self, forKey: .peakBPM)
        stoolDropBPM = try c.decodeIfPresent(Int.self, forKey: .stoolDropBPM)
        strikesCued = try c.decodeIfPresent(Int.self, forKey: .strikesCued) ?? 0
    }
}

struct AutoHRREvent: Codable, Identifiable, Equatable {
    let id: UUID
    let elapsedSeconds: TimeInterval
    let peakBPM: Int
    let recovery60BPM: Int
    let dropBPM: Int
    let contextLabel: String

    init(id: UUID = UUID(), elapsedSeconds: TimeInterval, peakBPM: Int, recovery60BPM: Int, dropBPM: Int, contextLabel: String) {
        self.id = id
        self.elapsedSeconds = elapsedSeconds
        self.peakBPM = peakBPM
        self.recovery60BPM = recovery60BPM
        self.dropBPM = dropBPM
        self.contextLabel = contextLabel
    }
}

struct WorkoutPOI: Codable, Identifiable, Equatable {
    let id: UUID
    let elapsedSeconds: TimeInterval
    let bpm: Int
    let shortTag: String
    let title: String
    let detail: String
    let symbol: String
    let isPositive: Bool

    enum CodingKeys: String, CodingKey {
        case id, elapsedSeconds, bpm, shortTag, title, detail, symbol, isPositive
    }

    init(id: UUID = UUID(), elapsedSeconds: TimeInterval, bpm: Int, shortTag: String = "POI", title: String, detail: String, symbol: String, isPositive: Bool) {
        self.id = id
        self.elapsedSeconds = elapsedSeconds
        self.bpm = bpm
        self.shortTag = shortTag
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.isPositive = isPositive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        elapsedSeconds = try c.decode(TimeInterval.self, forKey: .elapsedSeconds)
        bpm = try c.decode(Int.self, forKey: .bpm)
        title = try c.decode(String.self, forKey: .title)
        shortTag = try c.decodeIfPresent(String.self, forKey: .shortTag) ?? String(title.prefix(12))
        detail = try c.decode(String.self, forKey: .detail)
        symbol = try c.decode(String.self, forKey: .symbol)
        isPositive = try c.decode(Bool.self, forKey: .isPositive)
    }
}

struct GhostSession: Identifiable, Equatable {
    let id: UUID
    let title: String
    let subtitle: String
    let samples: [HeartRatePoint]
    let roundStats: [RoundStat]
    let avgBPM: Int
    let peakBPM: Int

    func interpolatedBPM(at elapsed: TimeInterval) -> Int? {
        guard !samples.isEmpty else { return nil }
        if elapsed <= samples.first!.elapsedSeconds { return samples.first!.bpm }
        if elapsed >= samples.last!.elapsedSeconds { return nil }
        if let idx = samples.firstIndex(where: { $0.elapsedSeconds >= elapsed }) {
            if idx == 0 { return samples[0].bpm }
            let prev = samples[idx - 1]
            let next = samples[idx]
            let span = max(0.001, next.elapsedSeconds - prev.elapsedSeconds)
            let ratio = (elapsed - prev.elapsedSeconds) / span
            return Int(round(Double(prev.bpm) + ratio * Double(next.bpm - prev.bpm)))
        }
        return nil
    }
}

struct SavedWorkout: Codable, Identifiable {
    let id: UUID
    let profileID: UUID
    let profileName: String
    let category: WorkoutCategory
    let drillTag: DrillTag
    let rpe: Int
    let notes: String
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let averageBPM: Int
    let maxBPM: Int
    let minBPM: Int
    let activeCalories: Double
    let bmrCalories: Double
    let calories: Double // Total = Active + BMR
    let epocBonusCalories: Double
    let trimpScore: Double
    let cardiacDriftPercent: Double
    let hrr60Drop: Int?
    let autoHRREvents: [AutoHRREvent]
    let rmssdMs: Double?
    let strikesCuedCount: Int
    let ghostBaselineName: String?
    let ghostAvgDeltaBPM: Double?
    let zoneSeconds: [Int: TimeInterval]
    let roundStats: [RoundStat]
    let pointsOfInterest: [WorkoutPOI]
    var samples: [HeartRatePoint]
    var isCompressedArchive: Bool
    var archiveFileName: String?

    enum CodingKeys: String, CodingKey {
        case id, profileID, profileName, category, drillTag, rpe, notes
        case startDate, endDate, duration, averageBPM, maxBPM, minBPM
        case activeCalories, bmrCalories, calories, epocBonusCalories
        case trimpScore, cardiacDriftPercent, hrr60Drop, autoHRREvents
        case rmssdMs, strikesCuedCount, ghostBaselineName, ghostAvgDeltaBPM
        case zoneSeconds, roundStats, pointsOfInterest, samples
        case isCompressedArchive, archiveFileName
    }

    init(
        id: UUID,
        profileID: UUID,
        profileName: String,
        category: WorkoutCategory,
        drillTag: DrillTag,
        rpe: Int,
        notes: String,
        startDate: Date,
        endDate: Date,
        duration: TimeInterval,
        averageBPM: Int,
        maxBPM: Int,
        minBPM: Int,
        activeCalories: Double,
        bmrCalories: Double,
        calories: Double,
        epocBonusCalories: Double,
        trimpScore: Double,
        cardiacDriftPercent: Double,
        hrr60Drop: Int?,
        autoHRREvents: [AutoHRREvent],
        rmssdMs: Double?,
        strikesCuedCount: Int,
        ghostBaselineName: String?,
        ghostAvgDeltaBPM: Double?,
        zoneSeconds: [Int: TimeInterval],
        roundStats: [RoundStat],
        pointsOfInterest: [WorkoutPOI],
        samples: [HeartRatePoint],
        isCompressedArchive: Bool,
        archiveFileName: String?
    ) {
        self.id = id
        self.profileID = profileID
        self.profileName = profileName
        self.category = category
        self.drillTag = drillTag
        self.rpe = rpe
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.averageBPM = averageBPM
        self.maxBPM = maxBPM
        self.minBPM = minBPM
        self.activeCalories = activeCalories
        self.bmrCalories = bmrCalories
        self.calories = calories
        self.epocBonusCalories = epocBonusCalories
        self.trimpScore = trimpScore
        self.cardiacDriftPercent = cardiacDriftPercent
        self.hrr60Drop = hrr60Drop
        self.autoHRREvents = autoHRREvents
        self.rmssdMs = rmssdMs
        self.strikesCuedCount = strikesCuedCount
        self.ghostBaselineName = ghostBaselineName
        self.ghostAvgDeltaBPM = ghostAvgDeltaBPM
        self.zoneSeconds = zoneSeconds
        self.roundStats = roundStats
        self.pointsOfInterest = pointsOfInterest
        self.samples = samples
        self.isCompressedArchive = isCompressedArchive
        self.archiveFileName = archiveFileName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        profileID = try c.decode(UUID.self, forKey: .profileID)
        profileName = try c.decode(String.self, forKey: .profileName)
        category = try c.decode(WorkoutCategory.self, forKey: .category)
        drillTag = try c.decode(DrillTag.self, forKey: .drillTag)
        rpe = try c.decode(Int.self, forKey: .rpe)
        notes = try c.decode(String.self, forKey: .notes)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decode(Date.self, forKey: .endDate)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        averageBPM = try c.decode(Int.self, forKey: .averageBPM)
        maxBPM = try c.decode(Int.self, forKey: .maxBPM)
        minBPM = try c.decode(Int.self, forKey: .minBPM)
        let total = try c.decode(Double.self, forKey: .calories)
        calories = total
        bmrCalories = try c.decodeIfPresent(Double.self, forKey: .bmrCalories) ?? (duration / 60.0) * 1.25
        activeCalories = try c.decodeIfPresent(Double.self, forKey: .activeCalories) ?? max(0, total - bmrCalories)
        epocBonusCalories = try c.decodeIfPresent(Double.self, forKey: .epocBonusCalories) ?? 0
        trimpScore = try c.decode(Double.self, forKey: .trimpScore)
        cardiacDriftPercent = try c.decode(Double.self, forKey: .cardiacDriftPercent)
        hrr60Drop = try c.decodeIfPresent(Int.self, forKey: .hrr60Drop)
        autoHRREvents = try c.decodeIfPresent([AutoHRREvent].self, forKey: .autoHRREvents) ?? []
        rmssdMs = try c.decodeIfPresent(Double.self, forKey: .rmssdMs)
        strikesCuedCount = try c.decodeIfPresent(Int.self, forKey: .strikesCuedCount) ?? 0
        ghostBaselineName = try c.decodeIfPresent(String.self, forKey: .ghostBaselineName)
        ghostAvgDeltaBPM = try c.decodeIfPresent(Double.self, forKey: .ghostAvgDeltaBPM)
        zoneSeconds = try c.decode([Int: TimeInterval].self, forKey: .zoneSeconds)
        roundStats = try c.decodeIfPresent([RoundStat].self, forKey: .roundStats) ?? []
        pointsOfInterest = try c.decodeIfPresent([WorkoutPOI].self, forKey: .pointsOfInterest) ?? []
        samples = try c.decodeIfPresent([HeartRatePoint].self, forKey: .samples) ?? []
        isCompressedArchive = try c.decodeIfPresent(Bool.self, forKey: .isCompressedArchive) ?? false
        archiveFileName = try c.decodeIfPresent(String.self, forKey: .archiveFileName)
    }

    var avgInterRoundDrop: Int? {
        let drops = roundStats.compactMap(\.stoolDropBPM)
        guard !drops.isEmpty else { return nil }
        return drops.reduce(0, +) / drops.count
    }

    var redlineSeconds: TimeInterval {
        zoneSeconds[5, default: 0]
    }

    var aerobicEfficiencyIndex: Double {
        guard averageBPM > 0 else { return 0 }
        let minutes = max(1.0, duration / 60.0)
        return (activeCalories / minutes) / (Double(averageBPM) / 100.0)
    }

    func toGhostSession() -> GhostSession {
        GhostSession(
            id: id,
            title: "\(category.rawValue) (\(startDate.formatted(date: .abbreviated, time: .omitted)))",
            subtitle: "Avg \(averageBPM) • Peak \(maxBPM) BPM",
            samples: samples,
            roundStats: roundStats,
            avgBPM: averageBPM,
            peakBPM: maxBPM
        )
    }
}

// MARK: - Physiology & Analytics Engine

enum FighterAnalytics {
    /// Keytel et al. Active Exercise Calories + Mifflin-St Jeor Resting BMR Calories
    static func calculateCalorieBreakdown(bpm: Int, durationSeconds: TimeInterval, profile: AthleteProfile) -> (active: Double, bmr: Double, total: Double) {
        let minutes = durationSeconds / 60.0
        guard minutes > 0 else { return (0, 0, 0) }
        let bmr = profile.bmrCaloriesPerMinute * minutes
        guard bpm > 40 else { return (0, bmr, bmr) }

        let totalKcalPerMin: Double
        if profile.sex == .male {
            totalKcalPerMin = (-55.0969 + (0.6309 * Double(bpm)) + (0.1988 * profile.weightKg) + (0.2017 * Double(profile.age))) / 4.184
        } else {
            totalKcalPerMin = (-20.4022 + (0.4472 * Double(bpm)) - (0.1263 * profile.weightKg) + (0.074 * Double(profile.age))) / 4.184
        }
        let total = max(bmr, totalKcalPerMin * minutes)
        let active = max(0, total - bmr)
        return (active, bmr, total)
    }

    static func calculateTRIMP(samples: [HeartRatePoint], profile: AthleteProfile) -> Double {
        guard samples.count >= 2 else { return 0 }
        let rest = Double(profile.restingHR)
        let span = max(35.0, Double(profile.effectiveMaxHR) - rest)
        let bFactor = profile.sex == .male ? 1.92 : 1.67
        var trimp = 0.0

        for i in 1..<samples.count {
            let dtMinutes = max(0, samples[i].elapsedSeconds - samples[i - 1].elapsedSeconds) / 60.0
            let hrr = min(1.0, max(0.0, (Double(samples[i].bpm) - rest) / span))
            trimp += dtMinutes * hrr * 0.64 * exp(bFactor * hrr)
        }
        return trimp
    }

    static func calculateCardiacDrift(samples: [HeartRatePoint]) -> Double {
        guard samples.count >= 20 else { return 0 }
        let trimmed = Array(samples.dropFirst(samples.count / 10))
        guard trimmed.count >= 10 else { return 0 }
        let mid = trimmed.count / 2
        let firstHalf = trimmed[..<mid].map { Double($0.bpm) }
        let secondHalf = trimmed[mid...].map { Double($0.bpm) }
        let avg1 = firstHalf.reduce(0, +) / Double(firstHalf.count)
        let avg2 = secondHalf.reduce(0, +) / Double(secondHalf.count)
        guard avg1 > 0 else { return 0 }
        return ((avg2 - avg1) / avg1) * 100.0
    }

    static func calculateRMSSD(samples: [HeartRatePoint]) -> Double? {
        let allRR = samples.flatMap(\.rrIntervalsMs).filter { $0 >= 280 && $0 <= 2000 }
        guard allRR.count >= 10 else { return nil }
        var sumSqDiff = 0.0
        for i in 1..<allRR.count {
            let diff = allRR[i] - allRR[i - 1]
            sumSqDiff += diff * diff
        }
        return sqrt(sumSqDiff / Double(allRR.count - 1))
    }

    static func calculateEPOC(zoneSeconds: [Int: TimeInterval], weightKg: Double) -> Double {
        let z4Mins = zoneSeconds[4, default: 0] / 60.0
        let z5Mins = zoneSeconds[5, default: 0] / 60.0
        let weightScale = weightKg / 75.0
        return ((z4Mins * 1.6) + (z5Mins * 3.4)) * weightScale
    }

    static func detectPointsOfInterest(
        samples: [HeartRatePoint],
        roundStats: [RoundStat],
        autoHRREvents: [AutoHRREvent],
        profile: AthleteProfile
    ) -> [WorkoutPOI] {
        guard samples.count >= 5 else { return [] }
        var pois: [WorkoutPOI] = []
        let zones = profile.activeZones

        // 1. Peak Heart Rate
        if let peak = samples.max(by: { $0.bpm < $1.bpm }) {
            let pct = Int(round((Double(peak.bpm) / Double(profile.effectiveMaxHR)) * 100))
            pois.append(WorkoutPOI(
                elapsedSeconds: peak.elapsedSeconds,
                bpm: peak.bpm,
                shortTag: "PEAK \(peak.bpm)",
                title: "Peak Redline (\(peak.bpm) BPM)",
                detail: "Reached \(pct)% of Max HR at \(formatTime(peak.elapsedSeconds)).",
                symbol: "flame.fill",
                isPositive: false
            ))
        }

        // 2. Best Automatic In-Workout HRR-60 Recovery
        if let bestHRR = autoHRREvents.max(by: { $0.dropBPM < $1.dropBPM }) {
            pois.append(WorkoutPOI(
                elapsedSeconds: bestHRR.elapsedSeconds,
                bpm: bestHRR.recovery60BPM,
                shortTag: "-\(bestHRR.dropBPM) HRR",
                title: "Fastest 60s Recovery (-\(bestHRR.dropBPM) BPM)",
                detail: "\(bestHRR.contextLabel): dropped \(bestHRR.peakBPM) → \(bestHRR.recovery60BPM) BPM in 60s.",
                symbol: "arrow.down.heart.fill",
                isPositive: true
            ))
        } else if let bestRound = roundStats.filter({ $0.stoolDropBPM != nil }).max(by: { ($0.stoolDropBPM ?? 0) < ($1.stoolDropBPM ?? 0) }),
                  let drop = bestRound.stoolDropBPM {
            pois.append(WorkoutPOI(
                elapsedSeconds: bestRound.endElapsed + 60,
                bpm: max(profile.restingHR, bestRound.peakBPM - drop),
                shortTag: "R\(bestRound.roundNumber) -\(drop)",
                title: "Fastest Stool Recovery (R\(bestRound.roundNumber))",
                detail: "Dropped \(drop) BPM during the 60s corner rest after Round \(bestRound.roundNumber).",
                symbol: "arrow.down.heart.fill",
                isPositive: true
            ))
        }

        // 3. Fastest 20-Second Surge
        for i in 0..<samples.count {
            if let future = samples[i...].first(where: { $0.elapsedSeconds - samples[i].elapsedSeconds >= 20 && $0.elapsedSeconds - samples[i].elapsedSeconds <= 26 }) {
                let rise = future.bpm - samples[i].bpm
                if rise >= 24 {
                    pois.append(WorkoutPOI(
                        elapsedSeconds: future.elapsedSeconds,
                        bpm: future.bpm,
                        shortTag: "+\(rise) SURGE",
                        title: "Explosive Output Surge (+\(rise) BPM)",
                        detail: "Jumped from \(samples[i].bpm) to \(future.bpm) BPM in 20s.",
                        symbol: "bolt.fill",
                        isPositive: false
                    ))
                    break
                }
            }
        }

        // 4. First Zone 5 Redline Crossing
        if let redline = samples.first(where: { $0.bpm > zones.z4Max }) {
            pois.append(WorkoutPOI(
                elapsedSeconds: redline.elapsedSeconds,
                bpm: redline.bpm,
                shortTag: "Z5 ENTRY",
                title: "Anaerobic Zone 5 Entry",
                detail: "Crossed \(zones.z4Max) BPM threshold at \(formatTime(redline.elapsedSeconds)).",
                symbol: "exclamationmark.triangle.fill",
                isPositive: false
            ))
        }

        return Array(pois.prefix(5))
    }

    static func formatTime(_ sec: TimeInterval) -> String {
        let s = Int(sec)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}