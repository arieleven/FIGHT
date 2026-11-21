import Foundation

/// The three doors on the Today screen.
enum MainChoice: String, CaseIterable, Identifiable {
    case fight = "Fight"
    case roadwork = "Roadwork"
    case conditioning = "Conditioning"
    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .fight: return "Bag, pads, sparring"
        case .roadwork: return "Runs and walks with GPS"
        case .conditioning: return "Plyo, rope, circuits"
        }
    }

    var icon: String {
        switch self {
        case .fight: return "figure.boxing"
        case .roadwork: return "figure.run"
        case .conditioning: return "bolt.fill"
        }
    }
}

/// How long: a round count and round/rest length (and the bag tempo for bag work).
struct LengthOption: Identifiable, Hashable {
    let title: String
    let rounds: Int
    let work: Int
    let rest: Int
    var tempo: BagTempo? = nil
    var id: String { title }

    var detail: String {
        func clock(_ s: Int) -> String { s % 60 == 0 ? "\(s / 60) min" : (s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : "\(s) s") }
        return "\(rounds) × \(clock(work)), \(clock(rest)) rest"
    }
}

/// One thing you can do, in plain words, with everything the app needs to set it up.
struct ActivityOption: Identifiable, Hashable {
    let title: String
    let subtitle: String
    let icon: String
    let category: WorkoutCategory
    let drill: DrillTag
    var bagCoach = false
    /// Sport shown with it ("Muay Thai · Bag work"); nil for runs and conditioning.
    var sport: String? = nil
    var lengths: [LengthOption] = []
    var id: String { (sport ?? "") + title }

    /// "Muay Thai · Bag work"
    var displayName: String { sport.map { "\($0) · \(title)" } ?? title }

    /// What happens when you press Start, as a short checklist.
    var checklist: [String] {
        var c: [String] = []
        if !lengths.isEmpty { c.append("Round bell and rest timer") }
        if bagCoach { c.append("The coach calls combos") }
        if category.isRun { c.append("GPS distance, pace and splits") }
        if category == .lthrTest { c.append("10 min warm-up, 20 min all-out. Zones update at the end") }
        if drill == .aerobicZ2 && category.isRun { c.append("Warns you above Zone 2") }
        c.append("Heart rate and zones (if your strap is on)")
        return c
    }
}

/// Every choice behind the three doors.
enum WorkoutMenu {
    /// The sports this fighter trains, main sport first (MMA fighters see one MMA door, etc.).
    static func sports(_ profile: AthleteProfile) -> [String] {
        profile.trainedDisciplines
    }

    static func category(forSport sport: String) -> WorkoutCategory {
        switch sport {
        case "Muay Thai": return .muayThai
        case "BJJ", "Wrestling": return .bjj
        case "Boxing": return .heavyBag
        default: return .kickboxing
        }
    }

    // MARK: Fight

    static func fight(sport: String, format: FightFormat) -> [ActivityOption] {
        let rounds = format.rounds, work = format.minutes * 60
        let fightLike = [
            LengthOption(title: "Fight length", rounds: rounds, work: work, rest: 60),
            LengthOption(title: "Double", rounds: rounds * 2, work: work, rest: 60),
            LengthOption(title: "Quick", rounds: 3, work: 120, rest: 60)
        ]
        let bag = [
            LengthOption(title: "Fight length", rounds: rounds, work: work, rest: 60, tempo: .fightPace),
            LengthOption(title: "Long session", rounds: rounds * 2, work: work, rest: 60, tempo: .steady),
            LengthOption(title: "Burnout", rounds: 8, work: 60, rest: 30, tempo: .burnout)
        ]
        let technique = [
            LengthOption(title: "4 rounds", rounds: 4, work: work, rest: 60),
            LengthOption(title: "6 rounds", rounds: 6, work: work, rest: 60),
            LengthOption(title: "10 rounds", rounds: 10, work: work, rest: 45)
        ]
        let grappling = [
            LengthOption(title: "5 rounds", rounds: 5, work: 300, rest: 60),
            LengthOption(title: "8 rounds", rounds: 8, work: 300, rest: 60),
            LengthOption(title: "Shark tank", rounds: 6, work: 180, rest: 30)
        ]
        let own = category(forSport: sport)

        if sport == "BJJ" || sport == "Wrestling" {
            let wrestling = sport == "Wrestling"
            return [
                ActivityOption(title: "Drilling", subtitle: "Reps of the move of the day", icon: "repeat",
                               category: .bjj, drill: .technical, sport: sport, lengths: technique),
                ActivityOption(title: wrestling ? "Takedowns" : "Positional", subtitle: wrestling ? "Shots, sprawls, chain wrestling" : "Start from a position, fight to escape or finish",
                               icon: "arrow.triangle.2.circlepath", category: .bjj, drill: .technical, sport: sport, lengths: grappling),
                ActivityOption(title: wrestling ? "Live wrestling" : "Rolling", subtitle: "Full live rounds", icon: "flame.fill",
                               category: .bjj, drill: .hardSparring, sport: sport, lengths: grappling)
            ]
        }

        var list: [ActivityOption] = [
            ActivityOption(title: "Bag work", subtitle: "The coach calls combos for you", icon: "figure.boxing",
                           category: .heavyBag, drill: .bagWork, bagCoach: true, sport: sport, lengths: bag),
            ActivityOption(title: sport == "Boxing" ? "Mitts" : "Pads", subtitle: "With your coach or partner", icon: "hand.raised.fill",
                           category: .padWork, drill: .bagWork, sport: sport, lengths: fightLike),
            ActivityOption(title: "Shadowboxing", subtitle: "Technique, footwork, head movement", icon: "figure.kickboxing",
                           category: own, drill: .technical, sport: sport, lengths: technique)
        ]
        if sport == "Muay Thai" {
            list.append(ActivityOption(title: "Clinch", subtitle: "Plum, knees, sweeps", icon: "figure.wrestling",
                                       category: .muayThai, drill: .technical, sport: sport, lengths: technique))
        }
        if sport == "MMA" {
            list.append(ActivityOption(title: "Grappling", subtitle: "Takedowns and ground work", icon: "figure.wrestling",
                                       category: .bjj, drill: .technical, sport: sport, lengths: grappling))
        }
        list.append(ActivityOption(title: "Sparring", subtitle: "Live rounds with a partner", icon: "person.2.fill",
                                   category: .sparring, drill: .hardSparring, sport: sport, lengths: fightLike))
        list.append(ActivityOption(title: "Technique", subtitle: "Class or drilling, controlled pace", icon: "graduationcap.fill",
                                   category: own, drill: .technical, sport: sport))
        return list
    }

    // MARK: Roadwork

    static let roadwork: [ActivityOption] = [
        ActivityOption(title: "Easy run", subtitle: "Zone 2. Builds the engine for late rounds", icon: "figure.run",
                       category: .roadwork, drill: .aerobicZ2),
        ActivityOption(title: "Fight rounds run", subtitle: "Run hard for a round, jog the rest", icon: "timer",
                       category: .roadwork, drill: .intervals,
                       lengths: [LengthOption(title: "5 rounds", rounds: 5, work: 180, rest: 60),
                                 LengthOption(title: "3 rounds", rounds: 3, work: 180, rest: 60)]),
        ActivityOption(title: "Sprints", subtitle: "All-out bursts, full recovery", icon: "hare.fill",
                       category: .roadwork, drill: .intervals,
                       lengths: [LengthOption(title: "8 sprints", rounds: 8, work: 20, rest: 100),
                                 LengthOption(title: "6 × 30 s", rounds: 6, work: 30, rest: 90)]),
        ActivityOption(title: "Hill sprints", subtitle: "Sprint up, walk down", icon: "mountain.2.fill",
                       category: .roadwork, drill: .intervals,
                       lengths: [LengthOption(title: "8 hills", rounds: 8, work: 15, rest: 90),
                                 LengthOption(title: "10 hills", rounds: 10, work: 20, rest: 100)]),
        ActivityOption(title: "Recovery walk", subtitle: "Easy day, loosen up", icon: "figure.walk",
                       category: .walk, drill: .aerobicZ2)
    ]

    // MARK: Conditioning (timed ones; plyo, mix, plans and the test have their own screens)

    static let jumpRope = ActivityOption(
        title: "Jump rope", subtitle: "Rounds of skipping, fighter style", icon: "figure.jumprope",
        category: .conditioning, drill: .intervals,
        lengths: [LengthOption(title: "3 rounds", rounds: 3, work: 180, rest: 60),
                  LengthOption(title: "5 rounds", rounds: 5, work: 180, rest: 60),
                  LengthOption(title: "Tabata", rounds: 8, work: 20, rest: 10)])

    static let circuit = ActivityOption(
        title: "Circuit", subtitle: "Bodyweight HIIT: burpees, sprawls, squats", icon: "flame.fill",
        category: .conditioning, drill: .intervals,
        lengths: [LengthOption(title: "10 × 45 s", rounds: 10, work: 45, rest: 15),
                  LengthOption(title: "Tabata", rounds: 8, work: 20, rest: 10),
                  LengthOption(title: "5 × 3 min", rounds: 5, work: 180, rest: 60)])

    static let fitnessTest = ActivityOption(
        title: "Fitness test", subtitle: "30 min. Sets your heart-rate zones", icon: "stopwatch.fill",
        category: .lthrTest, drill: .lthrProtocol)
}
