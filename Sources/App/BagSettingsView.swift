import SwiftUI

struct BagSettingsSheet: View {
    @Binding var prefs: BagPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Callouts", selection: $prefs.mode) {
                        ForEach(BagCoachMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Tempo", selection: $prefs.tempo) {
                        ForEach(BagTempo.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Number calls (1 = jab, 2 = cross…)", isOn: $prefs.numberCalls)
                } header: {
                    Text("Calling")
                } footer: {
                    Text("Tempo is the reset time after you've thrown the combo. Burnout keeps combos short and resets fast. The next combo is only called once you've heard the last one.")
                }

                Section("You") {
                    Picker("Stance", selection: $prefs.stance) {
                        ForEach(Stance.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Level", selection: $prefs.difficulty) {
                        ForEach(BagDifficulty.allCases) { d in
                            Text("\(d.rawValue) (\(d.lengthRange.lowerBound)–\(d.lengthRange.upperBound) strikes)").tag(d)
                        }
                    }
                }

                Section("Strikes") {
                    Toggle("Kicks & teeps", isOn: $prefs.includeKicks)
                    Toggle("Knees & elbows", isOn: $prefs.includeKneesElbows)
                    Toggle("Defence & counters", isOn: $prefs.includeDefense)
                    Toggle("Dutch finish (end on a kick)", isOn: $prefs.dutchFinish)
                        .disabled(!prefs.includeKicks)
                }

                Section {
                    Picker("Total time", selection: $prefs.totalMinutes) {
                        ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    Picker("Round", selection: $prefs.workSeconds) {
                        ForEach([30, 60, 90, 120, 180, 240, 300], id: \.self) { Text(Self.clock($0)).tag($0) }
                    }
                    Picker("Rest", selection: $prefs.restSeconds) {
                        ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text(Self.clock($0)).tag($0) }
                    }
                } header: {
                    Text("Session")
                } footer: {
                    Text("\(prefs.estimatedTotalRounds) rounds. You'll hear \"Final round\", a 10-second clapper, a triple bell at the end, and a \"Punch out!\" flurry in each round's last 10 seconds.")
                }

                Section {
                    Toggle("Adaptive tempo", isOn: $prefs.adaptiveTempo)
                } footer: {
                    Text("With a coach plan loaded, the pace speeds up when you're below the target heart-rate band and eases off when you're above it.")
                }

                Section {
                    NavigationLink {
                        CustomComboEditor(prefs: $prefs)
                    } label: {
                        LabeledContent("My combos", value: "\(prefs.customCombos.count)")
                    }
                    Toggle("Only use my combos", isOn: $prefs.customOnly)
                        .disabled(prefs.customCombos.isEmpty)
                } header: {
                    Text("Custom drills")
                } footer: {
                    Text("Your combos are mixed into the rotation, or used exclusively for focused drilling.")
                }
            }
            .navigationTitle("Bag Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    static func clock(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct CustomComboEditor: View {
    @Binding var prefs: BagPreferences

    var body: some View {
        ComboListEditor(combos: $prefs.customCombos, stance: prefs.stance, numbers: prefs.numberCalls)
            .navigationTitle("My Combos")
            .onChange(of: prefs.customCombos.count) { _, count in
                if count == 0 { prefs.customOnly = false }
            }
    }
}
