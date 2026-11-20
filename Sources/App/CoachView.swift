import SwiftUI
import Charts

struct CoachView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var navigation: AppNavigation

    @State private var report: CoachReport?
    @State private var selectedMetric: MetricScore?
    @State private var showingReadinessCheck = false
    @State private var showingLoadInfo = false

    var body: some View {
        NavigationStack {
            Group {
                if let report {
                    content(report)
                } else {
                    ProgressView("Analysing your training…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Coach")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingReadinessCheck = true
                    } label: {
                        Label("Readiness Check", systemImage: "heart.text.square")
                    }
                }
            }
            .sheet(item: $selectedMetric) { metric in
                MetricDetailSheet(metric: metric)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingReadinessCheck) {
                ReadinessCheckView()
            }
            .onAppear(perform: refresh)
            .onChange(of: workoutStore.workouts.count) { _, _ in refresh() }
            .onChange(of: workoutStore.readinessReadings.count) { _, _ in refresh() }
            .onChange(of: workoutStore.activeProfileID) { _, _ in refresh() }
            .refreshable { refresh() }
        }
    }

    private func refresh() {
        report = CoachEngine.buildReport(
            workouts: workoutStore.workouts,
            readings: workoutStore.readinessReadings,
            profile: workoutStore.activeProfile,
            resolveSamples: { workoutStore.resolvedSamples(for: $0) }
        )
    }

    @ViewBuilder
    private func content(_ report: CoachReport) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                readinessCard(report)
                nextWorkoutCard(report.nextWorkout)

                if report.hasEnoughData {
                    fightFitnessSection(report)
                    loadChartCard(report)
                } else {
                    ContentUnavailableView {
                        Label("Your coach is learning", systemImage: "figure.kickboxing")
                    } description: {
                        Text("Record \(max(0, 3 - report.workoutCount)) more workout\(3 - report.workoutCount == 1 ? "" : "s") to unlock performance ratings. Use the round timer so stamina and recovery can be measured.")
                    }
                    .padding(.vertical)
                }

                if !report.recommendations.isEmpty {
                    recommendationsSection(report.recommendations)
                }

                thresholdsCard(report)
            }
            .padding()
        }
    }

    // MARK: Readiness

    private func readinessCard(_ report: CoachReport) -> some View {
        let r = report.readiness
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ScoreRing(score: r.score, color: r.color, lineWidth: 10)
                    .frame(width: 86, height: 86)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TODAY'S READINESS")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(r.headline)
                        .font(.title3.weight(.bold))
                    if let reading = report.latestReading, Date().timeIntervalSince(reading.date) < 18 * 3600 {
                        HStack(spacing: 10) {
                            Label("\(reading.restingHR)", systemImage: "heart.fill")
                            if let h = reading.hrvScore {
                                Label("HRV \(h)", systemImage: "waveform.path.ecg")
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedMetric = r }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows what's driving your readiness")
            .accessibilityAddTraits(.isButton)

            if report.latestReading.map({ Date().timeIntervalSince($0.date) > 18 * 3600 }) ?? true {
                Button {
                    showingReadinessCheck = true
                } label: {
                    Label("Take 2-min Readiness Check", systemImage: "heart.text.square.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.pink)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Next workout

    private func nextWorkoutCard(_ p: WorkoutPrescription) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(p.isRestDay ? "TODAY: RECOVER" : "NEXT SESSION", systemImage: p.isRestDay ? "bed.double.fill" : "calendar.badge.plus")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(p.isRestDay ? .cyan : .green)
                Spacer()
                Text("~\(p.durationMinutes) min")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline) {
                Image(systemName: p.category.icon)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(p.title)
                    .font(.title3.weight(.bold))
            }

            Text(p.structure)
                .font(.subheadline.weight(.semibold))

            Label("Target \(p.targetLowBPM)–\(p.targetHighBPM) BPM", systemImage: "heart.circle")
                .font(.subheadline)
                .foregroundStyle(.pink)

            Text(p.rationale)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                navigation.load(p)
            } label: {
                Label("Load in Live Tab", systemImage: "play.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(p.isRestDay ? .cyan : .green)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Fight fitness

    private func fightFitnessSection(_ report: CoachReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Fight Fitness")
                    .font(.title3.weight(.bold))
                Spacer()
                if let f = report.fightFitness {
                    Text("\(f)")
                        .font(.title2.weight(.heavy))
                        .monospacedDigit()
                        .foregroundStyle(MetricScore.color(for: f))
                    Text("/ 100")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(report.metrics) { metric in
                    Button {
                        selectedMetric = metric
                    } label: {
                        MetricTile(metric: metric)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Ratings compare your last 28 days. Arrows show the change versus the 28 days before. Tap any tile for details.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Load chart

    private func loadChartCard(_ report: CoachReport) -> some View {
        let points = Array(report.load.suffix(42))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Training Load")
                    .font(.headline)
                Spacer()
                Button {
                    showingLoadInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("About training load")
            }

            HStack(spacing: 16) {
                loadStat("Fitness", report.load.last?.fitness ?? 0, .blue)
                loadStat("Fatigue", report.load.last?.fatigue ?? 0, .pink)
                loadStat("Form", report.currentForm, report.currentForm >= -10 ? .green : .orange, signed: true)
            }

            Chart {
                ForEach(points) { p in
                    BarMark(x: .value("Day", p.date, unit: .day), y: .value("Load", p.load))
                        .foregroundStyle(Color.gray.opacity(0.35))
                }
                ForEach(points) { p in
                    LineMark(x: .value("Day", p.date, unit: .day), y: .value("Value", p.fitness))
                        .foregroundStyle(by: .value("Series", "Fitness"))
                        .interpolationMethod(.catmullRom)
                }
                ForEach(points) { p in
                    LineMark(x: .value("Day", p.date, unit: .day), y: .value("Value", p.fatigue))
                        .foregroundStyle(by: .value("Series", "Fatigue"))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartForegroundStyleScale(["Fitness": Color.blue, "Fatigue": Color.pink])
            .chartLegend(position: .bottom)
            .frame(height: 170)
            .accessibilityLabel("Training load over the last six weeks")

            if showingLoadInfo {
                Text("Bars are each day's training load (TRIMP). Fitness is your 42-day average load, and fatigue your 7-day average. Form = fitness − fatigue: below −20 means you're overreaching, and between −10 and +5 is ideal for productive training. Taper toward +5 to +15 for fight night.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func loadStat(_ title: String, _ value: Double, _ color: Color, signed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(signed ? String(format: "%+.0f", value) : String(format: "%.0f", value))
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Recommendations

    private func recommendationsSection(_ recs: [CoachRecommendation]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Coach's Notes")
                .font(.title3.weight(.bold))
            ForEach(recs) { rec in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: rec.icon)
                        .font(.title3)
                        .foregroundStyle(rec.tint)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rec.title).font(.subheadline.weight(.bold))
                        Text(rec.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Thresholds

    private func thresholdsCard(_ report: CoachReport) -> some View {
        let profile = workoutStore.activeProfile
        return VStack(alignment: .leading, spacing: 10) {
            Text("Your Physiology")
                .font(.headline)
            thresholdRow("Max HR", "\(profile.effectiveMaxHR) BPM", profile.useAutoMaxHR ? "age estimate" : "set manually")
            thresholdRow("Lactate threshold", "\(profile.lactateThresholdHR) BPM", "from profile / LTHR test")
            if let v = report.vt1 {
                thresholdRow("Aerobic threshold (VT1)", "≈ \(v.bpm) BPM", "from beat-to-beat analysis")
            } else {
                thresholdRow("Aerobic threshold (VT1)", "—", "needs clean RR data across easy→hard efforts")
            }
            thresholdRow("Resting HR", "\(profile.restingHR) BPM",
                         report.measuredRestingHR.map { "morning checks: \($0)" } ?? "do morning checks to measure")
            if let c = report.rrCoverage {
                Text("Beat-to-beat data was present in \(Int(c * 100))% of recent samples. Chest straps (e.g. CooSpo H808S) give the cleanest HRV and threshold detection; optical armbands are best at rest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func thresholdRow(_ title: String, _ value: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Components

struct ScoreRing: View {
    let score: Int?
    let color: Color
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(score ?? 0) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(score.map(String.init) ?? "–")
                .font(.system(.title2, design: .rounded).weight(.heavy))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.map { "Score \($0) out of 100" } ?? "Not enough data")
    }
}

struct MetricTile: View {
    let metric: MetricScore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: metric.icon)
                    .foregroundStyle(metric.color)
                Spacer()
                if let t = metric.trend, t != 0 {
                    Label("\(abs(t))", systemImage: t > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(t > 0 ? .green : .orange)
                }
            }
            Text(metric.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(metric.score.map(String.init) ?? "–")
                    .font(.system(.title, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                    .foregroundStyle(metric.color)
                Text(metric.grade)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(metric.score ?? 0), total: 100)
                .tint(metric.color)
            Text(metric.score == nil ? metric.dataHint : metric.headline)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title), \(metric.score.map { "\($0) out of 100, \(metric.grade)" } ?? "not enough data")")
        .accessibilityHint("Shows details and how to improve")
    }
}

struct MetricDetailSheet: View {
    let metric: MetricScore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        ScoreRing(score: metric.score, color: metric.color)
                            .frame(width: 72, height: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.grade).font(.title3.weight(.bold)).foregroundStyle(metric.color)
                            Text(metric.score == nil ? metric.dataHint : metric.headline)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let t = metric.trend {
                                Text(t == 0 ? "No change vs previous 4 weeks" : "\(t > 0 ? "+" : "")\(t) vs previous 4 weeks")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(t >= 0 ? .green : .orange)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !metric.evidence.isEmpty {
                    Section("What the data shows") {
                        ForEach(metric.evidence, id: \.self) { line in
                            Text(line).font(.subheadline)
                        }
                    }
                }

                Section("How to improve") {
                    Text(metric.howToImprove).font(.subheadline)
                }
            }
            .navigationTitle(metric.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Workout review card (used in WorkoutDetailView)

struct CoachReviewCard: View {
    let review: WorkoutReview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("COACH REVIEW", systemImage: "person.fill.checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.purple)
                Spacer()
                if let o = review.overall {
                    Text("\(o)")
                        .font(.title2.weight(.heavy))
                        .monospacedDigit()
                        .foregroundStyle(MetricScore.color(for: o))
                    Text("/ 100").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            ForEach(review.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(item.title, systemImage: item.icon)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(item.score)")
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(MetricScore.color(for: item.score))
                    }
                    ProgressView(value: Double(item.score), total: 100)
                        .tint(MetricScore.color(for: item.score))
                    Text(item.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if let load = review.loadComparison {
                Label(load, systemImage: "scalemass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !review.takeaways.isEmpty {
                Divider()
                Text("Next time").font(.subheadline.weight(.bold))
                ForEach(review.takeaways, id: \.self) { t in
                    Label {
                        Text(t).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
