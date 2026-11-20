import Foundation

// MARK: - Strikes

enum Stance: String, Codable, CaseIterable, Identifiable {
    case orthodox = "Orthodox"
    case southpaw = "Southpaw"
    var id: String { rawValue }
}

enum StrikeKind: String, Codable {
    case punch, kick, knee, elbow, defense
}

/// A strike described by side (lead/rear) so stance can map it to left/right.
enum Strike: String, Codable, CaseIterable, Identifiable {
    case jab, cross, leadHook, rearHook, leadUppercut, rearUppercut
    case leadBodyHook, rearBodyHook
    case leadTeep, rearTeep, leadLowKick, rearLowKick, leadMidKick, rearMidKick, leadHighKick, rearHighKick, switchKick
    case leadKnee, rearKnee, leadElbow, rearElbow
    case slip, roll, check, pivot, block

    var id: String { rawValue }

    var kind: StrikeKind {
        switch self {
        case .jab, .cross, .leadHook, .rearHook, .leadUppercut, .rearUppercut, .leadBodyHook, .rearBodyHook: return .punch
        case .leadTeep, .rearTeep, .leadLowKick, .rearLowKick, .leadMidKick, .rearMidKick, .leadHighKick, .rearHighKick, .switchKick: return .kick
        case .leadKnee, .rearKnee: return .knee
        case .leadElbow, .rearElbow: return .elbow
        case .slip, .roll, .check, .pivot, .block: return .defense
        }
    }

    /// Standard boxing numbers.
    var number: Int? {
        switch self {
        case .jab: return 1
        case .cross: return 2
        case .leadHook: return 3
        case .rearHook: return 4
        case .leadUppercut: return 5
        case .rearUppercut: return 6
        default: return nil
        }
    }

    private var isLead: Bool? {
        switch self {
        case .jab, .leadHook, .leadUppercut, .leadBodyHook, .leadTeep, .leadLowKick, .leadMidKick, .leadHighKick, .leadKnee, .leadElbow:
            return true
        case .cross, .rearHook, .rearUppercut, .rearBodyHook, .rearTeep, .rearLowKick, .rearMidKick, .rearHighKick, .rearKnee, .rearElbow:
            return false
        default:
            return nil
        }
    }

    private func sideWord(_ stance: Stance) -> String {
        guard let lead = isLead else { return "" }
        let leadIsLeft = stance == .orthodox
        return (lead == leadIsLeft) ? "Left" : "Right"
    }

    /// Spoken callout for the given stance and call style.
    func callout(stance: Stance, numbers: Bool) -> String {
        if numbers, let n = number {
            return ["One!", "Two!", "Three!", "Four!", "Five!", "Six!"][n - 1]
        }
        let side = sideWord(stance)
        switch self {
        case .jab: return "Jab!"
        case .cross: return "Cross!"
        case .leadHook, .rearHook: return "\(side) hook!"
        case .leadUppercut, .rearUppercut: return "\(side) uppercut!"
        case .leadBodyHook, .rearBodyHook: return "\(side) body!"
        case .leadTeep, .rearTeep: return numbers ? "Teep!" : "\(side) teep!"
        case .leadLowKick, .rearLowKick: return numbers ? "\(side) low!" : "\(side) low kick!"
        case .leadMidKick, .rearMidKick: return numbers ? "\(side) kick!" : "\(side) body kick!"
        case .leadHighKick, .rearHighKick: return numbers ? "\(side) high!" : "\(side) high kick!"
        case .switchKick: return "Switch kick!"
        case .leadKnee, .rearKnee: return "\(side) knee!"
        case .leadElbow, .rearElbow: return "\(side) elbow!"
        case .slip: return "Slip!"
        case .roll: return "Roll!"
        case .check: return "Check!"
        case .pivot: return "Pivot!"
        case .block: return "Block!"
        }
    }

    /// Short label for on-screen chips and the custom-combo builder.
    func shortLabel(stance: Stance) -> String {
        if let n = number { return "\(n)" }
        let side = sideWord(stance).prefix(1)
        switch self {
        case .leadBodyHook, .rearBodyHook: return "\(side) Body"
        case .leadTeep, .rearTeep: return "\(side) Teep"
        case .leadLowKick, .rearLowKick: return "\(side) Low"
        case .leadMidKick, .rearMidKick: return "\(side) Kick"
        case .leadHighKick, .rearHighKick: return "\(side) High"
        case .switchKick: return "Switch"
        case .leadKnee, .rearKnee: return "\(side) Knee"
        case .leadElbow, .rearElbow: return "\(side) Elbow"
        case .slip: return "Slip"
        case .roll: return "Roll"
        case .check: return "Check"
        case .pivot: return "Pivot"
        case .block: return "Block"
        default: return rawValue
        }
    }

    /// Seconds to physically throw it after the callout (before the tempo reset).
    var executionSeconds: Double {
        switch kind {
        case .punch: return 0.35
        case .kick: return 0.7
        case .knee: return 0.5
        case .elbow: return 0.4
        case .defense: return 0.5
        }
    }
}

// MARK: - Preferences

enum BagDifficulty: String, Codable, CaseIterable, Identifiable {
    case beginner = "Beginner"
    case intermediate = "Intermediate"
    case advanced = "Advanced"
    case pro = "Pro"
    var id: String { rawValue }

    var lengthRange: ClosedRange<Int> {
        switch self {
        case .beginner: return 1...3
        case .intermediate: return 2...4
        case .advanced: return 3...5
        case .pro: return 3...6
        }
    }
}

extension BagTempo {
    /// Seconds of reset *after* the strikes have been thrown.
    func resetRange(roundProgress: Double) -> ClosedRange<Double> {
        switch self {
        case .technical: return 3.5...5.5
        case .steady: return 2.0...3.2
        case .fightPace: return 1.0...2.0
        case .burnout: return 0.3...0.8
        case .variable:
            if roundProgress < 0.35 { return 2.5...3.5 }
            if roundProgress < 0.8 { return 1.2...2.2 }
            return 0.4...1.0
        }
    }

    /// Burnout favours short combos so the pace stays relentless.
    var maxComboLength: Int? {
        switch self {
        case .burnout: return 3
        default: return nil
        }
    }

    var speechRate: Float {
        switch self {
        case .technical: return 0.52
        case .steady: return 0.55
        case .fightPace: return 0.58
        case .burnout: return 0.62
        case .variable: return 0.57
        }
    }
}

struct BagPreferences: Codable, Equatable {
    var mode: BagCoachMode = .voiceCombos
    var tempo: BagTempo = .steady
    var stance: Stance = .orthodox
    var difficulty: BagDifficulty = .intermediate
    var numberCalls = false
    var includeKicks = true
    var includeKneesElbows = true
    var includeDefense = true
    var dutchFinish = true
    var adaptiveTempo = false
    var customOnly = false
    var customCombos: [[Strike]] = []
    var totalMinutes = 30
    var workSeconds = 180
    var restSeconds = 60

    var estimatedTotalRounds: Int {
        let cycle = max(30, workSeconds + restSeconds)
        return max(1, (totalMinutes * 60 + restSeconds) / cycle)
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case mode, tempo, stance, difficulty, numberCalls, includeKicks, includeKneesElbows, includeDefense
        case dutchFinish, adaptiveTempo, customOnly, customCombos, totalMinutes, workSeconds, restSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BagPreferences()
        mode = (try? c.decodeIfPresent(BagCoachMode.self, forKey: .mode)) ?? d.mode
        tempo = (try? c.decodeIfPresent(BagTempo.self, forKey: .tempo)) ?? d.tempo
        stance = (try? c.decodeIfPresent(Stance.self, forKey: .stance)) ?? d.stance
        difficulty = (try? c.decodeIfPresent(BagDifficulty.self, forKey: .difficulty)) ?? d.difficulty
        numberCalls = (try? c.decodeIfPresent(Bool.self, forKey: .numberCalls)) ?? d.numberCalls
        includeKicks = (try? c.decodeIfPresent(Bool.self, forKey: .includeKicks)) ?? d.includeKicks
        includeKneesElbows = (try? c.decodeIfPresent(Bool.self, forKey: .includeKneesElbows)) ?? d.includeKneesElbows
        includeDefense = (try? c.decodeIfPresent(Bool.self, forKey: .includeDefense)) ?? d.includeDefense
        dutchFinish = (try? c.decodeIfPresent(Bool.self, forKey: .dutchFinish)) ?? d.dutchFinish
        adaptiveTempo = (try? c.decodeIfPresent(Bool.self, forKey: .adaptiveTempo)) ?? d.adaptiveTempo
        customOnly = (try? c.decodeIfPresent(Bool.self, forKey: .customOnly)) ?? d.customOnly
        customCombos = (try? c.decodeIfPresent([[Strike]].self, forKey: .customCombos)) ?? d.customCombos
        totalMinutes = (try? c.decodeIfPresent(Int.self, forKey: .totalMinutes)) ?? d.totalMinutes
        workSeconds = (try? c.decodeIfPresent(Int.self, forKey: .workSeconds)) ?? d.workSeconds
        restSeconds = (try? c.decodeIfPresent(Int.self, forKey: .restSeconds)) ?? d.restSeconds
    }
}

// MARK: - Combo generator

/// Builds realistic kickboxing / Muay Thai combinations from a curated library,
/// filtered by enabled strike types and difficulty, with an optional
/// "Dutch finish" (end on a kick) and no immediate repeats.
struct ComboGenerator {
    var prefs: BagPreferences
    private(set) var recent: [[Strike]] = []
    /// Library picks before any Dutch-finish kick was added, so a base combo
    /// can't be re-picked and turned into an identical repeat.
    private var recentBases: [[Strike]] = []

    init(prefs: BagPreferences) {
        self.prefs = prefs
    }

    static let library: [[Strike]] = [
        // Boxing foundations
        [.jab], [.jab, .jab], [.jab, .cross], [.jab, .cross, .leadHook], [.jab, .cross, .leadHook, .cross],
        [.jab, .rearUppercut, .leadHook], [.cross, .leadHook, .cross], [.leadHook, .cross],
        [.jab, .cross, .leadUppercut, .cross], [.leadBodyHook, .leadHook, .cross],
        [.jab, .rearBodyHook, .leadHook], [.leadUppercut, .leadHook, .cross], [.jab, .jab, .cross],
        [.cross, .leadHook, .rearUppercut], [.jab, .cross, .leadBodyHook, .leadHook],
        // Kickboxing
        [.jab, .cross, .leadLowKick], [.jab, .cross, .rearLowKick], [.jab, .cross, .leadHook, .rearLowKick],
        [.jab, .rearMidKick], [.cross, .leadHook, .rearMidKick], [.jab, .cross, .switchKick],
        [.leadTeep, .cross, .leadHook], [.jab, .leadTeep], [.rearTeep, .jab, .cross],
        [.jab, .cross, .leadHook, .rearHighKick], [.leadLowKick, .cross], [.rearMidKick, .cross, .leadHook],
        [.leadHook, .rearLowKick], [.jab, .leadHighKick], [.jab, .cross, .leadHook, .cross, .rearLowKick],
        // Muay Thai close range
        [.jab, .cross, .rearKnee], [.leadHook, .rearElbow], [.jab, .rearElbow, .leadKnee],
        [.cross, .leadElbow, .rearKnee], [.leadKnee, .rearKnee], [.jab, .cross, .leadHook, .rearElbow],
        [.rearElbow, .leadElbow], [.leadTeep, .rearKnee],
        // Defence and counters
        [.slip, .cross, .leadHook], [.roll, .leadHook, .cross], [.check, .rearLowKick], [.check, .cross, .leadHook],
        [.jab, .cross, .slip, .cross], [.block, .rearMidKick], [.jab, .pivot, .cross],
        [.jab, .cross, .roll, .leadHook, .cross], [.slip, .rearUppercut, .leadHook]
    ]

    private func allowed(_ combo: [Strike]) -> Bool {
        for s in combo {
            switch s.kind {
            case .kick where !prefs.includeKicks: return false
            case .knee where !prefs.includeKneesElbows, .elbow where !prefs.includeKneesElbows: return false
            case .defense where !prefs.includeDefense: return false
            default: continue
            }
        }
        return true
    }

    private var lengthRange: ClosedRange<Int> {
        let base = prefs.difficulty.lengthRange
        guard let cap = prefs.tempo.maxComboLength else { return base }
        return base.lowerBound...max(base.lowerBound, min(base.upperBound, cap))
    }

    mutating func next() -> [Strike] {
        let custom = prefs.customCombos.filter { !$0.isEmpty }
        var pool: [[Strike]]
        if prefs.customOnly && !custom.isEmpty {
            pool = custom
        } else {
            pool = Self.library.filter { allowed($0) && lengthRange.contains($0.count) } + custom
        }
        if pool.isEmpty { pool = [[.jab, .cross]] }

        let fresh = pool.filter { candidate in !recent.contains(candidate) && !recentBases.contains(candidate) }
        let base = (fresh.isEmpty ? pool : fresh).randomElement() ?? [.jab, .cross]
        var combo = base

        // Dutch-style finish: close punch combos with a kick.
        if !prefs.customOnly, prefs.dutchFinish, prefs.includeKicks,
           let last = combo.last, last.kind == .punch,
           combo.count < lengthRange.upperBound, Double.random(in: 0...1) < 0.35 {
            let leadSide: [Strike] = [.jab, .leadHook, .leadUppercut, .leadBodyHook]
            let lastIsLeadSide = leadSide.contains(last)
            combo.append(lastIsLeadSide ? .rearLowKick : .leadLowKick)
        }

        if combo == recent.last, combo.count > base.count {
            combo = base // never repeat the previous combo exactly
        }
        recent.append(combo)
        recentBases.append(base)
        if recent.count > 4 { recent.removeFirst() }
        if recentBases.count > 4 { recentBases.removeFirst() }
        return combo
    }

    /// Every distinct phrase this configuration can say (for pre-rendering).
    static func vocabulary(prefs: BagPreferences) -> [String] {
        var set = Set(Strike.allCases.map { $0.callout(stance: prefs.stance, numbers: prefs.numberCalls) })
        set.insert("Punch out!")
        return Array(set).sorted()
    }
}
