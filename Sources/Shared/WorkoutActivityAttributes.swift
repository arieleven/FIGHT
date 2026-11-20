import Foundation
import ActivityKit

struct WorkoutActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var currentBPM: Int
        var zoneNumber: Int
        var zoneShortName: String
        var calories: Int
        var workoutStartDate: Date
        var isTimedRound: Bool
        var roundNumber: Int
        var isRest: Bool
        var phaseEndDate: Date
    }

    var athleteName: String
    var discipline: String
}
