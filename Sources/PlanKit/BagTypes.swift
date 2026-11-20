import Foundation

/// How the bag coach calls combinations. Raw values are part of the saved and
/// shared file format: never change them; use `displayName` for UI.
enum BagCoachMode: String, Codable, CaseIterable, Identifiable {
    case voiceCombos = "Voice Callouts"
    case cadenceBeep = "Strike-Cue Beep"
    case hybrid = "Voice + Cue Beep"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .voiceCombos: return "Voice callouts"
        case .cadenceBeep: return "Strike-cue beeps"
        case .hybrid: return "Voice + beep"
        }
    }
}

/// Bag-work pace. Raw values are part of the saved and shared file format:
/// never change them; use `displayName` for UI.
enum BagTempo: String, Codable, CaseIterable, Identifiable {
    case technical = "Technical (9–12s)"
    case steady = "Steady Tempo (6–9s)"
    case fightPace = "Fight Pace (4–7s)"
    case burnout = "Burnout (2.5–4.5s)"
    case variable = "Variable Fight Flow"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .technical: return "Technical"
        case .steady: return "Steady"
        case .fightPace: return "Fight pace"
        case .burnout: return "Burnout"
        case .variable: return "Variable flow"
        }
    }
}
