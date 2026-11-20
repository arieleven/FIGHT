import Foundation
import SwiftUI
import Combine
import AudioToolbox
import UIKit

@MainActor
final class WorkoutStore: ObservableObject {
    // Profiles
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

    // Round Timer State
    @Published var currentRound: Int = 1
    @Published var isRoundRest: Bool = false
    @Published var roundSecondsRemaining: Int = 0

    // Post-Workout 60-Second Heart Rate Recovery (HRR-60) State
    @Published var isMeasuringHRR = false
    @Published var hrrSecondsRemaining: Int = 60
    @Published var hrrStartBPM: Int = 0
    @Published var hrrCurrentDrop: Int = 0

    // History & Morning HRV logs
    @Published var savedWorkouts: [SavedWorkout] = []
    @Published var latestMorningRMSSD: Double? = nil

    private var workoutStartDate: Date?
    private var lastSampleDate: Date?
    private var timer: Timer?
    private var hrrTimer: Timer?
    private var activeSamples: [HeartRatePoint] = []
    private var roundPeakBPM: Int = 0
    private var interRoundDrops: [Int] = []
    private var hrrLowestBPM: Int = 999

    private var profilesURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profiles.json")
    }

    private var workoutsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workouts_v2.json")
    }

    var activeProfile: AthleteProfile {
        get {
            profiles.first(where: { $0.id == activeProfileID }) ?? .defaultFighter
        }
        set {
            if let idx = profiles.firstIndex(where: { $0.id == newValue.id }) {
                profiles[idx] = newValue
                persistProfiles()
            }
        }
    }

    var activeProfileWorkouts: [SavedWorkout] {
        savedWorkouts.filter { $0.athleteID == activeProfile.id }
    }

    init() {
        loadProfiles()
        loadWorkouts()
    }

    // MARK: - Profile Management
    func addProfile(name: String) {
        var newProfile = AthleteProfile.defaultFighter
        newProfile.id = UUID()
        newProfile.name = name.isEmpty ? "Fighter \(profiles.count + 1)" : name
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

    // MARK: - Workout Lifecycle
    func startWorkout() {
        let start = Date()
        workoutStartDate = start
        lastSampleDate = start
        activeSamples.removeAll()
        interRoundDrops.removeAll()
        roundPeakBPM = 0
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
        roundSecondsRemaining = selectedRoundPreset.workSeconds
        isWorkoutActive = true

        if selectedRoundPreset != .open {
            triggerRoundBell()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickSecond()
            }
        }
    }

    private func tickSecond() {
        guard let start = workoutStartDate else { return }
        elapsedSeconds = Date().timeIntervalSince(start)

        guard selectedRoundPreset != .open else { return }
        if roundSecondsRemaining > 1 {
            roundSecondsRemaining -= 1
        } else {
            // Transition between Work and Rest
            if !isRoundRest {
                // Entering rest: record peak HR of that round
                roundPeakBPM = activeSamples.last?.bpm ?? maxBPM
                isRoundRest = true
                roundSecondsRemaining = selectedRoundPreset.restSeconds
                triggerRoundBell()
            } else {
                // Rest ended: measure how much HR dropped on the stool
                if let endRestBPM = activeSamples.last?.bpm, roundPeakBPM > endRestBPM {
                    interRoundDrops.append(roundPeakBPM - endRestBPM)
                }
                currentRound += 1
                isRoundRest = false
                roundSecondsRemaining = selectedRoundPreset.workSeconds
                triggerRoundBell()
            }
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

        let elapsed = timestamp.timeIntervalSince(start)
        activeSamples.append(HeartRatePoint(timestamp: timestamp, elapsedSeconds: elapsed, bpm: bpm, rrIntervalMs: rrMs))

        maxBPM = max(maxBPM, bpm)
        minBPM = (minBPM == 0) ? bpm : min(minBPM, bpm)
        let sum = activeSamples.reduce(0) { $0 + $1.bpm }
        averageBPM = sum / activeSamples.count

        let profile = activeProfile
        let zoneInfo = profile.zone(for: bpm)

        if let previous = lastSampleDate {
            let dt = min(timestamp.timeIntervalSince(previous), 10.0)
            if dt > 0 {
                activeZoneSeconds[zoneInfo.number, default: 0] += dt

                // Keytel et al. (2005) gender-specific physiological calorie expenditure
                let baseKcalPerMin: Double
                if profile.sex == .male {
                    baseKcalPerMin = (-55.0969 + (0.6309 * Double(bpm)) + (0.1988 * profile.weightKg) + (0.2017 * Double(profile.age))) / 4.184
                } else {
                    baseKcalPerMin = (-20.4022 + (0.4472 * Double(bpm)) - (0.1263 * profile.weightKg) + (0.074 * Double(profile.age))) / 4.184
                }

                let clampedBase = max(1.0, baseKcalPerMin) * (dt / 60.0)

                // EPOC (Afterburn) multiplier for anaerobic glycolytic zones
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
    }

    /// Starts the 60-second Heart Rate Recovery cooldown window before finalizing
    func initiateFinishAndMeasureHRR(currentBPM: Int) {
        timer?.invalidate()
        timer = nil
        isWorkoutActive = false

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

        // Banister TRIMP score
        let durationMinutes = duration / 60.0
        let hrrFraction = max(0.0, min(1.2, Double(averageBPM - profile.restingHR) / Double(max(30, profile.effectiveMaxHR - profile.restingHR))))
        let genderFactor = (profile.sex == .male) ? 1.92 : 1.67
        let trimp = durationMinutes * hrrFraction * 0.64 * exp(genderFactor * hrrFraction)

        // Session RMSSD from captured RR intervals
        let rrList = activeSamples.compactMap { $0.rrIntervalMs }
        let sessionRMSSD = BLEHeartRateManager.computeRMSSD(from: rrList)

        // Cardiac drift (1st half avg HR vs 2nd half avg HR)
        let drift = computeCardiacDrift(samples: activeSamples)

        // Average between-round recovery drop
        let avgRoundDrop = interRoundDrops.isEmpty ? nil : (interRoundDrops.reduce(0, +) / interRoundDrops.count)

        // Detect Points of Interest on the HR curve
        let pois = detectPointsOfInterest(samples: activeSamples, hrr60: hrr60)

        let workout = SavedWorkout(
            id: UUID(),
            athleteID: profile.id,
            category: selectedCategory,
            roundPreset: selectedRoundPreset,
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
            samples: activeSamples,
            pointsOfInterest: pois
        )

        savedWorkouts.insert(workout, at: 0)
        persistWorkouts()
        statusMessage = "Saved \(selectedCategory.rawValue) • \(Int(estimatedCalories)) kcal • TRIMP \(Int(trimp))"
        workoutStartDate = nil
    }

    func deleteWorkout(_ workout: SavedWorkout) {
        savedWorkouts.removeAll { $0.id == workout.id }
        persistWorkouts()
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

        // 1. Peak Heart Rate
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

        // 2. Biggest 30-second Anaerobic Surge (e.g., combo flurry / sprint)
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

        // 3. Fastest 60-second Recovery Drop during session
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

        // 4. Post-Workout HRR-60
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

    // MARK: - Fighter Readiness & Coach Diagnostics Engine
    func computeFighterAnalytics() -> FighterAnalytics {
        let profile = activeProfile
        let workouts = activeProfileWorkouts
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recent7d = workouts.filter { $0.startDate >= sevenDaysAgo }

        let weeklyTRIMP = recent7d.reduce(0.0) { $0 + $1.trimpScore }

        // Time in zones across recent sessions
        var z12Seconds = 0.0
        var z3Seconds = 0.0
        var z45Seconds = 0.0
        for w in recent7d {
            z12Seconds += (w.zoneSeconds[1, default: 0] + w.zoneSeconds[2, default: 0])
            z3Seconds += w.zoneSeconds[3, default: 0]
            z45Seconds += (w.zoneSeconds[4, default: 0] + w.zoneSeconds[5, default: 0])
        }
        let totalZSeconds = max(1.0, z12Seconds + z3Seconds + z45Seconds)

        // Aerobic Score (low cardiac drift + Zone 2 base volume)
        let steadyWorkouts = recent7d.filter { !$0.category.isAnaerobicFocus && $0.duration >= 900 }
        let avgDrift = steadyWorkouts.isEmpty ? 3.5 : (steadyWorkouts.map { abs($0.cardiacDriftPercent) }.reduce(0, +) / Double(steadyWorkouts.count))
        let driftComponent = max(35.0, min(100.0, 100.0 - (avgDrift * 6.0)))
        let z2Minutes = z12Seconds / 60.0
        let baseVolumeBonus = min(20.0, z2Minutes / 6.0)
        let aerobicScore = Int(min(99, max(40, driftComponent * 0.8 + baseVolumeBonus)))

        // Anaerobic Score (Zone 4/5 output + peak HR capability)
        let z45Minutes = z45Seconds / 60.0
        let anaerobicWorkouts = recent7d.filter { $0.category.isAnaerobicFocus }
        let peakRatio = anaerobicWorkouts.isEmpty ? 0.88 : (Double(anaerobicWorkouts.map { $0.maxBPM }.max() ?? 175) / Double(profile.effectiveMaxHR))
        let anaerobicScore = Int(min(99, max(40, (peakRatio * 75.0) + min(24.0, z45Minutes * 0.8))))

        // Recovery Score (HRR-60 + HRV RMSSD)
        let latestHRR = workouts.compactMap { $0.hrr60Drop }.first
        let latestHRV = latestMorningRMSSD ?? workouts.compactMap { $0.rmssdMs }.first

        var recoveryRaw = 72.0
        if let hrr = latestHRR {
            // 12 BPM -> 50, 25 BPM -> 82, 35+ BPM -> 98
            recoveryRaw = min(99.0, max(35.0, 30.0 + Double(hrr) * 2.0))
        }
        if let hrv = latestHRV {
            let hrvRatio = hrv / max(20.0, profile.baselineRMSSD)
            let hrvScore = min(100.0, max(30.0, hrvRatio * 80.0))
            recoveryRaw = (recoveryRaw * 0.55) + (hrvScore * 0.45)
        }
        let recoveryScore = Int(round(recoveryRaw))

        let staminaRating = Int(round(Double(aerobicScore) * 0.35 + Double(anaerobicScore) * 0.40 + Double(recoveryScore) * 0.25))

        // Sleep & Recovery Hours Prescription
        let lastSession = workouts.first
        let lastTRIMP = lastSession?.trimpScore ?? 0
        var recHours = 12
        if lastTRIMP > 140 { recHours = 36 }
        else if lastTRIMP > 90 { recHours = 24 }
        else if lastTRIMP > 45 { recHours = 16 }

        if let hrv = latestHRV, hrv < profile.baselineRMSSD * 0.82 {
            recHours += 8
        }
        if let hrr = latestHRR, hrr < 15 {
            recHours += 6
        }

        var sleepHours = 7.5
        if z45Minutes > 25 || lastTRIMP > 100 { sleepHours += 0.75 }
        if let hrv = latestHRV, hrv < profile.baselineRMSSD * 0.85 { sleepHours += 0.75 }
        if profile.campPhase == .fightCut { sleepHours += 0.5 }
        sleepHours = min(9.5, sleepHours)

        // Generate Tailored Fight Coach Prescriptions
        var prescriptions: [CoachPrescription] = []

        if workouts.isEmpty {
            prescriptions.append(CoachPrescription(
                title: "Establish Your Fighter Baseline",
                tag: "ONBOARDING",
                tagColor: .blue,
                diagnosis: "No workouts logged yet for \(profile.name).",
                actionPlan: "Log 1 Kickboxing/Bag session (with 60s HRR cooldown) and 1 steady 30-min run so the engine can measure your aerobic drift and anaerobic gas-tank.",
                icon: "figure.kickboxing"
            ))
        } else {
            // Check 1: Anaerobic Gas-Out (High peak HR early, poor HRR < 18 or low inter-round drop)
            let poorRoundRecovery = (lastSession?.avgInterRoundDrop ?? 20) < 14
            if (latestHRR ?? 22) < 18 || poorRoundRecovery || anaerobicScore < 68 {
                prescriptions.append(CoachPrescription(
                    title: "Upgrade Anaerobic Gas Tank (Norwegian 4x4s)",
                    tag: "VO2 MAX & STOOL RECOVERY",
                    tagColor: .red,
                    diagnosis: "Your heart rate stays elevated too long after high-intensity bursts (\(latestHRR != nil ? "HRR-60: -\(latestHRR!) BPM" : "slow inter-round drop")), causing late-round fatigue.",
                    actionPlan: "Run 1–2x/week Norwegian 4x4 intervals: 4 min at 90–95% HRmax (\(profile.activeZones.z4Max)–\(profile.effectiveMaxHR) BPM) + 3 min active walk/jog, or 3-min heavy bag power rounds with strict nasal breathing during the 1-min rest.",
                    icon: "bolt.heart.fill"
                ))
            }

            // Check 2: Weak Aerobic Base (Cardiac drift > 5% or < 45 mins Zone 2/week)
            if avgDrift > 5.0 || z2Minutes < 45 {
                prescriptions.append(CoachPrescription(
                    title: "Build Aerobic Engine (Zone 2 LSD Runs)",
                    tag: "AEROBIC BASE",
                    tagColor: .green,
                    diagnosis: avgDrift > 5.0
                        ? String(format: "Cardiac drift is %.1f%%—your heart rate climbs steadily at constant pace, limiting 3-to-5 round stamina.", avgDrift)
                        : "Low weekly Zone 2 volume (\(Int(z2Minutes)) min). A bigger aerobic base clears lactate faster between kickboxing exchanges.",
                    actionPlan: "Add two 45–60 min Long Slow Distance runs or incline walks locked strictly in Zone 2 (\(profile.activeZones.z1Max + 1)–\(profile.activeZones.z2Max) BPM). Do not drift into Zone 3.",
                    icon: "lungs.fill"
                ))
            }

            // Check 3: Gray Zone Trap (> 45% of training in Zone 3)
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

            // Check 4: CNS / Autonomic Fatigue or Fight Cut Protection
            if recoveryScore < 62 || profile.campPhase == .fightCut {
                prescriptions.append(CoachPrescription(
                    title: profile.campPhase == .fightCut ? "Fight Cut Glycogen & CNS Protocol" : "Autonomic Deload & Sleep Priority",
                    tag: "RECOVERY",
                    tagColor: .purple,
                    diagnosis: profile.campPhase == .fightCut
                        ? "Cutting \(String(format: "%.1f", max(0, profile.weightDeltaKg))) kg toward \(String(format: "%.1f", profile.targetFightWeightKg)) kg increases cortisol and slows HR recovery."
                        : "Suppressed recovery score (\(recoveryScore)/100) indicates accumulated sympathetic nervous system load.",
                    actionPlan: "Target \(String(format: "%.1f", sleepHours))h sleep tonight, ingest 30–40g fast carbs 30 min pre-sparring, and keep today's session technical (shadowboxing/mobility below \(profile.activeZones.z2Max) BPM).",
                    icon: "bed.double.fill"
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
            trendLabel: trendLabel,
            prescriptions: prescriptions
        )
    }

    // MARK: - TCX Export
    func exportTCXFile(for workout: SavedWorkout) -> URL {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startString = iso.string(from: workout.startDate)

        var trackpointsXML = ""
        for point in workout.samples {
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
              <Notes>\(workout.category.rawValue) (\(activeProfile.name)) logged via CoospoTracker</Notes>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let fileName = "Coospo_\(workout.category.rawValue.replacingOccurrences(of: " ", with: "_"))_\(Int(workout.startDate.timeIntervalSince1970)).tcx"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? tcx.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    // MARK: - Persistence
    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: profilesURL, options: .atomic)
        }
        UserDefaults.standard.set(activeProfileID.uuidString, forKey: "ActiveAthleteProfileID")
    }

    private func loadProfiles() {
        if let data = try? Data(contentsOf: profilesURL),
           let decoded = try? JSONDecoder().decode([AthleteProfile].self, from: data),
           !decoded.isEmpty {
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

    private func persistWorkouts() {
        if let data = try? JSONEncoder().encode(savedWorkouts) {
            try? data.write(to: workoutsURL, options: .atomic)
        }
    }

    private func loadWorkouts() {
        guard let data = try? Data(contentsOf: workoutsURL),
              let decoded = try? JSONDecoder().decode([SavedWorkout].self, from: data) else { return }
        savedWorkouts = decoded
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}