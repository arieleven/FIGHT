import SwiftUI
import Charts

/// Everything the weekly coach report needs, gathered once.
struct WeeklyReportData {
    let profile: AthleteProfile
    let start: Date
    let end: Date
    let coach: CoachReport
    let sessions: [SavedWorkout]
    let reviews: [UUID: WorkoutReview]
    let plan: CampPlan?
    let weight: WeightCutStatus
    let readings: [ReadinessReading]
    let weighIns: [WeighIn]

    var totalDuration: TimeInterval { sessions.reduce(0) { $0 + $1.duration } }
    var totalLoad: Double { sessions.reduce(0) { $0 + $1.effectiveLoad } }
    var totalCalories: Double { sessions.reduce(0) { $0 + $1.activeCalories } }
    var totalRounds: Int { sessions.reduce(0) { $0 + $1.roundStats.count } }

    var zoneMinutes: [Double] {
        (1...5).map { z in sessions.reduce(0) { $0 + $1.zoneSeconds[z, default: 0] } / 60 }
    }

    var avgRecovery: Int? {
        let drops = sessions.flatMap { $0.roundStats.compactMap(\.stoolDropBPM) + $0.autoHRREvents.map(\.dropBPM) }
        return drops.isEmpty ? nil : drops.reduce(0, +) / drops.count
    }

    @MainActor
    init(store: WorkoutStore, now: Date = Date()) {
        let profile = store.activeProfile
        self.profile = profile
        self.end = now
        self.start = now.addingTimeInterval(-7 * 86400)
        self.coach = CoachEngine.buildReport(
            workouts: store.workouts, readings: store.readinessReadings, profile: profile,
            resolveSamples: { store.resolvedSamples(for: $0) }, now: now
        )
        let weekStart = now.addingTimeInterval(-7 * 86400)
        let weekSessions = store.workouts
            .filter { $0.profileID == profile.id && $0.startDate >= weekStart }
            .sorted { $0.startDate < $1.startDate }
        self.sessions = weekSessions
        var reviews: [UUID: WorkoutReview] = [:]
        for s in weekSessions {
            reviews[s.id] = CoachEngine.review(workout: s, profile: profile, history: store.workouts)
        }
        self.reviews = reviews
        self.plan = CampPlanner.buildPlan(profile: profile, workouts: store.workouts, now: now)
        self.weight = CampPlanner.weightStatus(weighIns: store.weighIns, readings: store.readinessReadings, profile: profile, now: now)
        self.readings = store.readinessReadings.filter { $0.date >= weekStart }.sorted { $0.date < $1.date }
        self.weighIns = store.weighIns
            .filter { $0.profileID == profile.id && $0.date >= now.addingTimeInterval(-28 * 86400) }
            .sorted { $0.date < $1.date }
    }
}

@MainActor
enum WeeklyReportRenderer {
    static let pageSize = CGSize(width: 612, height: 792) // US Letter, prints fine on A4

    static func render(store: WorkoutStore) -> URL? {
        let data = WeeklyReportData(store: store)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        let safeName = data.profile.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        let url = store.exportsDirectory.appendingPathComponent("CoachReport_\(safeName)_\(stamp.string(from: data.end)).pdf")

        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }

        let pages: [AnyView] = [
            AnyView(ReportPageOne(data: data)),
            AnyView(ReportPageTwo(data: data))
        ]
        for page in pages {
            let content = page
                .frame(width: pageSize.width, height: pageSize.height, alignment: .top)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(pageSize)
            renderer.render { _, draw in
                ctx.beginPDFPage(nil)
                draw(ctx)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - Shared pieces

private struct ReportSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Color(white: 0.4))
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ReportHeader: View {
    let data: WeeklyReportData
    let page: Int

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Weekly Training Report")
                    .font(.system(size: 18, weight: .heavy))
                Text("\(data.profile.name) • \(data.start.formatted(date: .abbreviated, time: .omitted)) – \(data.end.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.35))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let fight = data.profile.fightDate, fight > data.end {
                    let days = Int(fight.timeIntervalSince(data.end) / 86400)
                    Text("\(days) days to fight")
                        .font(.system(size: 11, weight: .bold))
                    Text(fight.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 9))
                        .foregroundStyle(Color(white: 0.4))
                }
                Text("Page \(page) of 2")
                    .font(.system(size: 8))
                    .foregroundStyle(Color(white: 0.5))
            }
        }
    }
}

private func scoreColor(_ s: Int?) -> Color {
    guard let s else { return Color(white: 0.6) }
    switch s {
    case 70...: return Color(red: 0.13, green: 0.6, blue: 0.3)
    case 55..<70: return Color(red: 0.2, green: 0.65, blue: 0.6)
    case 40..<55: return Color(red: 0.85, green: 0.65, blue: 0.0)
    default: return Color(red: 0.9, green: 0.45, blue: 0.1)
    }
}

private func durationText(_ t: TimeInterval) -> String {
    let m = Int(t) / 60
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

// MARK: - Page 1: overview

private struct ReportPageOne: View {
    let data: WeeklyReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReportHeader(data: data, page: 1)

            HStack(spacing: 10) {
                ReportSection(title: "Readiness today") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(data.coach.readiness.score.map(String.init) ?? "–")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundStyle(scoreColor(data.coach.readiness.score))
                        Text(data.coach.readiness.headline)
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                ReportSection(title: "Fight fitness") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(data.coach.fightFitness.map(String.init) ?? "–")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundStyle(scoreColor(data.coach.fightFitness))
                        Text("/ 100 (aerobic, anaerobic, stamina, recovery)")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(white: 0.4))
                    }
                }
            }

            ReportSection(title: "This week") {
                HStack {
                    weekStat("\(data.sessions.count)", "sessions")
                    weekStat(durationText(data.totalDuration), "training")
                    weekStat("\(Int(data.totalLoad))", "load (TRIMP)")
                    weekStat("\(data.totalRounds)", "rounds")
                    weekStat("\(Int(data.totalCalories))", "active kcal")
                    weekStat(data.avgRecovery.map { "−\($0)" } ?? "–", "avg 60s recovery")
                }
                zoneBar
            }

            ReportSection(title: "Performance ratings (last 28 days)") {
                VStack(spacing: 5) {
                    ForEach(data.coach.metrics) { m in
                        HStack(spacing: 8) {
                            Text(m.title)
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 100, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color(white: 0.88))
                                    Capsule().fill(scoreColor(m.score))
                                        .frame(width: geo.size.width * CGFloat(m.score ?? 0) / 100)
                                }
                            }
                            .frame(height: 7)
                            Text(m.score.map(String.init) ?? "–")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 24, alignment: .trailing)
                            Text(m.grade)
                                .font(.system(size: 8))
                                .foregroundStyle(Color(white: 0.4))
                                .frame(width: 58, alignment: .leading)
                            Text(m.trend.map { $0 == 0 ? "=" : ($0 > 0 ? "▲\($0)" : "▼\(-$0)") } ?? "")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle((m.trend ?? 0) >= 0 ? Color.green : Color.orange)
                                .frame(width: 26, alignment: .trailing)
                        }
                    }
                }
            }

            ReportSection(title: "Training load (6 weeks)") {
                let pts = Array(data.coach.load.suffix(42))
                Chart {
                    ForEach(pts) { p in
                        BarMark(x: .value("Day", p.date, unit: .day), y: .value("Load", p.load))
                            .foregroundStyle(Color(white: 0.75))
                    }
                    ForEach(pts) { p in
                        LineMark(x: .value("Day", p.date, unit: .day), y: .value("v", p.fitness))
                            .foregroundStyle(by: .value("S", "Fitness"))
                    }
                    ForEach(pts) { p in
                        LineMark(x: .value("Day", p.date, unit: .day), y: .value("v", p.fatigue))
                            .foregroundStyle(by: .value("S", "Fatigue"))
                    }
                }
                .chartForegroundStyleScale(["Fitness": Color.blue, "Fatigue": Color.pink])
                .chartLegend(position: .trailing)
                .frame(height: 110)
                Text(String(format: "Form %+.0f", data.coach.currentForm) +
                     (data.coach.acwr.map { String(format: " • Acute:chronic %.2f", $0) } ?? ""))
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.35))
            }

            if let plan = data.plan, let week = plan.currentWeek {
                ReportSection(title: "Camp progress — \(week.title) of \(plan.weeks.count)") {
                    Text("Load \(Int(week.actualLoad)) of \(Int(week.targetLoad)) target • \(week.actualSessions)/\(week.targetSessions) sessions • Focus: \(week.focus)")
                        .font(.system(size: 10))
                    Chart {
                        ForEach(plan.weeks) { w in
                            BarMark(x: .value("W", "W\(w.index)"), y: .value("L", w.targetLoad), width: .ratio(0.7))
                                .foregroundStyle(Color(white: 0.82))
                            BarMark(x: .value("W", "W\(w.index)"), y: .value("L", w.actualLoad), width: .ratio(0.45))
                                .foregroundStyle(w.phase.color)
                        }
                    }
                    .frame(height: 80)
                }
            }

            Spacer(minLength: 0)
            Text("Generated by FIGHT from heart-rate data. Ratings are estimates to guide training, not medical advice.")
                .font(.system(size: 7))
                .foregroundStyle(Color(white: 0.5))
        }
        .padding(28)
        .foregroundStyle(Color.black)
    }

    private func weekStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 14, weight: .bold))
            Text(label).font(.system(size: 8)).foregroundStyle(Color(white: 0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var zoneBar: some View {
        let mins = data.zoneMinutes
        let total = max(1, mins.reduce(0, +))
        let colors: [Color] = [.blue, .green, .yellow, .orange, .red]
        return VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(0..<5, id: \.self) { i in
                        Rectangle().fill(colors[i])
                            .frame(width: max(0, geo.size.width * CGFloat(mins[i] / total) - 1))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            HStack {
                ForEach(0..<5, id: \.self) { i in
                    Text("Z\(i + 1) \(Int(mins[i]))m")
                        .font(.system(size: 8))
                        .foregroundStyle(Color(white: 0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Page 2: sessions, weight, notes

private struct ReportPageTwo: View {
    let data: WeeklyReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReportHeader(data: data, page: 2)

            ReportSection(title: "Sessions") {
                if data.sessions.isEmpty {
                    Text("No sessions recorded this week.").font(.system(size: 10))
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            col("Date", 52); col("Session", 120); col("Time", 36); col("Avg/Max", 50); col("Load", 30); col("Review", 36)
                            Text("Coach note").font(.system(size: 8, weight: .bold)).foregroundStyle(Color(white: 0.4))
                        }
                        ForEach(data.sessions.prefix(9)) { s in
                            let r = data.reviews[s.id]
                            HStack(alignment: .top) {
                                cell(s.startDate.formatted(.dateTime.weekday(.abbreviated).day()), 52)
                                cell("\(s.category.rawValue) • \(s.drillTag.rawValue)", 120)
                                cell(durationText(s.duration), 36)
                                cell("\(s.averageBPM)/\(s.maxBPM)", 50)
                                cell("\(Int(s.effectiveLoad))", 30)
                                Text(r?.overall.map(String.init) ?? "–")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(scoreColor(r?.overall))
                                    .frame(width: 36, alignment: .leading)
                                Text(r?.takeaways.first ?? "")
                                    .font(.system(size: 8))
                                    .foregroundStyle(Color(white: 0.3))
                                    .lineLimit(2)
                            }
                        }
                        if data.sessions.count > 9 {
                            Text("+ \(data.sessions.count - 9) more sessions")
                                .font(.system(size: 8)).foregroundStyle(Color(white: 0.4))
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 10) {
                ReportSection(title: "Weight cut") {
                    let w = data.weight
                    let imp = data.profile.useImperial
                    Text("\(WeightUnits.text(w.currentKg, imp)) → \(WeightUnits.text(w.targetKg, imp)) target")
                        .font(.system(size: 11, weight: .bold))
                    Text(w.toGoKg > 0 ? "\(WeightUnits.text(w.toGoKg, imp)) (\(CampPlanner.fmt(w.toGoPercent))%) to go" : "On weight")
                        .font(.system(size: 9))
                    if let t = w.trendKgPerWeek {
                        Text(String(format: "Trend %+.1f %@/week", WeightUnits.value(t, imp), WeightUnits.unit(imp))).font(.system(size: 9))
                    }
                    if let r = w.requiredKgPerWeek, w.toGoKg > 0 {
                        Text("Needed \(WeightUnits.number(r, imp)) \(WeightUnits.unit(imp))/week").font(.system(size: 9))
                    }
                    if data.weighIns.count >= 2 {
                        Chart {
                            ForEach(data.weighIns) { e in
                                LineMark(x: .value("D", e.date), y: .value("kg", WeightUnits.value(e.weightKg, imp)))
                                    .foregroundStyle(Color.cyan)
                            }
                            RuleMark(y: .value("T", WeightUnits.value(w.targetKg, imp)))
                                .foregroundStyle(Color.green)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 90)
                    }
                }

                ReportSection(title: "Morning body signals") {
                    if data.readings.isEmpty {
                        Text("No readiness checks this week.").font(.system(size: 9))
                    } else {
                        ForEach(data.readings) { r in
                            HStack {
                                Text(r.date.formatted(.dateTime.weekday(.abbreviated).day()))
                                    .frame(width: 44, alignment: .leading)
                                Text("RHR \(r.restingHR)").frame(width: 50, alignment: .leading)
                                Text("HRV \(r.hrvScore.map(String.init) ?? "–")").frame(width: 48, alignment: .leading)
                                Text("Sleep \(r.sleepQuality)/5 • Sore \(r.soreness)/5")
                            }
                            .font(.system(size: 8))
                        }
                    }
                }
            }

            let flagged = data.weight.warnings.filter { $0.severity != .info }
            if !flagged.isEmpty {
                ReportSection(title: "Health flags") {
                    ForEach(flagged.prefix(4)) { w in
                        Text("• \(w.title): \(w.detail)")
                            .font(.system(size: 8.5))
                            .foregroundStyle(w.severity == .danger ? Color.red : Color.black)
                    }
                }
            }

            ReportSection(title: "Coach's notes") {
                ForEach(data.coach.recommendations.prefix(5)) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.system(size: 9, weight: .bold))
                        Text(r.detail).font(.system(size: 8)).foregroundStyle(Color(white: 0.3))
                    }
                }
            }

            ReportSection(title: "Suggested next session") {
                let p = data.coach.nextWorkout
                Text("\(p.title): \(p.structure)").font(.system(size: 10, weight: .bold))
                Text("Target \(p.targetLowBPM)–\(p.targetHighBPM) BPM • ~\(p.durationMinutes) min").font(.system(size: 9))
                Text(p.rationale).font(.system(size: 8)).foregroundStyle(Color(white: 0.3))
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .foregroundStyle(Color.black)
    }

    private func col(_ t: String, _ w: CGFloat) -> some View {
        Text(t).font(.system(size: 8, weight: .bold)).foregroundStyle(Color(white: 0.4)).frame(width: w, alignment: .leading)
    }

    private func cell(_ t: String, _ w: CGFloat) -> some View {
        Text(t).font(.system(size: 9)).lineLimit(2).frame(width: w, alignment: .leading)
    }
}
