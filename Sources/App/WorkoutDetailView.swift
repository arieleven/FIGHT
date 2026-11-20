import SwiftUI
import Charts

struct WorkoutDetailView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var healthKit: HealthKitManager
    let workout: SavedWorkout
    @State private var isSavingToHealth = false

    @State private var selectedElapsed: Double?
    @State private var loadedSamples: [HeartRatePoint] = []
    @State private var showRollingTrend = true
    @State private var showingComparison = false

    private var chartSamples: [HeartRatePoint] {
        guard loadedSamples.count > 360 else { return loadedSamples }
        let strideStep = max(1, loadedSamples.count / 360)
        return stride(from: 0, to: loadedSamples.count, by: strideStep).map { loadedSamples[$0] }
    }

    private var rollingTrendSamples: [HeartRatePoint] {
        guard chartSamples.count >= 8 else { return [] }
        let window = 6
        return chartSamples.indices.map { i in
            let lo = max(0, i - window)
            let hi = min(chartSamples.count - 1, i + window)
            let slice = chartSamples[lo...hi].map(\.bpm)
            let avg = slice.reduce(0, +) / slice.count
            return HeartRatePoint(timestamp: chartSamples[i].timestamp, elapsedSeconds: chartSamples[i].elapsedSeconds, bpm: avg)
        }
    }

    private var selectedSample: HeartRatePoint? {
        guard let target = selectedElapsed else { return nil }
        return chartSamples.min(by: { abs($0.elapsedSeconds - target) < abs($1.elapsedSeconds - target) })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSummaryCard
                CoachReviewCard(review: CoachEngine.review(
                    workout: workout,
                    profile: workoutStore.profile(for: workout),
                    history: workoutStore.workouts
                ))
                calorieBreakdownCard
                interactiveChartCard
                if !workout.pointsOfInterest.isEmpty {
                    poiSection
                }
                if !workout.autoHRREvents.isEmpty {
                    autoHRRSection
                }
                if workout.roundStats.count >= 2 {
                    roundDecayChartCard
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
                if healthKit.isAvailable {
                    Button {
                        guard !healthKit.isSaved(workout), !isSavingToHealth else { return }
                        isSavingToHealth = true
                        let samplesForHealth = loadedSamples
                        Task {
                            await healthKit.save(workout: workout, samples: samplesForHealth)
                            isSavingToHealth = false
                        }
                    } label: {
                        if isSavingToHealth {
                            ProgressView()
                        } else {
                            Image(systemName: healthKit.isSaved(workout) ? "heart.text.square.fill" : "heart.text.square")
                                .foregroundStyle(healthKit.isSaved(workout) ? .pink : .primary)
                        }
                    }
                    .accessibilityLabel(healthKit.isSaved(workout) ? "Saved to Apple Health" : "Save to Apple Health")
                }

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
                            Text("ARCHIVED")
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
                statBox(title: "MIN HR", value: "\(workout.minBPM)")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var calorieBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ENERGY EXPENDITURE BREAKDOWN")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTIVE BURN")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                    Text("\(Int(workout.activeCalories)) kcal")
                        .font(.title3.weight(.heavy).monospacedDigit())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("+")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text("RESTING BMR")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("\(Int(workout.bmrCalories)) kcal")
                        .font(.title3.weight(.bold).monospacedDigit())
                }
                Spacer()
                Text("=")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("TOTAL KCAL")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.cyan)
                    Text("\(Int(workout.calories)) kcal")
                        .font(.title3.weight(.heavy).monospacedDigit())
                        .foregroundStyle(.cyan)
                }
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

    private var interactiveChartCard: some View {
        let zones = workoutStore.activeProfile.activeZones

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("HEART RATE CURVE & POI MARKERS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Trend", isOn: $showRollingTrend)
                    .toggleStyle(.button)
                    .controlSize(.mini)
            }

            if let sample = selectedSample {
                let z = workoutStore.activeProfile.zone(for: sample.bpm)
                Text("Selected: \(formatDuration(sample.elapsedSeconds)) • \(sample.bpm) BPM (\(z.name))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(z.color)
            } else {
                Text("Drag on chart or tap a POI chip below to inspect")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                                colors: [.red.opacity(0.32), .orange.opacity(0.12), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Time (s)", pt.elapsedSeconds),
                            y: .value("BPM", pt.bpm)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2.0))
                        .foregroundStyle(by: .value("Series", "Heart Rate"))
                    }

                    if showRollingTrend {
                        ForEach(rollingTrendSamples) { pt in
                            LineMark(
                                x: .value("Time (s)", pt.elapsedSeconds),
                                y: .value("BPM", pt.bpm)
                            )
                            .lineStyle(StrokeStyle(lineWidth: 1.8, dash: [5, 3]))
                            .foregroundStyle(by: .value("Series", "Trend"))
                        }
                    }

                    ForEach(workout.pointsOfInterest) { poi in
                        RuleMark(x: .value("POI Line", poi.elapsedSeconds))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .foregroundStyle((poi.isPositive ? Color.cyan : Color.yellow).opacity(0.55))

                        PointMark(
                            x: .value("Time (s)", poi.elapsedSeconds),
                            y: .value("BPM", poi.bpm)
                        )
                        .symbolSize(110)
                        .foregroundStyle(poi.isPositive ? .cyan : .yellow)
                        .annotation(position: .top, spacing: 4) {
                            HStack(spacing: 3) {
                                Image(systemName: poi.symbol)
                                Text(poi.shortTag)
                            }
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.82), in: Capsule())
                            .foregroundStyle(poi.isPositive ? .cyan : .yellow)
                        }
                    }

                    if let sample = selectedSample {
                        RuleMark(x: .value("Selected", sample.elapsedSeconds))
                            .foregroundStyle(.white.opacity(0.75))
                        PointMark(
                            x: .value("Selected", sample.elapsedSeconds),
                            y: .value("BPM", sample.bpm)
                        )
                        .symbolSize(120)
                        .foregroundStyle(.white)
                    }
                }
                .chartForegroundStyleScale([
                    "Heart Rate": Color.red,
                    "Trend": Color.cyan.opacity(0.85)
                ])
                .chartLegend(.hidden)
                .chartYScale(domain: max(45, workout.minBPM - 10)...min(235, workout.maxBPM + 18))
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
                .frame(height: 250)

                if !workout.pointsOfInterest.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(workout.pointsOfInterest) { poi in
                                Button {
                                    selectedElapsed = poi.elapsedSeconds
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: poi.symbol)
                                        Text("\(poi.shortTag) @ \(formatDuration(poi.elapsedSeconds))")
                                    }
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background((poi.isPositive ? Color.cyan : Color.yellow).opacity(0.18), in: Capsule())
                                    .foregroundStyle(poi.isPositive ? .cyan : .yellow)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Not enough heart rate points recorded to plot graph.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Button {
                    selectedElapsed = poi.elapsedSeconds
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: poi.symbol)
                            .font(.headline)
                            .foregroundStyle(poi.isPositive ? .cyan : .yellow)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(poi.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(poi.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatDuration(poi.elapsedSeconds))
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var autoHRRSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AUTOMATIC IN-WORKOUT HRR-60 RECOVERIES")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ForEach(workout.autoHRREvents) { ev in
                HStack {
                    Image(systemName: "arrow.down.heart.fill")
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ev.contextLabel)
                            .font(.subheadline.weight(.semibold))
                        Text("\(ev.peakBPM) → \(ev.recovery60BPM) BPM @ \(formatDuration(ev.elapsedSeconds))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("-\(ev.dropBPM) BPM")
                        .font(.headline.monospacedDigit().weight(.bold))
                        .foregroundStyle(.cyan)
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

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
                    .symbol(.circle)

                    LineMark(
                        x: .value("Round", "R\(stat.roundNumber)"),
                        y: .value("BPM", stat.avgBPM)
                    )
                    .foregroundStyle(by: .value("Metric", "Avg BPM"))
                    .symbol(.square)

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

            Label("Cyan bars = 60s Stool HR Drop per round", systemImage: "arrow.down.heart.fill")
                .font(.caption2)
                .foregroundStyle(.cyan)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
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
            Text("CONDITIONING & FIGHTER ANALYTICS")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metricTile(
                    title: "PEAK AUTO HRR-60",
                    value: workout.hrr60Drop != nil ? "-\(workout.hrr60Drop!) BPM" : "No 60s Drop",
                    subtitle: hrrGrade(workout.hrr60Drop),
                    color: .cyan
                )
                metricTile(
                    title: "REDLINE EXPOSURE (Z5)",
                    value: formatDuration(workout.redlineSeconds),
                    subtitle: "Time above Z4 threshold",
                    color: .red
                )
                metricTile(
                    title: "TRAINING LOAD (TRIMP)",
                    value: "\(Int(workout.trimpScore))",
                    subtitle: workout.trimpScore > 120 ? "High fight load" : "Moderate load",
                    color: .orange
                )
                metricTile(
                    title: "CARDIAC DRIFT",
                    value: String(format: "%.1f%%", workout.cardiacDriftPercent),
                    subtitle: abs(workout.cardiacDriftPercent) <= 5.0 ? "Strong aerobic base" : "Aerobic decoupling",
                    color: .green
                )
                metricTile(
                    title: "AEROBIC EFFICIENCY",
                    value: String(format: "%.2f", workout.aerobicEfficiencyIndex),
                    subtitle: "Active kcal/min per 100 BPM",
                    color: .mint
                )
                metricTile(
                    title: "EPOC AFTERBURN",
                    value: "+\(Int(workout.epocBonusCalories)) kcal",
                    subtitle: "Post-session oxygen debt",
                    color: .yellow
                )
                if workout.strikesCuedCount > 0 {
                    let perMin = Double(workout.strikesCuedCount) / max(1.0, workout.duration / 60.0)
                    metricTile(
                        title: "BAG STRIKES CUED",
                        value: "\(workout.strikesCuedCount)",
                        subtitle: String(format: "%.1f strikes/min cadence", perMin),
                        color: .orange
                    )
                }
                if let ghostDelta = workout.ghostAvgDeltaBPM {
                    metricTile(
                        title: "VS GHOST PACE",
                        value: String(format: "%+.1f BPM", ghostDelta),
                        subtitle: ghostDelta <= 0 ? "More efficient than Ghost" : "Higher output than Ghost",
                        color: .purple
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
        guard let d = drop else { return "Trigger >80% MaxHR + 60s rest" }
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
