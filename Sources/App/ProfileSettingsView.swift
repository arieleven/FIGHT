import SwiftUI

struct ProfileSettingsView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var healthKit: HealthKitManager
    @State private var showingNewProfileAlert = false
    @State private var newFighterName = ""
    @AppStorage("fight.advanced.profile") private var showAdvanced = false

    enum ActiveWheelPicker: Hashable {
        case age, weight, height, targetWeight, restingHR, maxHR, lthr
    }
    @State private var expandedWheel: ActiveWheelPicker?

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
                Section("Fighter") {
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

                Section("Your Body") {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Fighter Name", text: binding(for: \.name))
                            .multilineTextAlignment(.trailing)
                    }

                    Picker("Sex", selection: binding(for: \.sex)) {
                        ForEach(BiologicalSex.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }

                    wheelValueRow(title: "Age", valueText: "\(profile.age) yrs", wheel: .age)
                    if expandedWheel == .age {
                        Picker("Age", selection: binding(for: \.age)) {
                            ForEach(13...85, id: \.self) { yrs in
                                Text("\(yrs) yrs").tag(yrs)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 130)
                    }

                    wheelValueRow(title: "Height", valueText: profile.heightImperial ? HeightUnits.text(profile.heightCm, true) : "\(Int(round(profile.heightCm)))",
                                  wheel: .height, unit: heightChip)
                    if expandedWheel == .height {
                        heightWheel(profile)
                    }

                    wheelValueRow(title: "Current Weight", valueText: WeightUnits.number(profile.weightKg, profile.useImperial),
                                  wheel: .weight, unit: weightChip)
                    if expandedWheel == .weight {
                        weightWheel("Current Weight", \.weightKg, imperial: profile.useImperial)
                    }

                    wheelValueRow(title: "Resting HR", valueText: "\(profile.restingHR) BPM", wheel: .restingHR)
                    if expandedWheel == .restingHR {
                        Picker("Resting HR", selection: binding(for: \.restingHR)) {
                            ForEach(30...110, id: \.self) { bpm in
                                Text("\(bpm) BPM").tag(bpm)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 130)
                    }

                    Toggle("Auto Max HR (Tanaka: \(Int(round(208.0 - 0.7 * Double(profile.age)))))", isOn: binding(for: \.useAutoMaxHR))

                    if !profile.useAutoMaxHR {
                        let minMaxHR = profile.restingHR + 35
                        wheelValueRow(title: "Custom Max HR", valueText: "\(profile.maxHR) BPM", wheel: .maxHR)
                        if expandedWheel == .maxHR {
                            Picker("Custom Max HR", selection: binding(for: \.maxHR)) {
                                ForEach(minMaxHR...230, id: \.self) { bpm in
                                    Text("\(bpm) BPM").tag(bpm)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(height: 130)
                        }
                    }
                }

                Section("Weight Goal") {
                    Picker("Camp Phase", selection: binding(for: \.campPhase)) {
                        ForEach(CampPhase.allCases) { phase in
                            Text(phase.rawValue).tag(phase)
                        }
                    }

                    wheelValueRow(title: "Target Fight Weight", valueText: WeightUnits.number(profile.targetFightWeightKg, profile.useImperial),
                                  wheel: .targetWeight, unit: weightChip)
                    if expandedWheel == .targetWeight {
                        weightWheel("Target Fight Weight", \.targetFightWeightKg, imperial: profile.useImperial)
                    }

                    HStack {
                        Text("Weight to Cut / Gain")
                        Spacer()
                        let delta = profile.weightDeltaKg
                        Text(delta > 0 ? "-\(WeightUnits.text(delta, profile.useImperial)) to cut" : "+\(WeightUnits.text(abs(delta), profile.useImperial)) buffer")
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

                Section("Apple Health") {
                    if healthKit.isAvailable {
                        HStack {
                            Label(healthKit.isAuthorized ? "Connected" : "Not Connected",
                                  systemImage: healthKit.isAuthorized ? "heart.fill" : "heart.slash")
                                .foregroundStyle(healthKit.isAuthorized ? .pink : .secondary)
                            Spacer()
                            if !healthKit.isAuthorized {
                                Button("Connect") {
                                    Task { await healthKit.requestAuthorization() }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.pink)
                                .controlSize(.small)
                            }
                        }
                        Toggle("Auto-save workouts to Health", isOn: $healthKit.autoSaveEnabled)
                            .tint(.pink)
                        Text("Saves each finished session as a Health workout with its full heart-rate trace and active calories. Past workouts can be sent from their detail screen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !healthKit.statusMessage.isEmpty {
                            Text(healthKit.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Apple Health isn't available on this device.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Show advanced settings", isOn: $showAdvanced)
                } footer: {
                    Text("Heart-rate zone formula, voice-coaching details and storage.")
                }

                if showAdvanced {
                Section("Heart-Rate Zones") {
                    Picker("Formula", selection: binding(for: \.zoneMethod)) {
                        ForEach(ZoneCalculationMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }

                    Text(profile.zoneMethod.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if profile.zoneMethod == .lactateThreshold {
                        wheelValueRow(title: "Lactate Threshold (LTHR)", valueText: "\(profile.lactateThresholdHR) BPM", wheel: .lthr)
                        if expandedWheel == .lthr {
                            Picker("LTHR", selection: binding(for: \.lactateThresholdHR)) {
                                ForEach(minLTHR...maxLTHR, id: \.self) { bpm in
                                    Text("\(bpm) BPM").tag(bpm)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(height: 130)
                        }
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

                Section("Voice Coaching") {
                    Toggle("Enable Voice HR Coaching", isOn: binding(for: \.audioCoach.masterEnabled))

                    if profile.audioCoach.masterEnabled {
                        Toggle("Zone Crossing Alerts (Z2 → Z3 → Z4 → Z5)", isOn: binding(for: \.audioCoach.announceZoneCrossings))
                        Toggle("Roadwork Zone 2 Ceiling Guard", isOn: binding(for: \.audioCoach.zone2CeilingAlert))
                        Toggle("Round Warnings (1m / 30s / 10s + BPM)", isOn: binding(for: \.audioCoach.announceRoundWarnings))
                        Toggle("Stool Rest Recovery Readout (HRR-60)", isOn: binding(for: \.audioCoach.announceStoolRecovery))
                        Toggle("Sustained Redline Warning (>92% MaxHR)", isOn: binding(for: \.audioCoach.announceRedlineWarning))
                        Toggle("Ghost Opponent Lead / Delta Alerts", isOn: binding(for: \.audioCoach.announceGhostDelta))

                        Toggle("10-Second Clapper Warnings", isOn: binding(for: \.audioCoach.clapperWarnings))
                        Toggle("Lower Music While Coaching", isOn: binding(for: \.audioCoach.duckMusic))
                        VStack(alignment: .leading) {
                            Text("Voice volume").font(.subheadline)
                            Slider(value: binding(for: \.audioCoach.voiceVolume), in: 0.2...1.0)
                        }
                        VStack(alignment: .leading) {
                            Text("Bell & clapper volume").font(.subheadline)
                            Slider(value: binding(for: \.audioCoach.bellVolume), in: 0.2...1.0)
                        }

                        Picker("Periodic BPM & Zone Check-In", selection: binding(for: \.audioCoach.periodicMinutes)) {
                            Text("Off").tag(0)
                            Text("Every 1 min").tag(1)
                            Text("Every 2 min").tag(2)
                            Text("Every 3 min").tag(3)
                            Text("Every 5 min").tag(5)
                        }
                    }
                }

                Section {
                    Toggle("Count head movement (AirPods)", isOn: binding(for: \.trackHeadMovement))
                    Toggle("Breathing tones between rounds", isOn: binding(for: \.guidedBreathing))
                } header: {
                    Text("Sensors & Recovery")
                } footer: {
                    Text("Head movement works with AirPods Pro, AirPods (3rd gen and later) and AirPods Max. Breathing tones guide a slow in-4, out-6 breath on the stool.")
                }

                Section("Storage") {
                    HStack {
                        Text("Fighter Profiles File")
                        Spacer()
                        Text("Profiles/fighter_profiles.json")
                            .font(.caption)
                            .foregroundStyle(.green)
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
            }
            .navigationTitle("Fighter")
            .alert("New Fighter Profile", isPresented: $showingNewProfileAlert) {
                TextField("Fighter Name", text: $newFighterName)
                Button("Create") {
                    workoutStore.addProfile(name: newFighterName)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var weightChip: UnitChip {
        UnitChip(metric: "kg", imperial: "lb", isImperial: binding(for: \.useImperial), accessibilityName: "Weight unit")
    }

    private var heightChip: UnitChip {
        UnitChip(metric: "cm", imperial: "ft", isImperial: binding(for: \.heightImperial), accessibilityName: "Height unit")
    }

    private func wheelValueRow(title: String, valueText: String, wheel: ActiveWheelPicker, unit: UnitChip? = nil) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy) {
                    expandedWheel = (expandedWheel == wheel) ? nil : wheel
                }
            } label: {
                HStack {
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(valueText)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(expandedWheel == wheel ? .orange : .cyan)
                    if unit == nil {
                        Image(systemName: expandedWheel == wheel ? "chevron.up" : "chevron.down")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            if let unit {
                unit
            }
        }
    }

    /// Weight wheel in 0.5 kg or 0.5 lb steps; always stores kilograms.
    private func weightWheel(_ title: String, _ keyPath: WritableKeyPath<AthleteProfile, Double>, imperial: Bool) -> some View {
        let steps: [Double] = imperial
            ? stride(from: 90.0, through: 400.0, by: 0.5).map { $0 }
            : stride(from: 40.0, through: 180.0, by: 0.5).map { $0 }
        let selection = Binding<Double>(
            get: { (WeightUnits.value(workoutStore.activeProfile[keyPath: keyPath], imperial) * 2).rounded() / 2 },
            set: { v in
                var p = workoutStore.activeProfile
                p[keyPath: keyPath] = WeightUnits.toKg(v, imperial)
                workoutStore.activeProfile = p
            }
        )
        return Picker(title, selection: selection) {
            ForEach(steps, id: \.self) { v in
                Text(String(format: "%.1f %@", v, WeightUnits.unit(imperial))).tag(v)
            }
        }
        .pickerStyle(.wheel)
        .frame(height: 130)
    }

    /// Height wheel: centimetres, or feet + inches side by side.
    @ViewBuilder
    private func heightWheel(_ profile: AthleteProfile) -> some View {
        if profile.heightImperial {
            let fi = HeightUnits.feetInches(profile.heightCm)
            HStack(spacing: 0) {
                Picker("Feet", selection: Binding(get: { fi.feet }, set: { setHeight(HeightUnits.cm(feet: $0, inches: fi.inches)) })) {
                    ForEach(4...7, id: \.self) { Text("\($0) ft").tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()
                Picker("Inches", selection: Binding(get: { fi.inches }, set: { setHeight(HeightUnits.cm(feet: fi.feet, inches: $0)) })) {
                    ForEach(0...11, id: \.self) { Text("\($0) in").tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .frame(height: 130)
        } else {
            Picker("Height", selection: Binding(get: { Int(round(profile.heightCm)) }, set: { setHeight(Double($0)) })) {
                ForEach(120...230, id: \.self) { cm in
                    Text("\(cm) cm").tag(cm)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 130)
        }
    }

    private func setHeight(_ cm: Double) {
        var p = workoutStore.activeProfile
        p.heightCm = cm
        p.sanitize()
        workoutStore.activeProfile = p
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
