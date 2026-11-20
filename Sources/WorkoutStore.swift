import Foundation
import Combine

enum WorkoutCategory: String, CaseIterable, Identifiable, Codable {
    case running = "Run"
    case walking = "Walk"
    case kickboxing = "Kickboxing"
    case hiit = "HIIT"
    case cycling = "Cycling"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .kickboxing: return "figure.kickboxing"
        case .hiit: return "flame.fill"
        case .cycling: return "bicycle"
        }
    }

    var tcxSport: String {
        switch self {
        case .running: return "Running"
        case .cycling: return "Biking"
        case .walking, .kickboxing, .hiit: return "Other"
        }
    }
}

struct HeartRatePoint: Codable {
    let timestamp: Date
    let bpm: Int
}

struct SavedWorkout: Identifiable, Codable {
    let id: UUID
    let category: WorkoutCategory
    let startDate: Date
    let duration: TimeInterval
    let averageBPM: Int
    let maxBPM: Int
    let calories: Double
    let samples: [HeartRatePoint]
}

@MainActor
final class WorkoutStore: ObservableObject {
    @Published var selectedCategory: WorkoutCategory = .kickboxing
    @Published var isWorkoutActive = false
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var averageBPM: Int = 0
    @Published var maxBPM: Int = 0
    @Published var estimatedCalories: Double = 0
    @Published var statusMessage: String?
    @Published var savedWorkouts: [SavedWorkout] = []

    private var workoutStartDate: Date?
    private var lastSampleDate: Date?
    private var timer: Timer?
    private var activeSamples: [HeartRatePoint] = []

    private var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workouts.json")
    }

    init() {
        loadWorkouts()
    }

    func startWorkout() {
        let start = Date()
        workoutStartDate = start
        lastSampleDate = start
        activeSamples.removeAll()
        elapsedSeconds = 0
        averageBPM = 0
        maxBPM = 0
        estimatedCalories = 0
        statusMessage = nil
        isWorkoutActive = true

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.workoutStartDate else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }
    }

    func recordHeartRate(_ bpm: Int, at timestamp: Date) {
        guard isWorkoutActive else { return }

        activeSamples.append(HeartRatePoint(timestamp: timestamp, bpm: bpm))
        maxBPM = max(maxBPM, bpm)
        let sum = activeSamples.reduce(0) { $0 + $1.bpm }
        averageBPM = sum / activeSamples.count

        if let previous = lastSampleDate {
            let deltaSeconds = min(timestamp.timeIntervalSince(previous), 10.0)
            if deltaSeconds > 0 {
                let kcalPerMinute = max(1.0, (-55.0969 + (0.6309 * Double(bpm)) + (0.1988 * 85.0) + (0.2017 * 22.0)) / 4.184)
                estimatedCalories += kcalPerMinute * (deltaSeconds / 60.0)
            }
        }
        lastSampleDate = timestamp
    }

    func endAndSaveWorkout() {
        timer?.invalidate()
        timer = nil
        isWorkoutActive = false

        guard let start = workoutStartDate else { return }
        let duration = Date().timeIntervalSince(start)

        let workout = SavedWorkout(
            id: UUID(),
            category: selectedCategory,
            startDate: start,
            duration: duration,
            averageBPM: averageBPM,
            maxBPM: maxBPM,
            calories: estimatedCalories,
            samples: activeSamples
        )

        savedWorkouts.insert(workout, at: 0)
        persistWorkouts()
        statusMessage = "Saved \(selectedCategory.rawValue) (\(activeSamples.count) HR points)"
        workoutStartDate = nil
    }

    func deleteWorkouts(at offsets: IndexSet) {
        savedWorkouts.remove(atOffsets: offsets)
        persistWorkouts()
    }

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
              <Notes>\(workout.category.rawValue) logged via CoospoTracker</Notes>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let fileName = "Coospo_\(workout.category.rawValue)_\(Int(workout.startDate.timeIntervalSince1970)).tcx"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? tcx.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func persistWorkouts() {
        if let data = try? JSONEncoder().encode(savedWorkouts) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private func loadWorkouts() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([SavedWorkout].self, from: data) else { return }
        savedWorkouts = decoded
    }
}