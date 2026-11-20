import SwiftUI

struct CoachSummaryView: View {
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @EnvironmentObject var workoutStore: WorkoutStore

    @State private var showingWeighInSheet = false
    @State private var showingOverlaySheet = false

    var body: some View {
        let analytics = workoutStore.computeFighterAnalytics()
        let profile = workoutStore.activeProfile

        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    staminaHeroCard(analytics: analytics, profile: profile)
                    fightWeekWeighInCard(profile: profile)
                    recoveryAndSleepCard(analytics: analytics)
                    morningHRVCard(profile: profile)
                    prescriptionsSection(analytics: analytics)
                }
                .padding()
            }
            .navigationTitle("Fighter Coach")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingOverlaySheet = true
                    } label: {
                        Label("Compare", systemImage: "square.stack.3d.up")
                    }
                }
            }
            .sheet(isPresented: $showingWeighInSheet) {
                WeighInEntrySheet()
            }
            .sheet(isPresented: $showingOverlaySheet) {
                ComparisonView(initialBaselineWorkout: nil)
            }
        }
    }

    private func staminaHeroCard(analytics: FighterAnalytics, profile: AthleteProfile) -> some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(profile.name.uppercased()) • READINESS")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(analytics.trendLabel)
                        .font(.title3.weight(.bold))
                }
                Spacer()
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.25), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: CGFloat(analytics.staminaRating) / 100.0)
                        .stroke(ratingColor(analytics.staminaRating), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(analytics.staminaRating)")
                            .font(.title2.weight(.heavy).monospacedDigit())
                        Text("STAMINA")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 74, height: 74)
            }

            Divider()

            HStack(spacing: 12) {
                subScorePill(title: "AEROBIC BASE", score: analytics.aerobicScore, color: .green)
                subScorePill(title: "ANAEROBIC GAS", score: analytics.anaerobicScore, color: .orange)
                subScorePill(title: "RECOVERY", score: analytics.recoveryScore, color: .cyan)
            }

            HStack {
                Label("7-Day TRIMP: \(Int(analytics.weeklyTRIMP))", systemImage: "flame.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Label("Target: \(profile.dailyCalorieTarget) kcal/d", systemImage: "fork.knife")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func subScorePill(title: String, score: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text("\(score)/100")
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Fight Week Water-Cut & Morning Weigh-In Log
    private func fightWeekWeighInCard(profile: AthleteProfile) -> some View {
        let entries = workoutStore.activeProfileWeighIns
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FIGHT WEEK WEIGH-IN & HYDRATION")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("Current: \(String(format: "%.1f", profile.weightKg)) kg • Target: \(String(format: "%.1f", profile.targetFightWeightKg)) kg")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                Button("Log Weigh-In") {
                    showingWeighInSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }

            if let latest = entries.first {
                HStack(spacing: 12) {
                    Text(latest.hydration.label)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(latest.hydration.color.opacity(0.2), in: Capsule())
                        .foregroundStyle(latest.hydration.color)
                    Spacer()
                    Text("Morning RHR: \(latest.morningRestingHR) BPM")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Log morning fasted weight, urine hydration status, and resting HR to detect over-dehydration spikes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func recoveryAndSleepCard(analytics: FighterAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECOVERY & SLEEP PRESCRIPTION")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("FULL RECOVERY", systemImage: "timer")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.cyan)
                    Text("\(analytics.recommendedRecoveryHours) hrs")
                        .font(.title2.weight(.bold))
                    Text("Before next hard sparring")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Label("TONIGHT'S SLEEP", systemImage: "bed.double.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.purple)
                    Text(String(format: "%.1f hrs", analytics.recommendedSleepHours))
                        .font(.title2.weight(.bold))
                    Text(analytics.latestHRV != nil ? "Calibrated via HRV" : "Calibrated via TRIMP")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func morningHRVCard(profile: AthleteProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("60-SEC MORNING / PRE-SESSION HRV CHECK")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("Baseline RMSSD: \(Int(profile.baselineRMSSD)) ms")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                if bleManager.isHRVScanning {
                    Button("Stop (\(bleManager.hrvScanSecondsLeft)s)") {
                        bleManager.cancelMorningHRVScan()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                } else {
                    Button("Measure HRV") {
                        bleManager.startMorningHRVScan { result in
                            if let rmssd = result {
                                workoutStore.updateBaselineHRV(rmssd)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                    .disabled(bleManager.connectionState != .connected)
                }
            }

            if bleManager.isHRVScanning {
                ProgressView(value: Double(60 - bleManager.hrvScanSecondsLeft), total: 60.0)
                    .tint(.purple)
                Text("Sit still and breathe normally. Live RMSSD: \(bleManager.rollingRMSSD != nil ? "\(Int(bleManager.rollingRMSSD!)) ms" : "Collecting RR intervals...")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let last = bleManager.lastMorningHRV {
                Text("Recorded RMSSD: \(Int(last)) ms — \(last >= profile.baselineRMSSD * 0.9 ? "CNS Primed for Hard Rounds" : "Elevated Stress — Prioritize Recovery")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else if bleManager.connectionState != .connected {
                Text("Connect your Coospo HW9 on the Train tab to run a 60s HRV check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func prescriptionsSection(analytics: FighterAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WHAT TO WORK ON NEXT")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ForEach(analytics.prescriptions) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: item.icon)
                            .foregroundStyle(item.tagColor)
                        Text(item.tag)
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(item.tagColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(item.tagColor)
                        Spacer()
                    }

                    Text(item.title)
                        .font(.headline)

                    Text(item.diagnosis)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(item.actionPlan)
                        .font(.subheadline)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func ratingColor(_ score: Int) -> Color {
        if score >= 80 { return .green }
        if score >= 65 { return .orange }
        return .red
    }
}

struct WeighInEntrySheet: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @Environment(\.dismiss) private var dismiss

    @State private var weightInput: Double = 85.0
    @State private var hydration: HydrationStatus = .slight
    @State private var morningRHR: Int = 58
    @FocusState private var isWeightFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Morning Fasted Metrics") {
                    HStack {
                        Text("Fasted Weight (kg)")
                        Spacer()
                        TextField("kg", value: $weightInput, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 85)
                            .focused($isWeightFocused)
                    }

                    Picker("Urine Hydration Status", selection: $hydration) {
                        ForEach(HydrationStatus.allCases) { h in
                            Text(h.label).tag(h)
                        }
                    }

                    Stepper("Morning Resting HR: \(morningRHR) BPM", value: $morningRHR, in: 35...115)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Log Fight Weigh-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isWeightFocused = false }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        workoutStore.logWeighIn(weightKg: weightInput, hydration: hydration, morningRHR: morningRHR)
                        dismiss()
                    }
                }
            }
            .onAppear {
                weightInput = workoutStore.activeProfile.weightKg
                morningRHR = bleManager.currentBPM > 0 ? bleManager.currentBPM : workoutStore.activeProfile.restingHR
            }
        }
    }
}