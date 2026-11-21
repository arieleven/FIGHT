import Foundation
import Compression
import UIKit

@MainActor
final class WorkoutStore: ObservableObject {
    @Published var workouts: [SavedWorkout] = []
    @Published var profiles: [AthleteProfile] = []
    @Published var activeProfileID: UUID {
        didSet {
            saveProfilesToDisk()
        }
    }
    @Published var savedGhostSessions: [GhostSession] = []
    @Published var readinessReadings: [ReadinessReading] = []
    @Published var weighIns: [WeighIn] = []
    @Published var plans: [TrainingPlan] = []
    @Published var soreness: [SorenessEntry] = []
    // Cached so the Live tab doesn't decompress archives on every BPM-driven redraw.
    private var cachedGhosts: [GhostSession] = []

    private let archiveThresholdDays: TimeInterval = 7 * 24 * 60 * 60

    var activeProfile: AthleteProfile {
        get {
            if let found = profiles.first(where: { $0.id == activeProfileID }) {
                return found
            }
            return profiles.first ?? AthleteProfile()
        }
        set {
            var clean = newValue
            clean.sanitize()
            if let old = profiles.first(where: { $0.id == clean.id }) {
                CampCompare.archiveFinishedCamp(old: old, new: &clean)
            }
            if let idx = profiles.firstIndex(where: { $0.id == clean.id }) {
                profiles[idx] = clean
            } else {
                profiles.append(clean)
            }
            saveProfilesToDisk()
        }
    }

    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var profilesDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var profilesFileURL: URL {
        profilesDirectory.appendingPathComponent("fighter_profiles.json")
    }

    var workoutsDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Workouts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var archivesDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("CompressedArchives", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var exportsDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var ghostsDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("GhostOpponents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        self.activeProfileID = UUID()
        loadProfilesFromDisk()
        loadWorkouts()
        loadExternalGhosts()
        runLosslessAutoCompression()
        refreshGhostCache()
        loadReadiness()
        loadWeighIns()
        loadPlans()
        loadSoreness()
    }

    private struct ProfileContainer: Codable {
        var activeProfileID: UUID
        var profiles: [AthleteProfile]
    }

    private func loadProfilesFromDisk() {
        let decoder = JSONDecoder()

        if let data = try? Data(contentsOf: profilesFileURL),
           let container = try? decoder.decode(ProfileContainer.self, from: data),
           !container.profiles.isEmpty {
            self.profiles = container.profiles
            self.activeProfileID = container.activeProfileID
            return
        }

        let defaultFighter = AthleteProfile()
        self.profiles = [defaultFighter]
        self.activeProfileID = defaultFighter.id
        saveProfilesToDisk()
    }

    func saveProfilesToDisk() {
        let container = ProfileContainer(activeProfileID: activeProfileID, profiles: profiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(container) {
            try? data.write(to: profilesFileURL, options: .atomic)
        }
    }

    /// Adds a sample fighter with three realistic sessions, a week of morning checks,
    /// weigh-ins and an upcoming fight, so every coach feature has data to show.
    func loadSampleFighter() {
        if let existing = profiles.first(where: { $0.name == SampleData.profileName }) {
            activeProfileID = existing.id
            saveProfilesToDisk()
            return
        }
        let sample = SampleData.make()
        profiles.append(sample.profile)
        activeProfileID = sample.profile.id
        saveProfilesToDisk()
        for w in sample.workouts { save(w) }
        readinessReadings.append(contentsOf: sample.readings)
        readinessReadings.sort { $0.date > $1.date }
        saveReadiness()
        for wi in sample.weighIns { addWeighIn(wi) }
    }

    func addProfile(name: String) {
        var p = AthleteProfile()
        p.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Sparring Partner" : name
        p.sanitize()
        profiles.append(p)
        activeProfileID = p.id
        saveProfilesToDisk()
    }

    func deleteProfile(_ profile: AthleteProfile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if profile.name == SampleData.profileName {
            // Sample data is removed completely with its profile.
            for w in workouts where w.profileID == profile.id { delete(w) }
            readinessReadings.removeAll { $0.profileID == profile.id }
            saveReadiness()
            weighIns.removeAll { $0.profileID == profile.id }
            saveWeighIns()
        }
        if activeProfileID == profile.id, let first = profiles.first {
            activeProfileID = first.id
        }
        saveProfilesToDisk()
    }

    func loadWorkouts() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: workoutsDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [SavedWorkout] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let workout = try? decoder.decode(SavedWorkout.self, from: data) {
                loaded.append(workout)
            }
        }
        workouts = loaded.sorted { $0.startDate > $1.startDate }
    }

    func save(_ workout: SavedWorkout) {
        var w = workout
        let age = Date().timeIntervalSince(w.startDate)
        if age > archiveThresholdDays && !w.samples.isEmpty {
            w = compressWorkoutSamples(w)
        }
        writeWorkoutMetadata(w)
        workouts.removeAll { $0.id == w.id }
        workouts.insert(w, at: 0)
        workouts.sort { $0.startDate > $1.startDate }
        refreshGhostCache()
    }

    /// Stores the athlete's post-session effort rating (enables session-RPE load).
    func updateRating(workoutID: UUID, rpe: Int, notes: String) {
        guard let idx = workouts.firstIndex(where: { $0.id == workoutID }) else { return }
        var w = workouts[idx]
        w.rpe = min(max(rpe, 1), 10)
        w.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        w.rpeRated = true
        workouts[idx] = w
        writeWorkoutMetadata(w)
    }

    /// Saves what a session was about: technique focus, sparring partner and round scores.
    func updateTags(workoutID: UUID, focus: [String], partner: String?, roundResults: [String]) {
        guard let idx = workouts.firstIndex(where: { $0.id == workoutID }) else { return }
        var w = workouts[idx]
        w.focusTags = focus
        let p = partner?.trimmingCharacters(in: .whitespacesAndNewlines)
        w.partner = (p?.isEmpty ?? true) ? nil : p
        w.roundResults = roundResults
        workouts[idx] = w
        writeWorkoutMetadata(w)
    }

    /// Partners this fighter has sparred with, most recent first.
    func recentPartners(profileID: UUID) -> [String] {
        var seen = Set<String>()
        return workouts.filter { $0.profileID == profileID }.compactMap(\.partner).filter { seen.insert($0).inserted }
    }

    /// Zips the whole Documents folder (workouts, profiles, checks, weigh-ins, exports)
    /// into a single backup file for the share sheet.
    func exportAllDataArchive() -> URL? {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var result: URL?
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("FIGHT-Backup-\(stamp.string(from: Date())).zip")
        coordinator.coordinate(readingItemAt: documentsDirectory, options: [.forUploading], error: &coordError) { zipURL in
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: zipURL, to: dest)) != nil {
                result = dest
            }
        }
        return result
    }

    func delete(_ workout: SavedWorkout) {
        let metaURL = workoutsDirectory.appendingPathComponent("\(workout.id.uuidString).json")
        try? FileManager.default.removeItem(at: metaURL)
        if let archiveName = workout.archiveFileName {
            let archiveURL = archivesDirectory.appendingPathComponent(archiveName)
            try? FileManager.default.removeItem(at: archiveURL)
        }
        workouts.removeAll { $0.id == workout.id }
        refreshGhostCache()
    }

    func resolvedSamples(for workout: SavedWorkout) -> [HeartRatePoint] {
        if !workout.samples.isEmpty {
            return workout.samples
        }
        guard let archiveName = workout.archiveFileName else { return [] }
        let archiveURL = archivesDirectory.appendingPathComponent(archiveName)
        guard let compressed = try? Data(contentsOf: archiveURL),
              let decompressed = decompressLZFSE(compressed) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HeartRatePoint].self, from: decompressed)) ?? []
    }

    func runLosslessAutoCompression() {
        let now = Date()
        var didChange = false

        for i in workouts.indices {
            let age = now.timeIntervalSince(workouts[i].startDate)
            if age > archiveThresholdDays && !workouts[i].isCompressedArchive && !workouts[i].samples.isEmpty {
                workouts[i] = compressWorkoutSamples(workouts[i])
                writeWorkoutMetadata(workouts[i])
                didChange = true
            }
        }
        if didChange {
            objectWillChange.send()
        }
    }

    private func compressWorkoutSamples(_ workout: SavedWorkout) -> SavedWorkout {
        var copy = workout
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let rawJSON = try? encoder.encode(workout.samples),
              let compressed = compressLZFSE(rawJSON) else {
            return workout
        }
        let archiveName = "\(workout.id.uuidString).fpk"
        let archiveURL = archivesDirectory.appendingPathComponent(archiveName)
        try? compressed.write(to: archiveURL, options: .atomic)

        copy.samples = []
        copy.isCompressedArchive = true
        copy.archiveFileName = archiveName
        return copy
    }

    private func writeWorkoutMetadata(_ workout: SavedWorkout) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = workoutsDirectory.appendingPathComponent("\(workout.id.uuidString).json")
        if let data = try? encoder.encode(workout) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func compressLZFSE(_ data: Data) -> Data? {
        return data.withUnsafeBytes { rawBuffer -> Data? in
            guard let srcPtr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let dstCapacity = max(4096, data.count)
            let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
            defer { dstBuffer.deallocate() }
            let written = compression_encode_buffer(dstBuffer, dstCapacity, srcPtr, data.count, nil, COMPRESSION_LZFSE)
            guard written > 0 else { return nil }
            var output = Data()
            var originalSize = UInt32(data.count).littleEndian
            output.append(Data(bytes: &originalSize, count: 4))
            output.append(dstBuffer, count: written)
            return output
        }
    }

    private func decompressLZFSE(_ data: Data) -> Data? {
        guard data.count > 4 else { return nil }
        let originalSize = UInt32(littleEndian: data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let payload = data.dropFirst(4)
        let dstCapacity = Int(originalSize) + 1024
        return payload.withUnsafeBytes { rawBuffer -> Data? in
            guard let srcPtr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
            defer { dstBuffer.deallocate() }
            let decodedCount = compression_decode_buffer(dstBuffer, dstCapacity, srcPtr, payload.count, nil, COMPRESSION_LZFSE)
            guard decodedCount > 0 else { return nil }
            return Data(bytes: dstBuffer, count: decodedCount)
        }
    }

    var acuteChronicWorkloadRatio: (ratio: Double, status: String) {
        let now = Date()
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86400)
        let twentyEightDaysAgo = now.addingTimeInterval(-28 * 86400)

        let acuteLoad = workouts.filter { $0.startDate >= sevenDaysAgo }.reduce(0.0) { $0 + $1.effectiveLoad }
        let chronicTotal = workouts.filter { $0.startDate >= twentyEightDaysAgo }.reduce(0.0) { $0 + $1.effectiveLoad }
        let chronicWeeklyAvg = chronicTotal / 4.0

        guard chronicWeeklyAvg >= 20 else {
            return (1.0, "Building Baseline")
        }
        let ratio = acuteLoad / chronicWeeklyAvg
        if ratio < 0.8 {
            return (ratio, "Fresh / Tapered")
        } else if ratio <= 1.3 {
            return (ratio, "Optimal Fight Zone")
        } else if ratio <= 1.5 {
            return (ratio, "High Camp Strain")
        } else {
            return (ratio, "Overreach Risk")
        }
    }

    func importTCXGhost(from url: URL) -> GhostSession? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let parsed = TCXStreamParser.parse(data: data, fallbackName: url.deletingPathExtension().lastPathComponent) else {
            return nil
        }

        let dest = ghostsDirectory.appendingPathComponent(url.lastPathComponent)
        try? data.write(to: dest, options: .atomic)
        loadExternalGhosts()
        return parsed
    }

    func loadExternalGhosts() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: ghostsDirectory, includingPropertiesForKeys: nil) else { return }
        var ghosts: [GhostSession] = []
        for file in files where file.pathExtension.lowercased() == "tcx" {
            if let data = try? Data(contentsOf: file),
               let session = TCXStreamParser.parse(data: data, fallbackName: file.deletingPathExtension().lastPathComponent) {
                ghosts.append(session)
            }
        }
        savedGhostSessions = ghosts
        refreshGhostCache()
    }

    func allAvailableGhosts() -> [GhostSession] {
        cachedGhosts
    }

    private func refreshGhostCache() {
        let fromWorkouts = workouts.prefix(15).map { w -> GhostSession in
            var g = w.toGhostSession()
            if g.samples.isEmpty {
                let resolved = resolvedSamples(for: w)
                g = GhostSession(
                    id: w.id,
                    title: "\(w.category.rawValue) (\(w.startDate.formatted(date: .abbreviated, time: .omitted)))",
                    subtitle: "Avg \(w.averageBPM) • Peak \(w.maxBPM) BPM",
                    samples: resolved,
                    roundStats: w.roundStats,
                    avgBPM: w.averageBPM,
                    peakBPM: w.maxBPM
                )
            }
            return g
        }.filter { !$0.samples.isEmpty }

        cachedGhosts = savedGhostSessions + fromWorkouts
    }

    func exportTCXFile(for workout: SavedWorkout) -> URL {
        let samples = resolvedSamples(for: workout)
        let iso = ISO8601DateFormatter()
        var rawNotes = "\(workout.category.rawValue) - \(workout.drillTag.rawValue) (RPE \(workout.rpe)/10)"
        if !workout.notes.isEmpty {
            rawNotes += " — " + workout.notes
        }
        let notesText = xmlEscape(rawNotes)
        var tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Other">
              <Id>\(iso.string(from: workout.startDate))</Id>
              <Lap StartTime="\(iso.string(from: workout.startDate))">
                <TotalTimeSeconds>\(String(format: "%.1f", workout.duration))</TotalTimeSeconds>
                <Calories>\(Int(workout.calories))</Calories>
                <AverageHeartRateBpm><Value>\(workout.averageBPM)</Value></AverageHeartRateBpm>
                <MaximumHeartRateBpm><Value>\(workout.maxBPM)</Value></MaximumHeartRateBpm>
                <Intensity>Active</Intensity>
                <TriggerMethod>Manual</TriggerMethod>
                <Track>
        """
        for pt in samples {
            tcx += """
                      <Trackpoint>
                        <Time>\(iso.string(from: pt.timestamp))</Time>
                        <HeartRateBpm><Value>\(pt.bpm)</Value></HeartRateBpm>
                      </Trackpoint>
            """
        }
        tcx += """
                </Track>
              </Lap>
              <Notes>\(notesText)</Notes>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let safeCategory = workout.category.rawValue.replacingOccurrences(of: "/", with: "-")
        let fileName = "\(safeCategory)_\(formatter.string(from: workout.startDate)).tcx"
        let fileURL = exportsDirectory.appendingPathComponent(fileName)
        try? tcx.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Readiness checks

    var readinessFileURL: URL {
        let dir = documentsDirectory.appendingPathComponent("Readiness", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("readiness_checks.json")
    }

    private func loadReadiness() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: readinessFileURL),
              let list = try? decoder.decode([ReadinessReading].self, from: data) else { return }
        readinessReadings = list.sorted { $0.date > $1.date }
    }

    private func saveReadiness() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(readinessReadings) {
            try? data.write(to: readinessFileURL, options: .atomic)
        }
    }

    /// Readiness checks for the active fighter (older checks without a fighter show for everyone).
    var activeReadings: [ReadinessReading] {
        readinessReadings.filter { $0.profileID == nil || $0.profileID == activeProfileID }
    }

    func addReadiness(_ reading: ReadinessReading) {
        var reading = reading
        if reading.profileID == nil { reading.profileID = activeProfileID }
        readinessReadings.insert(reading, at: 0)
        readinessReadings.sort { $0.date > $1.date }
        saveReadiness()
    }

    func deleteReadiness(_ reading: ReadinessReading) {
        readinessReadings.removeAll { $0.id == reading.id }
        saveReadiness()
    }

    // MARK: - Training plans

    var plansFileURL: URL {
        let dir = documentsDirectory.appendingPathComponent("Plans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("plans.json")
    }

    private func loadPlans() {
        guard let data = try? Data(contentsOf: plansFileURL),
              let list = try? PlanTransfer.decoder.decode([TrainingPlan].self, from: data) else { return }
        plans = list
    }

    private func savePlans() {
        if let data = try? PlanTransfer.encoder(pretty: true).encode(plans) {
            try? data.write(to: plansFileURL, options: .atomic)
        }
    }

    /// Adds or updates a plan (matched by id).
    func upsertPlan(_ plan: TrainingPlan) {
        if let i = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[i] = plan
        } else {
            plans.insert(plan, at: 0)
        }
        savePlans()
    }

    func deletePlan(_ plan: TrainingPlan) {
        plans.removeAll { $0.id == plan.id }
        savePlans()
    }

    func movePlans(from source: IndexSet, to destination: Int) {
        plans.move(fromOffsets: source, toOffset: destination)
        savePlans()
    }

    /// Plan workouts recorded for a given plan, newest first.
    func workouts(forPlan id: UUID) -> [SavedWorkout] {
        workouts.filter { $0.trainingPlanID == id }
    }

    // MARK: - Weigh-ins

    var weighInsFileURL: URL {
        let dir = documentsDirectory.appendingPathComponent("WeightCut", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("weigh_ins.json")
    }

    private func loadWeighIns() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: weighInsFileURL),
              let list = try? decoder.decode([WeighIn].self, from: data) else { return }
        weighIns = list.sorted { $0.date > $1.date }
    }

    private func saveWeighIns() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(weighIns) {
            try? data.write(to: weighInsFileURL, options: .atomic)
        }
    }

    func addWeighIn(_ entry: WeighIn) {
        weighIns.append(entry)
        weighIns.sort { $0.date > $1.date }
        saveWeighIns()
        syncProfileWeight(profileID: entry.profileID)
    }

    func deleteWeighIn(_ entry: WeighIn) {
        weighIns.removeAll { $0.id == entry.id }
        saveWeighIns()
    }

    /// Keeps the profile's body weight (used for calories and EPOC) equal to the newest weigh-in.
    private func syncProfileWeight(profileID: UUID) {
        guard let newest = weighIns.first(where: { $0.profileID == profileID }),
              let idx = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var p = profiles[idx]
        p.weightKg = newest.weightKg
        p.sanitize()
        profiles[idx] = p
        saveProfilesToDisk()
    }

    // MARK: - Fighter card photo

    /// Bumped when a fighter photo changes, so cards redraw.
    @Published var photoVersion = 0

    private func fighterPhotoURL(_ id: UUID) -> URL {
        let dir = documentsDirectory.appendingPathComponent("Body", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fighter-photo-\(id.uuidString).jpg")
    }

    func fighterPhoto(for id: UUID) -> UIImage? {
        UIImage(contentsOfFile: fighterPhotoURL(id).path)
    }

    func setFighterPhoto(_ image: UIImage?, for id: UUID) {
        let url = fighterPhotoURL(id)
        if let image {
            // Keep it light: the card never needs more than ~1200 px.
            let scale = min(1, 1200 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            try? resized.jpegData(compressionQuality: 0.85)?.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        photoVersion += 1
    }

    // MARK: - Soreness log

    private var sorenessFileURL: URL {
        let dir = documentsDirectory.appendingPathComponent("Body", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("soreness.json")
    }

    private func loadSoreness() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: sorenessFileURL),
              let list = try? decoder.decode([SorenessEntry].self, from: data) else { return }
        soreness = list.sorted { $0.date > $1.date }
    }

    private func saveSoreness() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(soreness) {
            try? data.write(to: sorenessFileURL, options: .atomic)
        }
    }

    func addSoreness(_ entries: [SorenessEntry]) {
        guard !entries.isEmpty else { return }
        soreness.append(contentsOf: entries)
        soreness.sort { $0.date > $1.date }
        saveSoreness()
    }

    func deleteSoreness(_ entry: SorenessEntry) {
        soreness.removeAll { $0.id == entry.id }
        saveSoreness()
    }

    var activeSoreness: [SorenessEntry] {
        SorenessInsights.active(soreness, profileID: activeProfileID)
    }

    func profile(for workout: SavedWorkout) -> AthleteProfile {
        profiles.first { $0.id == workout.profileID } ?? activeProfile
    }

    var savedStorageBytes: Int64 {
        let dirs = [profilesDirectory, workoutsDirectory, archivesDirectory, exportsDirectory, ghostsDirectory]
        var total: Int64 = 0
        for dir in dirs {
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for f in files {
                    if let sz = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        total += Int64(sz)
                    }
                }
            }
        }
        return total
    }

    var compressedArchiveCount: Int {
        workouts.filter(\.isCompressedArchive).count
    }
}

final class TCXStreamParser: NSObject, XMLParserDelegate {
    private var samples: [HeartRatePoint] = []
    private var currentElement = ""
    private var currentText = ""
    private var inTrackpoint = false
    private var inHeartRate = false
    private var currentTimestamp: Date?
    private var currentBPM: Int?
    private var firstDate: Date?
    private let iso = ISO8601DateFormatter()
    private let isoFractional: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    static func parse(data: Data, fallbackName: String) -> GhostSession? {
        let delegate = TCXStreamParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.samples.count >= 5 else { return nil }

        let bpms = delegate.samples.map(\.bpm)
        let avg = bpms.reduce(0, +) / bpms.count
        let peak = bpms.max() ?? avg
        return GhostSession(
            id: UUID(),
            title: "TCX: \(fallbackName)",
            subtitle: "Avg \(avg) • Peak \(peak) BPM",
            samples: delegate.samples,
            roundStats: [],
            avgBPM: avg,
            peakBPM: peak
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "Trackpoint" {
            inTrackpoint = true
            currentTimestamp = nil
            currentBPM = nil
        } else if elementName == "HeartRateBpm" {
            inHeartRate = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if inTrackpoint {
            if elementName == "Time" {
                currentTimestamp = isoFractional.date(from: trimmed) ?? iso.date(from: trimmed)
            } else if inHeartRate && elementName == "Value" {
                currentBPM = Int(trimmed)
            } else if elementName == "HeartRateBpm" {
                inHeartRate = false
            } else if elementName == "Trackpoint" {
                if let bpm = currentBPM, bpm > 30 {
                    let ts = currentTimestamp ?? Date()
                    if firstDate == nil { firstDate = ts }
                    let elapsed = max(0, ts.timeIntervalSince(firstDate ?? ts))
                    samples.append(HeartRatePoint(timestamp: ts, elapsedSeconds: elapsed, bpm: bpm))
                }
                inTrackpoint = false
            }
        }
    }
}
