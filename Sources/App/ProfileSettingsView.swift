import SwiftUI

struct ProfileSettingsView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @State private var showingNewProfileAlert = false
    @State private var newFighterName = ""

    enum Field: Hashable {
        case name, weight, targetWeight, height
    }
    @FocusState private var focusedField: Field?

    var body: some View {
        let profile = workoutStore.activeProfile
        let zones = profile.activeZones
        let minLTHR = profile.restingHR + 25
        let maxLTHR = max(minLTHR, profile.effectiveMaxHR - 3)
        let z1Upper = max(80, zones.z2Max - 5)
        let z2Lower = zones.z1Max + 5
        let z2Upper = max(z2Lower, zones.z3Max - 5)
        let z3Lower = zones.z2Max + 5
        let z3Upper = max(z3Lower, zones.z4Max - 5)
        let z4Lower = zones.z3Max + 5
        let z4Upper = max(z4Lower, profile.effectiveMaxHR - 5)

        NavigationStack {
            Form {
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

                Section("Biometrics & Physiology (Clamped Safe Bounds)") {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Name", text: binding(for: \.name))
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .name)
                    }

                    Picker("Sex", selection: binding(for: \.sex)) {
                        ForEach(BiologicalSex.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }

                    Stepper("Age: \(profile.age) yrs", value: binding(for: \.age), in: 13...85)

                    HStack {
                        Text("Current Weight (35–200 kg)")
                        Spacer()
                        TextField("kg", value: binding(for: \.weightKg), format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .focused($focusedField, equals: .weight)
                    }

                    HStack {
                        Text("Height (120–240 cm)")
                        Spacer()
                        TextField("cm", value: binding(for: \.heightCm), format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .focused($focusedField, equals: .height)
                    }

                    Stepper("Resting HR: \(profile.restingHR) BPM", value: binding(for: \.restingHR), in: 30...110)

                    Toggle("Auto Max HR (Tanaka: \(Int(round(208.0 - 0.7 * Double(profile.age)))))", isOn: binding(for: \.useAutoMaxHR))

                    if !profile.useAutoMaxHR {
                        let minMaxHR = profile.restingHR + 35
                        Stepper("Custom Max HR: \(profile.maxHR) BPM", value: binding(for: \.maxHR), in: minMaxHR...max(minMaxHR, 230))
                    }
                }

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
                            .focused($focusedField, equals: .targetWeight)
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
                        Stepper("Lactate Threshold (LTHR): \(profile.lactateThresholdHR) BPM", value: binding(for: \.lactateThresholdHR), in: minLTHR...maxLTHR)
                    }

                    if profile.zoneMethod == .manual {
                        Stepper("Z1 Ceiling: \(zones.z1Max) BPM", value: binding(for: \.manualZones.z1Max), in: 80...z1Upper)
                        Stepper("Z2 Ceiling: \(zones.z2Max) BPM", value: binding(for: \.manualZones.z2Max), in: z2Lower...z2Upper)
                        Stepper("Z3 Ceiling: \(zones.z3Max) BPM", value: binding(for: \.manualZones.z3Max), in: z3Lower...z3Upper)
                        Stepper("Z4 Ceiling: \(zones.z4Max) BPM", value: binding(for: \.manualZones.z4Max), in: z4Lower...z4Upper)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        zoneRow(label: "Zone 1 • Recovery", range: "< \(zones.z1Max) BPM", color: .blue)
                        zoneRow(label: "Zone 2 • Aerobic Base", range: "\(zones.z1Max + 1)–\(zones.z2Max) BPM", color: .green)
                        zoneRow(label: "Zone 3 • Tempo", range: "\(zones.z2Max + 1)–\(zones.z3Max) BPM", color: .yellow)
                        zoneRow(label: "Zone 4 • Threshold", range: "\(zones.z3Max + 1)–\(zones.z4Max) BPM", color: .orange)
                        zoneRow(label: "Zone 5 • Anaerobic Peak", range: "> \(zones.z4Max) BPM", color: .red)
                    }
                    .padding(.vertical, 4)
                }

                Section("iPhone Files App & Lossless Archive (.cspk)") {
                    HStack {
                        Text("Files App Folder")
                        Spacer()
                        Text("On My iPhone / Coospo Workout")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Compressed (>7 Days Old)")
                        Spacer()
                        Text("\(workoutStore.compressedArchiveCount) workouts")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                    }
                    HStack {
                        Text("Total Disk Footprint")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: workoutStore.savedStorageBytes, countStyle: .file))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button("Run Lossless Archive Check Now") {
                        workoutStore.runLosslessAutoCompression()
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Fighter & Zones")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
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
                updated.sanitize()
                workoutStore.activeProfile = updated
            }
        )
    }
}