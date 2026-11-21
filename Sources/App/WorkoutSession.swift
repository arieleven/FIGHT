import Foundation
import SwiftUI
import UIKit
import ActivityKit

// MARK: - Draft (autosave / crash recovery)

/// Everything needed to rebuild a workout if the app is killed mid-session.
struct WorkoutSetup: Codable, Equatable {
    var category: WorkoutCategory
    var drill: DrillTag
    var roundTimer: Bool
    var workSeconds: Int
    var restSeconds: Int
    var bag: Bool
}

struct WorkoutSetupMemory: Codable {
    var last: WorkoutSetup?
    var byCategory: [String: WorkoutSetup] = [:]
}

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
    var trainingPlanID: UUID?
    var trainingPlanTitle: String?
    var blockResults: [BlockResult]?
    var comboEvents: [ComboEvent]?
    var headMovesPerMinute: Double?
    var breathingGuided: Bool?
    var impactsCount: Int?
}

enum WorkoutFinalizer {
    /// Turns raw session data into a fully analysed SavedWorkout.
    static func makeWorkout(from d: WorkoutDraft, profile: AthleteProfile, ghost: GhostSession?, end: Date) -> SavedWorkout {
        let steadyKinds: [WorkoutCategory] = [.walk, .roadwork, .lthrTest]
        let detected = d.rounds.isEmpty && !steadyKinds.contains(d.category)
            ? AutoRounds.detect(samples: d.samples, profile: profile) : []
        let rounds = d.rounds.isEmpty ? detected : d.rounds
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

        var made = SavedWorkout(
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
            roundStats: rounds,
            pointsOfInterest: FighterAnalytics.detectPointsOfInterest(
                samples: d.samples, roundStats: rounds, autoHRREvents: d.autoHRREvents, profile: profile
            ),
            samples: d.samples,
            isCompressedArchive: false,
            archiveFileName: nil,
            rpeRated: false,
            planTitle: d.planTitle,
            planTargetLow: d.planTargetLow,
            planTargetHigh: d.planTargetHigh,
            planAdherence: adherence,
            trainingPlanID: d.trainingPlanID,
            trainingPlanTitle: d.trainingPlanTitle,
            blockResults: d.blockResults ?? [],
            comboEvents: d.comboEvents ?? [],
            headMovesPerMinute: d.headMovesPerMinute,
            breathingGuided: d.breathingGuided ?? false
        )
        made.roundsAutoDetected = !detected.isEmpty
        if let hits = d.impactsCount { made.impactsCount = hits }
        return made
    }
}

// MARK: - Session

/// Owns a live workout: timing, rounds, bag coach, coaching cues, autosave and
/// saving. Lives for the whole app session, so switching tabs never disturbs it.
@MainActor
final class WorkoutSession: ObservableObject {
    let audio = AudioCoachEngine()
    let headMotion = HeadMotionTracker()

    /// The app's live session, for Siri and Shortcuts.
    static weak var shared: WorkoutSession?

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

    // MARK: Plan runner state
    @Published private(set) var queuedPlan: TrainingPlan?
    @Published private(set) var runningPlan: TrainingPlan?
    @Published private(set) var planBlockIndex = 0
    @Published private(set) var planBlockElapsed: TimeInterval = 0
    @Published private(set) var planTransitionRemaining: TimeInterval?
    @Published private(set) var planComplete = false
    @Published private(set) var blockResults: [BlockResult] = []
    private var blockStartElapsed: TimeInterval = 0
    private var blockStartStrikes = 0
    @Published private(set) var blockExtraRounds = 0
    @Published private(set) var blockExtraSeconds = 0
    private var roundNumberOffset = 0
    static let transitionSeconds: TimeInterval = 15
    static let firstBlockLeadIn: TimeInterval = 8

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

    // Signature-feature capture
    private var comboEvents: [ComboEvent] = []
    private var bestRecoveryRecord = 0
    private var recoveryRecordAnnounced = false
    private var nextBreathCue: TimeInterval?
    private var breathInhaleNext = true
    private var breathingUsed = false
    private var currentRoundStartHeadMoves = 0
    /// Short-lived banner, e.g. "New record: recovery −38 BPM".
    @Published private(set) var liveRecordBanner: String?

    // MARK: Wiring

    func bind(ble: BLEHeartRateManager, store: WorkoutStore, health: HealthKitManager) {
        let firstBind = self.store == nil
        Self.shared = self
        audio.onComboPlayed = { [weak self] combo in self?.logCombo(combo) }
        self.ble = ble
        self.store = store
        self.health = health
        if firstBind {
            syncFromProfile()
            restoreLastSetup()
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

    var isRunningPlan: Bool { runningPlan != nil }
    var isInPlanTransition: Bool { planTransitionRemaining != nil }

    /// The block being run (or, during a transition, the one coming up).
    var currentBlock: PlanBlock? {
        guard let p = runningPlan, planBlockIndex < p.blocks.count else { return nil }
        return p.blocks[planBlockIndex]
    }

    var upcomingBlock: PlanBlock? {
        guard let p = runningPlan else { return nil }
        let i = isInPlanTransition ? planBlockIndex : planBlockIndex + 1
        return i < p.blocks.count ? p.blocks[i] : nil
    }

    /// Rounds in the current round-based unit: a plan block, or a bag session.
    var roundsLimit: Int? {
        if isRunningPlan {
            guard let b = currentBlock, b.kind.isRoundBased, !isInPlanTransition, !planComplete else { return nil }
            return b.rounds + blockExtraRounds
        }
        return bagEnabled ? totalBagRounds : nil
    }

    /// Time left in a timed (non-round) plan block.
    var blockRemaining: TimeInterval {
        guard let b = currentBlock, !b.kind.isRoundBased, !isInPlanTransition else { return 0 }
        return max(0, Double(b.durationSeconds + blockExtraSeconds) - planBlockElapsed)
    }

    /// HR band to hold right now: the plan block's target, else a Coach-tab prescription.
    var activeTargetRange: ClosedRange<Int>? {
        if isRunningPlan {
            guard !isInPlanTransition, !planComplete, let t = currentBlock?.target else { return nil }
            return t.bpmRange(for: profile)
        }
        if let p = activePlan { return p.targetLowBPM...max(p.targetLowBPM, p.targetHighBPM) }
        return nil
    }

    // MARK: Setup changes

    // MARK: Remembered setup

    private var setupMemoryKey: String { "fight.setup.\(profile.id.uuidString)" }

    private func loadSetupMemory() -> WorkoutSetupMemory {
        guard let data = UserDefaults.standard.data(forKey: setupMemoryKey),
              let m = try? JSONDecoder().decode(WorkoutSetupMemory.self, from: data) else { return WorkoutSetupMemory() }
        return m
    }

    private var currentSetup: WorkoutSetup {
        WorkoutSetup(category: selectedCategory, drill: selectedDrillTag, roundTimer: roundTimerEnabled,
                     workSeconds: workDurationSeconds, restSeconds: restDurationSeconds, bag: bagEnabled)
    }

    /// Saves this workout's setup so the next one starts the same way (per workout type).
    private func rememberSetup() {
        guard selectedCategory != .lthrTest, queuedPlan == nil, runningPlan == nil else { return }
        var m = loadSetupMemory()
        m.last = currentSetup
        m.byCategory[selectedCategory.rawValue] = currentSetup
        if let data = try? JSONEncoder().encode(m) { UserDefaults.standard.set(data, forKey: setupMemoryKey) }
    }

    /// Puts back the setup from your last workout (call on launch and when the fighter changes).
    func restoreLastSetup() {
        guard !isRecording, queuedPlan == nil, let last = loadSetupMemory().last else { return }
        apply(last)
    }

    private func apply(_ s: WorkoutSetup) {
        suppressDefaults = true
        selectedCategory = s.category
        suppressDefaults = false
        selectedDrillTag = s.drill
        let noBag: [WorkoutCategory] = [.walk, .roadwork, .lthrTest]
        bagEnabled = s.bag && !noBag.contains(s.category)
        roundTimerEnabled = s.roundTimer || bagEnabled
        if !bagEnabled {
            workDurationSeconds = s.workSeconds
            restDurationSeconds = s.restSeconds
        }
    }

    /// One line describing what Start will do, e.g. "Muay Thai · 5 × 3:00 · Bag Coach".
    var setupSummary: String {
        if let plan = queuedPlan { return plan.title }
        var parts = [selectedCategory.rawValue]
        if selectedCategory == .lthrTest { return "30-min threshold test" }
        func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
        if bagEnabled {
            parts.append("\(bagPrefs.estimatedTotalRounds) × \(clock(bagPrefs.workSeconds))")
            parts.append("Bag Coach")
        } else if roundTimerEnabled {
            parts.append("\(clock(workDurationSeconds)) rounds")
        }
        return parts.joined(separator: " · ")
    }

    private func applyDisciplineDefaults(_ category: WorkoutCategory) {
        if let saved = loadSetupMemory().byCategory[category.rawValue] {
            apply(saved)
            return
        }
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

    // MARK: Training plans

    /// Loads a plan to run on the next Start.
    func queue(_ plan: TrainingPlan) {
        guard !isRecording else { return }
        suppressDefaults = true
        selectedCategory = plan.category
        suppressDefaults = false
        bagEnabled = false
        activePlan = nil
        queuedPlan = plan
    }

    func unqueuePlan() {
        guard !isRecording else { return }
        queuedPlan = nil
    }

    private func prefs(for block: PlanBlock) -> BagPreferences {
        var p = bagPrefs // keeps the fighter's stance, call style, level and strike toggles
        p.tempo = block.tempo
        p.workSeconds = block.workSeconds
        p.restSeconds = block.restSeconds
        if block.combos.isEmpty {
            p.customOnly = false
        } else {
            p.customCombos = block.combos
            p.customOnly = true
        }
        return p
    }

    private func beginTransition(to index: Int, seconds: TimeInterval) {
        guard let plan = runningPlan, index < plan.blocks.count else { return }
        audio.stopBagCoach()
        roundTimerEnabled = false
        isRestPeriod = false
        phaseElapsed = 0
        planBlockIndex = index
        planBlockElapsed = 0
        planTransitionRemaining = seconds
        let b = plan.blocks[index]
        let lead = index == 0 ? "First up: " : "Next up: "
        audio.announceCoachingCue(lead + b.spokenIntro + (b.cue.isEmpty ? "" : " \(b.cue)"), enabled: true)
    }

    private func startBlock(_ index: Int) {
        guard let plan = runningPlan, index < plan.blocks.count else { return }
        let b = plan.blocks[index]
        planBlockIndex = index
        planBlockElapsed = 0
        planTransitionRemaining = nil
        blockExtraRounds = 0
        blockExtraSeconds = 0
        blockStartElapsed = elapsedSeconds
        blockStartStrikes = audio.strikesCuedCount
        roundNumberOffset = completedRounds.count
        pendingRecovery = nil
        pendingRecoveryRemaining = nil

        if b.kind.isRoundBased {
            roundTimerEnabled = true
            workDurationSeconds = b.workSeconds
            restDurationSeconds = b.restSeconds
            currentRound = 1
            isRestPeriod = false
            phaseElapsed = 0
            currentRoundStartElapsed = elapsedSeconds
            currentWorkEndElapsed = 0
            currentRoundStartStrikes = audio.strikesCuedCount
            roundEndPeakBPM = 0
        } else {
            roundTimerEnabled = false
            isRestPeriod = false
            phaseElapsed = 0
        }
        audio.playRoundStartBell()
        if b.kind == .bagRounds {
            startBagCoach(prefs: prefs(for: b))
        } else {
            audio.stopBagCoach()
        }
        saveDraft()
    }

    private func appendResult(for b: PlanBlock, completed: Bool, start: TimeInterval) {
        let blockSamples = samples.filter { $0.elapsedSeconds >= start }
        let bpms = blockSamples.map(\.bpm)
        var inTarget: Double?
        if let t = b.target, !bpms.isEmpty {
            let r = t.bpmRange(for: profile)
            inTarget = Double(bpms.filter { r.contains($0) }.count) / Double(bpms.count)
        }
        blockResults.append(BlockResult(
            blockID: b.id, title: b.title, kind: b.kind, plannedSeconds: b.plannedSeconds,
            startElapsed: start, endElapsed: elapsedSeconds, completed: completed,
            avgBPM: bpms.isEmpty ? nil : bpms.reduce(0, +) / bpms.count,
            peakBPM: bpms.max(), timeInTarget: inTarget, targetLabel: b.target?.label,
            roundsCompleted: b.kind.isRoundBased ? max(0, completedRounds.count - roundNumberOffset) : nil,
            strikesCalled: max(0, audio.strikesCuedCount - blockStartStrikes)
        ))
    }

    /// Ends the running block (naturally, via "Done", or skipped) and moves on.
    func finishCurrentBlock(skipped: Bool = false) {
        guard isRecording, let plan = runningPlan, !planComplete else { return }
        if isInPlanTransition {
            // Skipping the block that was about to start.
            if let b = currentBlock {
                blockStartStrikes = audio.strikesCuedCount
                roundNumberOffset = completedRounds.count
                appendResult(for: b, completed: false, start: elapsedSeconds)
            }
        } else if let b = currentBlock {
            if b.kind.isRoundBased && skipped && !isRestPeriod {
                currentWorkEndElapsed = elapsedSeconds
                recordRound(stoolDrop: nil)
            }
            appendResult(for: b, completed: !skipped, start: blockStartElapsed)
            audio.flushCombos()
            if !b.kind.isRoundBased || skipped { audio.playRoundEndBell() }
        }
        audio.stopBagCoach()
        roundTimerEnabled = false
        isRestPeriod = false
        pendingRecovery = nil
        pendingRecoveryRemaining = nil

        let next = planBlockIndex + 1
        if next < plan.blocks.count {
            beginTransition(to: next, seconds: Self.transitionSeconds)
        } else {
            planTransitionRemaining = nil
            planComplete = true
            audio.announceCoachingCue("Plan complete. Great work.", enabled: true)
            requestFinishPrompt = true
        }
        saveDraft()
    }

    func startNextBlockNow() {
        guard isInPlanTransition else { return }
        startBlock(planBlockIndex)
    }

    /// +1 round for round blocks, +1 minute for timed blocks.
    func extendCurrentBlock() {
        guard let b = currentBlock, !isInPlanTransition, !planComplete else { return }
        if b.kind.isRoundBased { blockExtraRounds += 1 } else { blockExtraSeconds += 60 }
    }

    private func advancePlan(by dt: TimeInterval) {
        if let t = planTransitionRemaining {
            let after = t - dt
            if t > 3 && after <= 3 && profile.audioCoach.clapperWarnings { audio.playClapper() }
            if after <= 0 {
                startBlock(planBlockIndex)
            } else {
                planTransitionRemaining = after
            }
            return
        }
        guard let b = currentBlock, !b.kind.isRoundBased else { return }
        planBlockElapsed += dt
        let total = Double(b.durationSeconds + blockExtraSeconds)
        let before = total - (planBlockElapsed - dt)
        let after = total - planBlockElapsed
        if total > 30 && before > 10 && after <= 10 && profile.audioCoach.clapperWarnings { audio.playClapper() }
        if total >= 240 && before > total / 2 && after <= total / 2 {
            audio.announceCoachingCue("Halfway.", enabled: true)
        }
        if after <= 0 { finishCurrentBlock() }
    }

    // MARK: Start / stop

    func startWorkout() {
        guard !isRecording else { return }
        rememberSetup()
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
        comboEvents = []
        bestRecoveryRecord = store.map { Records.bestRecovery(workouts: $0.workouts, profileID: $0.activeProfileID) } ?? 0
        recoveryRecordAnnounced = false
        liveRecordBanner = nil
        nextBreathCue = nil
        breathInhaleNext = true
        breathingUsed = false
        currentRoundStartHeadMoves = 0
        if profile.trackHeadMovement { headMotion.start() }
        runningPlan = queuedPlan
        queuedPlan = nil
        planBlockIndex = 0
        planBlockElapsed = 0
        planTransitionRemaining = nil
        planComplete = false
        blockResults = []
        blockExtraRounds = 0
        blockExtraSeconds = 0
        roundNumberOffset = 0
        _ = ble?.consumeLatestRRIntervals()

        let now = Date()
        startTime = now
        lastTick = now
        lastDraftSave = now
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true

        audio.prepareForWorkout(settings: profile.audioCoach)
        if isRunningPlan {
            bagEnabled = false
            beginTransition(to: 0, seconds: Self.firstBlockLeadIn)
        } else {
            if roundTimerEnabled || bagEnabled {
                audio.playRoundStartBell()
            }
            if bagEnabled {
                if totalBagRounds == 1 { announceFinalRound() }
                startBagCoach()
            }
        }
        startLiveActivity()

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        saveDraft()
    }

    private func startBagCoach(prefs override: BagPreferences? = nil) {
        let context = BagLoopContext(
            isWorkPhase: { [weak self] in
                guard let self else { return false }
                return self.isRecording && !self.bagSessionComplete && !self.isInPlanTransition && !self.planComplete
                    && (!self.roundTimerEnabled || !self.isRestPeriod)
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
                guard let self, let range = self.activeTargetRange else { return 0 }
                let bpm = self.currentBPM
                if bpm <= 0 { return 0 }
                if bpm < range.lowerBound { return -1 }
                if bpm > range.upperBound { return 1 }
                return 0
            }
        )
        audio.startBagCoach(prefs: override ?? bagPrefs, context: context)
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
        headMotion.stop()
        audio.shutdownAudio()
        endLiveActivity()
    }

    func finishAndSave() {
        guard isRecording, let store else { return }
        if isRunningPlan && !planComplete, let b = currentBlock {
            if isInPlanTransition {
                // Remaining blocks were never started.
            } else {
                appendResult(for: b, completed: false, start: blockStartElapsed)
            }
        }
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
        resetPlanState()
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
        resetPlanState()
    }

    private func resetPlanState() {
        runningPlan = nil
        planComplete = false
        planTransitionRemaining = nil
        planBlockIndex = 0
        planBlockElapsed = 0
        blockResults = []
        roundNumberOffset = 0
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

        if roundTimerEnabled && !bagSessionComplete && !isInPlanTransition {
            advanceRoundClock(by: dt, bpm: bpm, coachCfg: coachCfg)
        }
        if isRunningPlan && !planComplete {
            advancePlan(by: dt)
        }
        guideBreathingIfNeeded()

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

        if let limit = roundsLimit, currentRound >= limit {
            recordRound(stoolDrop: nil)
            if isRunningPlan {
                finishCurrentBlock()
                return
            }
            bagSessionComplete = true
            audio.stopBagCoach()
            audio.announceCoachingCue("Session complete. Great work.", enabled: true)
            requestFinishPrompt = true
            return
        }

        isRestPeriod = true
        nextBreathCue = elapsedSeconds + 2.5
        breathInhaleNext = true
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
        if let drop, checkRecoveryRecord(drop) {
            // Record announcement replaces the normal recovery cue.
        } else if let drop, coachCfg.masterEnabled && coachCfg.announceStoolRecovery {
            audio.announceCoachingCue("Recovered \(drop) beats.", enabled: true)
        }
        currentRound += 1
        isRestPeriod = false
        nextBreathCue = nil
        currentRoundStartElapsed = elapsedSeconds
        currentRoundStartStrikes = audio.strikesCuedCount
        currentRoundStartHeadMoves = headMotion.totalMoves
        roundEndPeakBPM = 0
        audio.playRoundStartBell()
        if let limit = roundsLimit, currentRound == limit, limit > 1 {
            if isRunningPlan {
                audio.announceCoachingCue("Last round.", enabled: true)
            } else {
                announceFinalRound()
            }
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
            roundNumber: roundNumberOffset + currentRound,
            startElapsed: currentRoundStartElapsed,
            endElapsed: workEnd,
            avgBPM: avg,
            peakBPM: peak,
            stoolDropBPM: stoolDrop,
            strikesCued: max(0, audio.strikesCuedCount - currentRoundStartStrikes),
            headMoves: headMotion.isReceiving ? max(0, headMotion.totalMoves - currentRoundStartHeadMoves) : nil
        ))
    }

    // MARK: Signature features

    private func logCombo(_ combo: [Strike]) {
        guard isRecording else { return }
        let t = elapsedSeconds + (lastTick.map { Date().timeIntervalSince($0) } ?? 0)
        comboEvents.append(ComboEvent(t: t, strikes: combo))
    }

    /// Speaks a new personal record the moment it happens. Returns true if it did.
    private func checkRecoveryRecord(_ drop: Int) -> Bool {
        guard bestRecoveryRecord >= 15, drop > bestRecoveryRecord else { return false }
        bestRecoveryRecord = drop
        liveRecordBanner = "New record: recovered \(drop) BPM in 60 s"
        guard !recoveryRecordAnnounced else { return false }
        recoveryRecordAnnounced = true
        audio.announceCoachingCue("New recovery record! \(drop) beats.", enabled: profile.audioCoach.masterEnabled)
        return profile.audioCoach.masterEnabled
    }

    /// Paced breathing tones on the stool: in for 4, out for 6 (6 breaths a minute).
    private func guideBreathingIfNeeded() {
        guard profile.guidedBreathing, roundTimerEnabled, isRestPeriod, let next = nextBreathCue,
              elapsedSeconds >= next else { return }
        let remaining = currentPhaseTarget - phaseElapsed
        guard remaining > 7 else { nextBreathCue = nil; return }
        let seconds: Double = breathInhaleNext ? 4 : 6
        audio.playBreathCue(inhale: breathInhaleNext, seconds: seconds)
        breathingUsed = true
        breathInhaleNext.toggle()
        nextBreathCue = next + seconds
    }

    private var headMovesPerMinute: Double? {
        guard headMotion.isReceiving else { return nil }
        let rounds = completedRounds.filter { $0.headMoves != nil }
        let workSeconds = rounds.reduce(0.0) { $0 + ($1.endElapsed - $1.startElapsed) }
        if workSeconds >= 60 {
            return Double(rounds.compactMap(\.headMoves).reduce(0, +)) / workSeconds * 60
        }
        guard elapsedSeconds >= 60 else { return nil }
        return Double(headMotion.totalMoves) / elapsedSeconds * 60
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
                    _ = checkRecoveryRecord(drop)
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
        let settle: TimeInterval = isRunningPlan ? 45 : 90
        guard let range = activeTargetRange, coachCfg.masterEnabled,
              elapsedSeconds - (isRunningPlan ? blockStartElapsed : 0) > settle,
              elapsedSeconds - lastPlanAlertTime >= 75,
              !(roundTimerEnabled && isRestPeriod) else { return }
        if bpm > range.upperBound + 4 {
            lastPlanAlertTime = elapsedSeconds
            audio.announceCoachingCue("Above target. Ease back under \(range.upperBound).", enabled: true)
        } else if isRunningPlan, let b = currentBlock, b.kind == .steady || b.kind == .timedDrill, bpm < range.lowerBound - 6 {
            lastPlanAlertTime = elapsedSeconds
            audio.announceCoachingCue("Below target. Pick it up to \(range.lowerBound).", enabled: true)
        }
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
        let key = (bpm: bpm, zone: z.number, round: currentRound * 100 + planBlockIndex, rest: isRestPeriod || isInPlanTransition)
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
            workoutStartDate: startTime ?? now,
            isTimedRound: roundTimerEnabled || (isRunningPlan && !isInPlanTransition && !(currentBlock?.kind.isRoundBased ?? true)),
            roundNumber: isRunningPlan ? planBlockIndex + 1 : currentRound,
            isRest: isRestPeriod || isInPlanTransition,
            phaseEndDate: now.addingTimeInterval(isInPlanTransition ? (planTransitionRemaining ?? 0) : (roundTimerEnabled ? phaseRemaining : blockRemaining))
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
            planTargetLow: activePlan?.targetLowBPM, planTargetHigh: activePlan?.targetHighBPM,
            trainingPlanID: runningPlan?.id, trainingPlanTitle: runningPlan?.title,
            blockResults: blockResults,
            comboEvents: comboEvents,
            headMovesPerMinute: headMovesPerMinute,
            breathingGuided: breathingUsed
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
