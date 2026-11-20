import SwiftUI
import Charts

struct ComparisonView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @Environment(\.dismiss) private var dismiss

    let initialBaselineWorkout: SavedWorkout?

    @State private var baselineID: UUID?
    @State private var contenderID: UUID?

    private var baseline: SavedWorkout? {
        workoutStore.workouts.first { $0.id == baselineID }
    }

    private var contender: SavedWorkout? {
        workoutStore.workouts.first { $0.id == contenderID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    sessionSelectors

                    if let base = baseline, let cont = contender {
                        overlayChartCard(baseline: base, contender: cont)
                        headToHeadMetricsCard(baseline: base, contender: cont)
                    } else {
                        ContentUnavailableView(
                            "Select Two Workouts",
                            systemImage: "square.stack.3d.up",
                            description: Text("Compare sparring sessions, bag workouts, or roadwork progress side-by-side.")
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("Compare Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if baselineID == nil {
                    baselineID = initialBaselineWorkout?.id ?? workoutStore.workouts.first?.id
                }
                if contenderID == nil {
                    contenderID = workoutStore.workouts.first(where: { $0.id != baselineID })?.id
                }
            }
        }
    }

    private var sessionSelectors: some View {
        VStack(spacing: 10) {
            HStack {
                Circle().fill(.cyan).frame(width: 10, height: 10)
                Text("Baseline")
                    .font(.caption.weight(.bold))
                Spacer()
                Picker("Baseline", selection: $baselineID) {
                    ForEach(workoutStore.workouts) { w in
                        Text("\(w.category.rawValue) • \(w.startDate.formatted(date: .abbreviated, time: .omitted))").tag(Optional(w.id))
                    }
                }
                .pickerStyle(.menu)
            }

            Divider()

            HStack {
                Circle().fill(.orange).frame(width: 10, height: 10)
                Text("Compare")
                    .font(.caption.weight(.bold))
                Spacer()
                Picker("Compare", selection: $contenderID) {
                    ForEach(workoutStore.workouts) { w in
                        Text("\(w.category.rawValue) • \(w.startDate.formatted(date: .abbreviated, time: .omitted))").tag(Optional(w.id))
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func overlayChartCard(baseline: SavedWorkout, contender: SavedWorkout) -> some View {
        let baseSamples = downsample(workoutStore.resolvedSamples(for: baseline), maxPoints: 180)
        let contSamples = downsample(workoutStore.resolvedSamples(for: contender), maxPoints: 180)

        return VStack(alignment: .leading, spacing: 10) {
            Text("HEART RATE CURVE OVERLAY")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            if baseSamples.count >= 2 && contSamples.count >= 2 {
                Chart {
                    ForEach(baseSamples) { pt in
                        LineMark(
                            x: .value("Elapsed", pt.elapsedSeconds),
                            y: .value("BPM", pt.bpm)
                        )
                        .foregroundStyle(by: .value("Session", "Baseline"))
                    }
                    ForEach(contSamples) { pt in
                        LineMark(
                            x: .value("Elapsed", pt.elapsedSeconds),
                            y: .value("BPM", pt.bpm)
                        )
                        .foregroundStyle(by: .value("Session", "Compare"))
                    }
                }
                .chartForegroundStyleScale([
                    "Baseline": Color.cyan,
                    "Compare": Color.orange
                ])
                .frame(height: 220)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func headToHeadMetricsCard(baseline: SavedWorkout, contender: SavedWorkout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HEAD-TO-HEAD CONDITIONING DELTA")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            deltaRow(
                metric: "Average HR",
                baseVal: "\(baseline.averageBPM) BPM",
                contVal: "\(contender.averageBPM) BPM",
                diff: contender.averageBPM - baseline.averageBPM,
                lowerIsBetter: true
            )
            deltaRow(
                metric: "Peak HR",
                baseVal: "\(baseline.maxBPM) BPM",
                contVal: "\(contender.maxBPM) BPM",
                diff: contender.maxBPM - baseline.maxBPM,
                lowerIsBetter: false
            )
            deltaRow(
                metric: "Active Burn",
                baseVal: "\(Int(baseline.activeCalories)) kcal",
                contVal: "\(Int(contender.activeCalories)) kcal",
                diff: Int(contender.activeCalories - baseline.activeCalories),
                lowerIsBetter: false
            )
            deltaRow(
                metric: "TRIMP Load",
                baseVal: "\(Int(baseline.trimpScore))",
                contVal: "\(Int(contender.trimpScore))",
                diff: Int(contender.trimpScore - baseline.trimpScore),
                lowerIsBetter: false
            )
            if let bHRR = baseline.hrr60Drop, let cHRR = contender.hrr60Drop {
                deltaRow(
                    metric: "Auto HRR-60",
                    baseVal: "-\(bHRR) BPM",
                    contVal: "-\(cHRR) BPM",
                    diff: cHRR - bHRR,
                    lowerIsBetter: false
                )
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func deltaRow(metric: String, baseVal: String, contVal: String, diff: Int, lowerIsBetter: Bool) -> some View {
        let improved = lowerIsBetter ? (diff < 0) : (diff > 0)
        return HStack {
            Text(metric)
                .font(.subheadline)
            Spacer()
            Text(baseVal)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.cyan)
            Text("→")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(contVal)
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.orange)
            Text(diff == 0 ? "0" : (diff > 0 ? "+\(diff)" : "\(diff)"))
                .font(.caption2.monospacedDigit().weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((diff == 0 ? Color.gray : (improved ? Color.green : Color.red)).opacity(0.2), in: Capsule())
                .foregroundStyle(diff == 0 ? .secondary : (improved ? .green : .red))
        }
    }

    private func downsample(_ pts: [HeartRatePoint], maxPoints: Int) -> [HeartRatePoint] {
        guard pts.count > maxPoints else { return pts }
        let step = max(1, pts.count / maxPoints)
        return stride(from: 0, to: pts.count, by: step).map { pts[$0] }
    }
}
