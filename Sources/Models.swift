import Foundation
import SwiftUI

enum BiologicalSex: String, CaseIterable, Identifiable, Codable {
    case male = "Male"
    case female = "Female"
    var id: String { rawValue }
}

enum CampPhase: String, CaseIterable, Identifiable, Codable {
    case offCamp = "Off-Camp / Base"
    case fightCamp = "Fight Camp"
    case fightCut = "Fight Cut (-500 kcal)"
    case peakTaper = "Fight Week / Taper"
    case massBuild = "Strength / Surplus"

    var id: String { rawValue }

    var calorieAdjustment: Double {
        switch self {
        case .offCamp: return 0
        case .fightCamp: return -200
        case .fightCut: return -500
        case .peakTaper: return -300
        case .massBuild: return 350
        }
    }

    var adviceTag: String {
        switch self {
        case .offCamp: return "Build aerobic engine & base strength"
        case .fightCamp: return "High glycolytic output + moderate deficit"
        case .fightCut: return "Preserve glycogen around sparring; prioritize protein (2.2g/kg)"
        case .peakTaper: return "Drop volume 40%, keep sharpness & hydration"
        case .massBuild: return "Fuel anaerobic power & hypertrophy"
        }
    }
}

enum ZoneCalculationMethod: String, CaseIterable, Identifiable, Codable {
    case karvonen = "Karvonen (HR Reserve)"
    case percentMax = "% of Max HR"
    case lactateThreshold = "Lactate Threshold (%LTHR)"
    case manual = "Custom Manual BPM"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .karvonen: return "Uses Resting HR + Max HR (best for combat athletes)"
        case .percentMax: return "Classic 50/60/70/80/90% of Max Heart Rate"
        case .lactateThreshold: return "Joe Friel model anchored to anaerobic threshold"
        case .manual: return "Set exact BPM ceilings for Zones 1–4"
        }
    }
}

struct ZoneBoundary: Codable, Equatable {
    var z1Max: Int
    var z2Max: Int
    var z3Max: Int
    var z4Max: Int
}

struct AthleteProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var sex: BiologicalSex
    var age: Int
    var weightKg: Double
    var targetFightWeightKg: Double
    var heightCm: Double
    var restingHR: Int
    var maxHR: Int
    var useAutoMaxHR: Bool
    var lactateThresholdHR: Int
    var campPhase: CampPhase
    var zoneMethod: ZoneCalculationMethod
    var manualZones: ZoneBoundary
    var baselineRMSSD: Double

    static var defaultFighter: AthleteProfile {
        AthleteProfile(
            name: "Fighter 1",
            sex: .male,
            age: 20,
            weightKg: 90.0,
            targetFightWeightKg: 84.0,
            heightCm: 180.0,
            restingHR: 56,
            maxHR: 194,
            useAutoMaxHR: true,
            lactateThresholdHR: 174,
            campPhase: .fightCamp,
            zoneMethod: .karvonen,
            manualZones: ZoneBoundary(z1Max: 125, z2Max: 142, z3Max: 160, z4Max: 177),
            baselineRMSSD: 55.0
        )
    }

    var effectiveMaxHR: Int {
        if useAutoMaxHR {
            // Tanaka formula: 208 - (0.7 * age)
            return Int(round(208.0 - (0.7 * Double(age))))
        }
        return max(120, maxHR)
    }

    var activeZones: ZoneBoundary {
        let hrm = Double(effectiveMaxHR)
        let rhr = Double(restingHR)
        switch zoneMethod {
        case .karvonen:
            let hrr = max(40.0, hrm - rhr)
            return ZoneBoundary(
                z1Max: Int(round(rhr + hrr * 0.60)),
                z2Max: Int(round(rhr + hrr * 0.70)),
                z3Max: Int(round(rhr + hrr * 0.80)),
                z4Max: Int(round(rhr + hrr * 0.90))
            )
        case .percentMax:
            return ZoneBoundary(
                z1Max: Int(round(hrm * 0.60)),
                z2Max: Int(round(hrm * 0.70)),
                z3Max: Int(round(hrm * 0.80)),
                z4Max: Int(round(hrm * 0.90))
            )
        case .lactateThreshold:
            let lt = Double(lactateThresholdHR)
            return ZoneBoundary(
                z1Max: Int(round(lt * 0.81)),
                z2Max: Int(round(lt * 0.89)),
                z3Max: Int(round(lt * 0.95)),
                z4Max: Int(round(lt * 1.00))
            )
        case .manual:
            return manualZones
        }
    }

    /// Mifflin-St Jeor BMR * 1.55 moderate training baseline + camp adjustment
    var dailyCalorieTarget: Int {
        let s: Double = (sex == .male) ? 5.0 : -161.0
        let bmr = (10.0 * weightKg) + (6.25 * heightCm) - (5.0 * Double(age)) + s
        let tdee = bmr * 1.55
        return max(1400, Int(round(tdee + campPhase.calorieAdjustment)))
    }

    var weightDeltaKg: Double {
        weightKg - targetFightWeightKg
    }

    func zone(for bpm: Int) -> HRZoneInfo {
        let z = activeZones
        if bpm <= z.z1Max {
            return HRZoneInfo(number: 1, name: "Zone 1 • Recovery", shortName: "Z1", color: .blue)
        } else if bpm <= z.z2Max {
            return HRZoneInfo(number: 2, name: "Zone 2 • Aerobic Base", shortName: "Z2", color: .green)
        } else if bpm <= z.z3Max {
            return HRZoneInfo(number: 3, name: "Zone 3 • Tempo", shortName: "Z3", color: .yellow)
        } else if bpm <= z.z4Max {
            return HRZoneInfo(number: 4, name: "Zone 4 • Threshold", shortName: "Z4", color: .orange)
        } else {
            return HRZoneInfo(number: 5, name: "Zone 5 • Anaerobic Peak", shortName: "Z5", color: .red)
        }
    }
}

struct HRZoneInfo {
    let number: Int
    let name: String
    let shortName: String
    let color: Color
}

enum WorkoutCategory: String, CaseIterable, Identifiable, Codable {
    case kickboxing = "Kickboxing"
    case sparring = "Sparring"
    case heavyBag = "Bag / Pads"
    case running = "Run"
    case zone2Run = "Zone 2 LSD"
    case intervals4x4 = "4x4 VO2 Max"
    case walking = "Walk"
    case conditioning = "Strength / HIIT"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .kickboxing, .sparring, .heavyBag: return "figure.kickboxing"
        case .running, .zone2Run, .intervals4x4: return "figure.run"
        case .walking: return "figure.walk"
        case .conditioning: return "flame.fill"
        }
    }

    var tcxSport: String {
        switch self {
        case .running, .zone2Run, .intervals4x4: return "Running"
        default: return "Other"
        }
    }

    var isAnaerobicFocus: Bool {
        switch self {
        case .kickboxing, .sparring, .heavyBag, .intervals4x4, .conditioning: return true
        case .running, .zone2Run, .walking: return false
        }
    }
}

enum RoundPreset: String, CaseIterable, Identifiable, Codable {
    case open = "Open Session"
    case kickboxing3x1 = "3m × 1m Rounds"
    case mma5x1 = "5m × 1m Rounds"
    case norwegian4x4 = "4m × 3m (4x4)"
    case tabata = "20s × 10s Sprints"

    var id: String { rawValue }

    var workSeconds: Int {
        switch self {
        case .open: return 0
        case .kickboxing3x1: return 180
        case .mma5x1: return 300
        case .norwegian4x4: return 240
        case .tabata: return 20
        }
    }

    var restSeconds: Int {
        switch self {
        case .open: return 0
        case .kickboxing3x1: return 60
        case .mma5x1: return 60
        case .norwegian4x4: return 180
        case .tabata: return 10
        }
    }
}

struct HeartRatePoint: Codable, Identifiable {
    var id: UUID = UUID()
    let timestamp: Date
    let elapsedSeconds: Double
    let bpm: Int
    let rrIntervalMs: Double?
}

struct WorkoutPOI: Identifiable, Codable {
    var id: UUID = UUID()
    let title: String
    let detail: String
    let elapsedSeconds: Double
    let bpm: Int
    let symbol: String
    let isPositive: Bool
}

struct SavedWorkout: Identifiable, Codable {
    let id: UUID
    let athleteID: UUID
    let category: WorkoutCategory
    let roundPreset: RoundPreset
    let startDate: Date
    let duration: TimeInterval
    let averageBPM: Int
    let maxBPM: Int
    let minBPM: Int
    let calories: Double
    let epocBonusCalories: Double
    let trimpScore: Double
    let hrr60Drop: Int?
    let avgInterRoundDrop: Int?
    let rmssdMs: Double?
    let cardiacDriftPercent: Double
    let zoneSeconds: [Int: Double]
    let samples: [HeartRatePoint]
    let pointsOfInterest: [WorkoutPOI]
}

struct CoachPrescription: Identifiable {
    let id = UUID()
    let title: String
    let tag: String
    let tagColor: Color
    let diagnosis: String
    let actionPlan: String
    let icon: String
}

struct FighterAnalytics {
    let staminaRating: Int
    let aerobicScore: Int
    let anaerobicScore: Int
    let recoveryScore: Int
    let weeklyTRIMP: Double
    let recommendedRecoveryHours: Int
    let recommendedSleepHours: Double
    let latestHRV: Double?
    let latestHRR60: Int?
    let trendLabel: String
    let prescriptions: [CoachPrescription]
}