import Foundation

extension ZoneTarget {
    /// Resolves the relative zone target to BPM on this fighter's own zones.
    func bpmRange(for profile: AthleteProfile) -> ClosedRange<Int> {
        let z = profile.activeZones
        let floors = [profile.restingHR + 10, z.z1Max + 1, z.z2Max + 1, z.z3Max + 1, z.z4Max + 1]
        let ceilings = [z.z1Max, z.z2Max, z.z3Max, z.z4Max, profile.effectiveMaxHR]
        let lo = floors[min(max(lowZone, 1), 5) - 1]
        let hi = ceilings[min(max(highZone, 1), 5) - 1]
        return lo...max(lo, hi)
    }
}

extension TrainingPlan {
    var category: WorkoutCategory {
        WorkoutCategory(rawValue: discipline) ?? .kickboxing
    }
}

extension SessionResultPackage {
    /// Packages a saved plan workout for the coach.
    init(workout w: SavedWorkout, athlete: AthleteProfile, reviewScore: Int?) {
        self.init(
            id: w.id,
            athleteName: athlete.name,
            planID: w.trainingPlanID,
            planTitle: w.trainingPlanTitle ?? w.category.rawValue,
            discipline: w.category.rawValue,
            date: w.startDate,
            durationSeconds: w.duration,
            averageBPM: w.averageBPM,
            maxBPM: w.maxBPM,
            activeCalories: w.activeCalories,
            load: w.effectiveLoad,
            rpe: w.rpeRated ? w.rpe : nil,
            notes: w.notes,
            reviewScore: reviewScore,
            zoneMinutes: (1...5).map { Int((w.zoneSeconds[$0, default: 0] / 60).rounded()) },
            blocks: w.blockResults
        )
    }
}
