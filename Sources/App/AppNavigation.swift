import SwiftUI

/// Shared navigation state so the Coach tab can hand a planned workout to the Live tab.
@MainActor
final class AppNavigation: ObservableObject {
    enum Tab: Hashable {
        case live, coach, history, profile
    }

    /// The app's navigation, for Siri and Shortcuts.
    static weak var shared: AppNavigation?

    @Published var selectedTab: Tab = .live
    /// Set by the "Readiness check" shortcut; the Coach tab opens the check.
    @Published var requestReadinessCheck = false
    @Published var pendingPrescription: WorkoutPrescription?

    /// A plan opened from a file, link or QR code, waiting for the import preview.
    @Published var incomingPlan: TrainingPlan?
    /// A fighter's session result opened from a `.fightresult` file.
    @Published var incomingResult: SessionResultPackage?
    @Published var importError: String?
    /// A plan the fighter chose to run; picked up by the Live tab.
    @Published var planToRun: TrainingPlan?

    func run(_ plan: TrainingPlan) {
        planToRun = plan
        selectedTab = .live
    }

    /// Handles `fight://plan?d=…` links and opened `.fightplan` / `.fightresult` files.
    func handleOpenURL(_ url: URL) {
        do {
            if url.isFileURL {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                if url.pathExtension.lowercased() == PlanTransfer.resultExtension {
                    incomingResult = try PlanTransfer.result(from: data)
                } else {
                    incomingPlan = try PlanTransfer.plan(from: data)
                }
            } else {
                incomingPlan = try PlanTransfer.plan(fromLink: url)
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    func load(_ prescription: WorkoutPrescription) {
        pendingPrescription = prescription
        selectedTab = .live
    }
}
