import SwiftUI

// MARK: - Keyboard

extension View {
    /// A Done button above number pads (which have no return key), and tap-away to close the keyboard.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
                    .fontWeight(.semibold)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

@MainActor
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// MARK: - Shared chips

struct ChoiceChip: View {
    let title: String
    var icon: String? = nil
    let selected: Bool
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title)
                if let badge {
                    Text(badge).font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red, in: Capsule()).foregroundStyle(.white)
                }
                if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(selected ? Color.red.opacity(0.16) : Color(.tertiarySystemFill), in: Capsule())
            .foregroundStyle(selected ? Color.red : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Multi-select disciplines (first = main) and the gear the fighter owns.
struct TrainingChoices: View {
    @Binding var disciplines: [String]
    @Binding var equipment: [Equipment]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What do you train?").font(.headline)
            FlowLayout(spacing: 8) {
                ForEach(DisciplineRules.all, id: \.self) { d in
                    ChoiceChip(title: d, selected: disciplines.contains(d), badge: disciplines.first == d ? "MAIN" : nil) {
                        if let i = disciplines.firstIndex(of: d) {
                            if disciplines.count > 1 { disciplines.remove(at: i) }
                        } else {
                            disciplines.append(d)
                        }
                    }
                }
            }
            Text("Your first pick is your main discipline. Only these show up in workouts and combos.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Your gear").font(.headline).padding(.top, 6)
            FlowLayout(spacing: 8) {
                ForEach(Equipment.allCases) { e in
                    ChoiceChip(title: e.rawValue, icon: e.icon, selected: equipment.contains(e)) {
                        if let i = equipment.firstIndex(of: e) { equipment.remove(at: i) } else { equipment.append(e) }
                    }
                }
            }
        }
    }
}

/// You tab: change disciplines, gear and plyo level in one place.
struct TrainingSettingsView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var session: WorkoutSession

    var body: some View {
        let binding = Binding<AthleteProfile>(get: { workoutStore.activeProfile }, set: { new in
            var p = new
            if p.disciplines != workoutStore.activeProfile.disciplines { p.setDisciplines(p.disciplines) }
            workoutStore.activeProfile = p
            session.syncFromProfile()
        })
        Form {
            Section {
                TrainingChoices(disciplines: Binding(get: { binding.wrappedValue.trainedDisciplines },
                                                     set: { binding.wrappedValue.disciplines = $0 }),
                                equipment: binding.equipment)
                    .padding(.vertical, 6)
            }
            Section {
                Picker("Plyometrics level", selection: binding.plyoLevel) {
                    ForEach(PlyoLevel.allCases) { Text($0.rawValue).tag($0) }
                }
            } footer: {
                Text("Sets how many jumps a plyo session can have: about \(binding.wrappedValue.plyoLevel.maxContacts) landings at most.")
            }
        }
        .navigationTitle("My Training")
    }
}

// MARK: - Plyo picker with gear checklist

struct PlyoPickerSheet: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var navigation: AppNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var variant: PlyoVariant
    @State private var gear: Set<Equipment> = []
    @State private var level: PlyoLevel = .intermediate
    @State private var loaded = false

    init(initial: PlyoVariant = .power) {
        _variant = State(initialValue: initial)
    }

    var body: some View {
        let profile = workoutStore.activeProfile
        let plan = PlyoLibrary.plan(variant, gear: gear, level: level, format: profile.fightFormat)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(PlyoVariant.allCases) { v in
                        Button {
                            variant = v
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: v.icon).font(.title2).foregroundStyle(.red).frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.rawValue).font(.headline).foregroundStyle(.primary)
                                    Text(v.blurb).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Image(systemName: variant == v ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(variant == v ? Color.red : Color.secondary)
                            }
                            .card(tint: variant == v ? .red : nil)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Got it with you today?").font(.headline)
                        FlowLayout(spacing: 8) {
                            ForEach(profile.equipment) { e in
                                ChoiceChip(title: e.rawValue, icon: e.icon, selected: gear.contains(e)) {
                                    if gear.contains(e) { gear.remove(e) } else { gear.insert(e) }
                                }
                            }
                        }
                        if profile.equipment.isEmpty {
                            Text("No gear needed. Add gear in You → My Training.").font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Level", selection: $level) {
                            ForEach(PlyoLevel.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    .card()

                    let landings = PlyoLibrary.contacts(plan)
                    Text("About \(plan.plannedSeconds / 60) min" + (landings > 0 ? " · \(landings) landings" : ""))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Button {
                        navigation.run(plan)
                        dismiss()
                    } label: {
                        Text("Load \(variant.rawValue)").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)

                    Text("Plyos come first in a session, when you're fresh. Land soft and stop if a jump hurts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Plyometrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                gear = Set(profile.equipment)
                level = profile.plyoLevel
            }
        }
    }
}

// MARK: - Mix builder

struct MixBuilderSheet: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var navigation: AppNavigation
    @EnvironmentObject var undo: UndoCenter
    @Environment(\.dismiss) private var dismiss
    @State private var items: [MixItem] = MixBuilder.presets[0].items
    @State private var gear: Set<Equipment> = []
    @State private var loaded = false
    @State private var saved = false

    var body: some View {
        let profile = workoutStore.activeProfile
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(MixBuilder.presets.indices, id: \.self) { i in
                                let preset = MixBuilder.presets[i]
                                ChoiceChip(title: preset.name, selected: items.map(\.kind) == preset.items.map(\.kind)) {
                                    items = preset.items
                                }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section {
                    ForEach($items) { $item in
                        HStack(spacing: 12) {
                            Image(systemName: item.kind.icon).foregroundStyle(.red).frame(width: 26)
                            Text(item.kind.rawValue).font(.body.weight(.semibold))
                            Spacer()
                            if let v = item.kind.plyo {
                                Text("~\(PlyoLibrary.plan(v, gear: gear, level: profile.plyoLevel, format: profile.fightFormat).plannedSeconds / 60 - 8) min")
                                    .foregroundStyle(.secondary)
                            } else {
                                Stepper("\(item.minutes) min", value: $item.minutes, in: 2...90, step: item.minutes < 10 ? 1 : 5)
                                    .fixedSize()
                                    .monospacedDigit()
                            }
                        }
                    }
                    .onDelete { offsets in
                        let before = items
                        items.remove(atOffsets: offsets)
                        undo.show("Removed from mix") { items = before }
                    }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                    Menu {
                        ForEach(MixItem.Kind.allCases) { k in
                            Button { items.append(MixItem(k)) } label: { Label(k.rawValue, systemImage: k.icon) }
                        }
                    } label: {
                        Label("Add", systemImage: "plus.circle.fill").font(.body.weight(.semibold))
                    }
                } header: {
                    Text("Total about \(totalMinutes(profile)) min")
                } footer: {
                    Text("Swipe to remove, hold and drag to reorder.")
                }

                if items.contains(where: { $0.kind.plyo != nil || $0.kind == .rope || $0.kind == .bag }) {
                    Section("Got it with you today?") {
                        FlowLayout(spacing: 8) {
                            ForEach(profile.equipment) { e in
                                ChoiceChip(title: e.rawValue, icon: e.icon, selected: gear.contains(e)) {
                                    if gear.contains(e) { gear.remove(e) } else { gear.insert(e) }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Button {
                        navigation.run(MixBuilder.plan(items, profile: profile, gear: gear))
                        dismiss()
                    } label: {
                        Text("Load Mix").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(items.isEmpty)
                    .listRowBackground(Color.clear)
                    Button(saved ? "Saved to Plans" : "Save as a Plan") {
                        var plan = MixBuilder.plan(items, profile: profile, gear: gear,
                                                   title: items.map(\.kind.rawValue).prefix(3).joined(separator: " + "))
                        plan.id = UUID()
                        workoutStore.upsertPlan(plan)
                        saved = true
                    }
                    .disabled(items.isEmpty || saved)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
            .undoHost()
            .navigationTitle("Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                gear = Set(profile.equipment)
            }
            .onChange(of: items) { _, _ in saved = false }
        }
    }

    private func totalMinutes(_ profile: AthleteProfile) -> Int {
        items.reduce(0) { sum, item in
            if let v = item.kind.plyo {
                return sum + max(5, PlyoLibrary.plan(v, gear: gear, level: profile.plyoLevel, format: profile.fightFormat).plannedSeconds / 60 - 8)
            }
            return sum + item.minutes
        }
    }
}
