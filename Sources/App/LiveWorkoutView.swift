import SwiftUI
import Charts
import AudioToolbox
import ActivityKit
import UniformTypeIdentifiers

struct LiveWorkoutView: View {
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @EnvironmentObject var workoutStore: WorkoutStore
    @StateObject private var audioCoach = AudioCoachEngine()

    @State private var selectedCategory: WorkoutCategory = .muayThai
    @State private var selectedDrillTag: DrillTag = .technical
    @State private var rpeScore: Int = 7
    @State private var workoutNotes: String = ""

    @State private var isRecording = false
    @State private var startTime: Date?
    @State private var elapsedSeconds: TimeInterval = 0
    @State private var samples: [HeartRatePoint] = []
    @State private var zoneSeconds: [Int: TimeInterval] = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
    @State private var activeCalories: Double = 0
    @State private var bmrCalories: Double = 0
    @State private var timer: Timer?

    @State private var roundTimerEnabled = true
    @State private var workDurationSeconds = 180
    @State private var restDurationSeconds = 60
    @State private var currentRound = 1
    @State private var isRestPeriod = false
    @State private var phaseElapsed: TimeInterval = 0
    @State private var currentRoundStartElapsed: TimeInterval = 0
    @State private var currentRoundStartStrikes: Int = 0
    @State private var roundEndPeakBPM: Int = 0
    @State private var completedRounds: [RoundStat] = []

    @State private var bagConfig = BagCoachConfig()

    private struct PendingRecoveryTracker {
        let startElapsed: TimeInterval
        let peakBPM: Int
        let contextLabel: String
        var lowestSeenBPM: Int
    }
    @State private var pendingRecovery: PendingRecoveryTracker?
    @State private var autoHRREvents: [AutoHRREvent] = []
    @State private var latestAutoHRRBanner: String?

    @State private var lthrTestResultBanner: Int?

    @State private var selectedGhost: GhostSession?
    @State private var showingTCXImporter = false

    @State private var lastAnnouncedZone: Int = 0
    @State private var lastZone2AlertTime: TimeInterval = -999
    @State private var lastPeriodicMinute: Int = 0
    @State private var redlineSecondsAccumulator: TimeInterval = 0
    @State private var lastRedlineAlertTime: TimeInterval = -999
    @State private var lastGhostAlertTime: TimeInterval = -999
    @State private var announced30sWarning = false
    @State private var announced10sWarning = false

    @State private var currentActivity: Activity<WorkoutActivityAttributes>?

    @State private var showingDeviceSheet = false
    @State private var showingPostWorkoutSummary = false
    @State private var finishedWorkout: SavedWorkout?

    var body: some View {
        let profile = workoutStore.activeProfile
        let currentZone = profile.zone(for: bleManager.currentBPM)

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionBanner

                    if let lthr = lthrTestResultBanner {
                        lthrSuccessBanner(lthr: lthr)
                    }

                    if let autoBanner = latestAutoHRRBanner {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.heart.fill")
                                .foregroundStyle(.cyan)
                            Text(autoBanner)
                                .font(.caption.weight(.bold))
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.cyan.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(spacing: 10) {
                        HStack {
                            Label(profile.name, systemImage: "figure.boxing")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.cyan)
                            Spacer()
                            Text(selectedCategory.timerModeHint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if !isRecording {
                            HStack {
                                Picker("Discipline", selection: $selectedCategory) {
                                    ForEach(WorkoutCategory.allCases) { cat in
                                        Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: selectedCategory) { _, newCat in
                                    applyDisciplineDefaults(newCat)
                                }

                                Spacer()

                                Picker("Drill Tag", selection: $selectedDrillTag) {
                                    ForEach(DrillTag.allCases) { tag in
                                        Text(tag.rawValue).tag(tag)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        } else {
                            HStack {
                                Label(selectedCategory.rawValue, systemImage: selectedCategory.icon)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.orange)
                                Spacer()
                                Text(selectedDrillTag.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                    heroBPMCard(currentZone: currentZone)

                    if selectedCategory == .lthrTest {
                        lthrFieldTestCard
                    }

                    if selectedCategory != .walk && selectedCategory != .lthrTest {
                        guidedBagCoachCard
                    }

                    if selectedCategory != .lthrTest {
                        roundBellCard
                    }

                    ghostSimulatorCard

                    liveSparklineCard

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
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                }
            }
            .sheet(isPresented: $showingDeviceSheet) {
                DeviceScannerSheet()
            }
            .sheet(isPresented: $showingPostWorkoutSummary) {
                if let workout = finishedWorkout {
                    NavigationStack {
                        WorkoutDetailView(workout: workout)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") { showingPostWorkoutSummary = false }
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
                if case .success(let urls) = result, let url = urls.first {
                    if let imported = workoutStore.importTCXGhost(from: url) {
                        selectedGhost = imported
                    }
                }
            }
        }
    }

    private func applyDisciplineDefaults(_ category: WorkoutCategory) {
        roundTimerEnabled = category.usesRoundTimerByDefault
        workDurationSeconds = category.defaultWorkSeconds
        restDurationSeconds = category.defaultRestSeconds

        if category == .lthrTest {
            selectedDrillTag = .lthrProtocol
            bagConfig.enabled = false
        } else if category == .walk || category == .roadwork {
            selectedDrillTag = .aerobicZ2
            bagConfig.enabled = false
        } else if category == .heavyBag {
            selectedDrillTag = .bagWork
        } else if category == .sparring {
            selectedDrillTag = .hardSparring
        }
    }

    private var connectionBanner: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(bleManager.isConnected ? Color.green : Color.orange)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(bleManager.isConnected ? bleManager.connectedDeviceName : "Sensor Not Connected")
                    .font(.subheadline.weight(.semibold))
                Text(bleManager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let battery = bleManager.batteryLevel {
                Label("\(battery)%", systemImage: "battery.75")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
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

    private func heroBPMCard(currentZone: HeartRateZoneInfo) -> some View {
        let totalCalories = activeCalories + bmrCalories

        return VStack(spacing: 12) {
            HStack {
                Text(currentZone.name.uppercased())
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(currentZone.color.opacity(0.22), in: Capsule())
                    .foregroundStyle(currentZone.color)

                Spacer()

                if let pending = pendingRecovery {
                    let remain = max(0, 60 - Int(elapsedSeconds - pending.startElapsed))
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
                    .font(.system(size: 32))
                    .foregroundStyle(bleManager.currentBPM > 0 ? currentZone.color : .secondary)

                Text(bleManager.currentBPM > 0 ? "\(bleManager.currentBPM)" : "--")
                    .font(.system(size: 74, weight: .heavy, design: .rounded))
                    .monospacedDigit()

                Text("BPM")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text("ELAPSED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(formatDuration(elapsedSeconds))
                        .font(.headline.monospacedDigit())
                }
                .frame(maxWidth: .infinity)

                Divider().frame(height: 28)

                VStack(spacing: 2) {
                    Text("ACTIVE KCAL")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                    Text("\(Int(activeCalories))")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity)

                Divider().frame(height: 28)

                VStack(spacing: 2) {
                    Text("TOTAL (+BMR)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("\(Int(totalCalories))")
                        .font(.headline.monospacedDigit())
                }
                .frame(maxWidth: .infinity)

                Divider().frame(height: 28)

                VStack(spacing: 2) {
                    Text("AVG / MAX")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("\(liveAverageBPM)/\(liveMaxBPM)")
                        .font(.headline.monospacedDigit())
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var lthrFieldTestCard: some View {
        let warmupRemaining = max(0, 600 - Int(elapsedSeconds))
        let trialElapsed = max(0, Int(elapsedSeconds) - 600)
        let trialRemaining = max(0, 1200 - trialElapsed)
        let rollingTrialSamples = samples.filter { $0.elapsedSeconds >= 600 && $0.elapsedSeconds <= 1800 }
        let rollingLTHR = rollingTrialSamples.isEmpty ? 0 : rollingTrialSamples.map(\.bpm).reduce(0, +) / rollingTrialSamples.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("30-MIN LTHR FIELD TEST PROTOCOL", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.orange)
                Spacer()
                if isRecording {
                    Text(elapsedSeconds < 600 ? "PHASE 1: WARM-UP" : "PHASE 2: 20M TRIAL")
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            Text("10:00 progressive warm-up → 20:00 maximum sustainable pace. Average BPM of the final 20 minutes sets your exact Lactate Threshold HR & 5 zones automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isRecording {
                HStack {
                    if elapsedSeconds < 600 {
                        Text("Warm-Up Left: \(formatDuration(TimeInterval(warmupRemaining)))")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                    } else {
                        Text("Trial Left: \(formatDuration(TimeInterval(trialRemaining)))")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.orange)
                        Spacer()
                        Text("Live 20m LTHR: \(rollingLTHR > 0 ? "\(rollingLTHR) BPM" : "--")")
                            .font(.subheadline.weight(.heavy).monospacedDigit())
                            .foregroundStyle(.cyan)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func lthrSuccessBanner(lthr: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("LTHR Updated Automatically: \(lthr) BPM")
                    .font(.subheadline.weight(.bold))
                Text("Fighter zones switched to Lactate Threshold (LTHR %) model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("OK") { lthrTestResultBanner = nil }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
    }

    private var guidedBagCoachCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(isOn: $bagConfig.enabled) {
                    Label("Coached Bag Work & Tempo Metronome", systemImage: "metronome.fill")
                        .font(.subheadline.weight(.bold))
                }
                .tint(.orange)
                .onChange(of: bagConfig.enabled) { _, enabled in
                    if enabled {
                        roundTimerEnabled = true
                        workDurationSeconds = bagConfig.workSeconds
                        restDurationSeconds = bagConfig.restSeconds
                        if isRecording {
                            startBagEngine()
                        }
                    } else {
                        audioCoach.stopBagCoachLoop()
                    }
                }
            }

            if bagConfig.enabled {
                if isRecording {
                    VStack(spacing: 6) {
                        Text(audioCoach.currentComboDisplay.isEmpty ? "READY — HANDS UP" : audioCoach.currentComboDisplay)
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))

                        HStack {
                            Text("Strikes Cued: \(audioCoach.strikesCuedCount)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Music-Safe Audio (.mixWithOthers)")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                } else {
                    HStack {
                        Button("30m • 3×1m Steady") {
                            bagConfig.totalMinutes = 30
                            bagConfig.workSeconds = 180
                            bagConfig.restSeconds = 60
                            bagConfig.tempo = .steady
                            workDurationSeconds = 180
                            restDurationSeconds = 60
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button("15m • 3×1m Fight Pace") {
                            bagConfig.totalMinutes = 15
                            bagConfig.workSeconds = 180
                            bagConfig.restSeconds = 60
                            bagConfig.tempo = .fightPace
                            workDurationSeconds = 180
                            restDurationSeconds = 60
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Spacer()
                        Text("~\(bagConfig.estimatedTotalRounds) rds")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Picker("Audio", selection: $bagConfig.mode) {
                            ForEach(BagCoachMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.menu)

                        Spacer()

                        Picker("Tempo", selection: $bagConfig.tempo) {
                            ForEach(BagTempo.allCases) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    HStack(spacing: 12) {
                        Picker("Total", selection: $bagConfig.totalMinutes) {
                            ForEach([10, 15, 20, 30, 45, 60], id: \.self) { m in
                                Text("\(m) min").tag(m)
                            }
                        }
                        .pickerStyle(.menu)

                        Toggle("Kicks", isOn: $bagConfig.includeKicks)
                            .toggleStyle(.button)
                            .controlSize(.mini)
                        Toggle("Knees/Elbows", isOn: $bagConfig.includeKneesElbows)
                            .toggleStyle(.button)
                            .controlSize(.mini)
                        Toggle("Defense", isOn: $bagConfig.includeDefense)
                            .toggleStyle(.button)
                            .controlSize(.mini)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var roundBellCard: some View {
        let phaseTarget = isRestPeriod ? TimeInterval(restDurationSeconds) : TimeInterval(workDurationSeconds)
        let remaining = max(0, phaseTarget - phaseElapsed)

        return VStack(spacing: 10) {
            HStack {
                Toggle(isOn: $roundTimerEnabled) {
                    Label("Round Bell & Corner Timer", systemImage: "bell.fill")
                        .font(.subheadline.weight(.bold))
                }
                .tint(.orange)
            }

            if roundTimerEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isRestPeriod ? "ROUND \(currentRound) • STOOL REST" : "ROUND \(currentRound) • WORK")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(isRestPeriod ? .cyan : .orange)
                        Text(formatDuration(remaining))
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isRestPeriod ? .cyan : .primary)
                    }
                    Spacer()

                    if !isRecording {
                        VStack(alignment: .trailing, spacing: 6) {
                            Picker("Work", selection: $workDurationSeconds) {
                                Text("2:00 Work").tag(120)
                                Text("3:00 Work").tag(180)
                                Text("5:00 Work").tag(300)
                            }
                            .pickerStyle(.menu)

                            Picker("Rest", selection: $restDurationSeconds) {
                                Text("0:30 Rest").tag(30)
                                Text("0:45 Rest").tag(45)
                                Text("1:00 Rest").tag(60)
                            }
                            .pickerStyle(.menu)
                        }
                    } else if !isRestPeriod {
                        Button("End Round") {
                            transitionToRestPeriod()
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

    private var ghostSimulatorCard: some View {
        let availableGhosts = workoutStore.allAvailableGhosts()
        let ghostBPM = selectedGhost?.interpolatedBPM(at: elapsedSeconds)
        let delta: Int? = (bleManager.currentBPM > 0 && ghostBPM != nil) ? (bleManager.currentBPM - ghostBPM!) : nil

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Opponent Pace Simulator (Ghost)", systemImage: "figure.run.square.stack.fill")
                    .font(.subheadline.weight(.bold))
                Spacer()
                if !isRecording {
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

            if !isRecording {
                Picker("Ghost Session", selection: $selectedGhost) {
                    Text("None (Solo Session)").tag(Optional<GhostSession>.none)
                    ForEach(availableGhosts) { g in
                        Text(g.title).tag(Optional(g))
                    }
                }
                .pickerStyle(.menu)
            } else if let ghost = selectedGhost {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ghost.title)
                            .font(.caption.weight(.bold))
                        Text("Ghost BPM: \(ghostBPM != nil ? "\(ghostBPM!)" : "Finished")")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                    Spacer()
                    if let d = delta {
                        Text(d <= 0 ? "\(d) BPM (More Efficient)" : "+\(d) BPM (Higher Strain)")
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

    private var liveSparklineCard: some View {
        let recent = Array(samples.suffix(120))
        let zones = workoutStore.activeProfile.activeZones

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("REAL-TIME HEART RATE TRACE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if selectedGhost != nil {
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
                        LineMark(
                            x: .value("Time", pt.elapsedSeconds),
                            y: .value("BPM", pt.bpm)
                        )
                        .foregroundStyle(by: .value("Series", "Live"))
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }

                    if let ghost = selectedGhost {
                        ForEach(recent) { pt in
                            if let gBPM = ghost.interpolatedBPM(at: pt.elapsedSeconds) {
                                LineMark(
                                    x: .value("Time", pt.elapsedSeconds),
                                    y: .value("BPM", gBPM)
                                )
                                .foregroundStyle(by: .value("Series", "Ghost"))
                                .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                            }
                        }
                    }
                }
                .chartForegroundStyleScale([
                    "Live": Color.red,
                    "Ghost": Color.purple.opacity(0.8)
                ])
                .chartLegend(.hidden)
                .chartYScale(domain: 55...210)
                .chartXAxis(.hidden)
                .frame(height: 130)
            } else {
                Text("Start workout to stream live heart rate graph")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 95)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var controlButtons: some View {
        VStack(spacing: 10) {
            if !isRecording {
                Button {
                    startWorkout()
                } label: {
                    Label(selectedCategory == .lthrTest ? "Start 30-Min LTHR Test" : "Start Workout", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            } else {
                HStack(spacing: 12) {
                    Picker("RPE", selection: $rpeScore) {
                        ForEach(1...10, id: \.self) { val in
                            Text("RPE \(val)/10").tag(val)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    TextField("Corner note...", text: $workoutNotes)
                        .textFieldStyle(.roundedBorder)
                }

                Button(role: .destructive) {
                    finishAndSaveWorkout()
                } label: {
                    Label("Finish & Save Workout", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var liveAverageBPM: Int {
        guard !samples.isEmpty else { return bleManager.currentBPM }
        return samples.map(\.bpm).reduce(0, +) / samples.count
    }

    private var liveMaxBPM: Int {
        samples.map(\.bpm).max() ?? bleManager.currentBPM
    }

    private func startWorkout() {
        samples.removeAll()
        zoneSeconds = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
        activeCalories = 0
        bmrCalories = 0
        elapsedSeconds = 0
        currentRound = 1
        isRestPeriod = false
        phaseElapsed = 0
        currentRoundStartElapsed = 0
        currentRoundStartStrikes = 0
        roundEndPeakBPM = 0
        completedRounds.removeAll()
        pendingRecovery = nil
        autoHRREvents.removeAll()
        latestAutoHRRBanner = nil
        lthrTestResultBanner = nil
        lastAnnouncedZone = 0
        lastZone2AlertTime = -999
        lastPeriodicMinute = 0
        redlineSecondsAccumulator = 0
        lastRedlineAlertTime = -999
        lastGhostAlertTime = -999
        announced30sWarning = false
        announced10sWarning = false
        audioCoach.strikesCuedCount = 0
        audioCoach.prepareForWorkout()

        startTime = Date()
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true

        if roundTimerEnabled || bagConfig.enabled {
            audioCoach.playBellCue()
        }
        if bagConfig.enabled {
            startBagEngine()
        }

        startLiveActivity()

        // Added in .common mode so ticks keep firing while the user scrolls
        // (a plain scheduledTimer pauses during scroll tracking, which made the
        // round clock and zone-time counters fall behind).
        let t = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                recordSecondTick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func startBagEngine() {
        audioCoach.startBagCoachLoop(
            config: bagConfig,
            isWorkPhaseProvider: { [self] in !self.roundTimerEnabled || !self.isRestPeriod },
            roundProgressProvider: { [self] in
                guard self.roundTimerEnabled, self.workDurationSeconds > 0 else { return 0.5 }
                return min(1.0, self.phaseElapsed / Double(self.workDurationSeconds))
            }
        )
    }

    private func recordSecondTick() {
        guard isRecording, let start = startTime else { return }
        elapsedSeconds = Date().timeIntervalSince(start)
        let bpm = bleManager.currentBPM
        let profile = workoutStore.activeProfile
        let coachCfg = profile.audioCoach

        let calSplit = FighterAnalytics.calculateCalorieBreakdown(bpm: bpm, durationSeconds: 1.0, profile: profile)
        activeCalories += calSplit.active
        bmrCalories += calSplit.bmr

        if bpm > 0 {
            let rr = bleManager.consumeLatestRRIntervals()
            samples.append(HeartRatePoint(timestamp: Date(), elapsedSeconds: elapsedSeconds, bpm: bpm, rrIntervalsMs: rr))
            let z = profile.zone(for: bpm)
            zoneSeconds[z.number, default: 0] += 1.0

            if roundTimerEnabled && !isRestPeriod {
                roundEndPeakBPM = max(roundEndPeakBPM, bpm)
            }

            evaluateAutomaticHRR(bpm: bpm, profile: profile)
            evaluateLiveAudioCoaching(bpm: bpm, zone: z, profile: profile, coachCfg: coachCfg)
        }

        if roundTimerEnabled {
            phaseElapsed += 1.0
            let target = isRestPeriod ? TimeInterval(restDurationSeconds) : TimeInterval(workDurationSeconds)
            let remain = Int(round(target - phaseElapsed))

            if !isRestPeriod && coachCfg.masterEnabled && coachCfg.announceRoundWarnings {
                if remain == 30 && !announced30sWarning {
                    announced30sWarning = true
                    audioCoach.announceCoachingCue("30 seconds left in Round \(currentRound), heart rate \(bpm)", enabled: true)
                } else if remain == 10 && !announced10sWarning {
                    announced10sWarning = true
                    audioCoach.announceCoachingCue("10 seconds, empty the tank!", enabled: true)
                }
            }

            if phaseElapsed >= target {
                if isRestPeriod {
                    let stoolDrop: Int? = (roundEndPeakBPM > 0 && bpm > 0) ? max(0, roundEndPeakBPM - bpm) : nil
                    let roundSamples = samples.filter { $0.elapsedSeconds >= currentRoundStartElapsed && $0.elapsedSeconds <= (elapsedSeconds - TimeInterval(restDurationSeconds)) }
                    let avgR = roundSamples.isEmpty ? bpm : roundSamples.map(\.bpm).reduce(0, +) / roundSamples.count
                    let peakR = roundSamples.map(\.bpm).max() ?? roundEndPeakBPM
                    let roundStrikes = max(0, audioCoach.strikesCuedCount - currentRoundStartStrikes)

                    completedRounds.append(RoundStat(
                        roundNumber: currentRound,
                        startElapsed: currentRoundStartElapsed,
                        endElapsed: elapsedSeconds - TimeInterval(restDurationSeconds),
                        avgBPM: avgR,
                        peakBPM: peakR,
                        stoolDropBPM: stoolDrop,
                        strikesCued: roundStrikes
                    ))

                    if let drop = stoolDrop, coachCfg.masterEnabled && coachCfg.announceStoolRecovery {
                        audioCoach.announceCoachingCue("Stool recovery \(drop) B P M. Round \(currentRound + 1)!", enabled: true)
                    }

                    currentRound += 1
                    isRestPeriod = false
                    phaseElapsed = 0
                    currentRoundStartElapsed = elapsedSeconds
                    currentRoundStartStrikes = audioCoach.strikesCuedCount
                    roundEndPeakBPM = 0
                    announced30sWarning = false
                    announced10sWarning = false
                    audioCoach.playBellCue()
                } else {
                    transitionToRestPeriod()
                }
            }
        }

        if selectedCategory == .lthrTest {
            if Int(elapsedSeconds) == 600 {
                audioCoach.playBellCue()
                audioCoach.announceCoachingCue("Warm up complete. Begin 20 minute threshold time trial now!", enabled: true)
            } else if elapsedSeconds >= 1800 {
                finishAndSaveWorkout()
                return
            }
        }

        updateLiveActivity()
    }

    private func transitionToRestPeriod() {
        isRestPeriod = true
        phaseElapsed = 0
        announced30sWarning = false
        announced10sWarning = false
        audioCoach.playBellCue()

        let peak = max(roundEndPeakBPM, bleManager.currentBPM)
        if peak > 90 {
            pendingRecovery = PendingRecoveryTracker(
                startElapsed: elapsedSeconds,
                peakBPM: peak,
                contextLabel: "Round \(currentRound) Stool Rest",
                lowestSeenBPM: peak
            )
        }
    }

    private func evaluateAutomaticHRR(bpm: Int, profile: AthleteProfile) {
        let highEffortThreshold = Int(Double(profile.effectiveMaxHR) * 0.80)

        if var tracker = pendingRecovery {
            tracker.lowestSeenBPM = min(tracker.lowestSeenBPM, bpm)
            if !isRestPeriod && bpm > tracker.peakBPM + 3 {
                pendingRecovery = nil
                return
            }
            pendingRecovery = tracker

            if elapsedSeconds - tracker.startElapsed >= 60.0 {
                let drop = max(0, tracker.peakBPM - bpm)
                if drop >= 8 {
                    let event = AutoHRREvent(
                        elapsedSeconds: elapsedSeconds,
                        peakBPM: tracker.peakBPM,
                        recovery60BPM: bpm,
                        dropBPM: drop,
                        contextLabel: tracker.contextLabel
                    )
                    autoHRREvents.append(event)
                    latestAutoHRRBanner = "Auto HRR-60 Detected: -\(drop) BPM (\(tracker.peakBPM) → \(bpm) BPM)"
                }
                pendingRecovery = nil
            }
        } else if !roundTimerEnabled && bpm >= highEffortThreshold {
            if samples.count >= 12 {
                let recent10 = samples.suffix(10).map(\.bpm)
                if let localPeak = recent10.max(), localPeak >= highEffortThreshold && (localPeak - bpm) >= 5 {
                    pendingRecovery = PendingRecoveryTracker(
                        startElapsed: elapsedSeconds,
                        peakBPM: localPeak,
                        contextLabel: "Mid-Session Recovery",
                        lowestSeenBPM: bpm
                    )
                }
            }
        }
    }

    private func evaluateLiveAudioCoaching(bpm: Int, zone: HeartRateZoneInfo, profile: AthleteProfile, coachCfg: AudioCoachSettings) {
        guard coachCfg.masterEnabled else { return }

        if coachCfg.zone2CeilingAlert && (selectedCategory == .roadwork || selectedDrillTag == .aerobicZ2) {
            let z2Max = profile.activeZones.z2Max
            if bpm > z2Max && (elapsedSeconds - lastZone2AlertTime) >= 45 {
                lastZone2AlertTime = elapsedSeconds
                audioCoach.announceCoachingCue("Zone 2 ceiling reached at \(bpm) B P M, ease pace.", enabled: true)
            }
        }

        if coachCfg.announceZoneCrossings && zone.number != lastAnnouncedZone && elapsedSeconds > 15 {
            if zone.number >= 3 {
                audioCoach.announceCoachingCue("Entering \(zone.name), \(bpm) B P M.", enabled: true)
            }
            lastAnnouncedZone = zone.number
        } else if lastAnnouncedZone == 0 {
            lastAnnouncedZone = zone.number
        }

        let redlineCutoff = Int(Double(profile.effectiveMaxHR) * 0.92)
        if bpm >= redlineCutoff {
            redlineSecondsAccumulator += 1
            if coachCfg.announceRedlineWarning && redlineSecondsAccumulator >= 45 && (elapsedSeconds - lastRedlineAlertTime) >= 90 {
                lastRedlineAlertTime = elapsedSeconds
                audioCoach.announceCoachingCue("Sustained redline warning, heart rate \(bpm).", enabled: true)
            }
        } else {
            redlineSecondsAccumulator = 0
        }

        if coachCfg.announceGhostDelta, let ghost = selectedGhost, let gBPM = ghost.interpolatedBPM(at: elapsedSeconds), (elapsedSeconds - lastGhostAlertTime) >= 75 {
            let diff = bpm - gBPM
            if abs(diff) >= 8 {
                lastGhostAlertTime = elapsedSeconds
                if diff > 0 {
                    audioCoach.announceCoachingCue("Ghost pace check: \(diff) B P M higher than opponent.", enabled: true)
                } else {
                    audioCoach.announceCoachingCue("Ghost pace check: \(abs(diff)) B P M more efficient than opponent.", enabled: true)
                }
            }
        }

        if coachCfg.periodicMinutes > 0 {
            let currentMinute = Int(elapsedSeconds) / 60
            if currentMinute > 0 && currentMinute != lastPeriodicMinute && (currentMinute % coachCfg.periodicMinutes == 0) {
                lastPeriodicMinute = currentMinute
                audioCoach.announceCoachingCue("\(currentMinute) minutes elapsed, heart rate \(bpm), \(zone.shortName).", enabled: true)
            }
        }
    }

    private func finishAndSaveWorkout() {
        timer?.invalidate()
        timer = nil
        audioCoach.stopBagCoachLoop()
        audioCoach.shutdownAudio()
        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        endLiveActivity()

        let end = Date()
        let start = startTime ?? end.addingTimeInterval(-elapsedSeconds)
        let profile = workoutStore.activeProfile
        let bpms = samples.map(\.bpm)
        let avgBPM = bpms.isEmpty ? bleManager.currentBPM : (bpms.reduce(0, +) / bpms.count)
        let maxBPM = bpms.max() ?? avgBPM
        let minBPM = bpms.min() ?? avgBPM

        if selectedCategory == .lthrTest {
            let trialSamples = samples.filter { $0.elapsedSeconds >= 600 }
            let source = trialSamples.count >= 30 ? trialSamples : samples
            if !source.isEmpty {
                let computedLTHR = source.map(\.bpm).reduce(0, +) / source.count
                var updatedProfile = profile
                updatedProfile.lactateThresholdHR = computedLTHR
                updatedProfile.zoneMethod = .lactateThreshold
                updatedProfile.sanitize()
                workoutStore.activeProfile = updatedProfile
                lthrTestResultBanner = computedLTHR
            }
        }

        let bestHRR = autoHRREvents.map(\.dropBPM).max()
        let trimp = FighterAnalytics.calculateTRIMP(samples: samples, profile: profile)
        let drift = FighterAnalytics.calculateCardiacDrift(samples: samples)
        let rmssd = FighterAnalytics.calculateRMSSD(samples: samples)
        let epoc = FighterAnalytics.calculateEPOC(zoneSeconds: zoneSeconds, weightKg: profile.weightKg)
        let pois = FighterAnalytics.detectPointsOfInterest(
            samples: samples,
            roundStats: completedRounds,
            autoHRREvents: autoHRREvents,
            profile: profile
        )

        var ghostAvgDelta: Double?
        if let ghost = selectedGhost, !samples.isEmpty {
            let deltas = samples.compactMap { pt -> Double? in
                guard let g = ghost.interpolatedBPM(at: pt.elapsedSeconds) else { return nil }
                return Double(pt.bpm - g)
            }
            if !deltas.isEmpty {
                ghostAvgDelta = deltas.reduce(0, +) / Double(deltas.count)
            }
        }

        let saved = SavedWorkout(
            id: UUID(),
            profileID: profile.id,
            profileName: profile.name,
            category: selectedCategory,
            drillTag: selectedDrillTag,
            rpe: rpeScore,
            notes: workoutNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: start,
            endDate: end,
            duration: elapsedSeconds,
            averageBPM: avgBPM,
            maxBPM: maxBPM,
            minBPM: minBPM,
            activeCalories: activeCalories,
            bmrCalories: bmrCalories,
            calories: activeCalories + bmrCalories,
            epocBonusCalories: epoc,
            trimpScore: trimp,
            cardiacDriftPercent: drift,
            hrr60Drop: bestHRR,
            autoHRREvents: autoHRREvents,
            rmssdMs: rmssd,
            strikesCuedCount: audioCoach.strikesCuedCount,
            ghostBaselineName: selectedGhost?.title,
            ghostAvgDeltaBPM: ghostAvgDelta,
            zoneSeconds: zoneSeconds,
            roundStats: completedRounds,
            pointsOfInterest: pois,
            samples: samples,
            isCompressedArchive: false,
            archiveFileName: nil
        )

        workoutStore.save(saved)
        finishedWorkout = saved
        workoutNotes = ""
        showingPostWorkoutSummary = true
    }

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let profile = workoutStore.activeProfile
        let attributes = WorkoutActivityAttributes(
            athleteName: profile.name,
            discipline: selectedCategory.rawValue
        )
        let state = WorkoutActivityAttributes.ContentState(
            currentBPM: bleManager.currentBPM,
            zoneNumber: 1,
            zoneShortName: "Z1",
            calories: 0,
            workoutStartDate: Date(),
            isTimedRound: roundTimerEnabled,
            roundNumber: 1,
            isRest: false,
            phaseEndDate: Date().addingTimeInterval(TimeInterval(workDurationSeconds))
        )
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            print("Live Activity start failed: \(error)")
        }
    }

    private func updateLiveActivity() {
        guard let activity = currentActivity else { return }
        let z = workoutStore.activeProfile.zone(for: bleManager.currentBPM)
        let target = isRestPeriod ? TimeInterval(restDurationSeconds) : TimeInterval(workDurationSeconds)
        let remain = max(0, target - phaseElapsed)

        let state = WorkoutActivityAttributes.ContentState(
            currentBPM: bleManager.currentBPM,
            zoneNumber: z.number,
            zoneShortName: z.shortName,
            calories: Int(activeCalories),
            workoutStartDate: startTime ?? Date(),
            isTimedRound: roundTimerEnabled,
            roundNumber: currentRound,
            isRest: isRestPeriod,
            phaseEndDate: Date().addingTimeInterval(remain)
        )
        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    private func endLiveActivity() {
        guard let activity = currentActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            currentActivity = nil
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
