import SwiftUI

@main
struct CoospoTrackerApp: App {
    @StateObject private var bleManager = BLEHeartRateManager()
    @StateObject private var workoutStore = WorkoutStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
                .environmentObject(workoutStore)
                .preferredColorScheme(.dark)
        }
    }
}