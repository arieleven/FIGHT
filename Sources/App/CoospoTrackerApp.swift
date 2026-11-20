import SwiftUI

@main
struct CoospoTrackerApp: App {
    @StateObject private var bleManager = BLEHeartRateManager()
    @StateObject private var workoutStore = WorkoutStore()
    @StateObject private var healthKit = HealthKitManager()

    var body: some Scene {
        WindowGroup {
            TabView {
                LiveWorkoutView()
                    .tabItem {
                        Label("Live", systemImage: "heart.fill")
                    }

                HistoryListView()
                    .tabItem {
                        Label("History", systemImage: "list.bullet.clipboard")
                    }

                ProfileSettingsView()
                    .tabItem {
                        Label("Fighter", systemImage: "person.crop.circle")
                    }
            }
            .environmentObject(bleManager)
            .environmentObject(workoutStore)
            .environmentObject(healthKit)
            .preferredColorScheme(.dark)
        }
    }
}
