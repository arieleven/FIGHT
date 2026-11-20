import SwiftUI
import Charts

struct OverlayPoint: Identifiable {
    let id = UUID()
    let sessionLabel: String
    let elapsedSeconds: Double
    let bpm: Int
}

struct ComparisonView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @Environment(\.dismiss) private var dismiss

    let initialBaselineWorkout: SavedWorkout?

    @State private var sessionAID: UUID?
    @State private var sessionBID: UUID?

    private var workouts: [SavedWorkout] {
        workoutStore.activeProfileWorkouts
    }

    private var workoutA: SavedWorkout? {
        workouts.first(where: { $0.id == sessionAID }) ?? workouts.first
    }

    private var workoutB: SavedWorkout? {
        workouts.first(where: { $0.id == sessionBID }) ?? (workouts.count > 1 ? workouts[1] : workouts.first)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if workouts.count < 2 {
                        Text("Log at least 2 workouts to overlay and compare your cardiovascular progression.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        pickerCard
                        if let wA = workoutA, let wB = workoutB {
                            overlayChart(wA: wA, wB: wB)
                            deltaComparisonTable(wA: wA, wB: wB)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Session Overlay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let initW = initialBaselineWorkout {
                    sessionAID = initW.id
                    let sameCategoryOther = workouts.first(where: { $0.id != initW.id && $0.category == initW.category })
                        ?? workouts.first(where: { $0.id != initW.id })
                    sessionBID = sameCategoryOther?.id
                } else {
                    sessionAID = workouts.first?.id
                    sessionBID = workouts.dropFirst().first?.id
                }
            }
        }
    }

    private var pickerCard: some View {
        VStack(spacing: 12) {
            HStack {
                Circle().fill(Color.cyan).frame(width: 10, height: 10)
                Text("Current (A)")
                    .font(.caption.weight(.bold))
                Spacer()
                Picker("Session A", selection: $sessionAID) {
                    ForEach(workouts) { w in
                        Text("\(w.category.rawValue) • \(w.startDate.formatted(date: .abbreviated, time: .omitted))").tag(Optional(w.id))
                    }
                }
            }

            Divider()

            HStack {
                Circle().fill(Color.orange).frame(width: 10, height: 10)
                Text("Baseline (B)")
                    .font(.caption.weight(.bold))
                Spacer()
                Picker("Session B", selection: $sessionBID) {
                    ForEach(workouts) { w in
                        Text("\(w.category.rawValue) • \(w.startDate.formatted(date: .abbreviated, time: .omitted))").tag(Optional(w.id))
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func overlayChart(wA: SavedWorkout, wB: SavedWorkout) -> some View {
        let samplesA = downsample(workoutStore.resolvedSamples(for: wA), label: "Current (A)")
        let samplesB = downsample(workoutStore.resolvedSamples(for: wB), label: "Baseline (B)")
        let combined = samplesA + samplesB

        return VStack(alignment: .leading, spacing: 10) {
            Text("HEART RATE CURVE OVERLAY")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            Chart(combined) { pt in
                LineMark(
                    x: .value("Elapsed (s)", pt.elapsedSeconds),
                    y: .value("BPM", pt.bpm)
                )
                .foregroundStyle(by: .value("Session", pt.sessionLabel))
                .lineStyle(StrokeStyle(lineWidth: 2.2))
            }
            .chartForegroundStyleScale([
                "Current (A)": Color.cyan,
                "Baseline (B)": Color.orange
            ])
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { val in
                    AxisGridLine()
                    AxisValueLabel {
                        if let sec = val.as(Double.self) {
                            Text("\(Int(sec) / 60)m")
                                .font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 230)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func deltaComparisonTable(wA: SavedWorkout, wB: SavedWorkout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ADAPTATION DELTA (A VS B)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            deltaRow(metric: "Average HR", valA: "\(wA.averageBPM) BPM", valB: "\(wB.averageBPM) BPM", diff: wA.averageBPM - wB.averageBPM, lowerIsBetter: true)
            deltaRow(metric: "Peak HR", valA: "\(wA.maxBPM) BPM", valB: "\(wB.maxBPM) BPM", diff: wA.maxBPM - wB.maxBPM, lowerIsBetter: false)
            if let hA = wA.hrr60Drop, let hB = wB.hrr60Drop {
                deltaRow(metric: "HRR-60 Drop", valA: "-\(hA) BPM", valB: "-\(hB) BPM", diff: hA - hB, lowerIsBetter: false)
            }
            if let sA = wA.avgInterRoundDrop, let sB = wB.avgInterRoundDrop {
                deltaRow(metric: "Stool Recovery", valA: "-\(sA) BPM", valB: "-\(sB) BPM", diff: sA - sB, lowerIsBetter: false)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func deltaRow(metric: String, valA: String, valB: String, diff: Int, lowerIsBetter: Bool) -> some View {
        let improved = lowerIsBetter ? (diff < 0) : (diff > 0)
        let diffText = diff == 0 ? "0" : (diff > 0 ? "+\(diff)" : "\(diff)")

        return HStack {
            Text(metric)
                .font(.subheadline)
            Spacer()
            Text(valA)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.cyan)
            Text("vs \(valB)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(diffText)
                .font(.caption.weight(.heavy).monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((diff == 0 ? Color.gray : (improved ? Color.green : Color.orange)).opacity(0.2), in: Capsule())
                .foregroundStyle(diff == 0 ? .gray : (improved ? .green : .orange))
        }
    }

    private func downsample(_ pts: [HeartRatePoint], label: String) -> [OverlayPoint] {
        guard pts.count > 240 else {
            return pts.map { OverlayPoint(sessionLabel: label, elapsedSeconds: $0.elapsedSeconds, bpm: $0.bpm) }
        }
        let step = max(1, pts.count / 240)
        return stride(from: 0, to: pts.count, by: step).map {
            OverlayPoint(sessionLabel: label, elapsedSeconds: pts[$0].elapsedSeconds, bpm: pts[$0].bpm)
        }
    }
}