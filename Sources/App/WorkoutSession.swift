import Foundation
import SwiftUI
import UIKit
import ActivityKit

// MARK: - Draft (autosave / crash recovery)

/// Everything needed to rebuild a workout if the app is killed mid-session.
struct WorkoutDraft: Codable {
    var id: UUID
    var profileID: UUID
    var startTime: Date
    var lastUpdate: Date
    var elapsedSeconds: TimeInterval
    var category: WorkoutCategory
    var drillTag: DrillTag
    var notes: String
    var samples: [HeartRatePoint]
    var zoneSeconds: [Int: TimeInterval]
    var activeCalories: Double
    var bmrCalories: Double
    var rounds: [RoundStat]
    var autoHRREvents: [AutoHRREvent]
    var strikesCued: Int
    var ghostTitle: String?
    var planTitle: String?
    var planTargetLow: Int?
    var planTargetHigh: Int?
}

enum WorkoutFinalizer {
    /// Turns raw session data into a fully analysed SavedWorkout.
    static func makeWorkout(from d: WorkoutDraft, profile: AthleteProfile, ghost: GhostSession?, end: Date) -> SavedWorkout {
        let bpms = d.samples.map(\.bpm)
        let avg = bpms.isEmpty ? 0 : bpms.reduce(0, +) / bpms.count
        let maxB = bpms.max() ?? avg
        let minB = bpms.min() ?? avg

        var ghostDelta: Double?
        if let ghost, !d.samples.isEmpty {
            let deltas = d.samples.compactMap { pt -> Double? in
                ghost.interpolatedBPM(at: pt.elapsedSeconds).map { Double(pt.bpm - $0) }
            }
            if !deltas.isEmpty { ghostDelta = deltas.reduce(0, +) / Double(deltas.count) }
        }

        var adherence: Double?
        if let lo = d.planTargetLow, let hi = d.planTargetHigh, !d.samples.isEmpty {
            let inBand = d.samples.filter { $0.bpm >= lo && $0.bpm <= hi }.count
            adherence = Double(inBand) / Double(d.samples.count)
        }

        return SavedWorkout(
            id: d.id,
            profileID: d.profileID,
            profileName: profile.name,
            category: d.category,
            drillTag: d.drillTag,
            rpe: 5,
            notes: d.notes.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: d.startTime,
            endDate: end,
            duration: d.elapsedSeconds,
            averageBPM: avg,
            maxBPM: maxB,
            minBPM: minB,
            activeCalories: d.activeCalories,
            bmrCalories: d.bmrCalories,
            calories: d.activeCalories + d.bmrCalories,
            epocBonusCalories: FighterAnalytics.calculateEPOC(zoneSeconds: d.zoneSeconds, weightKg: profile.weightKg),
            trimpScore: FighterAnalytics.calculateTRIMP(samples: d.samples, profile: profile),
            cardiacDriftPercent: FighterAnalytics.calculateCardiacDrift(samples: d.samples),
            hrr60Drop: d.autoHRREvents.map(\.dropBPM).max(),
            autoHRREvents: d.autoHRREvents,
            rmssdMs: FighterAnalytics.calculateRMSSD(samples: d.samples),
            strikesCuedCount: d.strikesCued,
            ghostBaselineName: d.ghostTitle,
            ghostAvgDeltaBPM: ghostDelta,
            zoneSeconds: d.zoneSeconds,
            roundStats: d.rounds,
            pointsOfInterest: FighterAnalytics.detectPointsOfInterest(
                samples: d.samples, roundStats: d.rounds, autoHRREvents: d.autoHRREvents, profile: profile
            ),
            samples: d.samples,
            isCompressedArchive: false,
            archiveFileName: nil,
            rpeRated: false,
            planTitle: d.planTitle,
            planTargetLow: d.planTargetLow,
            planTargetHigh: d.planTargetHigh,
            planAdherence: adherence
        )
    }
}

// MARK: - Session

/// Owns a live workout: timing, rounds, bag coach, coaching cues, autosave and
/// saving. Lives for the whole app session, so switching tabs never disturbs it.
@MainActor
final class WorkoutSession: ObservableObject {
    let audio = AudioCoachEngine()

    private var ble: BLEHeartRateManager?
    private var store: WorkoutStore?
    private var health: HealthKitManager?

    // MARK: Setup state
    @Published var selectedCategory: WorkoutCategory = .muayThai {
        didSet {
            guard oldValue != selectedCategory, !suppressDefaults else { return }
            applyDisciplineDefaults(selectedCategory)
        }
    }
    @Published var selectedDrillTag: DrillTag = .technical
    @Published var workoutNotes: String = ""
    @Published var roundTimerEnabled = true
    @Published var workDurationSeconds = 180
    @Published var restDurationSeconds = 60
    @Published var bagEnabled = false {
        didSet {
            guard oldValue != bagEnabled else { return }
            bagEnabledChanged()
        }
    }
    @Published var bagPrefs = BagPreferences() {
        didSet {
            guard oldValue != bagPrefs, !loadingPrefs else { return }
            bagPrefsChanged(old: oldValue)
        }
    }
    @Published var selectedGhost: GhostSession?
    @Published var activePlan: WorkoutPrescription?

    // MARK: Live state
    @Published private(set) var isRecording = false
    @Published private(set) var startTime: Date?
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var samples: [HeartRatePoint] = []
    @Published private(set) var zoneSeconds: [Int: TimeInterval] = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
    @Published private(set) var activeCalories: Double = 0
    @Published private(set) var bmrCalories: Double = 0
    @Published private(set) var currentRound = 1
    @Published private(set) var isRestPeriod = false
    @Published private(set) var phaseElapsed: TimeInterval = 0
    @Published private(set) var completedRounds: [RoundStat] = []
    @Published private(set) var autoHRREvents: [AutoHRREvent] = []
    @Published private(set) var latestAutoHRRBanner: String?
    @Published var lthrTestResultBanner: Int?
    @Published private(set) var liveAlpha1: Double?
    @Published private(set) var pendingRecoveryRemaining: Int?
    @Published private(set) var bagSessionComplete = false

    // MARK: Flow state
    @Published var finishedWorkout: SavedWorkout?
    @Published var showingSummary = false
    @Published var requestFinishPrompt = false
    @Published var recoverableDraft: WorkoutDraft?

    // MARK: Private bookkeeping
    private var draftID = UUID()
    private var timer: Timer?
    private var lastTick: Date?
    private var lastDraftSave = Date.distantPast
    private var suppressDefaults = false
    private var loadingPrefs = false

    private var sumBPM = 0
    private var maxBPMSeen = 0

    private var currentRoundStartElapsed: TimeInterval = 0
    private var currentWorkEndElapsed: TimeInterval = 0
    private var currentRoundStartStrikes = 0
    private var roundEndPeakBPM = 0

    private struct PendingRecovery {
        let startElapsed: TimeInterval
        let peakBPM: Int
        let contextLabel: String
        var lowestSeenBPM: Int
    }
    private var pendingRecovery: PendingRecovery?

    private var lastAnnouncedZone = 0
    private var lastZone2AlertTime: TimeInterval = -999
    private var lastPeriodicMinute = 0
    private var redlineSecondsAccumulator: TimeInterval = 0
    private var lastRedlineAlertTime: TimeInterval = -999
    private var lastGhostAlertTime: TimeInterval = -999
    private var lastPlanAlertTime: TimeInterval = -999
    private var lthrWarmupAnnounced = false
    private var finalRoundAnnounced = false

    private var currentActivity: Activity<WorkoutActivityAttributes>?
    private var lastActivityPush = Date.distantPast
    private var lastActivityState: (bpm: Int, zone: Int, round: Int, rest: Bool)?

    // MARK: Wiring

    func bind(ble: BLEHeartRateManager, store: WorkoutStore, health: HealthKitManager) {
        let firstBind = self.store == nil
        self.ble = ble
        self.store = store
        self.health = health
        if firstBind {
            syncFromProfile()
            recoverableDraft = loadDraft()
        }
    }

    /// Reloads per-fighter bag preferences (call when the active profile changes).
    func syncFromProfile() {
        guard !isRecording, let store else { return }
        loadingPrefs = true
        bagPrefs = store.activeProfile.bagPreferences
        loadingPrefs = false
    }

    private var profile: AthleteProfile { store?.activeProfile ?? AthleteProfile() }
    private var currentBPM: Int { ble?.currentBPM ?? 0 }

    var liveAverageBPM: Int { samples.isEmpty ? currentBPM : sumBPM / samples.count }
    var liveMaxBPM: Int { samples.isEmpty ? currentBPM : maxBPMSeen }
    var currentPhaseTarget: TimeInterval { TimeInterval(isRestPeriod ? restDurationSeconds : workDurationSeconds) }
    var phaseRemaining: TimeInterval { max(0, currentPhaseTarget - phaseElapsed) }
    var totalBagRounds: Int { bagPrefs.estimatedTotalRounds }

    // MARK: Setup changes

    private func applyDisciplineDefaults(_ category: WorkoutCategory) {
        roundTimerEnabled = category.usesRoundTimerByDefault
        workDurationSeconds = category.defaultWorkSeconds
        restDurationSeconds = category.defaultRestSeconds
        switch category {
        case .lthrTest:
            selectedDrillTag = .lthrProtocol
            bagEnabled = false
        case .walk, .roadwork:
            selectedDrillTag = .aerobicZ2
            bagEnabled = false
        case .heavyBag:
            selectedDrillTag = .bagWork
        case .sparring:
            selectedDrillTag = .hardSparring
        default:
            break
        }
    }

    private func bagEnabledChanged() {
        if bagEnabled {
            roundTimerEnabled = true
            workDurationSeconds = bagPrefs.workSeconds
            restDurationSeconds = bagPrefs.restSeconds
            if isRecording {
                startBagCoach()
            } else if bagPrefs.mode != .cadenceBeep {
                let prefs = bagPrefs
                Task { await audio.prepareVocabulary(prefs: prefs) }
            }
        } else {
            audio.stopBagCoach()
        }
    }

    private func bagPrefsChanged(old: BagPreferences) {
        if let store {
            var p = store.activeProfile
            p.bagPreferences = bagPrefs
            store.activeProfile = p
        }
        if bagEnabled && !isRecording {
            workDurationSeconds = bagPrefs.workSeconds
            restDurationSeconds = bagPrefs.restSeconds
        }
        let voiceChanged = old.stance != bagPrefs.stance || old.numberCalls != bagPrefs.numberCalls || old.tempo != bagPrefs.tempo
        if voiceChanged && bagEnabled && bagPrefs.mode != .cadenceBeep && !isRecording {
            let prefs = bagPrefs
            Task { await audio.prepareVocabulary(prefs: prefs) }
        }
        if isRecording && bagEnabled {
            startBagCoach()
        }
    }

    func apply(_ p: WorkoutPrescription) {
        guard !isRecording else { return }
        suppressDefaults = true
        selectedCategory = p.category
        suppressDefaults = false
        selectedDrillTag = p.drillTag
        var prefs = bagPrefs
        prefs.workSeconds = p.workSeconds
        prefs.restSeconds = p.restSeconds
        prefs.tempo = p.bagTempo
        let totals = [10, 15, 20, 30, 45, 60]
        prefs.totalMinutes = totals.min(by: { abs($0 - p.durationMinutes) < abs($1 - p.durationMinutes) }) ?? 30
        bagPrefs = prefs
        let noBag: [WorkoutCategory] = [.walk, .roadwork, .lthrTest]
        bagEnabled = p.useBagCoach && !noBag.contains(p.category)
        roundTimerEnabled = p.roundTimer
        workDurationSeconds = p.workSeconds
        restDurationSeconds = p.restSeconds
        activePlan = p
    }

    // MARK: Start / stop

    func startWorkout() {
        guard !isRecording else { return }
        draftID = UUID()
        samples.removeAll()
        zoneSeconds = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
        activeCalories = 0
        bmrCalories = 0
        elapsedSeconds = 0
        sumBPM = 0
        maxBPMSeen = 0
        currentRound = 1
        isRestPeriod = false
        phaseElapsed = 0
        currentRoundStartElapsed = 0
        currentWorkEndElapsed = 0
        currentRoundStartStrikes = 0
        roundEndPeakBPM = 0
        completedRounds.removeAll()
        pendingRecovery = nil
        pendingRecoveryRemaining = nil
        autoHRREvents.removeAll()
        latestAutoHRRBanner = nil
        lthrTestResultBanner = nil
        lastAnnouncedZone = 0
        lastZone2AlertTime = -999
        lastPeriodicMinute = 0
        redlineSecondsAccumulator = 0
        lastRedlineAlertTime = -999
        lastGhostAlertTime = -999
        lastPlanAlertTime = -999
        lthrWarmupAnnounced = false
        finalRoundAnnounced = false
        bagSessionComplete = false
        requestFinishPrompt = false
        liveAlpha1 = nil
        audio.strikesCuedCount = 0
        _ = ble?.consumeLatestRRIntervals()

        let now = Date()
        startTime = now
        lastTick = now
        lastDraftSave = now
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true

        audio.prepareForWorkout(settings: profile.audioCoach)
        if roundTimerEnabled || bagEnabled {
            audio.playRoundStartBell()
        }
        if bagEnabled {
            if totalBagRounds == 1 { announceFinalRound() }
            startBagCoach()
        }
        startLiveActivity()

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        saveDraft()
    }

    private func startBagCoach() {
        let context = BagLoopContext(
            isWorkPhase: { [weak self] in
                guard let self else { return false }
                return self.isRecording && !self.bagSessionComplete && (!self.roundTimerEnabled || !self.isRestPeriod)
            },
            roundProgress: { [weak self] in
                guard let self, self.roundTimerEnabled, self.workDurationSeconds > 0 else { return 0.5 }
                return min(1, self.livePhaseElapsed / Double(self.workDurationSeconds))
            },
            workRemaining: { [weak self] in
                guard let self, self.roundTimerEnabled, !self.isRestPeriod else { return nil }
                return Double(self.workDurationSeconds) - self.livePhaseElapsed
            },
            hrBandStatus: { [weak self] in
                guard let self, let plan = self.activePlan else { return 0 }
                let bpm = self.currentBPM
                if bpm <= 0 { return 0 }
                if bpm < plan.targetLowBPM { return -1 }
                if bpm > plan.targetHighBPM { return 1 }
                return 0
            }
        )
        audio.startBagCoach(prefs: bagPrefs, context: context)
    }

    /// Phase time including the fraction since the last 1-s tick (smooth countdowns).
    private var livePhaseElapsed: TimeInterval {
        phaseElapsed + (lastTick.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func stopRecordingCommon() {
        timer?.invalidate()
        timer = nil
        lastTick = nil
        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        audio.shutdownAudio()
        endLiveActivity()
    }

    func finishAndSave() {
        guard isRecording, let store else { return }
        let end = Date()
        let draft = makeDraft(now: end)
        stopRecordingCommon()

        let current = store.activeProfile
        if selectedCategory == .lthrTest {
            let trial = samples.filter { $0.elapsedSeconds >= 600 }
            let source = trial.count >= 30 ? trial : samples
            if !source.isEmpty {
                var updated = current
                updated.lactateThresholdHR = source.map(\.bpm).reduce(0, +) / source.count
                updated.zoneMethod = .lactateThreshold
                updated.sanitize()
                store.activeProfile = updated
                lthrTestResultBanner = updated.lactateThresholdHR
            }
        }

        let saved = WorkoutFinalizer.makeWorkout(from: draft, profile: current, ghost: selectedGhost, end: end)
        store.save(saved)
        deleteDraft()

        if let health, health.autoSaveEnabled {
            let sensor = ble?.sensorInfo
            let hkSamples = saved.samples
            Task { await health.save(workout: saved, samples: hkSamples, sensor: sensor) }
        }

        finishedWorkout = saved
        workoutNotes = ""
        activePlan = nil
        showingSummary = true
    }

    func discard() {
        guard isRecording else { return }
        stopRecordingCommon()
        deleteDraft()
        samples.removeAll()
        completedRounds.removeAll()
        elapsedSeconds = 0
        liveAlpha1 = nil
    }

    // MARK: Tick

    private func tick() {
        guard isRecording, let start = startTime else { return }
        let now = Date()
        // Real time since the previous tick. Timers can be late or skipped (e.g.
        // phone locked), so the round clock follows wall time, while HR-based
        // accounting only credits up to 5 s per tick (no data = no credit).
        let dt = max(0, now.timeIntervalSince(lastTick ?? now))
        let creditedDT = min(dt, 5)
        lastTick = now
        elapsedSeconds = now.timeIntervalSince(start)

        let bpm = currentBPM
        let p = profile
        let coachCfg = p.audioCoach

        let cal = FighterAnalytics.calculateCalorieBreakdown(bpm: bpm, durationSeconds: creditedDT, profile: p)
        activeCalories += cal.active
        bmrCalories += cal.bmr

        if bpm > 0 {
            let rr = ble?.consumeLatestRRIntervals() ?? []
            samples.append(HeartRatePoint(timestamp: now, elapsedSeconds: elapsedSeconds, bpm: bpm, rrIntervalsMs: rr))
            sumBPM += bpm
            maxBPMSeen = max(maxBPMSeen, bpm)
            let z = p.zone(for: bpm)
            zoneSeconds[z.number, default: 0] += creditedDT
            if roundTimerEnabled && !isRestPeriod {
                roundEndPeakBPM = max(roundEndPeakBPM, bpm)
            }
            evaluateAutomaticHRR(bpm: bpm, profile: p)
            evaluateLiveAudioCoaching(bpm: bpm, zone: z, profile: p, coachCfg: coachCfg)
            evaluatePlan(bpm: bpm, coachCfg: coachCfg)
            if Int(elapsedSeconds) % 10 == 0 && samples.count >= 60 {
                liveAlpha1 = HRVMath.liveAlpha1(recentSamples: Array(samples.suffix(150)))
            }
        }

        if roundTimerEnabled && !bagSessionComplete {
            advanceRoundClock(by: dt, bpm: bpm, coachCfg: coachCfg)
        }

        if selectedCategory == .lthrTest {
            if !lthrWarmupAnnounced && elapsedSeconds >= 600 {
                lthrWarmupAnnounced = true
                audio.playRoundStartBell()
                audio.announceCoachingCue("Warm up complete. Begin your 20 minute threshold effort now!", enabled: true)
            } else if elapsedSeconds >= 1800 {
                finishAndSave()
                return
            }
        }

        updateLiveActivity()
        if now.timeIntervalSince(lastDraftSave) >= 30 {
            saveDraft()
        }
    }

    private func advanceRoundClock(by dt: TimeInterval, bpm: Int, coachCfg: AudioCoachSettings) {
        let before = currentPhaseTarget - phaseElapsed
        phaseElapsed += dt
        let after = currentPhaseTarget - phaseElapsed
        let warningsOn = coachCfg.masterEnabled

        if !isRestPeriod {
            if before > 30 && after <= 30 && warningsOn && coachCfg.announceRoundWarnings && workDurationSeconds >= 90 {
                audio.announceCoachingCue("30 seconds, heart rate \(bpm)", enabled: true)
            }
            if before > 10 && after <= 10 {
                if coachCfg.clapperWarnings { audio.playClapper() }
            }
        } else if before > 10 && after <= 10 {
            if coachCfg.clapperWarnings { audio.playClapper() }
            if warningsOn && coachCfg.announceRoundWarnings {
                audio.announceCoachingCue("Round \(currentRound + 1) in 10 seconds", enabled: true)
            }
        }

        var guardCount = 0
        while phaseElapsed >= currentPhaseTarget && guardCount < 20 && !bagSessionComplete {
            guardCount += 1
            phaseElapsed -= currentPhaseTarget
            if isRestPeriod {
                beginNextRound(bpm: bpm, coachCfg: coachCfg)
            } else {
                endWorkPhase(bpm: bpm)
            }
        }
    }

    /// Ends the current work phase (bell or "End Round" button).
    func endWorkPhase(bpm: Int? = nil, manual: Bool = false) {
        guard isRecording, !isRestPeriod else { return }
        let hr = bpm ?? currentBPM
        if manual { phaseElapsed = 0 }
        currentWorkEndElapsed = elapsedSeconds
        audio.flushCombos()
        audio.playRoundEndBell()

        let isFinalBagRound = bagEnabled && currentRound >= totalBagRounds
        if isFinalBagRound {
            recordRound(stoolDrop: nil)
            bagSessionComplete = true
            audio.stopBagCoach()
            audio.announceCoachingCue("Session complete. Great work.", enabled: true)
            requestFinishPrompt = true
            return
        }

        isRestPeriod = true
        let peak = max(roundEndPeakBPM, hr)
        if peak > 90 {
            pendingRecovery = PendingRecovery(startElapsed: elapsedSeconds, peakBPM: peak,
                                              contextLabel: "Round \(currentRound) Stool Rest", lowestSeenBPM: peak)
        }
        saveDraft()
    }

    private func beginNextRound(bpm: Int, coachCfg: AudioCoachSettings) {
        let drop: Int? = (roundEndPeakBPM > 0 && bpm > 0) ? max(0, roundEndPeakBPM - bpm) : nil
        recordRound(stoolDrop: drop)
        if let drop, coachCfg.masterEnabled && coachCfg.announceStoolRecovery {
            audio.announceCoachingCue("Recovered \(drop) beats.", enabled: true)
        }
        currentRound += 1
        isRestPeriod = false
        currentRoundStartElapsed = elapsedSeconds
        currentRoundStartStrikes = audio.strikesCuedCount
        roundEndPeakBPM = 0
        audio.playRoundStartBell()
        if bagEnabled && currentRound == totalBagRounds {
            announceFinalRound()
        }
    }

    private func announceFinalRound() {
        guard !finalRoundAnnounced else { return }
        finalRoundAnnounced = true
        audio.announceCoachingCue("Final round! Empty the tank.", enabled: true)
    }

    private func recordRound(stoolDrop: Int?) {
        let workEnd = currentWorkEndElapsed > currentRoundStartElapsed ? currentWorkEndElapsed : elapsedSeconds
        let roundSamples = samples.filter { $0.elapsedSeconds >= currentRoundStartElapsed && $0.elapsedSeconds <= workEnd }
        let avg = roundSamples.isEmpty ? currentBPM : roundSamples.map(\.bpm).reduce(0, +) / roundSamples.count
        let peak = roundSamples.map(\.bpm).max() ?? roundEndPeakBPM
        completedRounds.append(RoundStat(
            roundNumber: currentRound,
            startElapsed: currentRoundStartElapsed,
            endElapsed: workEnd,
            avgBPM: avg,
            peakBPM: peak,
            stoolDropBPM: stoolDrop,
            strikesCued: max(0, audio.strikesCuedCount - currentRoundStartStrikes)
        ))
    }

    // MARK: Live analysis

    private func evaluateAutomaticHRR(bpm: Int, profile: AthleteProfile) {
        let highEffort = Int(Double(profile.effectiveMaxHR) * 0.80)
        if var tracker = pendingRecovery {
            tracker.lowestSeenBPM = min(tracker.lowestSeenBPM, bpm)
            if !isRestPeriod && bpm > tracker.peakBPM + 3 {
                pendingRecovery = nil
                pendingRecoveryRemaining = nil
                return
            }
            pendingRecovery = tracker
            let since = elapsedSeconds - tracker.startElapsed
            pendingRecoveryRemaining = max(0, 60 - Int(since))
            if since >= 60 {
                let drop = max(0, tracker.peakBPM - bpm)
                if drop >= 8 {
                    autoHRREvents.append(AutoHRREvent(elapsedSeconds: elapsedSeconds, peakBPM: tracker.peakBPM,
                                                      recovery60BPM: bpm, dropBPM: drop, contextLabel: tracker.contextLabel))
                    latestAutoHRRBanner = "Auto HRR-60: −\(drop) BPM (\(tracker.peakBPM) → \(bpm))"
                }
                pendingRecovery = nil
                pendingRecoveryRemaining = nil
            }
        } else if !roundTimerEnabled && bpm >= highEffort && samples.count >= 12 {
            let recent10 = samples.suffix(10).map(\.bpm)
            if let localPeak = recent10.max(), localPeak >= highEffort && (localPeak - bpm) >= 5 {
                pendingRecovery = PendingRecovery(startElapsed: elapsedSeconds, peakBPM: localPeak,
                                                  contextLabel: "Mid-Session Recovery", lowestSeenBPM: bpm)
            }
        }
    }

    private func evaluateLiveAudioCoaching(bpm: Int, zone: HeartRateZoneInfo, profile: AthleteProfile, coachCfg: AudioCoachSettings) {
        guard coachCfg.masterEnabled else { return }
        // During bag work the combos are the priority: keep cues to essentials.
        let bagActive = bagEnabled && !isRestPeriod

        if coachCfg.zone2CeilingAlert && (selectedCategory == .roadwork || selectedDrillTag == .aerobicZ2) {
            let z2Max = profile.activeZones.z2Max
            if bpm > z2Max && (elapsedSeconds - lastZone2AlertTime) >= 45 {
                lastZone2AlertTime = elapsedSeconds
                audio.announceCoachingCue("Zone 2 ceiling, \(bpm). Ease off.", enabled: true)
            }
        }

        if coachCfg.announceZoneCrossings && zone.number != lastAnnouncedZone && elapsedSeconds > 15 {
            if zone.number >= 3 && !bagActive {
                audio.announceCoachingCue("Zone \(zone.number), \(bpm).", enabled: true)
            }
            lastAnnouncedZone = zone.number
        } else if lastAnnouncedZone == 0 {
            lastAnnouncedZone = zone.number
        }

        let redline = Int(Double(profile.effectiveMaxHR) * 0.92)
        if bpm >= redline {
            redlineSecondsAccumulator += 1
            if coachCfg.announceRedlineWarning && redlineSecondsAccumulator >= 45 && (elapsedSeconds - lastRedlineAlertTime) >= 90 {
                lastRedlineAlertTime = elapsedSeconds
                audio.announceCoachingCue("Sustained redline, \(bpm).", enabled: true)
            }
        } else {
            redlineSecondsAccumulator = 0
        }

        if coachCfg.announceGhostDelta, !bagActive, let ghost = selectedGhost,
           let g = ghost.interpolatedBPM(at: elapsedSeconds), (elapsedSeconds - lastGhostAlertTime) >= 75 {
            let diff = bpm - g
            if abs(diff) >= 8 {
                lastGhostAlertTime = elapsedSeconds
                audio.announceCoachingCue(diff > 0 ? "Ghost check: \(diff) beats above." : "Ghost check: \(abs(diff)) beats more efficient.", enabled: true)
            }
        }

        if coachCfg.periodicMinutes > 0 && !bagActive {
            let minute = Int(elapsedSeconds) / 60
            if minute > 0 && minute != lastPeriodicMinute && minute % coachCfg.periodicMinutes == 0 {
                lastPeriodicMinute = minute
                audio.announceCoachingCue("\(minute) minutes, \(bpm), zone \(zone.number).", enabled: true)
            }
        }
    }

    private func evaluatePlan(bpm: Int, coachCfg: AudioCoachSettings) {
        guard let plan = activePlan, coachCfg.masterEnabled, elapsedSeconds > 90,
              elapsedSeconds - lastPlanAlertTime >= 75,
              bpm > plan.targetHighBPM + 4, !(roundTimerEnabled && isRestPeriod) else { return }
        lastPlanAlertTime = elapsedSeconds
        audio.announceCoachingCue("Above plan target. Ease back under \(plan.targetHighBPM).", enabled: true)
    }

    // MARK: Live Activity (throttled)

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let p = profile
        let attributes = WorkoutActivityAttributes(athleteName: p.name, discipline: selectedCategory.rawValue)
        let state = WorkoutActivityAttributes.ContentState(
            currentBPM: currentBPM, zoneNumber: 1, zoneShortName: "Z1", calories: 0,
            workoutStartDate: Date(), isTimedRound: roundTimerEnabled, roundNumber: 1, isRest: false,
            phaseEndDate: Date().addingTimeInterval(TimeInterval(workDurationSeconds))
        )
        currentActivity = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil), pushType: nil)
        lastActivityPush = Date()
        lastActivityState = nil
    }

    /// Pushes only when something visible changes (zone, round, phase, ±3 BPM) or every 15 s.
    private func updateLiveActivity() {
        guard let activity = currentActivity else { return }
        let bpm = currentBPM
        let z = profile.zone(for: bpm)
        let key = (bpm: bpm, zone: z.number, round: currentRound, rest: isRestPeriod)
        let now = Date()
        if let last = lastActivityState,
           last.zone == key.zone, last.round == key.round, last.rest == key.rest,
           abs(last.bpm - key.bpm) < 3, now.timeIntervalSince(lastActivityPush) < 15 {
            return
        }
        lastActivityState = key
        lastActivityPush = now
        let state = WorkoutActivityAttributes.ContentState(
            currentBPM: bpm, zoneNumber: z.number, zoneShortName: z.shortName, calories: Int(activeCalories),
            workoutStartDate: startTime ?? now, isTimedRound: roundTimerEnabled, roundNumber: currentRound,
            isRest: isRestPeriod, phaseEndDate: now.addingTimeInterval(phaseRemaining)
        )
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    private func endLiveActivity() {
        guard let activity = currentActivity else { return }
        currentActivity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: Draft persistence

    private var draftURL: URL? {
        guard let store else { return nil }
        let dir = store.documentsDirectory.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("active_workout.json")
    }

    private func makeDraft(now: Date) -> WorkoutDraft {
        WorkoutDraft(
            id: draftID, profileID: store?.activeProfileID ?? UUID(), startTime: startTime ?? now, lastUpdate: now,
            elapsedSeconds: elapsedSeconds, category: selectedCategory, drillTag: selectedDrillTag, notes: workoutNotes,
            samples: samples, zoneSeconds: zoneSeconds, activeCalories: activeCalories, bmrCalories: bmrCalories,
            rounds: completedRounds, autoHRREvents: autoHRREvents, strikesCued: audio.strikesCuedCount,
            ghostTitle: selectedGhost?.title, planTitle: activePlan?.title,
            planTargetLow: activePlan?.targetLowBPM, planTargetHigh: activePlan?.targetHighBPM
        )
    }

    private func saveDraft() {
        guard isRecording, let url = draftURL else { return }
        lastDraftSave = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(makeDraft(now: Date())) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadDraft() -> WorkoutDraft? {
        guard let url = draftURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let draft = try? decoder.decode(WorkoutDraft.self, from: data), draft.elapsedSeconds >= 60 else {
            deleteDraft()
            return nil
        }
        return draft
    }

    private func deleteDraft() {
        if let url = draftURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Saves or discards a workout recovered after the app was closed mid-session.
    func resolveRecoveredDraft(save: Bool) {
        guard let draft = recoverableDraft else { return }
        recoverableDraft = nil
        deleteDraft()
        guard save, let store else { return }
        let owner = store.profiles.first { $0.id == draft.profileID } ?? store.activeProfile
        let saved = WorkoutFinalizer.makeWorkout(from: draft, profile: owner, ghost: nil, end: draft.lastUpdate)
        store.save(saved)
        finishedWorkout = saved
        showingSummary = true
    }
}
