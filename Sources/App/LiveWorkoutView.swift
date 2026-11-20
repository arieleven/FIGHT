import SwiftUI
import Charts
import UniformTypeIdentifiers

struct LiveWorkoutView: View {
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var navigation: AppNavigation
    @EnvironmentObject var session: WorkoutSession
    @ScaledMetric(relativeTo: .largeTitle) private var heroBPMSize: CGFloat = 74

    @State private var showingDeviceSheet = false
    @State private var showingTCXImporter = false
    @State private var showingFinishConfirm = false
    @State private var showingBagSettings = false

    var body: some View {
        let profile = workoutStore.activeProfile
        let currentZone = profile.zone(for: bleManager.currentBPM)

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionBanner

                    if bleManager.isConnected && (bleManager.sensorContactDetected == false || bleManager.isSignalLost) {
                        Label(bleManager.isSignalLost ? "No heart-rate signal. Check the sensor is on and touching skin." :
                                "Poor sensor contact. Tighten the band or moisten the sensor.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if let plan = session.activePlan {
                        planBanner(plan)
                    }

                    if let lthr = session.lthrTestResultBanner {
                        lthrSuccessBanner(lthr: lthr)
                    }

                    if let autoBanner = session.latestAutoHRRBanner, session.isRecording {
                        Label(autoBanner, systemImage: "arrow.down.heart.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.cyan)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.cyan.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                    }

                    setupCard(profile: profile)

                    heroBPMCard(currentZone: currentZone, profile: profile)

                    if session.selectedCategory == .lthrTest {
                        lthrFieldTestCard
                    }

                    if session.bagEnabled && session.isRecording {
                        BagComboCard(audio: session.audio, round: session.currentRound,
                                     totalRounds: session.totalBagRounds, isComplete: session.bagSessionComplete)
                    }

                    if bagAvailable && !session.isRecording {
                        bagSetupCard
                    }

                    if session.selectedCategory != .lthrTest && (!session.isRecording || session.roundTimerEnabled) {
                        roundBellCard
                    }

                    if !session.isRecording || session.selectedGhost != nil {
                        ghostSimulatorCard
                    }

                    liveSparklineCard(profile: profile)

                    controlButtons
                }
                .padding()
            }
            .navigationTitle("Live Corner")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingDeviceSheet = true
                    } label: {
                        Label("Sensors", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            }
            .sheet(isPresented: $showingDeviceSheet) {
                DeviceScannerSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingBagSettings) {
                BagSettingsSheet(prefs: $session.bagPrefs)
            }
            .confirmationDialog(session.bagSessionComplete ? "Bag session complete" : "Finish workout?",
                                isPresented: $showingFinishConfirm, titleVisibility: .visible) {
                Button("Save Workout") { session.finishAndSave() }
                Button("Discard Workout", role: .destructive) { session.discard() }
                Button("Keep Going", role: .cancel) {}
            } message: {
                Text("\(formatDuration(session.elapsedSeconds)) recorded")
            }
            .alert("Recover unfinished workout?", isPresented: Binding(
                get: { session.recoverableDraft != nil },
                set: { if !$0 && session.recoverableDraft != nil { session.resolveRecoveredDraft(save: false) } }
            )) {
                Button("Save It") { session.resolveRecoveredDraft(save: true) }
                Button("Discard", role: .destructive) { session.resolveRecoveredDraft(save: false) }
            } message: {
                if let d = session.recoverableDraft {
                    Text("A \(d.category.rawValue) session from \(d.startTime.formatted(date: .abbreviated, time: .shortened)) (\(formatDuration(d.elapsedSeconds))) was interrupted.")
                }
            }
            .onAppear {
                session.syncFromProfile()
                applyPending()
            }
            .onChange(of: navigation.pendingPrescription) { _, _ in applyPending() }
            .onChange(of: workoutStore.activeProfileID) { _, _ in session.syncFromProfile() }
            .onChange(of: session.requestFinishPrompt) { _, wants in
                if wants {
                    showingFinishConfirm = true
                    session.requestFinishPrompt = false
                }
            }
            .sensoryFeedback(.impact(weight: .heavy), trigger: session.currentRound)
            .sensoryFeedback(.warning, trigger: session.isRestPeriod)
            .sensoryFeedback(.start, trigger: session.isRecording)
            .sheet(isPresented: $session.showingSummary) {
                if let workout = session.finishedWorkout {
                    NavigationStack {
                        WorkoutDetailView(workout: workout)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") { session.showingSummary = false }
                                }
                            }
                    }
                }
            }
            .fileImporter(
                isPresented: $showingTCXImporter,
                allowedContentTypes: [UTType(filenameExtension: "tcx") ?? .xml, .xml],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first,
                   let imported = workoutStore.importTCXGhost(from: url) {
                    session.selectedGhost = imported
                }
            }
        }
    }

    private var bagAvailable: Bool {
        session.selectedCategory != .walk && session.selectedCategory != .lthrTest && session.selectedCategory != .roadwork
    }

    private func applyPending() {
        guard let p = navigation.pendingPrescription, !session.isRecording else { return }
        navigation.pendingPrescription = nil
        session.apply(p)
    }

    // MARK: Banners

    private var connectionBanner: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(bleManager.isConnected ? (bleManager.isSignalLost ? Color.orange : Color.green) : Color.orange)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(bleManager.isConnected ? bleManager.connectedDeviceName : "Sensor Not Connected")
                    .font(.subheadline.weight(.semibold))
                Text(bleManager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let battery = bleManager.batteryLevel {
                Label("\(battery)%", systemImage: battery > 20 ? "battery.75" : "battery.25")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(battery > 20 ? .green : .orange)
            }
            Button(bleManager.isConnected ? "Change" : "Connect") {
                showingDeviceSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func planBanner(_ p: WorkoutPrescription) -> some View {
        let bpm = bleManager.currentBPM
        let status: (text: String, color: Color)
        if bpm <= 0 {
            status = ("Waiting for HR", Color.secondary)
        } else if bpm < p.targetLowBPM {
            status = ("Below target", Color.blue)
        } else if bpm > p.targetHighBPM {
            status = ("Above target", Color.orange)
        } else {
            status = ("On target", Color.green)
        }
        return HStack(spacing: 10) {
            Image(systemName: "list.clipboard.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Coach plan: \(p.title)")
                    .font(.subheadline.weight(.bold))
                Text("\(p.structure) • \(p.targetLowBPM)–\(p.targetHighBPM) BPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if session.isRecording {
                Text(status.text)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(status.color)
            } else {
                Button {
                    session.activePlan = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Remove coach plan")
            }
        }
        .padding(12)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func lthrSuccessBanner(lthr: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lactate threshold updated: \(lthr) BPM")
                    .font(.subheadline.weight(.bold))
                Text("Your zones now use the LTHR model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("OK") { session.lthrTestResultBanner = nil }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Setup

    private func setupCard(profile: AthleteProfile) -> some View {
        VStack(spacing: 10) {
            HStack {
                Label(profile.name, systemImage: "figure.boxing")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.cyan)
                Spacer()
                Text(session.selectedCategory.timerModeHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !session.isRecording {
                HStack {
                    Picker("Discipline", selection: $session.selectedCategory) {
                        ForEach(WorkoutCategory.allCases) { cat in
                            Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                    Picker("Drill Tag", selection: $session.selectedDrillTag) {
                        ForEach(DrillTag.allCases) { tag in
                            Text(tag.rawValue).tag(tag)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } else {
                HStack {
                    Label(session.selectedCategory.rawValue, systemImage: session.selectedCategory.icon)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.orange)
                    Spacer()
                    Text(session.selectedDrillTag.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Hero

    private func heroBPMCard(currentZone: HeartRateZoneInfo, profile: AthleteProfile) -> some View {
        let totalCalories = session.activeCalories + session.bmrCalories
        let bpm = bleManager.currentBPM
        return VStack(spacing: 12) {
            HStack {
                Text(currentZone.name.uppercased())
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(currentZone.color.opacity(0.22), in: Capsule())
                    .foregroundStyle(currentZone.color)
                Spacer()
                if let remain = session.pendingRecoveryRemaining {
                    Label("Auto HRR: \(remain)s", systemImage: "arrow.down.heart.fill")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.cyan.opacity(0.2), in: Capsule())
                        .foregroundStyle(.cyan)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "heart.fill")
                    .font(.system(size: heroBPMSize * 0.43))
                    .foregroundStyle(bpm > 0 ? currentZone.color : .secondary)
                    .symbolEffect(.pulse, isActive: bpm > 0)
                Text(bpm > 0 ? "\(bpm)" : "--")
                    .font(.system(size: heroBPMSize, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: bpm)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("BPM")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bpm > 0 ? "Heart rate \(bpm) beats per minute, \(currentZone.name)" : "No heart rate signal")

            zoneBar(bpm: bpm, profile: profile)

            if session.isRecording, let a = session.liveAlpha1 {
                Label(String(format: "%@ • DFA α1 %.2f", a >= 0.75 ? "Below aerobic threshold" : "Above aerobic threshold", a),
                      systemImage: "waveform.path.ecg")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(a >= 0.75 ? .green : .orange)
            }

            HStack(spacing: 12) {
                stat("ELAPSED", formatDuration(session.elapsedSeconds), .primary)
                Divider().frame(height: 28)
                stat("ACTIVE KCAL", "\(Int(session.activeCalories))", .orange)
                Divider().frame(height: 28)
                stat("TOTAL KCAL", "\(Int(totalCalories))", .primary)
                Divider().frame(height: 28)
                stat("AVG / MAX", "\(session.liveAverageBPM)/\(session.liveMaxBPM)", .primary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color == .primary ? Color.secondary : color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func zoneBar(bpm: Int, profile: AthleteProfile) -> some View {
        let current = bpm > 0 ? profile.zone(for: bpm).number : 0
        let colors: [Color] = [.blue, .green, .yellow, .orange, .red]
        return HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { z in
                VStack(spacing: 3) {
                    Capsule()
                        .fill(colors[z - 1].opacity(z == current ? 1 : 0.25))
                        .frame(height: z == current ? 10 : 6)
                    Text("Z\(z)")
                        .font(.caption2.weight(z == current ? .heavy : .regular))
                        .foregroundStyle(z == current ? colors[z - 1] : Color.secondary)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: current)
        .accessibilityHidden(true)
    }

    // MARK: LTHR

    private var lthrFieldTestCard: some View {
        let elapsed = session.elapsedSeconds
        let warmupRemaining = max(0, 600 - Int(elapsed))
        let trialRemaining = max(0, 1200 - max(0, Int(elapsed) - 600))
        let trial = session.samples.filter { $0.elapsedSeconds >= 600 }
        let rolling = trial.isEmpty ? 0 : trial.map(\.bpm).reduce(0, +) / trial.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("30-MIN LTHR FIELD TEST", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.orange)
                Spacer()
                if session.isRecording {
                    Text(elapsed < 600 ? "PHASE 1: WARM-UP" : "PHASE 2: 20-MIN TRIAL")
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            Text("10 min progressive warm-up, then 20 min at your maximum sustainable pace. The average HR of the final 20 minutes sets your lactate threshold and zones automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if session.isRecording {
                HStack {
                    if elapsed < 600 {
                        Text("Warm-up left: \(formatDuration(TimeInterval(warmupRemaining)))")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                    } else {
                        Text("Trial left: \(formatDuration(TimeInterval(trialRemaining)))")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.orange)
                        Spacer()
                        Text("Live LTHR: \(rolling > 0 ? "\(rolling)" : "--")")
                            .font(.subheadline.weight(.heavy).monospacedDigit())
                            .foregroundStyle(.cyan)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Bag setup

    private var bagSetupCard: some View {
        let prefs = session.bagPrefs
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $session.bagEnabled) {
                Label("Coached Bag Work", systemImage: "figure.boxing")
                    .font(.subheadline.weight(.bold))
            }
            .tint(.orange)

            if session.bagEnabled {
                Text("\(prefs.mode.rawValue) • \(prefs.tempo.rawValue) • \(prefs.stance.rawValue) • \(prefs.difficulty.rawValue)\(prefs.numberCalls ? " • Numbers" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    presetButton("Steady 30", minutes: 30, work: 180, rest: 60, tempo: .steady)
                    presetButton("Fight Pace 15", minutes: 15, work: 180, rest: 60, tempo: .fightPace)
                    presetButton("Burnout 10", minutes: 10, work: 60, rest: 30, tempo: .burnout)
                }

                HStack {
                    Text("\(prefs.totalMinutes) min • \(prefs.estimatedTotalRounds) rounds of \(formatDuration(TimeInterval(prefs.workSeconds))) / \(formatDuration(TimeInterval(prefs.restSeconds)))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button {
                        showingBagSettings = true
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                BagPreparationStatus(audio: session.audio)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func presetButton(_ title: String, minutes: Int, work: Int, rest: Int, tempo: BagTempo) -> some View {
        let p = session.bagPrefs
        let selected = p.totalMinutes == minutes && p.workSeconds == work && p.restSeconds == rest && p.tempo == tempo
        return Button(title) {
            var prefs = session.bagPrefs
            prefs.totalMinutes = minutes
            prefs.workSeconds = work
            prefs.restSeconds = rest
            prefs.tempo = tempo
            session.bagPrefs = prefs
        }
        .buttonStyle(.bordered)
        .tint(selected ? .orange : .secondary)
        .controlSize(.small)
    }

    // MARK: Round bell

    private var roundBellCard: some View {
        VStack(spacing: 10) {
            Toggle(isOn: $session.roundTimerEnabled) {
                Label("Round Bell & Corner Timer", systemImage: "bell.fill")
                    .font(.subheadline.weight(.bold))
            }
            .tint(.orange)
            .disabled(session.isRecording || session.bagEnabled)

            if session.roundTimerEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.isRestPeriod ? "ROUND \(session.currentRound) • REST" : "ROUND \(session.currentRound)\(session.bagEnabled ? " OF \(session.totalBagRounds)" : "") • WORK")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(session.isRestPeriod ? .cyan : .orange)
                        Text(formatDuration(session.isRecording ? session.phaseRemaining : session.currentPhaseTarget))
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(session.isRestPeriod ? .cyan : .primary)
                    }
                    Spacer()
                    if !session.isRecording && !session.bagEnabled {
                        VStack(alignment: .trailing, spacing: 6) {
                            Picker("Work", selection: $session.workDurationSeconds) {
                                ForEach([30, 60, 90, 120, 180, 240, 300], id: \.self) { s in
                                    Text("\(formatDuration(TimeInterval(s))) work").tag(s)
                                }
                            }
                            .pickerStyle(.menu)
                            Picker("Rest", selection: $session.restDurationSeconds) {
                                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { s in
                                    Text("\(formatDuration(TimeInterval(s))) rest").tag(s)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    } else if session.isRecording && !session.isRestPeriod && !session.bagSessionComplete {
                        Button("End Round") {
                            session.endWorkPhase(manual: true)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Ghost

    private var ghostSimulatorCard: some View {
        let ghostBPM = session.selectedGhost?.interpolatedBPM(at: session.elapsedSeconds)
        let delta: Int? = (bleManager.currentBPM > 0 && ghostBPM != nil) ? bleManager.currentBPM - (ghostBPM ?? 0) : nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Ghost Opponent Pace", systemImage: "figure.run.square.stack.fill")
                    .font(.subheadline.weight(.bold))
                Spacer()
                if !session.isRecording {
                    Button {
                        showingTCXImporter = true
                    } label: {
                        Label("Import .TCX", systemImage: "doc.badge.plus")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            if !session.isRecording {
                Picker("Ghost Session", selection: $session.selectedGhost) {
                    Text("None (solo session)").tag(Optional<GhostSession>.none)
                    ForEach(workoutStore.allAvailableGhosts()) { g in
                        Text(g.title).tag(Optional(g))
                    }
                }
                .pickerStyle(.menu)
            } else if let ghost = session.selectedGhost {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ghost.title).font(.caption.weight(.bold))
                        Text("Ghost BPM: \(ghostBPM.map(String.init) ?? "Finished")")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                    Spacer()
                    if let d = delta {
                        Text(d <= 0 ? "\(d) BPM (more efficient)" : "+\(d) BPM (higher strain)")
                            .font(.caption.weight(.heavy))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background((d <= 0 ? Color.green : Color.orange).opacity(0.2), in: Capsule())
                            .foregroundStyle(d <= 0 ? .green : .orange)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Sparkline

    private func liveSparklineCard(profile: AthleteProfile) -> some View {
        let recent = Array(session.samples.suffix(120))
        let zones = profile.activeZones
        let ghost = session.selectedGhost
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("REAL-TIME HEART RATE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if ghost != nil {
                    Text("Purple = Ghost")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.purple)
                }
            }
            if recent.count >= 2 {
                Chart {
                    RuleMark(y: .value("Z2", zones.z2Max))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.green.opacity(0.4))
                    RuleMark(y: .value("Threshold", zones.z4Max))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.orange.opacity(0.5))
                    ForEach(recent) { pt in
                        LineMark(x: .value("Time", pt.elapsedSeconds), y: .value("BPM", pt.bpm))
                            .foregroundStyle(by: .value("Series", "Live"))
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    if let ghost {
                        ForEach(recent) { pt in
                            if let g = ghost.interpolatedBPM(at: pt.elapsedSeconds) {
                                LineMark(x: .value("Time", pt.elapsedSeconds), y: .value("BPM", g))
                                    .foregroundStyle(by: .value("Series", "Ghost"))
                                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                            }
                        }
                    }
                }
                .chartForegroundStyleScale(["Live": Color.red, "Ghost": Color.purple.opacity(0.8)])
                .chartLegend(.hidden)
                .chartYScale(domain: 55...210)
                .chartXAxis(.hidden)
                .frame(height: 130)
                .accessibilityLabel("Heart rate over the last two minutes")
            } else {
                Text("Start a workout to see your live heart-rate trace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 95)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Controls

    private var controlButtons: some View {
        VStack(spacing: 10) {
            if !session.isRecording {
                Button {
                    session.startWorkout()
                } label: {
                    Label(session.selectedCategory == .lthrTest ? "Start 30-Min LTHR Test" : "Start Workout", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                if !bleManager.isConnected {
                    Text("No sensor connected. You can still record time and rounds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField("Corner note…", text: $session.workoutNotes)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) {
                    showingFinishConfirm = true
                } label: {
                    Label("Finish Workout", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Bag coach live card

struct BagComboCard: View {
    @ObservedObject var audio: AudioCoachEngine
    let round: Int
    let totalRounds: Int
    let isComplete: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("BAG COACH", systemImage: "figure.boxing")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.orange)
                Spacer()
                Text(isComplete ? "COMPLETE" : "Round \(min(round, totalRounds)) / \(totalRounds)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Group {
                if audio.comboTokens.isEmpty {
                    Text(isComplete ? "SESSION COMPLETE" : (audio.bagStatus.isEmpty ? "READY — HANDS UP" : audio.bagStatus))
                        .font(.system(.title, design: .rounded).weight(.heavy))
                        .foregroundStyle(audio.bagStatus.contains("REST") ? .cyan : .orange)
                        .multilineTextAlignment(.center)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(Array(audio.comboTokens.enumerated()), id: \.offset) { i, token in
                            Text(token)
                                .font(.system(.title2, design: .rounded).weight(.heavy))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(chipColor(i).opacity(i == audio.activeTokenIndex ? 1 : 0.22), in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(i == audio.activeTokenIndex ? Color.black : chipColor(i))
                                .scaleEffect(i == audio.activeTokenIndex ? 1.06 : 1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .animation(.spring(duration: 0.25), value: audio.activeTokenIndex)
            .animation(.easeOut(duration: 0.2), value: audio.comboSerial)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(audio.comboTokens.isEmpty ? audio.bagStatus : audio.comboTokens.joined(separator: ", "))

            HStack {
                Text("Strikes called: \(audio.strikesCuedCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if audio.isPreparingAudio {
                    ProgressView(value: audio.preparationProgress)
                        .frame(width: 80)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .sensoryFeedback(.impact(weight: .light), trigger: audio.comboSerial)
    }

    private func chipColor(_ i: Int) -> Color {
        i <= audio.activeTokenIndex ? .orange : .orange.opacity(0.9)
    }
}

struct BagPreparationStatus: View {
    @ObservedObject var audio: AudioCoachEngine

    var body: some View {
        if audio.isPreparingAudio {
            HStack(spacing: 8) {
                ProgressView(value: audio.preparationProgress)
                Text("Preparing voice…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if !audio.voiceName.isEmpty {
            Text("Voice: \(audio.voiceName). Install an Enhanced voice in Settings › Accessibility › Spoken Content for clearer calls.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Wraps children onto multiple lines (combo chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Lay out rows, then centre each row horizontally.
        var rows: [[(LayoutSubview, CGSize)]] = [[]]
        var x: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > bounds.width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((v, s))
            x += s.width + spacing
        }
        let totalHeight = rows.reduce(CGFloat(0)) { $0 + ($1.map { $0.1.height }.max() ?? 0) } + spacing * CGFloat(max(0, rows.count - 1))
        var y = bounds.minY + max(0, (bounds.height - totalHeight) / 2)
        for row in rows {
            let rowWidth = row.reduce(CGFloat(0)) { $0 + $1.1.width } + spacing * CGFloat(max(0, row.count - 1))
            let rowHeight = row.map { $0.1.height }.max() ?? 0
            var rx = bounds.minX + max(0, (bounds.width - rowWidth) / 2)
            for (v, s) in row {
                v.place(at: CGPoint(x: rx, y: y + (rowHeight - s.height) / 2), proposal: ProposedViewSize(s))
                rx += s.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
