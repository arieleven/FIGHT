import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @EnvironmentObject var workoutStore: WorkoutStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    connectionCard
                    heartRateHeroCard
                    exerciseSelectorSection
                    actionButton

                    if let status = workoutStore.statusMessage {
                        Text(status)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                    }

                    if !workoutStore.savedWorkouts.isEmpty {
                        savedWorkoutsSection
                    }
                }
                .padding()
            }
            .navigationTitle("Coospo Workout")
            .onAppear {
                bleManager.onHeartRateSample = { bpm, date in
                    workoutStore.recordHeartRate(bpm, at: date)
                }
            }
            .onChange(of: workoutStore.isWorkoutActive) { _, active in
                UIApplication.shared.isIdleTimerDisabled = active
            }
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

            if let battery = bleManager.batteryLevel {
                Label("\(battery)%", systemImage: "battery.75")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
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

    private var heartRateHeroCard: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.title)
                    .foregroundStyle(zoneInfo.color)
                Text(bleManager.currentBPM > 0 ? "\(bleManager.currentBPM)" : "--")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("BPM")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(zoneInfo.label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(zoneInfo.color.opacity(0.2), in: Capsule())
                .foregroundStyle(zoneInfo.color)

            Divider()

            HStack {
                metricItem(title: "TIME", value: formatDuration(workoutStore.elapsedSeconds))
                Spacer()
                metricItem(title: "AVG BPM", value: workoutStore.averageBPM > 0 ? "\(workoutStore.averageBPM)" : "--")
                Spacer()
                metricItem(title: "MAX BPM", value: workoutStore.maxBPM > 0 ? "\(workoutStore.maxBPM)" : "--")
                Spacer()
                metricItem(title: "KCAL", value: "\(Int(workoutStore.estimatedCalories))")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
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

    private var exerciseSelectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SELECT WORKOUT")
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
        }
    }

    private var actionButton: some View {
        Button {
            if workoutStore.isWorkoutActive {
                workoutStore.endAndSaveWorkout()
            } else {
                workoutStore.startWorkout()
            }
        } label: {
            HStack {
                Image(systemName: workoutStore.isWorkoutActive ? "stop.fill" : "play.fill")
                Text(workoutStore.isWorkoutActive
                     ? "End & Save \(workoutStore.selectedCategory.rawValue)"
                     : "Start \(workoutStore.selectedCategory.rawValue)")
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(workoutStore.isWorkoutActive ? Color.red : Color.green, in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.white)
        }
    }

    private var savedWorkoutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WORKOUT LOG")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ForEach(workoutStore.savedWorkouts) { item in
                HStack {
                    Image(systemName: item.category.icon)
                        .font(.title3)
                        .foregroundStyle(.green)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(item.category.rawValue) • \(item.startDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline.weight(.semibold))
                        Text("\(formatDuration(item.duration)) • Avg \(item.averageBPM) • Max \(item.maxBPM) BPM • \(Int(item.calories)) kcal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    ShareLink(item: workoutStore.exportTCXFile(for: item)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .padding(8)
                            .background(Color(.tertiarySystemFill), in: Circle())
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
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

    private var zoneInfo: (label: String, color: Color) {
        let bpm = bleManager.currentBPM
        switch bpm {
        case ..<100: return ("REST / WARM UP", .gray)
        case 100..<120: return ("ZONE 1 • LIGHT", .blue)
        case 120..<140: return ("ZONE 2 • FAT BURN", .green)
        case 140..<160: return ("ZONE 3 • AEROBIC", .yellow)
        case 160..<175: return ("ZONE 4 • THRESHOLD", .orange)
        default: return ("ZONE 5 • PEAK", .red)
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