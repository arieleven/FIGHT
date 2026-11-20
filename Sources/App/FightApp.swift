import SwiftUI

@main
struct FightApp: App {
    @StateObject private var bleManager = BLEHeartRateManager()
    @StateObject private var workoutStore = WorkoutStore()
    @StateObject private var healthKit = HealthKitManager()
    @StateObject private var navigation = AppNavigation()

    var body: some Scene {
        WindowGroup {
            TabView(selection: $navigation.selectedTab) {
                LiveWorkoutView()
                    .tabItem { Label("Live", systemImage: "heart.fill") }
                    .tag(AppNavigation.Tab.live)

                CoachView()
                    .tabItem { Label("Coach", systemImage: "gauge.with.dots.needle.67percent") }
                    .tag(AppNavigation.Tab.coach)

                CampView()
                    .tabItem { Label("Camp", systemImage: "calendar.badge.clock") }
                    .tag(AppNavigation.Tab.camp)

                HistoryListView()
                    .tabItem { Label("History", systemImage: "list.bullet.clipboard") }
                    .tag(AppNavigation.Tab.history)

                ProfileSettingsView()
                    .tabItem { Label("Fighter", systemImage: "person.crop.circle") }
                    .tag(AppNavigation.Tab.profile)
            }
            .environmentObject(bleManager)
            .environmentObject(workoutStore)
            .environmentObject(healthKit)
            .environmentObject(navigation)
            .preferredColorScheme(.dark)
        }
    }
}
