import Foundation

/// Four fighter-focused plyometric sessions, built to fit the fighter's gear,
/// level (foot-contact budget) and fight format.
enum PlyoVariant: String, CaseIterable, Identifiable, Codable {
    case power = "Fight Power"
    case punch = "Punch Power"
    case feet = "Fast Feet"
    case rounds = "Plyo Rounds"
    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .power: return "Leg drive for kicks and punches. Few reps, maximum effort, full rest."
        case .punch: return "Upper-body and rotational power: throws, explosive push-ups, all-out punching."
        case .feet: return "Quick, light footwork plus a reaction game: jump where the coach calls."
        case .rounds: return "Explosive bursts and fast punches in your fight format. The hard one."
        }
    }

    var icon: String {
        switch self {
        case .power: return "figure.jumprope"
        case .punch: return "figure.boxing"
        case .feet: return "shoeprints.fill"
        case .rounds: return "flame.fill"
        }
    }

    var gear: [Equipment] {
        switch self {
        case .power: return [.plyoBox]
        case .punch: return [.medBall, .band, .heavyBag]
        case .feet: return [.jumpRope]
        case .rounds: return [.heavyBag]
        }
    }

    var planID: UUID { PlanTemplates.stableID(1100 + (PlyoVariant.allCases.firstIndex(of: self) ?? 0)) }
}

enum PlyoLibrary {
    private struct Exercise {
        let name: String
        let cue: String
        let sets: Int
        let seconds: Int
        let contactsPerSet: Int
        let rest: Int
        var calls: [String] = []
    }

    static func plan(_ v: PlyoVariant, gear: Set<Equipment>, level: PlyoLevel, format: FightFormat) -> TrainingPlan {
        var blocks: [PlanBlock] = [warmUp(gear)]
        switch v {
        case .power:
            blocks += sets(capped(powerExercises(gear, level), budget: level.maxContacts - 20))
        case .punch:
            blocks += sets(punchExercises(gear, level))
        case .feet:
            blocks += sets(capped(feetExercises(level), budget: level.maxContacts - 20))
            var rope = PlanBlock(kind: .timedDrill, title: gear.contains(.jumpRope) ? "Jump rope finisher" : "Fast feet finisher")
            rope.durationSeconds = 180
            rope.cue = gear.contains(.jumpRope) ? "Fast rope, stay light" : "Quick feet on the spot, stay light"
            rope.target = ZoneTarget(lowZone: 3, highZone: 4)
            blocks.append(rope)
        case .rounds:
            blocks += plyoRounds(format: format, budget: level.maxContacts - 20, bag: gear.contains(.heavyBag))
        }
        var cool = PlanBlock(kind: .steady, title: "Cool-down")
        cool.durationSeconds = 180
        cool.target = ZoneTarget(lowZone: 1, highZone: 1)
        cool.cue = "Walk it off and breathe slowly"
        blocks.append(cool)

        var plan = TrainingPlan(title: v.rawValue, author: "FIGHT", discipline: WorkoutCategory.conditioning.rawValue,
                                notes: v.blurb, blocks: blocks)
        plan.id = v.planID
        return plan
    }

    static func contacts(_ plan: TrainingPlan) -> Int { plan.blocks.reduce(0) { $0 + $1.contacts } }

    // MARK: Building blocks

    private static func warmUp(_ gear: Set<Equipment>) -> PlanBlock {
        var b = PlanBlock(kind: .timedDrill, title: gear.contains(.jumpRope) ? "Warm-up: easy rope" : "Warm-up: skips and shadowboxing")
        b.durationSeconds = 300
        b.target = ZoneTarget(lowZone: 2, highZone: 2)
        b.cue = "Easy pace, loosen the ankles, hips and shoulders"
        b.contacts = 20
        return b
    }

    private static func sets(_ exercises: [Exercise]) -> [PlanBlock] {
        var out: [PlanBlock] = []
        for (i, e) in exercises.enumerated() {
            for s in 1...e.sets {
                var b = PlanBlock(kind: .timedDrill, title: e.sets > 1 ? "\(e.name) \(s)/\(e.sets)" : e.name)
                b.durationSeconds = e.seconds
                b.cue = e.cue
                b.contacts = e.contactsPerSet
                b.calls = e.calls
                out.append(b)
                let lastSet = s == e.sets
                if !(lastSet && i == exercises.count - 1) {
                    var r = PlanBlock(kind: .rest, title: lastSet ? "Rest, next: \(exercises[i + 1].name)" : "Rest")
                    r.durationSeconds = lastSet ? e.rest + 30 : e.rest
                    r.untilRecovered = true
                    r.cue = "Breathe. Next set starts when you've recovered."
                    out.append(r)
                }
            }
        }
        return out
    }

    /// Drops sets from the end until the session fits the foot-contact budget (each exercise keeps at least one set).
    private static func capped(_ list: [Exercise], budget: Int) -> [Exercise] {
        var ex = list
        func total() -> Int { ex.reduce(0) { $0 + $1.sets * $1.contactsPerSet } }
        var i = ex.count - 1
        while total() > budget && ex.contains(where: { $0.sets > 1 }) {
            if ex[i].sets > 1 {
                let e = ex[i]
                ex[i] = Exercise(name: e.name, cue: e.cue, sets: e.sets - 1, seconds: e.seconds,
                                 contactsPerSet: e.contactsPerSet, rest: e.rest, calls: e.calls)
            }
            i = i == 0 ? ex.count - 1 : i - 1
        }
        return ex
    }

    private static func powerExercises(_ gear: Set<Equipment>, _ level: PlyoLevel) -> [Exercise] {
        let extra = level == .advanced ? 1 : (level == .beginner ? -1 : 0)
        return [
            gear.contains(.plyoBox)
                ? Exercise(name: "Box jumps", cue: "5 jumps. Explode up, land soft, step down", sets: 4 + extra, seconds: 25, contactsPerSet: 5, rest: 90)
                : Exercise(name: "Squat jumps", cue: "5 jumps. Maximum height, land soft and quiet", sets: 4 + extra, seconds: 20, contactsPerSet: 5, rest: 90),
            Exercise(name: "Broad jumps", cue: "4 jumps. As far as you can, stick the landing", sets: 3, seconds: 25, contactsPerSet: 4, rest: 90),
            Exercise(name: "Skater bounds", cue: "3 each side. Push sideways off one leg like a step-in kick", sets: 3, seconds: 20, contactsPerSet: 6, rest: 75),
            Exercise(name: "Split-jump switches", cue: "6 switches. Stance to stance, fast and tall", sets: 3 + max(0, extra), seconds: 20, contactsPerSet: 6, rest: 75)
        ]
    }

    private static func punchExercises(_ gear: Set<Equipment>, _ level: PlyoLevel) -> [Exercise] {
        let sets = level == .beginner ? 2 : (level == .advanced ? 4 : 3)
        var list: [Exercise] = []
        if gear.contains(.medBall) {
            list.append(Exercise(name: "Med-ball chest pass", cue: "6 throws against a wall. Push it like a cross", sets: sets, seconds: 25, contactsPerSet: 0, rest: 75))
            list.append(Exercise(name: "Rotational throws", cue: "5 each side. Turn the hips first, like a hook", sets: sets, seconds: 30, contactsPerSet: 0, rest: 75))
            list.append(Exercise(name: "Med-ball slams", cue: "6 slams. Everything you've got", sets: max(2, sets - 1), seconds: 20, contactsPerSet: 0, rest: 75))
        } else {
            list.append(Exercise(name: "Explosive push-ups", cue: "5 reps. Hands leave the floor every rep", sets: sets, seconds: 20, contactsPerSet: 0, rest: 75))
            list.append(gear.contains(.band)
                ? Exercise(name: "Band punch-throughs", cue: "8 each hand. Snap it out, control it back", sets: sets, seconds: 30, contactsPerSet: 0, rest: 60)
                : Exercise(name: "Hip-turn shadow hooks", cue: "Hard hip turns, 10 each side, full speed", sets: sets, seconds: 25, contactsPerSet: 0, rest: 60))
        }
        list.append(Exercise(name: gear.contains(.heavyBag) ? "All-out bag punches" : "All-out shadow punches",
                             cue: "10 seconds, as fast as you can", sets: 3, seconds: 10, contactsPerSet: 0, rest: 50))
        return list
    }

    private static func feetExercises(_ level: PlyoLevel) -> [Exercise] {
        [
            Exercise(name: "Pogo hops", cue: "Stiff ankles, quick off the floor", sets: 2, seconds: 12, contactsPerSet: 16, rest: 45),
            Exercise(name: "In-out hops", cue: "Feet in, feet out, as fast as you can", sets: 2, seconds: 12, contactsPerSet: 16, rest: 45),
            Exercise(name: "Lateral line hops", cue: "Side to side over a line, stay light", sets: 2, seconds: 12, contactsPerSet: 16, rest: 45),
            Exercise(name: "Reaction jumps", cue: "Jump where I call. Left, right, up or back", sets: level == .beginner ? 2 : 3,
                     seconds: 20, contactsPerSet: 12, rest: 60, calls: ["Left", "Right", "Up", "Back"])
        ]
    }

    private static func plyoRounds(format: FightFormat, budget: Int, bag: Bool) -> [PlanBlock] {
        let jumping = ["Tuck jumps", "Skater bounds", "Split-jump switches"]
        let ground = ["Sprawls", "Mountain climbers", "Burpees, no jump"]
        var out: [PlanBlock] = []
        var used = 0
        let rounds = min(format.rounds, 5)
        for r in 0..<rounds {
            let jumps = r % 2 == 0 && used + 36 <= budget
            var b = PlanBlock(kind: .intervals, title: "Plyo round \(r + 1)")
            b.rounds = 6
            b.workSeconds = 20
            b.restSeconds = 10
            let move = jumps ? jumping[(r / 2) % jumping.count] : ground[(r / 2) % ground.count]
            b.cue = "20 seconds of \(move.lowercased()), 10 seconds of fast \(bag ? "bag " : "")punches"
            b.target = ZoneTarget(lowZone: 4, highZone: 5)
            b.contacts = jumps ? 36 : 0
            used += b.contacts
            out.append(b)
            if r < rounds - 1 {
                var rest = PlanBlock(kind: .rest, title: "Corner")
                rest.durationSeconds = 60
                rest.cue = "Sit down, slow breaths"
                out.append(rest)
            }
        }
        return out
    }
}

// MARK: - Mix: combined sessions

/// One piece of a combined session.
struct MixItem: Identifiable, Equatable, Codable {
    enum Kind: String, CaseIterable, Codable, Identifiable {
        case rope = "Jump rope", bag = "Bag rounds", shadow = "Shadowboxing", pads = "Pads"
        case plyoPower = "Fight Power", plyoPunch = "Punch Power", plyoFeet = "Fast Feet", plyoRounds = "Plyo Rounds"
        case run = "Zone 2 run", strength = "Strength", cooldown = "Cool-down"
        var id: String { rawValue }

        var plyo: PlyoVariant? {
            switch self {
            case .plyoPower: return .power
            case .plyoPunch: return .punch
            case .plyoFeet: return .feet
            case .plyoRounds: return .rounds
            default: return nil
            }
        }

        var icon: String {
            if let p = plyo { return p.icon }
            switch self {
            case .rope: return "figure.jumprope"
            case .bag: return "figure.boxing"
            case .shadow: return "figure.kickboxing"
            case .pads: return "hand.raised.fill"
            case .run: return "figure.run"
            case .strength: return "dumbbell.fill"
            default: return "figure.cooldown"
            }
        }

        var defaultMinutes: Int {
            switch self {
            case .rope: return 10
            case .bag: return 30
            case .shadow, .cooldown: return 5
            case .pads: return 15
            case .run: return 30
            case .strength: return 20
            default: return 20
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var minutes: Int

    init(_ kind: Kind, _ minutes: Int? = nil) {
        self.kind = kind
        self.minutes = minutes ?? kind.defaultMinutes
    }
}

enum MixBuilder {
    static let presets: [(name: String, items: [MixItem])] = [
        ("Camp Classic", [MixItem(.rope, 10), MixItem(.bag, 30), MixItem(.plyoRounds, 20), MixItem(.cooldown, 5)]),
        ("Power Day", [MixItem(.rope, 8), MixItem(.plyoPower, 20), MixItem(.bag, 20), MixItem(.cooldown, 5)]),
        ("Engine Day", [MixItem(.rope, 10), MixItem(.plyoRounds, 20), MixItem(.run, 25), MixItem(.cooldown, 5)])
    ]

    static func plan(_ items: [MixItem], profile: AthleteProfile, gear: Set<Equipment>, title: String = "Mix") -> TrainingPlan {
        var blocks: [PlanBlock] = []
        let work = profile.formatMinutes * 60
        for item in items {
            let secs = item.minutes * 60
            if let v = item.kind.plyo {
                // Plyo inside a mix: the main part only (the mix has its own warm-up and cool-down).
                let full = PlyoLibrary.plan(v, gear: gear, level: profile.plyoLevel, format: profile.fightFormat).blocks
                blocks += full.dropFirst().dropLast()
                continue
            }
            var b: PlanBlock
            switch item.kind {
            case .bag, .pads:
                b = PlanBlock(kind: .bagRounds, title: item.kind.rawValue)
                b.workSeconds = work
                b.restSeconds = 60
                b.rounds = max(1, (secs + 60) / (work + 60))
                b.tempo = .fightPace
            case .rope:
                b = PlanBlock(kind: .timedDrill, title: "Jump rope")
                b.durationSeconds = secs
                b.target = ZoneTarget(lowZone: 2, highZone: 3)
                b.cue = "Light and steady"
            case .shadow:
                b = PlanBlock(kind: .timedDrill, title: "Shadowboxing")
                b.durationSeconds = secs
                b.cue = "Sharp technique, move your head"
            case .run:
                b = PlanBlock(kind: .steady, title: "Zone 2 run")
                b.durationSeconds = secs
                b.target = ZoneTarget(lowZone: 2, highZone: 2)
            case .strength:
                b = PlanBlock(kind: .strength, title: "Strength")
                b.durationSeconds = secs
            default:
                b = PlanBlock(kind: .steady, title: "Cool-down")
                b.durationSeconds = secs
                b.target = ZoneTarget(lowZone: 1, highZone: 1)
            }
            blocks.append(b)
        }
        let mainDiscipline = items.contains { $0.kind == .bag || $0.kind == .pads }
            ? (profile.trainedDisciplines.first == "Muay Thai" ? WorkoutCategory.muayThai : .kickboxing).rawValue
            : WorkoutCategory.conditioning.rawValue
        return TrainingPlan(title: title, author: profile.name, discipline: mainDiscipline, notes: "", blocks: blocks)
    }

    static func minutes(_ items: [MixItem]) -> Int { items.reduce(0) { $0 + $1.minutes } }
}

/// When the coach slots a plyo session in: 1–2 a week, rested legs, away from hard sparring and the fight.
enum PlyoScheduler {
    static func isPlyo(_ w: SavedWorkout) -> Bool {
        if !w.jumps.isEmpty { return true }
        guard let id = w.trainingPlanID else { return false }
        return PlyoVariant.allCases.contains { $0.planID == id }
    }

    /// Plyo sessions per week for where the fighter is in camp.
    static func weeklyTarget(profile: AthleteProfile, now: Date) -> Int {
        guard let fight = profile.fightDate else { return 2 }
        let days = fight.timeIntervalSince(now) / 86_400
        if days < 0 { return 2 }
        if days <= 5 { return 0 }       // fight week: no new soreness
        if days <= 14 { return 1 }      // taper: keep it sharp, less volume
        return 2                        // build
    }

    static func suggest(workouts: [SavedWorkout], readings: [ReadinessReading], profile: AthleteProfile, now: Date) -> PlyoVariant? {
        let target = weeklyTarget(profile: profile, now: now)
        guard target > 0 else { return nil }
        let live = workouts.filter { $0.deletedAt == nil }
        let plyos = live.filter(isPlyo).sorted { $0.endDate > $1.endDate }
        if let last = plyos.first, now.timeIntervalSince(last.endDate) < 48 * 3600 { return nil }
        let thisWeek = plyos.filter { now.timeIntervalSince($0.endDate) < 7 * 86_400 }.count
        guard thisWeek < target else { return nil }
        // Not within 48 h after hard sparring.
        let hardSparring = live.contains {
            $0.category == .sparring && now.timeIntervalSince($0.endDate) < 48 * 3600
                && ($0.zoneSeconds[4, default: 0] + $0.zoneSeconds[5, default: 0]) >= 300
        }
        if hardSparring { return nil }
        // Legs tired on this morning's jump test.
        if let today = readings.first, now.timeIntervalSince(today.date) < 18 * 3600, let j = today.jumpCm {
            let past = readings.dropFirst().compactMap(\.jumpCm).prefix(14)
            if past.count >= 3, j < past.reduce(0, +) / Double(past.count) * 0.9 { return nil }
        }
        // Taper: short and snappy. Otherwise rotate through the four.
        if target == 1, profile.fightDate != nil { return .feet }
        let lastVariant = plyos.first.flatMap { w in PlyoVariant.allCases.first { $0.planID == w.trainingPlanID } }
        guard let lv = lastVariant, let i = PlyoVariant.allCases.firstIndex(of: lv) else { return .power }
        let all = PlyoVariant.allCases
        return all[(i + 1) % all.count]
    }
}
