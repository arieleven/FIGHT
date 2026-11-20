import SwiftUI

struct ProfileSettingsView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @State private var showingNewProfileAlert = false
    @State private var newFighterName = ""

    var body: some View {
        let profile = workoutStore.activeProfile
        let zones = profile.activeZones

        NavigationStack {
            Form {
                // Multi-Person Switcher
                Section("Active Fighter Profile") {
                    Picker("Fighter", selection: $workoutStore.activeProfileID) {
                        ForEach(workoutStore.profiles) { p in
                            Text(p.name).tag(p.id)
                        }
                    }

                    Button {
                        newFighterName = ""
                        showingNewProfileAlert = true
                    } label: {
                        Label("Add Another Person / Sparring Partner", systemImage: "person.badge.plus")
                    }

                    if workoutStore.profiles.count > 1 {
                        Button(role: .destructive) {
                            workoutStore.deleteProfile(profile)
                        } label: {
                            Label("Delete Current Profile", systemImage: "trash")
                        }
                    }
                }

                // Biometrics
                Section("Biometrics & Physiology") {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Name", text: binding(for: \.name))
                            .multilineTextAlignment(.trailing)
                    }

                    Picker("Sex", selection: binding(for: \.sex)) {
                        ForEach(BiologicalSex.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }

                    Stepper("Age: \(profile.age) yrs", value: binding(for: \.age), in: 14...80)

                    HStack {
                        Text("Current Weight (kg)")
                        Spacer()
                        TextField("kg", value: binding(for: \.weightKg), format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    HStack {
                        Text("Height (cm)")
                        Spacer()
                        TextField("cm", value: binding(for: \.heightCm), format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    Stepper("Resting HR: \(profile.restingHR) BPM", value: binding(for: \.restingHR), in: 35...100)

                    Toggle("Auto Max HR (Tanaka: \(Int(round(208.0 - 0.7 * Double(profile.age)))))", isOn: binding(for: \.useAutoMaxHR))

                    if !profile.useAutoMaxHR {
                        Stepper("Custom Max HR: \(profile.maxHR) BPM", value: binding(for: \.maxHR), in: 140...225)
                    }
                }

                // Fight Cut & Weight Goals
                Section("Fight Camp & Weight Goal") {
                    Picker("Camp Phase", selection: binding(for: \.campPhase)) {
                        ForEach(CampPhase.allCases) { phase in
                            Text(phase.rawValue).tag(phase)
                        }
                    }

                    HStack {
                        Text("Target Fight Weight (kg)")
                        Spacer()
                        TextField("Target kg", value: binding(for: \.targetFightWeightKg), format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    HStack {
                        Text("Weight to Cut / Gain")
                        Spacer()
                        let delta = profile.weightDeltaKg
                        Text(delta > 0 ? String(format: "-%.1f kg to cut", delta) : String(format: "+%.1f kg buffer", abs(delta)))
                            .fontWeight(.semibold)
                            .foregroundStyle(delta > 0 ? .orange : .green)
                    }

                    HStack {
                        Text("Daily Calorie Target")
                        Spacer()
                        Text("\(profile.dailyCalorieTarget) kcal / day")
                            .fontWeight(.bold)
                            .foregroundStyle(.cyan)
                    }

                    Text(profile.campPhase.adviceTag)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Heart Rate Zone Calculation Method & Custom Editor
                Section("Heart Rate Zone Calculation") {
                    Picker("Formula", selection: binding(for: \.zoneMethod)) {
                        ForEach(ZoneCalculationMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }

                    Text(profile.zoneMethod.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if profile.zoneMethod == .lactateThreshold {
                        Stepper("Lactate Threshold (LTHR): \(profile.lactateThresholdHR) BPM", value: binding(for: \.lactateThresholdHR), in: 120...205)
                    }

                    if profile.zoneMethod == .manual {
                        Stepper("Z1 Ceiling: \(profile.manualZones.z1Max) BPM", value: binding(for: \.manualZones.z1Max), in: 90...160)
                        Stepper("Z2 Ceiling: \(profile.manualZones.z2Max) BPM", value: binding(for: \.manualZones.z2Max), in: 105...175)
                        Stepper("Z3 Ceiling: \(profile.manualZones.z3Max) BPM", value: binding(for: \.manualZones.z3Max), in: 120...190)
                        Stepper("Z4 Ceiling: \(profile.manualZones.z4Max) BPM", value: binding(for: \.manualZones.z4Max), in: 135...205)
                    }

                    // Active Zone Preview
                    VStack(alignment: .leading, spacing: 8) {
                        zoneRow(label: "Zone 1 • Recovery", range: "< \(zones.z1Max) BPM", color: .blue)
                        zoneRow(label: "Zone 2 • Aerobic Base", range: "\(zones.z1Max + 1)–\(zones.z2Max) BPM", color: .green)
                        zoneRow(label: "Zone 3 • Tempo", range: "\(zones.z2Max + 1)–\(zones.z3Max) BPM", color: .yellow)
                        zoneRow(label: "Zone 4 • Threshold", range: "\(zones.z3Max + 1)–\(zones.z4Max) BPM", color: .orange)
                        zoneRow(label: "Zone 5 • Anaerobic Peak", range: "> \(zones.z4Max) BPM", color: .red)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Fighter & Zones")
            .alert("New Fighter Profile", isPresented: $showingNewProfileAlert) {
                TextField("Fighter Name", text: $newFighterName)
                Button("Create") {
                    workoutStore.addProfile(name: newFighterName)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func zoneRow(label: String, range: String, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.subheadline)
            Spacer()
            Text(range).font(.subheadline.monospacedDigit().weight(.semibold))
        }
    }

    private func binding<T>(for keyPath: WritableKeyPath<AthleteProfile, T>) -> Binding<T> {
        Binding(
            get: { workoutStore.activeProfile[keyPath: keyPath] },
            set: { newValue in
                var updated = workoutStore.activeProfile
                updated[keyPath: keyPath] = newValue
                workoutStore.activeProfile = updated
            }
        )
    }
}