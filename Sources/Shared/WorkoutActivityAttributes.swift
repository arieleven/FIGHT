import Foundation
import ActivityKit

struct WorkoutActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var currentBPM: Int
        var zoneNumber: Int
        var zoneShortName: String
        var roundNumber: Int
        var isRest: Bool
        var isTimedRound: Bool
        var phaseEndDate: Date
        var workoutStartDate: Date
        var calories: Int
    }

    var athleteName: String
    var discipline: String
}