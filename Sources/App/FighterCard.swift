import SwiftUI
import PhotosUI

// MARK: - Card

/// Live numbers FIGHT adds to the card.
struct FighterCardStats {
    var fightFitness: Int?
    var gasTank: String?
    var bestRecovery: Int?

    @MainActor
    static func current(store: WorkoutStore, profile: AthleteProfile) -> FighterCardStats {
        let mine = store.workouts.filter { $0.profileID == profile.id }
        let report = profile.id == store.activeProfileID
            ? store.coachReportNow()
            : CoachEngine.buildReport(workouts: store.workouts, readings: store.activeReadings, profile: profile,
                                      resolveSamples: { store.resolvedSamples(for: $0) })
        let best = Records.bestRecovery(workouts: store.workouts, profileID: profile.id)
        return FighterCardStats(fightFitness: report.hasEnoughData ? report.fightFitness : nil,
                                gasTank: GasTank.evaluate(workouts: mine, profile: profile)?.headline,
                                bestRecovery: best > 0 ? best : nil)
    }
}

extension FighterBio.Corner {
    var color: Color {
        switch self {
        case .red: return Color(red: 0.91, green: 0.15, blue: 0.18)
        case .blue: return Color(red: 0.13, green: 0.38, blue: 0.86)
        case .gold: return Color(red: 0.84, green: 0.64, blue: 0.24)
        }
    }
}

/// UFC-style athlete card: photo, name, record, tale-of-the-tape details and FIGHT's live stats.
struct FighterProfileCard: View {
    let profile: AthleteProfile
    let photo: UIImage?
    let stats: FighterCardStats
    var hideName = false

    private var bio: FighterBio { profile.bio }
    private var accent: Color { bio.corner.color }
    private let panel = Color(red: 0.05, green: 0.055, blue: 0.07)

    private func heavy(_ s: CGFloat) -> Font { .system(size: s, weight: .heavy).width(.compressed) }
    private func cond(_ s: CGFloat, _ w: Font.Weight = .semibold) -> Font { .system(size: s, weight: w).width(.condensed) }

    private var division: FighterBio.WeightClass {
        bio.weightClass(fightWeightKg: profile.targetFightWeightKg)
    }

    private var displayName: String {
        if hideName { return bio.nickname.isEmpty ? "FIGHTER" : bio.nickname }
        return profile.name
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            recordRow
            detailsGrid
            if !liveStats.isEmpty { liveStrip }
            HStack {
                Text("\(bio.corner.rawValue.uppercased()) CORNER")
                Spacer()
                Text("COACHED BY FIGHT")
            }
            .font(cond(12, .bold))
            .tracking(0.6)
            .foregroundStyle(bio.corner == .gold ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(accent)
        }
        .frame(width: 320)
        .background(panel)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .environment(\.colorScheme, .dark)
    }

    // Photo with the name over it.

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [accent.opacity(0.55), panel], startPoint: .top, endPoint: .bottom)
                        Image(systemName: "figure.kickboxing")
                            .font(.system(size: 120, weight: .regular))
                            .foregroundStyle(.white.opacity(0.18))
                    }
                }
            }
            .frame(width: 320, height: 300)
            .clipped()

            LinearGradient(colors: [.clear, panel.opacity(0.85), panel], startPoint: .center, endPoint: .bottom)
                .frame(height: 300)

            VStack(alignment: .leading, spacing: 2) {
                if !bio.nickname.isEmpty && !hideName {
                    Text("“\(bio.nickname.uppercased())”").font(cond(17, .bold)).foregroundStyle(accent)
                }
                Text(displayName.uppercased())
                    .font(heavy(56)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.45)
                HStack(spacing: 6) {
                    if !bio.country.isEmpty {
                        Text(FighterBio.flag(bio.country))
                        Text((Locale.current.localizedString(forRegionCode: bio.country) ?? bio.country).uppercased())
                    }
                    Text(bio.discipline.uppercased()).foregroundStyle(.white.opacity(0.7))
                }
                .font(cond(14, .medium))
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .overlay(alignment: .topLeading) {
            Text("\(division.name.uppercased()) · \(bio.level.rawValue.uppercased())")
                .font(cond(12, .bold))
                .tracking(0.5)
                .foregroundStyle(bio.corner == .gold ? Color.black : Color.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(accent)
                .padding(12)
        }
    }

    private var recordRow: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                Text(bio.record).font(heavy(46)).foregroundStyle(.white).monospacedDigit()
                Text("W-L-D").font(cond(12, .bold)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            if let f = bio.finishesText {
                Text(f.uppercased()).font(cond(14, .bold)).foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(accent).frame(height: 3) }
    }

    private struct Detail: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private var details: [Detail] {
        let reach = bio.reachCm ?? profile.heightCm
        let reachText: String = profile.heightImperial ? "\(Int((reach / HeightUnits.cmPerInch).rounded()))″" : "\(Int(reach.rounded())) cm"
        return [
            Detail(label: "Height", value: HeightUnits.text(profile.heightCm, profile.heightImperial)),
            Detail(label: "Reach", value: reachText),
            Detail(label: "Stance", value: profile.bagPreferences.stance.rawValue),
            Detail(label: "Age", value: "\(profile.age)"),
            Detail(label: "Weight", value: bio.effectiveRules.limitText(division, imperial: profile.useImperial)),
            Detail(label: "Gym", value: bio.gym.isEmpty ? "—" : bio.gym)
        ]
    }

    private var detailsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 0) {
            ForEach(details) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label.uppercased()).font(cond(11, .bold)).foregroundStyle(.white.opacity(0.55))
                    Text(item.value).font(cond(17, .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
            }
        }
        .padding(.horizontal, 4)
    }

    private var liveStats: [(String, String)] {
        var s: [(String, String)] = []
        if bio.showFightFitness, let f = stats.fightFitness { s.append(("\(f)", "fight fitness")) }
        if bio.showGasTank, let g = stats.gasTank {
            s.append((g.hasPrefix("Ready for ") ? String(g.dropFirst(10)) : "Building", "gas tank"))
        }
        if bio.showBestRecovery, let r = stats.bestRecovery { s.append(("−\(r)", "best recovery")) }
        return s
    }

    private var liveStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(liveStats.enumerated()), id: \.offset) { i, item in
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.0).font(heavy(26)).foregroundStyle(panel).lineLimit(1).minimumScaleFactor(0.6)
                    Text(item.1).font(cond(11, .medium)).foregroundStyle(panel.opacity(0.7)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(alignment: .trailing) {
                    if i < liveStats.count - 1 { Rectangle().fill(Color.black.opacity(0.12)).frame(width: 1) }
                }
            }
        }
        .background(Color.white)
        .padding(.top, 6)
    }
}

// MARK: - Row in the You tab

struct FighterCardRow: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @State private var editing = false

    var body: some View {
        let p = workoutStore.activeProfile
        let photo = workoutStore.photoVersion >= 0 ? workoutStore.fighterPhoto(for: p.id) : nil
        Button {
            editing = true
        } label: {
            HStack(spacing: 14) {
                Group {
                    if let photo {
                        Image(uiImage: photo).resizable().scaledToFill()
                    } else {
                        Image(systemName: "figure.kickboxing").font(.title2).foregroundStyle(.white)
                    }
                }
                .frame(width: 54, height: 54)
                .background(p.bio.corner.color)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fighter Card").font(.headline).foregroundStyle(.primary)
                    Text("\(p.bio.record) · \(p.bio.weightClass(fightWeightKg: p.targetFightWeightKg).name)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Edit").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $editing) { FighterCardEditor() }
    }
}

// MARK: - Editor

struct FighterCardEditor: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AthleteProfile()
    @State private var loaded = false
    @State private var photo: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var stats = FighterCardStats()
    @State private var sharing = false
    @State private var photoChanged = false

    private static let disciplines = ["Kickboxing", "Muay Thai", "MMA", "Boxing", "K-1", "Karate", "Taekwondo", "BJJ", "Wrestling"]
    private struct Country: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    private static let countries: [Country] = Locale.Region.isoRegions
        .map { $0.identifier }
        .filter { $0.count == 2 && $0.allSatisfy { $0.isLetter } }
        .compactMap { code in Locale.current.localizedString(forRegionCode: code).map { Country(code: code, name: $0) } }
        .sorted { $0.name < $1.name }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FighterProfileCard(profile: draft, photo: photo, stats: stats)
                        .scaleEffect(0.86)
                        .frame(height: 540)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                Section("Photo") {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(photo == nil ? "Choose Photo" : "Change Photo", systemImage: "person.crop.square")
                    }
                    if photo != nil {
                        Button("Remove Photo", role: .destructive) {
                            photo = nil
                            photoChanged = true
                        }
                    }
                }

                Section("Fighter") {
                    TextField("Name", text: $draft.name)
                    TextField("Nickname (optional)", text: $draft.bio.nickname)
                        .textInputAutocapitalization(.words)
                    Picker("Discipline", selection: $draft.bio.discipline) {
                        ForEach(Self.disciplines, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Country", selection: $draft.bio.country) {
                        Text("None").tag("")
                        ForEach(Self.countries) { c in
                            Text("\(FighterBio.flag(c.code)) \(c.name)").tag(c.code)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    TextField("Gym (optional)", text: $draft.bio.gym)
                }

                Section("Record") {
                    Picker("Level", selection: $draft.bio.level) {
                        ForEach(FighterBio.Level.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper("Wins: \(draft.bio.wins)", value: $draft.bio.wins, in: 0...200)
                    Stepper("Losses: \(draft.bio.losses)", value: $draft.bio.losses, in: 0...200)
                    Stepper("Draws: \(draft.bio.draws)", value: $draft.bio.draws, in: 0...200)
                    Stepper("Wins by KO / TKO: \(draft.bio.finishes)", value: $draft.bio.finishes, in: 0...max(0, draft.bio.wins))
                }

                Section {
                    Picker("Weight classes", selection: $draft.bio.rules) {
                        Text("Auto (\(FighterBio.WeightRules.forDiscipline(draft.bio.discipline).rawValue))")
                            .tag(Optional<FighterBio.WeightRules>.none)
                        ForEach(FighterBio.WeightRules.allCases) { r in
                            Text(r.rawValue).tag(Optional(r))
                        }
                    }
                    Picker("Division", selection: $draft.bio.divisionName) {
                        let rules = draft.bio.effectiveRules
                        Text("Auto (\(rules.suggested(forKg: draft.targetFightWeightKg).name))")
                            .tag(Optional<String>.none)
                        ForEach(rules.classes) { c in
                            Text("\(c.name) · \(rules.limitText(c, imperial: draft.useImperial))").tag(Optional(c.name))
                        }
                    }
                    Stepper(value: reachBinding, in: reachRange, step: draft.heightImperial ? HeightUnits.cmPerInch : 1) {
                        HStack {
                            Text("Reach")
                            Spacer()
                            Text(reachText).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } header: {
                    Text("Tale of the tape")
                } footer: {
                    Text("Weight classes follow your discipline's usual standard (a K-1 middleweight is 75 kg, an MMA one 83.9 kg). Auto division uses your fight-weight target.")
                }

                Section {
                    Picker("Corner", selection: $draft.bio.corner) {
                        ForEach(FighterBio.Corner.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Show Fight Fitness", isOn: $draft.bio.showFightFitness)
                    Toggle("Show Gas Tank", isOn: $draft.bio.showGasTank)
                    Toggle("Show best recovery", isOn: $draft.bio.showBestRecovery)
                } header: {
                    Text("Look")
                } footer: {
                    Text("Live stats appear once FIGHT has enough sessions to rate you.")
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .navigationTitle("Fighter Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DiscardChangesButton(hasChanges: hasChanges) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        save()
                        sharing = true
                    } label: {
                        Label("Share to Story", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $sharing) { StoryShareSheet(focus: .profile) }
            .onChange(of: draft.bio.effectiveRules) { _, rules in
                // A division name from another standard doesn't carry over.
                if rules.weightClass(named: draft.bio.divisionName) == nil { draft.bio.divisionName = nil }
            }
            .onChange(of: photoItem) { _, item in
                Task {
                    guard let item, let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) else { return }
                    photo = img
                    photoChanged = true
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                draft = workoutStore.activeProfile
                photo = workoutStore.fighterPhoto(for: draft.id)
                stats = FighterCardStats.current(store: workoutStore, profile: draft)
            }
        }
    }

    private var reachBinding: Binding<Double> {
        Binding(get: { draft.bio.reachCm ?? draft.heightCm }, set: { draft.bio.reachCm = $0 })
    }

    private var reachRange: ClosedRange<Double> { 120...240 }

    private var reachText: String {
        let r = draft.bio.reachCm ?? draft.heightCm
        return draft.heightImperial ? "\(Int((r / HeightUnits.cmPerInch).rounded()))″" : "\(Int(r.rounded())) cm"
    }

    private var hasChanges: Bool {
        guard loaded else { return false }
        let p = workoutStore.activeProfile
        return photoChanged || draft.bio != p.bio || draft.name != p.name
    }

    private func save() {
        if photoChanged {
            workoutStore.setFighterPhoto(photo, for: draft.id)
            photoChanged = false
        }
        var p = workoutStore.activeProfile
        let trimmed = draft.name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { p.name = trimmed }
        p.bio = draft.bio
        p.bio.nickname = draft.bio.nickname.trimmingCharacters(in: .whitespaces)
        p.bio.finishes = min(p.bio.finishes, p.bio.wins)
        workoutStore.activeProfile = p
    }
}
