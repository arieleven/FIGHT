import SwiftUI

struct CoachSummaryView: View {
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @EnvironmentObject var workoutStore: WorkoutStore

    var body: some View {
        let analytics = workoutStore.computeFighterAnalytics()
        let profile = workoutStore.activeProfile

        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    staminaHeroCard(analytics: analytics, profile: profile)
                    recoveryAndSleepCard(analytics: analytics)
                    morningHRVCard(profile: profile)
                    prescriptionsSection(analytics: analytics)
                }
                .padding()
            }
            .navigationTitle("Fighter Coach")
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
                Label("7-Day TRIMP Load: \(Int(analytics.weeklyTRIMP))", systemImage: "flame.fill")
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

            HStack(spacing: 16) {
                if let hrv = analytics.latestHRV {
                    Text("HRV RMSSD: \(Int(hrv)) ms")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                }
                if let hrr = analytics.latestHRR60 {
                    Text("Last HRR-60: -\(hrr) BPM")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
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