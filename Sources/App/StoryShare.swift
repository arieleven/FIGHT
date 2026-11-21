import SwiftUI

// MARK: - Instagram Stories

enum InstagramStories {
    /// Meta app ID required by Instagram for Sharing to Stories.
    static let facebookAppID = "1320411766881372"
    static let backgroundTop = "#2A0A0E"
    static let backgroundBottom = "#000000"

    private static var url: URL? { URL(string: "instagram-stories://share?source_application=\(facebookAppID)") }

    @MainActor
    static var isAvailable: Bool {
        guard let url else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Sends the card to Instagram as a movable sticker on FIGHT's background colours.
    @MainActor
    static func share(sticker: UIImage) -> Bool {
        guard let url, UIApplication.shared.canOpenURL(url), let png = sticker.pngData() else { return false }
        let items: [[String: Any]] = [[
            "com.instagram.sharedSticker.stickerImage": png,
            "com.instagram.sharedSticker.backgroundTopColor": backgroundTop,
            "com.instagram.sharedSticker.backgroundBottomColor": backgroundBottom,
            "com.instagram.sharedSticker.appID": facebookAppID
        ]]
        UIPasteboard.general.setItems(items, options: [.expirationDate: Date().addingTimeInterval(300)])
        UIApplication.shared.open(url)
        return true
    }
}

// MARK: - Card data

enum StoryCardKind: String, CaseIterable, Identifiable {
    case session, progress, fighter, record, countdown
    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: return "Session"
        case .progress: return "Progress"
        case .fighter: return "Fighter Card"
        case .record: return "Record"
        case .countdown: return "Countdown"
        }
    }
}

struct StoryPrivacy {
    var hideName: Bool
    var hideWeight: Bool
    var onlyImprovements: Bool
}

/// Everything the cards show, computed once when the share screen opens.
struct StoryData {
    var name: String
    var workout: SavedWorkout?
    var workoutSamples: [HeartRatePoint] = []
    var workoutRecords: [PersonalRecord] = []
    var report: CoachReport?
    var gasTank: String?
    var benchmark: [Benchmark.Attempt] = []
    var latestRecord: PersonalRecord?
    var fightDate: Date?
    var campWeek: (index: Int, total: Int, title: String)?
    var kgToGo: Double?
    var useImperial = false
    var monthSessions = 0
    var monthRounds = 0
    var monthMinutes = 0
    var recoveryChange: Int?

    @MainActor
    static func build(store: WorkoutStore, workout: SavedWorkout?) -> StoryData {
        let profile = store.activeProfile
        let mine = store.workouts.filter { $0.profileID == profile.id }
        var d = StoryData(name: profile.name)
        d.workout = workout
        if let workout {
            d.workoutSamples = store.resolvedSamples(for: workout)
            d.workoutRecords = Records.newRecords(in: workout, workouts: store.workouts, profile: store.profile(for: workout))
        }
        d.report = CoachEngine.buildReport(workouts: store.workouts, readings: store.activeReadings, profile: profile,
                                           resolveSamples: { store.resolvedSamples(for: $0) })
        d.gasTank = GasTank.evaluate(workouts: mine, profile: profile)?.headline
        d.benchmark = Benchmark.attempts(mine)
        d.latestRecord = Records.all(workouts: store.workouts, profile: profile).max { $0.date < $1.date }
        d.useImperial = profile.useImperial
        if let fight = profile.fightDate, fight > Date() {
            d.fightDate = fight
            d.kgToGo = max(0, (store.weighIns.first { $0.profileID == profile.id }?.weightKg ?? profile.weightKg) - profile.targetFightWeightKg)
            if let plan = CampPlanner.buildPlan(profile: profile, workouts: store.workouts),
               let week = plan.currentWeek, let i = plan.weeks.firstIndex(where: { $0.start == week.start }) {
                d.campWeek = (i + 1, plan.weeks.count, week.title)
            }
        }
        let monthAgo = Date().addingTimeInterval(-30 * 86400)
        let twoMonthsAgo = Date().addingTimeInterval(-60 * 86400)
        let thisMonth = mine.filter { $0.startDate >= monthAgo }
        let lastMonth = mine.filter { $0.startDate >= twoMonthsAgo && $0.startDate < monthAgo }
        d.monthSessions = thisMonth.count
        d.monthRounds = thisMonth.reduce(0) { $0 + $1.roundStats.count }
        d.monthMinutes = Int(thisMonth.reduce(0) { $0 + $1.duration } / 60)
        let rNow = thisMonth.compactMap(\.avgInterRoundDrop)
        let rThen = lastMonth.compactMap(\.avgInterRoundDrop)
        if !rNow.isEmpty, !rThen.isEmpty {
            d.recoveryChange = rNow.reduce(0, +) / rNow.count - rThen.reduce(0, +) / rThen.count
        }
        return d
    }

    /// Cards that have something worth sharing right now.
    var availableKinds: [StoryCardKind] {
        var k: [StoryCardKind] = []
        if workout != nil { k.append(.session) }
        k.append(.progress)
        if report?.fightFitness != nil { k.append(.fighter) }
        if latestRecord != nil || !workoutRecords.isEmpty { k.append(.record) }
        if fightDate != nil { k.append(.countdown) }
        return k
    }
}

// MARK: - Card views

private let storyRed = Color(red: 0.93, green: 0.16, blue: 0.20)

/// The card itself (what becomes the Instagram sticker).
struct StoryCard: View {
    let kind: StoryCardKind
    let data: StoryData
    let privacy: StoryPrivacy

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("FIGHT").font(.system(size: 22, weight: .black, design: .rounded)).foregroundStyle(storyRed)
                Spacer()
                if !privacy.hideName, !data.name.isEmpty {
                    Text(data.name.uppercased()).font(.caption.weight(.heavy)).foregroundStyle(.white.opacity(0.75))
                }
            }
            content
            Spacer(minLength: 0)
            Text("Tracked with FIGHT · data-driven fight training")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(24)
        .frame(width: 320, height: 500, alignment: .topLeading)
        .background(
            LinearGradient(colors: [Color(red: 0.16, green: 0.05, blue: 0.07), Color(red: 0.05, green: 0.05, blue: 0.06)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 30)
        )
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(storyRed.opacity(0.35), lineWidth: 1.5))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .session: sessionContent
        case .progress: progressContent
        case .fighter: fighterContent
        case .record: recordContent
        case .countdown: countdownContent
        }
    }

    // Session

    @ViewBuilder
    private var sessionContent: some View {
        if let w = data.workout {
            VStack(alignment: .leading, spacing: 4) {
                Text(w.category.rawValue.uppercased()).font(.caption.weight(.heavy)).foregroundStyle(storyRed)
                Text(sessionHeadline(w)).font(.system(size: 30, weight: .heavy)).foregroundStyle(.white)
                Text(w.startDate.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            HRTraceShape(samples: data.workoutSamples)
                .stroke(LinearGradient(colors: [.orange, storyRed], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(height: 90)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                stat("\(Int(w.duration / 60)) min", "Time")
                stat("\(w.maxBPM)", "Peak BPM")
                if let r = w.roundStats.compactMap(\.stoolDropBPM).max() { stat("−\(r)", "Best recovery") }
                if w.strikesCuedCount > 0 { stat("\(w.strikesCuedCount)", "Strikes called") } else { stat("\(w.averageBPM)", "Avg BPM") }
            }
            if !data.workoutRecords.isEmpty {
                Label("\(data.workoutRecords.count) new personal record\(data.workoutRecords.count == 1 ? "" : "s")", systemImage: "trophy.fill")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.orange)
            }
        }
    }

    private func sessionHeadline(_ w: SavedWorkout) -> String {
        let rounds = w.roundStats.count
        guard rounds > 0 else { return "\(Int(w.duration / 60)) minutes" }
        let work = Int(w.roundStats.map { $0.endElapsed - $0.startElapsed }.reduce(0, +) / Double(rounds))
        return "\(rounds) × \(work / 60):" + String(format: "%02d", work % 60)
    }

    // Progress

    @ViewBuilder
    private var progressContent: some View {
        if data.benchmark.count >= 2, let first = data.benchmark.first, let last = data.benchmark.last,
           !privacy.onlyImprovements || last.averageWorkHR < first.averageWorkHR {
            let diff = first.averageWorkHR - last.averageWorkHR
            VStack(alignment: .leading, spacing: 6) {
                Text("FIGHT BENCHMARK").font(.caption.weight(.heavy)).foregroundStyle(storyRed)
                Text(diff >= 0 ? "−\(diff) BPM" : "+\(-diff) BPM").font(.system(size: 54, weight: .black)).foregroundStyle(.white)
                Text("Same 5 × 3 min work, lower heart rate than my first test \(first.date.formatted(.dateTime.month().day())).")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            }
            BenchmarkBars(values: data.benchmark.map(\.averageWorkHR))
                .frame(height: 110)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("LAST 30 DAYS").font(.caption.weight(.heavy)).foregroundStyle(storyRed)
                Text("\(data.monthSessions) sessions").font(.system(size: 44, weight: .black)).foregroundStyle(.white)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                stat("\(data.monthRounds)", "Rounds")
                stat("\(data.monthMinutes / 60)h \(data.monthMinutes % 60)m", "Training")
                if let c = data.recoveryChange, !privacy.onlyImprovements || c > 0 {
                    stat(String(format: "%+d BPM", c), "Recovery vs last month")
                }
                if let f = data.report?.fightFitness { stat("\(f)", "Fight Fitness") }
            }
        }
    }

    // Fighter

    @ViewBuilder
    private var fighterContent: some View {
        if let report = data.report {
            HStack(spacing: 16) {
                ScoreRing(score: report.fightFitness, color: MetricScore.color(for: report.fightFitness), lineWidth: 9)
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fight Fitness").font(.title3.weight(.heavy)).foregroundStyle(.white)
                    Text("Rated from my heart-rate data").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            VStack(spacing: 10) {
                ForEach(report.metrics.prefix(4)) { m in
                    HStack {
                        Text(m.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Spacer()
                        Text(m.score.map(String.init) ?? "--").font(.subheadline.weight(.bold)).monospacedDigit()
                            .foregroundStyle(MetricScore.color(for: m.score))
                    }
                    ProgressView(value: Double(m.score ?? 0), total: 100).tint(MetricScore.color(for: m.score))
                }
            }
            if let g = data.gasTank {
                Label(g, systemImage: "fuelpump.fill").font(.subheadline.weight(.bold)).foregroundStyle(.white)
            }
        }
    }

    // Record

    @ViewBuilder
    private var recordContent: some View {
        let records = data.workoutRecords.isEmpty ? (data.latestRecord.map { [$0] } ?? []) : data.workoutRecords
        Image(systemName: "trophy.fill").font(.system(size: 54)).foregroundStyle(.orange)
        Text(records.count > 1 ? "\(records.count) NEW RECORDS" : "NEW PERSONAL RECORD")
            .font(.caption.weight(.heavy)).foregroundStyle(storyRed)
        ForEach(records.prefix(3)) { r in
            VStack(alignment: .leading, spacing: 2) {
                Text(r.valueText).font(.system(size: records.count > 1 ? 28 : 40, weight: .black)).foregroundStyle(.white)
                Text(r.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    // Countdown

    @ViewBuilder
    private var countdownContent: some View {
        if let fight = data.fightDate {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                       to: Calendar.current.startOfDay(for: fight)).day ?? 0
            VStack(alignment: .leading, spacing: 0) {
                Text("FIGHT IN").font(.caption.weight(.heavy)).foregroundStyle(storyRed)
                Text("\(days)").font(.system(size: 96, weight: .black)).foregroundStyle(.white)
                Text(days == 1 ? "day" : "days").font(.title2.weight(.bold)).foregroundStyle(.white.opacity(0.75))
            }
            if let w = data.campWeek {
                stat("Week \(w.index) of \(w.total)", w.title)
            }
            if let r = data.report?.readiness.score {
                stat("\(r)/100", "Readiness today")
            }
            if !privacy.hideWeight, let kg = data.kgToGo {
                stat(kg < 0.05 ? "On weight" : "\(WeightUnits.text(kg, data.useImperial)) to go", "Weight cut")
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.heavy)).foregroundStyle(.white).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// The full 9:16 story image (card on the FIGHT background), for saving or other apps.
struct StoryCanvas: View {
    let card: StoryCard

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.165, green: 0.04, blue: 0.055), .black], startPoint: .top, endPoint: .bottom)
            card
        }
        .frame(width: 360, height: 640)
    }
}

/// Heart-rate trace drawn from samples, downsampled to fit.
struct HRTraceShape: Shape {
    let samples: [HeartRatePoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard samples.count > 2 else { return path }
        let step = max(1, samples.count / 160)
        let pts = stride(from: 0, to: samples.count, by: step).map { samples[$0] }
        guard let minB = pts.map(\.bpm).min(), let maxB = pts.map(\.bpm).max(),
              let t0 = pts.first?.elapsedSeconds, let t1 = pts.last?.elapsedSeconds, t1 > t0 else { return path }
        let span = Double(max(10, maxB - minB))
        for (i, p) in pts.enumerated() {
            let x = rect.minX + CGFloat((p.elapsedSeconds - t0) / (t1 - t0)) * rect.width
            let y = rect.maxY - CGFloat(Double(p.bpm - minB) / span) * rect.height
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

private struct BenchmarkBars: View {
    let values: [Int]

    var body: some View {
        let lo = (values.min() ?? 0) - 8
        let hi = max(lo + 1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(values.suffix(6).enumerated()), id: \.offset) { i, v in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(i == min(values.count, 6) - 1 ? storyRed : Color.white.opacity(0.35))
                        .frame(height: max(8, CGFloat(v - lo) / CGFloat(hi - lo) * 80))
                    Text("\(v)").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }
}

// MARK: - Share screen

struct StoryShareSheet: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    let focus: StoryCardKind
    var workout: SavedWorkout? = nil

    @AppStorage("fight.story.hideName") private var hideName = false
    @AppStorage("fight.story.hideWeight") private var hideWeight = true
    @AppStorage("fight.story.onlyImprovements") private var onlyImprovements = true

    @State private var data: StoryData?
    @State private var selection: StoryCardKind = .fighter
    @State private var shareImage: ShareableImage?
    @State private var instagramMissing = false

    private var privacy: StoryPrivacy {
        StoryPrivacy(hideName: hideName, hideWeight: hideWeight, onlyImprovements: onlyImprovements)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let data {
                        let kinds = data.availableKinds
                        if kinds.count > 1 {
                            Picker("Card", selection: $selection) {
                                ForEach(kinds) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        TabView(selection: $selection) {
                            ForEach(kinds) { kind in
                                StoryCanvas(card: StoryCard(kind: kind, data: data, privacy: privacy))
                                    .clipShape(RoundedRectangle(cornerRadius: 24))
                                    .scaleEffect(0.78)
                                    .tag(kind)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: 520)

                        Button {
                            shareToInstagram(data)
                        } label: {
                            Label("Share to Instagram Story", systemImage: "camera.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.pink)

                        Button {
                            if let img = render(StoryCanvas(card: StoryCard(kind: selection, data: data, privacy: privacy))) {
                                shareImage = ShareableImage(image: img)
                            }
                        } label: {
                            Label("More options…", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        VStack(spacing: 0) {
                            Toggle("Hide my name", isOn: $hideName)
                            Divider().padding(.vertical, 8)
                            Toggle("Hide my weight", isOn: $hideWeight)
                            Divider().padding(.vertical, 8)
                            Toggle("Only show improvements", isOn: $onlyImprovements)
                        }
                        .font(.subheadline)
                        .card()
                    } else {
                        ProgressView().padding(60)
                    }
                }
                .padding()
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(item: $shareImage) { item in ShareSheet(items: [item.image]) }
            .alert("Instagram isn't installed", isPresented: $instagramMissing) {
                Button("Use Share Sheet") {
                    if let data, let img = render(StoryCanvas(card: StoryCard(kind: selection, data: data, privacy: privacy))) {
                        shareImage = ShareableImage(image: img)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Save the image or send it to another app instead.")
            }
            .task {
                guard data == nil else { return }
                let built = StoryData.build(store: workoutStore, workout: workout)
                let kinds = built.availableKinds
                selection = kinds.contains(focus) ? focus : (kinds.first ?? .progress)
                data = built
            }
        }
    }

    private func shareToInstagram(_ data: StoryData) {
        guard let sticker = render(StoryCard(kind: selection, data: data, privacy: privacy)) else { return }
        if !InstagramStories.share(sticker: sticker) {
            instagramMissing = true
        }
    }

    private func render<V: View>(_ view: V) -> UIImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.isOpaque = false
        return renderer.uiImage
    }
}
