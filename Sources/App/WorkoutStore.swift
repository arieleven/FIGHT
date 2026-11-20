import Foundation
import Compression

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

    private let legacyProfilesKey = "coospo_fighter_profiles_v2"
    private let legacyActiveProfileKey = "coospo_active_profile_id_v2"
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
            if let idx = profiles.firstIndex(where: { $0.id == clean.id }) {
                profiles[idx] = clean
            } else {
                profiles.append(clean)
            }
            saveProfilesToDisk()
        }
    }

    // MARK: - iPhone Files App Directory Structure ("On My iPhone / Coospo Workout")

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
    }

    // MARK: - Fighter Profiles Persistence in Files App

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

        // Migrate legacy UserDefaults profiles into Files app seamlessly
        if let legacyData = UserDefaults.standard.data(forKey: legacyProfilesKey),
           let decoded = try? decoder.decode([AthleteProfile].self, from: legacyData),
           !decoded.isEmpty {
            self.profiles = decoded
            if let savedIDStr = UserDefaults.standard.string(forKey: legacyActiveProfileKey),
               let savedID = UUID(uuidString: savedIDStr) {
                self.activeProfileID = savedID
            } else {
                self.activeProfileID = decoded[0].id
            }
            saveProfilesToDisk()
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
        if activeProfileID == profile.id, let first = profiles.first {
            activeProfileID = first.id
        }
        saveProfilesToDisk()
    }

    // MARK: - Workout Storage & Lossless LZFSE (.cspk) Compression

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
    }

    func delete(_ workout: SavedWorkout) {
        let metaURL = workoutsDirectory.appendingPathComponent("\(workout.id.uuidString).json")
        try? FileManager.default.removeItem(at: metaURL)
        if let archiveName = workout.archiveFileName {
            let archiveURL = archivesDirectory.appendingPathComponent(archiveName)
            try? FileManager.default.removeItem(at: archiveURL)
        }
        workouts.removeAll { $0.id == workout.id }
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
        let archiveName = "\(workout.id.uuidString).cspk"
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
        let originalSize = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
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

    // MARK: - Fight Camp ACWR (Acute:Chronic Workload Ratio)

    var acuteChronicWorkloadRatio: (ratio: Double, status: String) {
        let now = Date()
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86400)
        let twentyEightDaysAgo = now.addingTimeInterval(-28 * 86400)

        let acuteLoad = workouts.filter { $0.startDate >= sevenDaysAgo }.reduce(0.0) { $0 + $1.trimpScore }
        let chronicTotal = workouts.filter { $0.startDate >= twentyEightDaysAgo }.reduce(0.0) { $0 + $1.trimpScore }
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

    // MARK: - TCX Import & Export (Opponent Pace Simulator + Strava/Garmin)

    func importTCXGhost(from url: URL) -> GhostSession? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let parsed = TCXStreamParser.parse(data: data, fallbackName: url.deletingPathExtension().lastPathComponent) else {
            return nil
        }

        // Copy TCX into GhostOpponents folder in Files app for future reuse
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
    }

    func allAvailableGhosts() -> [GhostSession] {
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

        return savedGhostSessions + fromWorkouts
    }

    func exportTCXFile(for workout: SavedWorkout) -> URL {
        let samples = resolvedSamples(for: workout)
        let iso = ISO8601DateFormatter()
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
              <Notes>\(workout.category.rawValue) - \(workout.drillTag.rawValue) (RPE \(workout.rpe)/10)</Notes>
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

// MARK: - TCX XML Parser for Ghost Opponent Mode

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
                currentTimestamp = iso.date(from: trimmed)
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