import Foundation

// PlanKit is shared, dependency-free code: the plan file format and the
// vocabulary it uses. A future FIGHT Coach app compiles this same folder so
// both apps read and write identical plan files.

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
