import Foundation
import HealthKit

/// Saves finished FIGHT sessions to Apple Health as workouts,
/// including the full heart-rate trace and active energy.
@MainActor
final class HealthKitManager: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published var autoSaveEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSaveEnabled, forKey: autoSaveKey) }
    }
    @Published var statusMessage: String = ""
    @Published private(set) var savedWorkoutIDs: Set<UUID> = []

    private let store = HKHealthStore()
    private let autoSaveKey = "fight_healthkit_autosave_v1"
    private let savedIDsKey = "fight_healthkit_saved_ids_v1"
    private let authorizedKey = "fight_healthkit_authorized_v1"

    private let heartRateType = HKQuantityType(.heartRate)
    private let activeEnergyType = HKQuantityType(.activeEnergyBurned)
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        [HKQuantityType(.restingHeartRate), HKQuantityType(.bodyMass)]
    }

    // MARK: Reading from Health

    private func quantitySamples(_ type: HKQuantityType, unit: HKUnit, since: Date) async -> [(date: Date, value: Double)] {
        guard isAvailable else { return [] }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: since, end: nil))],
                sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
                limit: 300
            )
            let results = try await descriptor.result(for: store)
            return results.map { ($0.startDate, $0.quantity.doubleValue(for: unit)) }
        } catch {
            statusMessage = "Couldn't read Apple Health: \(error.localizedDescription)"
            return []
        }
    }

    /// Imports body-weight entries (e.g. from a smart scale) as weigh-ins, skipping duplicates.
    @discardableResult
    func importWeighIns(into workoutStore: WorkoutStore, profileID: UUID, days: Int = 60) async -> Int {
        let samples = await quantitySamples(HKQuantityType(.bodyMass), unit: .gramUnit(with: .kilo),
                                            since: Date().addingTimeInterval(-Double(days) * 86400))
        var added = 0
        for s in samples {
            let duplicate = workoutStore.weighIns.contains {
                $0.profileID == profileID && abs($0.date.timeIntervalSince(s.date)) < 4 * 3600
            }
            guard !duplicate, s.value >= 30, s.value <= 250 else { continue }
            workoutStore.addWeighIn(WeighIn(profileID: profileID, date: s.date, weightKg: s.value, notes: "Apple Health"))
            added += 1
        }
        statusMessage = added == 0 ? "No new weigh-ins in Apple Health" : "Imported \(added) weigh-in\(added == 1 ? "" : "s") from Apple Health"
        return added
    }

    /// Imports daily resting HR (e.g. from Apple Watch) for days without a readiness check.
    @discardableResult
    func importRestingHR(into workoutStore: WorkoutStore, days: Int = 30) async -> Int {
        let samples = await quantitySamples(HKQuantityType(.restingHeartRate), unit: .count().unitDivided(by: .minute()),
                                            since: Date().addingTimeInterval(-Double(days) * 86400))
        let cal = Calendar.current
        var seenDays = Set(workoutStore.readinessReadings.map { cal.startOfDay(for: $0.date) })
        var added = 0
        for s in samples {
            let day = cal.startOfDay(for: s.date)
            guard !seenDays.contains(day), s.value >= 30, s.value <= 120 else { continue }
            seenDays.insert(day)
            workoutStore.addReadiness(ReadinessReading(
                date: s.date, durationSeconds: 0, restingHR: Int(s.value.rounded()), rmssd: nil, artifactRate: nil,
                sleepQuality: 3, soreness: 2, source: "health"
            ))
            added += 1
        }
        statusMessage = added == 0 ? "No new resting HR in Apple Health" : "Imported \(added) day\(added == 1 ? "" : "s") of resting HR"
        return added
    }

    init() {
        autoSaveEnabled = UserDefaults.standard.object(forKey: autoSaveKey) as? Bool ?? true
        if let stored = UserDefaults.standard.array(forKey: savedIDsKey) as? [String] {
            savedWorkoutIDs = Set(stored.compactMap(UUID.init(uuidString:)))
        }
        refreshAuthorizationState()
    }

    /// HealthKit never reveals read permission, but it does reveal share (write)
    /// permission, which is all this app needs.
    func refreshAuthorizationState() {
        guard isAvailable else {
            isAuthorized = false
            statusMessage = "Apple Health isn't available on this device"
            return
        }
        isAuthorized = store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
            && store.authorizationStatus(for: heartRateType) == .sharingAuthorized
    }

    func requestAuthorization() async {
        guard isAvailable else {
            statusMessage = "Apple Health isn't available on this device"
            return
        }
        let shareTypes: Set<HKSampleType> = [HKObjectType.workoutType(), heartRateType, activeEnergyType]
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            UserDefaults.standard.set(true, forKey: authorizedKey)
            refreshAuthorizationState()
            statusMessage = isAuthorized
                ? "Connected to Apple Health"
                : "Health access not granted — enable it in Settings › Health › Data Access & Devices"
        } catch {
            isAuthorized = false
            statusMessage = "Health permission failed: \(error.localizedDescription)"
        }
    }

    func isSaved(_ workout: SavedWorkout) -> Bool {
        savedWorkoutIDs.contains(workout.id)
    }

    /// Writes the workout, its heart-rate samples and active calories to Health.
    /// Returns true on success. Safe to call twice: already-saved workouts are skipped.
    @discardableResult
    func save(workout: SavedWorkout, samples: [HeartRatePoint], sensor: SensorInfo? = nil) async -> Bool {
        guard isAvailable else { return false }
        guard !savedWorkoutIDs.contains(workout.id) else { return true }
        guard workout.duration >= 60 else {
            statusMessage = "Workouts under 1 minute aren't sent to Apple Health"
            return false
        }

        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return false }
        }

        let config = HKWorkoutConfiguration()
        config.activityType = Self.activityType(for: workout.category)
        config.locationType = Self.locationType(for: workout.category)

        let device = HKDevice(
            name: sensor?.name ?? "Heart Rate Monitor",
            manufacturer: sensor?.manufacturer,
            model: sensor?.model,
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        )

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: device)
        let start = workout.startDate
        let end = max(workout.endDate, start.addingTimeInterval(1))

        do {
            try await builder.beginCollection(at: start)

            var hkSamples: [HKSample] = samples
                .filter { $0.bpm > 0 && $0.timestamp >= start && $0.timestamp <= end }
                .map { pt in
                    HKQuantitySample(
                        type: heartRateType,
                        quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(pt.bpm)),
                        start: pt.timestamp,
                        end: pt.timestamp,
                        device: device,
                        metadata: nil
                    )
                }

            if workout.activeCalories > 0 {
                hkSamples.append(HKQuantitySample(
                    type: activeEnergyType,
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: workout.activeCalories),
                    start: start,
                    end: end,
                    device: device,
                    metadata: nil
                ))
            }

            if !hkSamples.isEmpty {
                let samplesToAdd = hkSamples
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    builder.add(samplesToAdd) { success, error in
                        if let error {
                            cont.resume(throwing: error)
                        } else if !success {
                            cont.resume(throwing: NSError(domain: "FightHealth", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Health rejected the workout samples"]))
                        } else {
                            cont.resume()
                        }
                    }
                }
            }

            var metadata: [String: Any] = [
                HKMetadataKeyExternalUUID: workout.id.uuidString,
                HKMetadataKeyIndoorWorkout: config.locationType != .outdoor,
                "FightDiscipline": workout.category.rawValue,
                "FightDrill": workout.drillTag.rawValue,
                "FightRPE": workout.rpe
            ]
            if !workout.notes.isEmpty {
                metadata["FightNotes"] = workout.notes
            }
            try await builder.addMetadata(metadata)

            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()

            savedWorkoutIDs.insert(workout.id)
            UserDefaults.standard.set(savedWorkoutIDs.map(\.uuidString), forKey: savedIDsKey)
            statusMessage = "Saved \(workout.category.rawValue) to Apple Health"
            return true
        } catch {
            builder.discardWorkout()
            statusMessage = "Apple Health save failed: \(error.localizedDescription)"
            return false
        }
    }

    static func activityType(for category: WorkoutCategory) -> HKWorkoutActivityType {
        switch category {
        case .muayThai, .kickboxing: return .kickboxing
        case .heavyBag, .padWork: return .boxing
        case .sparring: return .martialArts
        case .bjj: return .wrestling
        case .roadwork: return .running
        case .walk: return .walking
        case .conditioning: return .functionalStrengthTraining
        case .lthrTest: return .running
        }
    }

    static func locationType(for category: WorkoutCategory) -> HKWorkoutSessionLocationType {
        switch category {
        case .roadwork, .walk, .lthrTest: return .outdoor
        default: return .indoor
        }
    }
}
