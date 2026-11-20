import SwiftUI
import Charts

struct WorkoutDetailView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    let workout: SavedWorkout

    @State private var selectedElapsed: Double?
    @State private var loadedSamples: [HeartRatePoint] = []
    @State private var showingComparison = false

    private var chartSamples: [HeartRatePoint] {
        guard loadedSamples.count > 360 else { return loadedSamples }
        let strideStep = max(1, loadedSamples.count / 360)
        return stride(from: 0, to: loadedSamples.count, by: strideStep).map { loadedSamples[$0] }
    }

    private var selectedSample: HeartRatePoint? {
        guard let target = selectedElapsed else { return nil }
        return chartSamples.min(by: { abs($0.elapsedSeconds - target) < abs($1.elapsedSeconds - target) })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSummaryCard
                interactiveChartCard
                if workout.roundStats.count >= 2 {
                    roundDecayChartCard
                }
                if !workout.pointsOfInterest.isEmpty {
                    poiSection
                }
                zoneBreakdownCard
                advancedMetricsGrid
            }
            .padding()
        }
        .navigationTitle(workout.category.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingComparison = true
                } label: {
                    Image(systemName: "square.stack.3d.up")
                }

                ShareLink(item: workoutStore.exportTCXFile(for: workout)) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingComparison) {
            ComparisonView(initialBaselineWorkout: workout)
        }
        .onAppear {
            loadedSamples = workoutStore.resolvedSamples(for: workout)
        }
    }

    private var headerSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: workout.category.icon)
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.startDate.formatted(date: .complete, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("\(workout.drillTag.rawValue) • RPE \(workout.rpe)/10")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                        if workout.isCompressedArchive {
                            Text("CSPK ARCHIVED")
                                .font(.system(size: 9, weight: .heavy))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.25), in: Capsule())
                                .foregroundStyle(.purple)
                        }
                    }
                }
                Spacer()
            }

            if !workout.notes.isEmpty {
                Text("\"\(workout.notes)\"")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                statBox(title: "DURATION", value: formatDuration(workout.duration))
                Spacer()
                statBox(title: "AVG HR", value: "\(workout.averageBPM)")
                Spacer()
                statBox(title: "MAX HR", value: "\(workout.maxBPM)")
                Spacer()
                statBox(title: "TOTAL KCAL", value: "\(Int(workout.calories))")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func statBox(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
    }

    // MARK: - Interactive HR Curve + Points of Interest
    private var interactiveChartCard: some View {
        let zones = workoutStore.activeProfile.activeZones

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("HEART RATE CURVE & HIGHLIGHTS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let sample = selectedSample {
                    let z = workoutStore.activeProfile.zone(for: sample.bpm)
                    Text("\(formatDuration(sample.elapsedSeconds)) • \(sample.bpm) BPM (\(z.shortName))")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(z.color)
                } else {
                    Text("Drag finger on graph")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if chartSamples.count >= 2 {
                Chart {
                    RuleMark(y: .value("Z2 Ceiling", zones.z2Max))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.green.opacity(0.45))

                    RuleMark(y: .value("Threshold", zones.z4Max))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.orange.opacity(0.55))

                    ForEach(chartSamples) { pt in
                        AreaMark(
                            x: .value("Time (s)", pt.elapsedSeconds),
                            y: .value("BPM", pt.bpm)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.red.opacity(0.35), .orange.opacity(0.15), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Time (s)", pt.elapsedSeconds),
                            y: .value("BPM", pt.bpm)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .foregroundStyle(.red)
                    }

                    ForEach(workout.pointsOfInterest) { poi in
                        PointMark(
                            x: .value("Time (s)", poi.elapsedSeconds),
                            y: .value("BPM", poi.bpm)
                        )
                        .symbolSize(90)
                        .foregroundStyle(poi.isPositive ? .cyan : .yellow)
                        .annotation(position: .top, spacing: 4) {
                            Image(systemName: poi.symbol)
                                .font(.caption2.bold())
                                .padding(4)
                                .background(Color.black.opacity(0.75), in: Circle())
                                .foregroundStyle(poi.isPositive ? .cyan : .yellow)
                        }
                    }

                    if let sample = selectedSample {
                        RuleMark(x: .value("Selected", sample.elapsedSeconds))
                            .foregroundStyle(.white.opacity(0.6))
                        PointMark(
                            x: .value("Selected", sample.elapsedSeconds),
                            y: .value("BPM", sample.bpm)
                        )
                        .symbolSize(110)
                        .foregroundStyle(.white)
                    }
                }
                .chartYScale(domain: max(45, workout.minBPM - 10)...min(230, workout.maxBPM + 12))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let sec = value.as(Double.self) {
                                Text(formatDuration(sec))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartXSelection(value: $selectedElapsed)
                .frame(height: 230)
            } else {
                Text("Not enough heart rate points recorded to plot graph.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Round-by-Round Fatigue Decay Chart
    private var roundDecayChartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ROUND-BY-ROUND FATIGUE DECAY")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            Chart {
                ForEach(workout.roundStats) { stat in
                    LineMark(
                        x: .value("Round", "R\(stat.roundNumber)"),
                        y: .value("BPM", stat.peakBPM)
                    )
                    .foregroundStyle(by: .value("Metric", "Peak BPM"))
                    .symbol(Circle())

                    LineMark(
                        x: .value("Round", "R\(stat.roundNumber)"),
                        y: .value("BPM", stat.avgBPM)
                    )
                    .foregroundStyle(by: .value("Metric", "Avg BPM"))
                    .symbol(Square())

                    if let drop = stat.stoolDropBPM {
                        BarMark(
                            x: .value("Round", "R\(stat.roundNumber)"),
                            y: .value("Stool Drop", drop)
                        )
                        .foregroundStyle(Color.cyan.opacity(0.35))
                    }
                }
            }
            .chartForegroundStyleScale([
                "Peak BPM": Color.red,
                "Avg BPM": Color.orange
            ])
            .frame(height: 190)

            HStack(spacing: 12) {
                Label("Cyan bars = 60s Stool HR Drop per round", systemImage: "arrow.down.heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var poiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("POINTS OF INTEREST")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ForEach(workout.pointsOfInterest) { poi in
                HStack(spacing: 12) {
                    Image(systemName: poi.symbol)
                        .font(.headline)
                        .foregroundStyle(poi.isPositive ? .cyan : .yellow)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(poi.title)
                            .font(.subheadline.weight(.semibold))
                        Text(poi.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var zoneBreakdownCard: some View {
        let total = max(1.0, workout.zoneSeconds.values.reduce(0, +))
        let zoneMeta: [(Int, String, Color)] = [
            (5, "Z5 Peak", .red),
            (4, "Z4 Threshold", .orange),
            (3, "Z3 Tempo", .yellow),
            (2, "Z2 Aerobic", .green),
            (1, "Z1 Recovery", .blue)
        ]

        return VStack(alignment: .leading, spacing: 10) {
            Text("TIME IN HEART RATE ZONES")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ForEach(zoneMeta, id: \.0) { zoneNum, label, color in
                let sec = workout.zoneSeconds[zoneNum, default: 0]
                let pct = sec / total
                VStack(spacing: 4) {
                    HStack {
                        Text(label)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(formatDuration(sec)) (\(Int(round(pct * 100)))%)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule()
                                .fill(color)
                                .frame(width: max(4, geo.size.width * pct))
                        }
                    }
                    .frame(height: 8)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var advancedMetricsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONDITIONING & RECOVERY METRICS")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metricTile(
                    title: "HRR-60 RECOVERY",
                    value: workout.hrr60Drop != nil ? "-\(workout.hrr60Drop!) BPM" : "Not Measured",
                    subtitle: hrrGrade(workout.hrr60Drop),
                    color: .cyan
                )
                metricTile(
                    title: "EPOC AFTERBURN",
                    value: "+\(Int(workout.epocBonusCalories)) kcal",
                    subtitle: "Anaerobic excess burn",
                    color: .orange
                )
                metricTile(
                    title: "TRAINING LOAD (TRIMP)",
                    value: "\(Int(workout.trimpScore))",
                    subtitle: workout.trimpScore > 120 ? "High fight load" : "Moderate load",
                    color: .red
                )
                metricTile(
                    title: "CARDIAC DRIFT",
                    value: String(format: "%.1f%%", workout.cardiacDriftPercent),
                    subtitle: abs(workout.cardiacDriftPercent) <= 5.0 ? "Strong aerobic base" : "Aerobic decoupling",
                    color: .green
                )
                if let roundDrop = workout.avgInterRoundDrop {
                    metricTile(
                        title: "AVG STOOL DROP",
                        value: "-\(roundDrop) BPM",
                        subtitle: "Between-round recovery",
                        color: .mint
                    )
                }
                if let rmssd = workout.rmssdMs {
                    metricTile(
                        title: "SESSION HRV (RMSSD)",
                        value: "\(Int(rmssd)) ms",
                        subtitle: "Autonomic variability",
                        color: .purple
                    )
                }
            }
        }
    }

    private func metricTile(title: String, value: String, subtitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func hrrGrade(_ drop: Int?) -> String {
        guard let d = drop else { return "Complete 60s cooldown" }
        if d >= 30 { return "Elite Fighter (<30s reset)" }
        if d >= 20 { return "Fight Ready" }
        if d >= 12 { return "Average Recovery" }
        return "Fatigued / Overreached"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}