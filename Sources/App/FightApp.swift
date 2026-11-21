import SwiftUI

@main
struct FightApp: App {
    @StateObject private var bleManager = BLEHeartRateManager()
    @StateObject private var workoutStore = WorkoutStore()
    @StateObject private var healthKit = HealthKitManager()
    @StateObject private var navigation = AppNavigation()
    @StateObject private var session = WorkoutSession()

    var body: some Scene {
        WindowGroup {
            TabView(selection: $navigation.selectedTab) {
                LiveWorkoutView()
                    .tabItem { Label("Train", systemImage: "heart.fill") }
                    .tag(AppNavigation.Tab.live)

                CoachView()
                    .tabItem { Label("Coach", systemImage: "gauge.with.dots.needle.67percent") }
                    .tag(AppNavigation.Tab.coach)

                HistoryListView()
                    .tabItem { Label("History", systemImage: "list.bullet.clipboard") }
                    .tag(AppNavigation.Tab.history)

                ProfileSettingsView()
                    .tabItem { Label("You", systemImage: "person.crop.circle") }
                    .tag(AppNavigation.Tab.profile)
            }
            .modifier(FirstRunModifier())
            .environmentObject(bleManager)
            .environmentObject(workoutStore)
            .environmentObject(healthKit)
            .environmentObject(navigation)
            .environmentObject(session)
            .task {
                AppNavigation.shared = navigation
                session.bind(ble: bleManager, store: workoutStore, health: healthKit)
            }
            .onOpenURL { url in
                navigation.handleOpenURL(url)
            }
            .sheet(item: $navigation.incomingPlan) { plan in
                PlanImportSheet(plan: plan)
                    .environmentObject(workoutStore)
                    .environmentObject(navigation)
            }
            .sheet(item: $navigation.incomingResult) { result in
                ResultViewerSheet(result: result)
            }
            .alert("Couldn't open plan", isPresented: Binding(
                get: { navigation.importError != nil },
                set: { if !$0 { navigation.importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(navigation.importError ?? "")
            }
            .preferredColorScheme(.dark)
        }
    }
}
