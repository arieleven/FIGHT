import SwiftUI

/// Shared navigation state so the Coach tab can hand a planned workout to the Live tab.
@MainActor
final class AppNavigation: ObservableObject {
    enum Tab: Hashable {
        case live, coach, history, profile
    }

    @Published var selectedTab: Tab = .live
    @Published var pendingPrescription: WorkoutPrescription?

    func load(_ prescription: WorkoutPrescription) {
        pendingPrescription = prescription
        selectedTab = .live
    }
}
