import Foundation
import SwiftUI
import Combine
import AudioToolbox
import UIKit
import ActivityKit

@MainActor
final class WorkoutStore: ObservableObject {
    @Published var profiles: [AthleteProfile] = []
    @Published var activeProfileID: UUID = UUID()

    // Active Workout State
    @Published var selectedCategory: WorkoutCategory = .kickboxing
    @Published var selectedRoundPreset: RoundPreset = .kickboxing3x1
    @Published var isWorkoutActive = false
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var averageBPM: Int = 0
    @Published var maxBPM: Int = 0
    @Published var minBPM: Int = 0
    @Published var estimatedCalories: Double = 0
    @Published var epocBonusCalories: Double = 0
    @Published var activeZoneSeconds: [Int: Double] = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
    @Published var statusMessage: String?

    // Deterministic Wall-Clock Round Timer State
    @Published var currentRound: Int = 1
    @Published var isRoundRest: Bool = false
    @Published var roundSecondsRemaining: Int = 0
    @Published var phaseEndDate: Date = Date()

    // Post-Workout HRR-60 & Quick Tagger Sheet
    @Published var isMeasuringHRR = false
    @Published var hrrSecondsRemaining: Int = 60
    @Published var hrrStartBPM: Int = 0
    @Published var hrrCurrentDrop: Int = 0
    @Published var pendingTagWorkout: SavedWorkout? = nil

    // History, Weigh-Ins & Storage Metrics
    @Published var savedWorkouts: [SavedWorkout] = []
    @Published var weighIns: [WeighInEntry] = []
    @Published var latestMorningRMSSD: Double? = nil
    @Published var compressedArchiveCount: Int = 0
    @Published var savedStorageBytes: Int64 = 0

    private var workoutStartDate: Date?
    private var lastSampleDate: Date?
    private var timer: Timer?
    private var hrrTimer: Timer?
    private var activeSamples: [HeartRatePoint] = []
    private var currentRoundSamples: [Int] = []
    private var completedRoundStats: [RoundStat] = []
    private var currentRoundPeakBPM: Int = 0
    private var currentRoundAvgBPM: Int = 0
    private var hrrLowestBPM: Int = 999
    private var currentActivity: Activity<WorkoutActivityAttributes>?
    private var lastLiveActivityUpdate: Date = .distantPast

    // MARK: - Files App Visible Directories
    private var baseFilesDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("CoospoLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var activeLogsDir: URL {
        let dir = baseFilesDir.appendingPathComponent("Active_Under7Days", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var compressedArchiveDir: URL {
        let dir = baseFilesDir.appendingPathComponent("Compressed_Lossless_CSPK", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var profilesURL: URL { baseFilesDir.appendingPathComponent("profiles.json") }
    private var workoutsIndexURL: URL { baseFilesDir.appendingPathComponent("workouts_index.json") }
    private var weighInsURL: URL { baseFilesDir.appendingPathComponent("fight_weigh_ins.json") }

    var activeProfile: AthleteProfile {
        get {
            profiles.first(where: { $0.id == activeProfileID }) ?? .defaultFighter
        }
        set {
            var sanitized = newValue
            sanitized.sanitize()
            if let idx = profiles.firstIndex(where: { $0.id == sanitized.id }) {
                profiles[idx] = sanitized
                persistProfiles()
            }
        }
    }

    var activeProfileWorkouts: [SavedWorkout] {
        savedWorkouts.filter { $0.athleteID == activeProfile.id }
    }

    var activeProfileWeighIns: [WeighInEntry] {
        weighIns
            .filter { $0.athleteID == activeProfile.id }
            .sorted { $0.date > $1.date }
    }

    init() {
        loadProfiles()
        loadWeighIns()
        loadWorkoutsAndRunAutoCompression()
    }

    // MARK: - Profile & Weigh-In Management
    func addProfile(name: String) {
        var newProfile = AthleteProfile.defaultFighter
        newProfile.id = UUID()
        newProfile.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Fighter \(profiles.count + 1)"
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        newProfile.sanitize()
        profiles.append(newProfile)
        activeProfileID = newProfile.id
        persistProfiles()
    }

    func deleteProfile(_ profile: AthleteProfile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id, let first = profiles.first {
            activeProfileID = first.id
        }
        persistProfiles()
    }

    func updateBaselineHRV(_ rmssd: Double) {
        latestMorningRMSSD = rmssd
        var p = activeProfile
        p.baselineRMSSD = (p.baselineRMSSD * 0.8) + (rmssd * 0.2)
        activeProfile = p
    }

    func logWeighIn(weightKg: Double, hydration: HydrationStatus, morningRHR: Int) {
        let clampedWeight = min(max(35.0, weightKg), 200.0)
        let clampedRHR = min(max(30, morningRHR), 120)

        let entry = WeighInEntry(
            athleteID: activeProfile.id,
            date: Date(),
            fastedWeightKg: clampedWeight,
            hydration: hydration,
            morningRestingHR: clampedRHR,
            morningRMSSD: latestMorningRMSSD
        )
        weighIns.insert(entry, at: 0)
        persistWeighIns()

        var p = activeProfile
        p.weightKg = clampedWeight
        p.restingHR = clampedRHR
        activeProfile = p
    }

    // MARK: - Workout Lifecycle (Wall-Clock Deterministic)
    func startWorkout() {
        let start = Date()
        workoutStartDate = start
        lastSampleDate = start
        activeSamples.removeAll()
        currentRoundSamples.removeAll()
        completedRoundStats.removeAll()
        currentRoundPeakBPM = 0
        currentRoundAvgBPM = 0
        elapsedSeconds = 0
        averageBPM = 0
        maxBPM = 0
        minBPM = 0
        estimatedCalories = 0
        epocBonusCalories = 0
        activeZoneSeconds = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
        statusMessage = nil

        currentRound = 1
        isRoundRest = false
        let workSec = selectedRoundPreset.workSeconds
        roundSecondsRemaining = workSec
        phaseEndDate = start.addingTimeInterval(TimeInterval(workSec))
        isWorkoutActive = true

        if selectedRoundPreset != .open {
            triggerRoundBell()
        }

        startLiveActivity(startDate: start)

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncWallClockRoundState()
            }
        }
    }

    private func syncWallClockRoundState() {
        guard let start = workoutStartDate else { return }
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(start))
        elapsedSeconds = elapsed

        guard selectedRoundPreset != .open else { return }
        let work = selectedRoundPreset.workSeconds
        let rest = selectedRoundPreset.restSeconds
        let cycleLength = work + rest
        guard cycleLength > 0 else { return }

        let totalSec = Int(elapsed)
        let newRound = (totalSec / cycleLength) + 1
        let secIntoCycle = totalSec % cycleLength
        let newIsRest = secIntoCycle >= work
        let newRemaining = newIsRest ? (cycleLength - secIntoCycle) : (work - secIntoCycle)
        let newPhaseEnd = now.addingTimeInterval(TimeInterval(newRemaining))

        // Detect phase transition (Work -> Rest or Rest -> Next Round)
        if newIsRest != isRoundRest || newRound != currentRound {
            if newIsRest && !isRoundRest {
                // Work round just ended: record peak & avg for this round
                currentRoundPeakBPM = currentRoundSamples.max() ?? (activeSamples.last?.bpm ?? maxBPM)
                currentRoundAvgBPM = currentRoundSamples.isEmpty
                    ? (activeSamples.last?.bpm ?? averageBPM)
                    : (currentRoundSamples.reduce(0, +) / currentRoundSamples.count)
                currentRoundSamples.removeAll()
            } else if !newIsRest && newRound > currentRound {
                // Rest stool just ended: compute stool drop and save RoundStat
                let endRestBPM = activeSamples.last?.bpm ?? currentRoundPeakBPM
                let drop = max(0, currentRoundPeakBPM - endRestBPM)
                completedRoundStats.append(RoundStat(
                    roundNumber: currentRound,
                    avgBPM: currentRoundAvgBPM,
                    peakBPM: currentRoundPeakBPM,
                    stoolDropBPM: drop
                ))
                currentRoundPeakBPM = 0
                currentRoundAvgBPM = 0
                currentRoundSamples.removeAll()
            }

            currentRound = newRound
            isRoundRest = newIsRest
            roundSecondsRemaining = newRemaining
            phaseEndDate = newPhaseEnd
            triggerRoundBell()
            updateLiveActivity(bpm: activeSamples.last?.bpm ?? 0, force: true)
        } else {
            roundSecondsRemaining = newRemaining
            phaseEndDate = newPhaseEnd
        }
    }

    private func triggerRoundBell() {
        AudioServicesPlaySystemSound(1005)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }

    func recordHeartRate(_ bpm: Int, rrMs: Double?, at timestamp: Date) {
        if isMeasuringHRR {
            hrrLowestBPM = min(hrrLowestBPM, bpm)
            hrrCurrentDrop = max(0, hrrStartBPM - hrrLowestBPM)
            return
        }

        guard isWorkoutActive, let start = workoutStartDate else { return }

        let elapsed = max(0, timestamp.timeIntervalSince(start))
        activeSamples.append(HeartRatePoint(timestamp: timestamp, elapsedSeconds: elapsed, bpm: bpm, rrIntervalMs: rrMs))

        if !isRoundRest {
            currentRoundSamples.append(bpm)
        }

        maxBPM = max(maxBPM, bpm)
        minBPM = (minBPM == 0) ? bpm : min(minBPM, bpm)
        let sum = activeSamples.reduce(0) { $0 + $1.bpm }
        averageBPM = sum / activeSamples.count

        let profile = activeProfile
        let zoneInfo = profile.zone(for: bpm)

        if let previous = lastSampleDate {
            let dt = min(max(0, timestamp.timeIntervalSince(previous)), 10.0)
            if dt > 0 {
                activeZoneSeconds[zoneInfo.number, default: 0] += dt

                let baseKcalPerMin: Double
                if profile.sex == .male {
                    baseKcalPerMin = (-55.0969 + (0.6309 * Double(bpm)) + (0.1988 * profile.weightKg) + (0.2017 * Double(profile.age))) / 4.184
                } else {
                    baseKcalPerMin = (-20.4022 + (0.4472 * Double(bpm)) - (0.1263 * profile.weightKg) + (0.074 * Double(profile.age))) / 4.184
                }

                let clampedBase = max(1.0, baseKcalPerMin) * (dt / 60.0)
                let epocFactor: Double
                switch zoneInfo.number {
                case 5: epocFactor = 0.22
                case 4: epocFactor = 0.14
                case 3: epocFactor = 0.06
                default: epocFactor = 0.0
                }

                let bonus = clampedBase * epocFactor
                epocBonusCalories += bonus
                estimatedCalories += (clampedBase + bonus)
            }
        }
        lastSampleDate = timestamp
        updateLiveActivity(bpm: bpm, force: false)
    }

    func initiateFinishAndMeasureHRR(currentBPM: Int) {
        timer?.invalidate()
        timer = nil
        isWorkoutActive = false
        endLiveActivity()

        // Capture final in-progress round if ended during work
        if selectedRoundPreset != .open && !isRoundRest && !currentRoundSamples.isEmpty {
            let peak = currentRoundSamples.max() ?? maxBPM
            let avg = currentRoundSamples.reduce(0, +) / currentRoundSamples.count
            completedRoundStats.append(RoundStat(
                roundNumber: currentRound,
                avgBPM: avg,
                peakBPM: peak,
                stoolDropBPM: nil
            ))
        }

        if currentBPM > 0 && activeSamples.count >= 5 {
            isMeasuringHRR = true
            hrrSecondsRemaining = 60
            hrrStartBPM = currentBPM
            hrrLowestBPM = currentBPM
            hrrCurrentDrop = 0

            hrrTimer?.invalidate()
            hrrTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                Task { @MainActor in
                    guard let self else { t.invalidate(); return }
                    if self.hrrSecondsRemaining > 1 {
                        self.hrrSecondsRemaining -= 1
                    } else {
                        t.invalidate()
                        self.isMeasuringHRR = false
                        self.finalizeAndSaveWorkout(hrr60: self.hrrCurrentDrop)
                    }
                }
            }
        } else {
            finalizeAndSaveWorkout(hrr60: nil)
        }
    }

    func skipHRRAndSaveNow() {
        hrrTimer?.invalidate()
        hrrTimer = nil
        let measured = (60 - hrrSecondsRemaining >= 20) ? hrrCurrentDrop : nil
        isMeasuringHRR = false
        finalizeAndSaveWorkout(hrr60: measured)
    }

    private func finalizeAndSaveWorkout(hrr60: Int?) {
        guard let start = workoutStartDate else { return }
        let duration = max(1.0, elapsedSeconds)
        let profile = activeProfile

        let durationMinutes = duration / 60.0
        let hrrFraction = max(0.0, min(1.2, Double(averageBPM - profile.restingHR) / Double(max(30, profile.effectiveMaxHR - profile.restingHR))))
        let genderFactor = (profile.sex == .male) ? 1.92 : 1.67
        let trimp = durationMinutes * hrrFraction * 0.64 * exp(genderFactor * hrrFraction)

        let rrList = activeSamples.compactMap { $0.rrIntervalMs }
        let sessionRMSSD = BLEHeartRateManager.computeRMSSD(from: rrList)
        let drift = computeCardiacDrift(samples: activeSamples)

        let drops = completedRoundStats.compactMap { $0.stoolDropBPM }
        let avgRoundDrop = drops.isEmpty ? nil : (drops.reduce(0, +) / drops.count)
        let pois = detectPointsOfInterest(samples: activeSamples, hrr60: hrr60)

        let defaultTag: DrillTag = selectedCategory.isAnaerobicFocus ? .heavyBagPower : .roadwork

        let workout = SavedWorkout(
            id: UUID(),
            athleteID: profile.id,
            category: selectedCategory,
            roundPreset: selectedRoundPreset,
            drillTag: defaultTag,
            rpe: 7,
            notes: "",
            startDate: start,
            duration: duration,
            averageBPM: averageBPM,
            maxBPM: maxBPM,
            minBPM: minBPM,
            calories: estimatedCalories,
            epocBonusCalories: epocBonusCalories,
            trimpScore: trimp,
            hrr60Drop: hrr60,
            avgInterRoundDrop: avgRoundDrop,
            rmssdMs: sessionRMSSD,
            cardiacDriftPercent: drift,
            zoneSeconds: activeZoneSeconds,
            roundStats: completedRoundStats,
            pointsOfInterest: pois,
            sampleCount: activeSamples.count,
            isCompressedArchive: false,
            samples: activeSamples
        )

        savedWorkouts.insert(workout, at: 0)
        writeActiveWorkoutJSON(workout)
        persistWorkoutsIndex()
        recalculateStorageStats()

        pendingTagWorkout = workout
        statusMessage = "Saved \(selectedCategory.rawValue) • \(Int(estimatedCalories)) kcal • TRIMP \(Int(trimp))"
        workoutStartDate = nil
    }

    func updateWorkoutTagging(workoutID: UUID, drillTag: DrillTag, rpe: Int, notes: String) {
        guard let idx = savedWorkouts.firstIndex(where: { $0.id == workoutID }) else { return }
        savedWorkouts[idx].drillTag = drillTag
        savedWorkouts[idx].rpe = min(max(1, rpe), 10)
        savedWorkouts[idx].notes = notes
        if !savedWorkouts[idx].isCompressedArchive {
            writeActiveWorkoutJSON(savedWorkouts[idx])
        }
        persistWorkoutsIndex()
    }

    func deleteWorkout(_ workout: SavedWorkout) {
        savedWorkouts.removeAll { $0.id == workout.id }
        let jsonURL = activeLogsDir.appendingPathComponent("\(workout.id.uuidString).json")
        let cspkURL = compressedArchiveDir.appendingPathComponent("\(workout.id.uuidString).cspk")
        try? FileManager.default.removeItem(at: jsonURL)
        try? FileManager.default.removeItem(at: cspkURL)
        persistWorkoutsIndex()
        recalculateStorageStats()
    }

    // MARK: - On-Demand Lossless Decompression for Archived Workouts (>7 Days Old)
    func resolvedSamples(for workout: SavedWorkout) -> [HeartRatePoint] {
        if !workout.samples.isEmpty {
            return workout.samples
        }
        let cspkURL = compressedArchiveDir.appendingPathComponent("\(workout.id.uuidString).cspk")
        if let data = try? Data(contentsOf: cspkURL),
           let unpacked = WorkoutCompressor.decompress(data: data) {
            return unpacked
        }
        let jsonURL = activeLogsDir.appendingPathComponent("\(workout.id.uuidString).json")
        if let data = try? Data(contentsOf: jsonURL),
           let fullWorkout = try? JSONDecoder().decode(SavedWorkout.self, from: data) {
            return fullWorkout.samples
        }
        return []
    }

    /// Scans all workouts older than 7 days and losslessly compresses their HR stream into .cspk
    func runLosslessAutoCompression() {
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 86400)
        var didModify = false

        for i in 0..<savedWorkouts.count {
            let w = savedWorkouts[i]
            if w.startDate < sevenDaysAgo && !w.isCompressedArchive {
                let rawSamples = resolvedSamples(for: w)
                if let compressedData = WorkoutCompressor.compress(samples: rawSamples),
                   let verification = WorkoutCompressor.decompress(data: compressedData),
                   verification.count == rawSamples.count {
                    let cspkURL = compressedArchiveDir.appendingPathComponent("\(w.id.uuidString).cspk")
                    try? compressedData.write(to: cspkURL, options: .atomic)

                    // Remove large raw JSON file once verified lossless archive is written
                    let jsonURL = activeLogsDir.appendingPathComponent("\(w.id.uuidString).json")
                    try? FileManager.default.removeItem(at: jsonURL)

                    savedWorkouts[i].isCompressedArchive = true
                    savedWorkouts[i].samples = [] // Free RAM; loaded on-demand from .cspk
                    didModify = true
                }
            }
        }

        if didModify {
            persistWorkoutsIndex()
        }
        recalculateStorageStats()
    }

    private func recalculateStorageStats() {
        compressedArchiveCount = savedWorkouts.filter { $0.isCompressedArchive }.count
        var totalBytes: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: baseFilesDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    totalBytes += Int64(size)
                }
            }
        }
        savedStorageBytes = totalBytes
    }

    // MARK: - Live Activity (Lock Screen & Dynamic Island)
    private func startLiveActivity(startDate: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let profile = activeProfile
        let attrs = WorkoutActivityAttributes(athleteName: profile.name, discipline: selectedCategory.rawValue)
        let state = WorkoutActivityAttributes.ContentState(
            currentBPM: 0,
            zoneNumber: 1,
            zoneShortName: "Z1",
            roundNumber: 1,
            isRest: false,
            isTimedRound: selectedRoundPreset != .open,
            phaseEndDate: phaseEndDate,
            workoutStartDate: startDate,
            calories: 0
        )
        do {
            currentActivity = try Activity.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            currentActivity = nil
        }
    }

    private func updateLiveActivity(bpm: Int, force: Bool) {
        guard let activity = currentActivity else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastLiveActivityUpdate) < 2.0 { return }
        lastLiveActivityUpdate = now

        let zone = activeProfile.zone(for: bpm)
        let state = WorkoutActivityAttributes.ContentState(
            currentBPM: bpm,
            zoneNumber: zone.number,
            zoneShortName: zone.shortName,
            roundNumber: currentRound,
            isRest: isRoundRest,
            isTimedRound: selectedRoundPreset != .open,
            phaseEndDate: phaseEndDate,
            workoutStartDate: workoutStartDate ?? now,
            calories: Int(estimatedCalories)
        )
        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    private func endLiveActivity() {
        guard let activity = currentActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
    }

    // MARK: - Analytics & Points of Interest
    private func computeCardiacDrift(samples: [HeartRatePoint]) -> Double {
        guard samples.count >= 20 else { return 0.0 }
        let mid = samples.count / 2
        let firstHalf = samples[..<mid].map { Double($0.bpm) }
        let secondHalf = samples[mid...].map { Double($0.bpm) }
        let avg1 = firstHalf.reduce(0, +) / Double(firstHalf.count)
        let avg2 = secondHalf.reduce(0, +) / Double(secondHalf.count)
        guard avg1 > 0 else { return 0.0 }
        return ((avg2 - avg1) / avg1) * 100.0
    }

    private func detectPointsOfInterest(samples: [HeartRatePoint], hrr60: Int?) -> [WorkoutPOI] {
        guard samples.count >= 5 else { return [] }
        var pois: [WorkoutPOI] = []

        if let peak = samples.max(by: { $0.bpm < $1.bpm }) {
            let pct = Int(round((Double(peak.bpm) / Double(activeProfile.effectiveMaxHR)) * 100))
            pois.append(WorkoutPOI(
                title: "Peak Output (\(peak.bpm) BPM)",
                detail: "\(pct)% of Max HR reached at \(formatTime(peak.elapsedSeconds))",
                elapsedSeconds: peak.elapsedSeconds,
                bpm: peak.bpm,
                symbol: "flame.fill",
                isPositive: false
            ))
        }

        var maxSurge = 0
        var surgePoint: HeartRatePoint?
        for i in 0..<samples.count {
            for j in (i + 1)..<samples.count {
                let dt = samples[j].elapsedSeconds - samples[i].elapsedSeconds
                if dt >= 20 && dt <= 40 {
                    let delta = samples[j].bpm - samples[i].bpm
                    if delta > maxSurge {
                        maxSurge = delta
                        surgePoint = samples[j]
                    }
                    break
                }
            }
        }
        if let sp = surgePoint, maxSurge >= 12 {
            pois.append(WorkoutPOI(
                title: "Explosive Surge (+\(maxSurge) BPM)",
                detail: "Rapid anaerobic spike in ~30s at \(formatTime(sp.elapsedSeconds))",
                elapsedSeconds: sp.elapsedSeconds,
                bpm: sp.bpm,
                symbol: "bolt.fill",
                isPositive: true
            ))
        }

        var maxDrop = 0
        var dropPoint: HeartRatePoint?
        for i in 0..<samples.count {
            for j in (i + 1)..<samples.count {
                let dt = samples[j].elapsedSeconds - samples[i].elapsedSeconds
                if dt >= 45 && dt <= 75 {
                    let drop = samples[i].bpm - samples[j].bpm
                    if drop > maxDrop {
                        maxDrop = drop
                        dropPoint = samples[j]
                    }
                    break
                }
            }
        }
        if let dp = dropPoint, maxDrop >= 12 {
            pois.append(WorkoutPOI(
                title: "Fast Recovery (-\(maxDrop) BPM/min)",
                detail: "Strong parasympathetic rebound at \(formatTime(dp.elapsedSeconds))",
                elapsedSeconds: dp.elapsedSeconds,
                bpm: dp.bpm,
                symbol: "lungs.fill",
                isPositive: true
            ))
        }

        if let hrr = hrr60, let last = samples.last {
            pois.append(WorkoutPOI(
                title: "Post-Session HRR-60: -\(hrr) BPM",
                detail: hrr >= 25 ? "Elite cardiac recovery" : (hrr >= 15 ? "Solid conditioning" : "Elevated fatigue"),
                elapsedSeconds: last.elapsedSeconds,
                bpm: last.bpm,
                symbol: "heart.text.square.fill",
                isPositive: hrr >= 18
            ))
        }

        return pois
    }

    // MARK: - Fighter Readiness & Adrenaline-Aware Coach Engine
    func computeFighterAnalytics() -> FighterAnalytics {
        let profile = activeProfile
        let workouts = activeProfileWorkouts
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recent7d = workouts.filter { $0.startDate >= sevenDaysAgo }

        let weeklyTRIMP = recent7d.reduce(0.0) { $0 + $1.trimpScore }

        var z12Seconds = 0.0
        var z3Seconds = 0.0
        var z45Seconds = 0.0
        for w in recent7d {
            z12Seconds += (w.zoneSeconds[1, default: 0] + w.zoneSeconds[2, default: 0])
            z3Seconds += w.zoneSeconds[3, default: 0]
            z45Seconds += (w.zoneSeconds[4, default: 0] + w.zoneSeconds[5, default: 0])
        }
        let totalZSeconds = max(1.0, z12Seconds + z3Seconds + z45Seconds)

        let steadyWorkouts = recent7d.filter { !$0.category.isAnaerobicFocus && $0.duration >= 900 }
        let avgDrift = steadyWorkouts.isEmpty ? 3.5 : (steadyWorkouts.map { abs($0.cardiacDriftPercent) }.reduce(0, +) / Double(steadyWorkouts.count))
        let driftComponent = max(35.0, min(100.0, 100.0 - (avgDrift * 6.0)))
        let z2Minutes = z12Seconds / 60.0
        let aerobicScore = Int(min(99, max(40, driftComponent * 0.8 + min(20.0, z2Minutes / 6.0))))

        let z45Minutes = z45Seconds / 60.0
        let anaerobicWorkouts = recent7d.filter { $0.category.isAnaerobicFocus }
        let peakRatio = anaerobicWorkouts.isEmpty ? 0.88 : (Double(anaerobicWorkouts.map { $0.maxBPM }.max() ?? 175) / Double(profile.effectiveMaxHR))
        let anaerobicScore = Int(min(99, max(40, (peakRatio * 75.0) + min(24.0, z45Minutes * 0.8))))

        let latestHRR = workouts.compactMap { $0.hrr60Drop }.first
        let latestHRV = latestMorningRMSSD ?? workouts.compactMap { $0.rmssdMs }.first

        var recoveryRaw = 72.0
        if let hrr = latestHRR {
            recoveryRaw = min(99.0, max(35.0, 30.0 + Double(hrr) * 2.0))
        }
        if let hrv = latestHRV {
            let hrvRatio = hrv / max(20.0, profile.baselineRMSSD)
            let hrvScore = min(100.0, max(30.0, hrvRatio * 80.0))
            recoveryRaw = (recoveryRaw * 0.55) + (hrvScore * 0.45)
        }
        let recoveryScore = Int(round(recoveryRaw))
        let staminaRating = Int(round(Double(aerobicScore) * 0.35 + Double(anaerobicScore) * 0.40 + Double(recoveryScore) * 0.25))

        // Fight Week Dehydration Check
        var dehydrationWarning: String? = nil
        let myWeighIns = activeProfileWeighIns
        if let latestWI = myWeighIns.first {
            let rhrSpike = latestWI.morningRestingHR - profile.restingHR
            let rapidDropPct: Double
            if myWeighIns.count >= 2 {
                let prev = myWeighIns[1].fastedWeightKg
                rapidDropPct = ((prev - latestWI.fastedWeightKg) / max(35.0, prev)) * 100.0
            } else {
                rapidDropPct = 0.0
            }

            if latestWI.hydration.rawValue >= 3 && (rhrSpike >= 6 || rapidDropPct >= 1.5) {
                dehydrationWarning = "Dehydration Alert: Urine status \(latestWI.hydration.rawValue)/4 with +\(max(0, rhrSpike)) BPM RHR spike (\(String(format: "%.1f", rapidDropPct))% 24h weight drop). Rehydrate with 1,000mg sodium + electrolytes before sparring."
            }
        }

        let lastSession = workouts.first
        let lastTRIMP = lastSession?.trimpScore ?? 0
        var recHours = 12
        if lastTRIMP > 140 { recHours = 36 }
        else if lastTRIMP > 90 { recHours = 24 }
        else if lastTRIMP > 45 { recHours = 16 }

        if let hrv = latestHRV, hrv < profile.baselineRMSSD * 0.82 { recHours += 8 }
        if let hrr = latestHRR, hrr < 15 { recHours += 6 }

        var sleepHours = 7.5
        if z45Minutes > 25 || lastTRIMP > 100 { sleepHours += 0.75 }
        if let hrv = latestHRV, hrv < profile.baselineRMSSD * 0.85 { sleepHours += 0.75 }
        if profile.campPhase == .fightCut || profile.campPhase == .peakTaper { sleepHours += 0.5 }
        sleepHours = min(9.5, sleepHours)

        var prescriptions: [CoachPrescription] = []

        if let warning = dehydrationWarning {
            prescriptions.append(CoachPrescription(
                title: "Fight Cut Over-Dehydration Warning",
                tag: "HYDRATION & RHR",
                tagColor: .red,
                diagnosis: warning,
                actionPlan: "Pause sauna/sweat-suit sessions for 24 hours. Sip 750ml–1L water with electrolytes slowly and keep training strictly technical shadowboxing.",
                icon: "drop.triangle.fill"
            ))
        }

        if workouts.isEmpty {
            prescriptions.append(CoachPrescription(
                title: "Establish Your Fighter Baseline",
                tag: "ONBOARDING",
                tagColor: .blue,
                diagnosis: "No workouts logged yet for \(profile.name).",
                actionPlan: "Log 1 Kickboxing/Bag session (with 60s HRR cooldown) and 1 steady 30-min Zone 2 run so the engine can measure your aerobic drift and anaerobic gas-tank.",
                icon: "figure.kickboxing"
            ))
        } else {
            // Distinguish Adrenaline Sparring Spikes vs True Anaerobic Conditioning Deficit
            let isAdrenalineSparring = (lastSession?.drillTag == .hardSparring || lastSession?.drillTag == .technicalSparring)
                && (lastSession?.rpe ?? 7) <= 6
                && (lastSession?.maxBPM ?? 0) >= profile.activeZones.z4Max

            if isAdrenalineSparring {
                prescriptions.append(CoachPrescription(
                    title: "Sympathetic Adrenaline Spike Detected (Not Cardio Failure)",
                    tag: "SPARRING COMPOSURE",
                    tagColor: .cyan,
                    diagnosis: "Your HR entered Z4/Z5 during \(lastSession!.drillTag.rawValue) despite moderate RPE (\(lastSession!.rpe)/10)—a classic fight-or-flight catecholamine surge.",
                    actionPlan: "Your aerobic engine is fine; focus on physiological sighs (double inhale, long exhale) between exchanges and relaxed guard posture during sparring rounds.",
                    icon: "brain.head.profile"
                ))
            } else {
                let poorRoundRecovery = (lastSession?.avgInterRoundDrop ?? 20) < 14
                if (latestHRR ?? 22) < 18 || poorRoundRecovery || anaerobicScore < 68 {
                    prescriptions.append(CoachPrescription(
                        title: "Upgrade Anaerobic Gas Tank (Norwegian 4x4s)",
                        tag: "VO2 MAX & STOOL RECOVERY",
                        tagColor: .red,
                        diagnosis: "High RPE (\(lastSession?.rpe ?? 8)/10) paired with slow HR drop (\(latestHRR != nil ? "HRR-60: -\(latestHRR!) BPM" : "slow stool recovery")) shows true glycolytic fatigue.",
                        actionPlan: "Run 1–2x/week Norwegian 4x4 intervals: 4 min at 90–95% HRmax (\(profile.activeZones.z4Max)–\(profile.effectiveMaxHR) BPM) + 3 min active walk/jog.",
                        icon: "bolt.heart.fill"
                    ))
                }
            }

            if avgDrift > 5.0 || z2Minutes < 45 {
                prescriptions.append(CoachPrescription(
                    title: "Build Aerobic Engine (Zone 2 LSD Runs)",
                    tag: "AEROBIC BASE",
                    tagColor: .green,
                    diagnosis: avgDrift > 5.0
                        ? String(format: "Cardiac drift is %.1f%%—your heart rate climbs steadily at constant pace, limiting late-round stamina.", avgDrift)
                        : "Low weekly Zone 2 volume (\(Int(z2Minutes)) min). A bigger aerobic base clears lactate faster between rounds.",
                    actionPlan: "Add two 45–60 min Long Slow Distance runs locked strictly in Zone 2 (\(profile.activeZones.z1Max + 1)–\(profile.activeZones.z2Max) BPM).",
                    icon: "lungs.fill"
                ))
            }

            if (z3Seconds / totalZSeconds) > 0.45 && recent7d.count >= 2 {
                prescriptions.append(CoachPrescription(
                    title: "Escape the Zone 3 'Gray Zone' Trap",
                    tag: "POLARIZATION",
                    tagColor: .yellow,
                    diagnosis: "\(Int((z3Seconds / totalZSeconds) * 100))% of your week is spent in moderate Zone 3—too hard for recovery, too easy to raise VO2 max.",
                    actionPlan: "Polarize your week (80/20 rule): keep roadwork easy in Z2, and push pad/bag rounds into Z4–Z5.",
                    icon: "chart.bar.xaxis"
                ))
            }
        }

        let trendLabel: String
        if weeklyTRIMP > 350 { trendLabel = "Peak Fight Load" }
        else if weeklyTRIMP > 150 { trendLabel = "Building Momentum" }
        else { trendLabel = "Fresh / Ready to Push" }

        return FighterAnalytics(
            staminaRating: staminaRating,
            aerobicScore: aerobicScore,
            anaerobicScore: anaerobicScore,
            recoveryScore: recoveryScore,
            weeklyTRIMP: weeklyTRIMP,
            recommendedRecoveryHours: recHours,
            recommendedSleepHours: sleepHours,
            latestHRV: latestHRV,
            latestHRR60: latestHRR,
            dehydrationWarning: dehydrationWarning,
            trendLabel: trendLabel,
            prescriptions: prescriptions
        )
    }

    // MARK: - TCX Export (Supports Both Active & Losslessly Archived Workouts)
    func exportTCXFile(for workout: SavedWorkout) -> URL {
        let fullSamples = resolvedSamples(for: workout)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startString = iso.string(from: workout.startDate)

        var trackpointsXML = ""
        for point in fullSamples {
            trackpointsXML += """
                    <Trackpoint>
                      <Time>\(iso.string(from: point.timestamp))</Time>
                      <HeartRateBpm><Value>\(point.bpm)</Value></HeartRateBpm>
                    </Trackpoint>\n
            """
        }

        let tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="\(workout.category.tcxSport)">
              <Id>\(startString)</Id>
              <Lap StartTime="\(startString)">
                <TotalTimeSeconds>\(Int(workout.duration))</TotalTimeSeconds>
                <DistanceMeters>0</DistanceMeters>
                <Calories>\(Int(workout.calories))</Calories>
                <AverageHeartRateBpm><Value>\(workout.averageBPM)</Value></AverageHeartRateBpm>
                <MaximumHeartRateBpm><Value>\(workout.maxBPM)</Value></MaximumHeartRateBpm>
                <Intensity>Active</Intensity>
                <TriggerMethod>Manual</TriggerMethod>
                <Track>
        \(trackpointsXML)        </Track>
              </Lap>
              <Notes>\(workout.category.rawValue) [\(workout.drillTag.rawValue), RPE \(workout.rpe)/10]</Notes>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let fileName = "Coospo_\(workout.category.rawValue.replacingOccurrences(of: " ", with: "_"))_\(Int(workout.startDate.timeIntervalSince1970)).tcx"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? tcx.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    // MARK: - Persistence Helpers
    private func writeActiveWorkoutJSON(_ workout: SavedWorkout) {
        let jsonURL = activeLogsDir.appendingPathComponent("\(workout.id.uuidString).json")
        if let data = try? JSONEncoder().encode(workout) {
            try? data.write(to: jsonURL, options: .atomic)
        }
    }

    private func persistWorkoutsIndex() {
        // Store metadata index without duplicating huge sample arrays
        let indexItems = savedWorkouts.map { item -> SavedWorkout in
            var copy = item
            copy.samples = []
            return copy
        }
        if let data = try? JSONEncoder().encode(indexItems) {
            try? data.write(to: workoutsIndexURL, options: .atomic)
        }
    }

    private func loadWorkoutsAndRunAutoCompression() {
        if let data = try? Data(contentsOf: workoutsIndexURL),
           let decoded = try? JSONDecoder().decode([SavedWorkout].self, from: data) {
            savedWorkouts = decoded
        }
        runLosslessAutoCompression()
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: profilesURL, options: .atomic)
        }
        UserDefaults.standard.set(activeProfileID.uuidString, forKey: "ActiveAthleteProfileID")
    }

    private func loadProfiles() {
        if let data = try? Data(contentsOf: profilesURL),
           var decoded = try? JSONDecoder().decode([AthleteProfile].self, from: data),
           !decoded.isEmpty {
            for i in 0..<decoded.count { decoded[i].sanitize() }
            profiles = decoded
        } else {
            profiles = [.defaultFighter]
        }

        if let savedID = UserDefaults.standard.string(forKey: "ActiveAthleteProfileID"),
           let uuid = UUID(uuidString: savedID),
           profiles.contains(where: { $0.id == uuid }) {
            activeProfileID = uuid
        } else if let first = profiles.first {
            activeProfileID = first.id
        }
    }

    private func persistWeighIns() {
        if let data = try? JSONEncoder().encode(weighIns) {
            try? data.write(to: weighInsURL, options: .atomic)
        }
    }

    private func loadWeighIns() {
        guard let data = try? Data(contentsOf: weighInsURL),
              let decoded = try? JSONDecoder().decode([WeighInEntry].self, from: data) else { return }
        weighIns = decoded
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}