import AppIntents
import Foundation

enum FanModeControlAction: String, AppEnum {
    case automatic, profile, maximum
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Режим охлаждения")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .automatic: "Авто", .profile: "Профиль", .maximum: "Максимум"
    ]
}

/// Compiled into both bundles. The system routes execution to the main app;
/// the widget never connects to the privileged helper or owns a control lease.
@available(macOS 27.0, *)
struct FanModeControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Установить режим охлаждения FanMacly"
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Режим") var mode: FanModeControlAction
    init() { mode = .automatic }
    init(_ mode: FanModeControlAction) { self.mode = mode }
    func perform() async throws -> some IntentResult {
        try await FanModeControlRouter.perform(mode)
        return .result()
    }
}

@MainActor enum FanModeControlRouter {
    static var handler: ((FanModeControlAction) async throws -> Void)?
    static func perform(_ action: FanModeControlAction) async throws {
        // A cold launch may deliver the intent before AppKit finishes setup.
        for _ in 0..<50 {
            if let handler { try await handler(action); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "FanMacly", code: 1, userInfo: [NSLocalizedDescriptionKey: "FanMacly не завершил запуск."])
    }
}
