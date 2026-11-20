import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @EnvironmentObject var workoutStore: WorkoutStore

    var body: some View {
        TabView {
            trainTab
                .tabItem {
                    Label("Train", systemImage: "heart.fill")
                }

            CoachSummaryView()
                .tabItem {
                    Label("Coach", systemImage: "chart.line.uptrend.xyaxis")
                }

            ProfileSettingsView()
                .tabItem {
                    Label("Fighter", systemImage: "person.crop.circle")
                }
        }
        .onAppear {
            bleManager.onHeartRateSample = { bpm, rrMs, date in
                workoutStore.recordHeartRate(bpm, rrMs: rrMs, at: date)
            }
        }
        .onChange(of: workoutStore.isWorkoutActive) { _, active in
            UIApplication.shared.isIdleTimerDisabled = active || workoutStore.isMeasuringHRR
        }
    }

    // MARK: - Tab 1: Train
    private var trainTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    connectionCard
                    if workoutStore.isMeasuringHRR {
                        hrrMeasurementCard
                    }
                    heartRateHeroCard
                    if workoutStore.isWorkoutActive && workoutStore.selectedRoundPreset != .open {
                        activeRoundCard
                    }
                    workoutConfigSection
                    actionButton

                    if let status = workoutStore.statusMessage {
                        Text(status)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                    }

                    if !workoutStore.activeProfileWorkouts.isEmpty {
                        savedWorkoutsSection
                    }
                }
                .padding()
            }
            .navigationTitle("\(workoutStore.activeProfile.name) • Train")
        }
    }

    private var connectionCard: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(bleManager.deviceName)
                    .font(.headline)
                Text(bleManager.connectionState.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let rmssd = bleManager.rollingRMSSD {
                Text("HRV \(Int(rmssd))ms")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.2), in: Capsule())
                    .foregroundStyle(.purple)
            }

            if let battery = bleManager.batteryLevel {
                Label("\(battery)%", systemImage: "battery.75")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if bleManager.connectionState == .connected {
                Button("Disconnect") {
                    bleManager.disconnect()
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            } else {
                Button("Scan") {
                    bleManager.startScanning()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var hrrMeasurementCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "lungs.fill")
                    .font(.title2)
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading) {
                    Text("MEASURING HEART RATE RECOVERY (HRR-60)")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.cyan)
                    Text("Stand still & breathe normally for \(workoutStore.hrrSecondsRemaining)s")
                        .font(.subheadline)
                }
                Spacer()
            }

            HStack {
                Text("Drop so far: -\(workoutStore.hrrCurrentDrop) BPM")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.green)
                Spacer()
                Button("Skip & Save Now") {
                    workoutStore.skipHRRAndSaveNow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color.cyan.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
    }

    private var heartRateHeroCard: some View {
        let profile = workoutStore.activeProfile
        let zone = profile.zone(for: bleManager.currentBPM)

        return VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.title)
                    .foregroundStyle(zone.color)
                Text(bleManager.currentBPM > 0 ? "\(bleManager.currentBPM)" : "--")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("BPM")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(bleManager.currentBPM > 0 ? zone.name.uppercased() : "WAITING FOR PULSE")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(zone.color.opacity(0.2), in: Capsule())
                .foregroundStyle(zone.color)

            Divider()

            HStack {
                metricItem(title: "TIME", value: formatDuration(workoutStore.elapsedSeconds))
                Spacer()
                metricItem(title: "AVG", value: workoutStore.averageBPM > 0 ? "\(workoutStore.averageBPM)" : "--")
                Spacer()
                metricItem(title: "MAX", value: workoutStore.maxBPM > 0 ? "\(workoutStore.maxBPM)" : "--")
                Spacer()
                metricItem(title: "KCAL (+\(Int(workoutStore.epocBonusCalories)))", value: "\(Int(workoutStore.estimatedCalories))")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var activeRoundCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ROUND \(workoutStore.currentRound) • \(workoutStore.isRoundRest ? "STOOL REST" : "WORK")")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(workoutStore.isRoundRest ? .cyan : .orange)
                Text(workoutStore.isRoundRest ? "Drop HR via slow nasal exhales" : "Keep output sharp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatDuration(TimeInterval(workoutStore.roundSecondsRemaining)))
                .font(.system(size: 32, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(workoutStore.isRoundRest ? .cyan : .orange)
        }
        .padding()
        .background(
            (workoutStore.isRoundRest ? Color.cyan : Color.orange).opacity(0.15),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    private func metricItem(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
    }

    private var workoutConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DISCIPLINE")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(WorkoutCategory.allCases) { category in
                        let isSelected = workoutStore.selectedCategory == category
                        Button {
                            if !workoutStore.isWorkoutActive {
                                workoutStore.selectedCategory = category
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: category.icon)
                                Text(category.rawValue)
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                isSelected ? Color.accentColor : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? .white : .primary)
                        }
                        .disabled(workoutStore.isWorkoutActive)
                    }
                }
            }

            Text("ROUND BELL TIMER")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RoundPreset.allCases) { preset in
                        let selected = workoutStore.selectedRoundPreset == preset
                        Button {
                            if !workoutStore.isWorkoutActive {
                                workoutStore.selectedRoundPreset = preset
                            }
                        } label: {
                            Text(preset.rawValue)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    selected ? Color.orange : Color(.secondarySystemBackground),
                                    in: Capsule()
                                )
                                .foregroundStyle(selected ? .white : .primary)
                        }
                        .disabled(workoutStore.isWorkoutActive)
                    }
                }
            }
        }
    }

    private var actionButton: some View {
        Button {
            if workoutStore.isWorkoutActive {
                workoutStore.initiateFinishAndMeasureHRR(currentBPM: bleManager.currentBPM)
            } else if !workoutStore.isMeasuringHRR {
                workoutStore.startWorkout()
            }
        } label: {
            HStack {
                Image(systemName: workoutStore.isWorkoutActive ? "stop.fill" : "play.fill")
                Text(workoutStore.isWorkoutActive
                     ? "Finish & Measure 60s Recovery"
                     : "Start \(workoutStore.selectedCategory.rawValue)")
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(workoutStore.isWorkoutActive ? Color.red : Color.green, in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.white)
        }
        .disabled(workoutStore.isMeasuringHRR)
    }

    private var savedWorkoutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WORKOUT LOG (TAP FOR GRAPH & HIGHLIGHTS)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ForEach(workoutStore.activeProfileWorkouts) { item in
                NavigationLink {
                    WorkoutDetailView(workout: item)
                } label: {
                    HStack {
                        Image(systemName: item.category.icon)
                            .font(.title3)
                            .foregroundStyle(.green)
                            .frame(width: 30)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(item.category.rawValue) • \(item.startDate.formatted(date: .abbreviated, time: .shortened))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(formatDuration(item.duration)) • Avg \(item.averageBPM) • Max \(item.maxBPM) • \(Int(item.calories)) kcal\(item.hrr60Drop != nil ? " • HRR -\(item.hrr60Drop!)" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private var statusColor: Color {
        switch bleManager.connectionState {
        case .connected: return .green
        case .scanning, .connecting, .reconnecting: return .orange
        case .disconnected, .bluetoothOff: return .red
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        return hrs > 0
            ? String(format: "%d:%02d:%02d", hrs, mins, secs)
            : String(format: "%02d:%02d", mins, secs)
    }
}