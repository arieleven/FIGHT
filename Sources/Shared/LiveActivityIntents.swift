import AppIntents
import Foundation

/// Lock-screen buttons on the workout Live Activity. The intent runs in the app's
/// process, which sets `handler` at launch.
enum LiveActivityActions {
    @MainActor static var handler: ((String) -> Void)?
}

struct RoundActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Round Action"
    static let isDiscoverable = false

    @Parameter(title: "Action") var action: String

    init() { action = "" }
    init(action: String) { self.action = action }

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveActivityActions.handler?(action)
        return .result()
    }
}
