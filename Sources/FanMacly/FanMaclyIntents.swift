import AppIntents
import Foundation
import FanMaclyCore

/// Modes exposed to Shortcuts, Siri and Focus filters.
enum CoolingModeOption: String, AppEnum {
    case automatic, quiet, balanced, cool, maximum
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Режим FanMacly")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(title: "Авто (macOS)", image: .init(systemName: "a.circle")),
        .quiet: DisplayRepresentation(title: "Тихий", image: .init(systemName: "leaf")),
        .balanced: DisplayRepresentation(title: "Сбалансированный", image: .init(systemName: "dial.medium")),
        .cool: DisplayRepresentation(title: "Прохладный", image: .init(systemName: "snowflake")),
        .maximum: DisplayRepresentation(title: "Максимум", image: .init(systemName: "wind"))
    ]
    var selection: ModeSelection {
        switch self {
        case .automatic: return .automatic
        case .quiet: return .preset(.quiet)
        case .balanced: return .preset(.balanced)
        case .cool: return .preset(.cool)
        case .maximum: return .maximum
        }
    }
}

@MainActor enum FanMaclyIntentRouter {
    static weak var model: AppModel?
    static func waitForModel() async throws -> AppModel {
        for _ in 0..<50 {
            if let model { return model }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw FanMaclyError.message("FanMacly не завершил запуск.")
    }
}

struct SetCoolingModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Установить режим охлаждения"
    static let description = IntentDescription("Включает режим вентиляторов FanMacly.")
    @Parameter(title: "Режим", default: .balanced) var mode: CoolingModeOption
    static var parameterSummary: some ParameterSummary { Summary("Установить режим \(\.$mode)") }
    init() {}
    init(mode: CoolingModeOption) { self.mode = mode }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await FanMaclyIntentRouter.waitForModel()
        try await model.perform(mode.selection)
        return .result(dialog: "Режим «\(model.title(for: mode.selection))» включён.")
    }
}

struct StartBoostIntent: AppIntent {
    static let title: LocalizedStringResource = "Включить буст вентиляторов"
    static let description = IntentDescription("Максимальные обороты на заданное время, затем возврат к текущему режиму.")
    @Parameter(title: "Минуты", default: 10, inclusiveRange: (1, 240)) var minutes: Int
    static var parameterSummary: some ParameterSummary { Summary("Буст на \(\.$minutes) мин") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await FanMaclyIntentRouter.waitForModel()
        for _ in 0..<50 where !model.helper.connected || !model.hasFans { try await Task.sleep(for: .milliseconds(100)) }
        guard model.helper.connected else { throw FanMaclyError.message("Нет связи с системным компонентом FanMacly.") }
        guard let until = model.startBoost(minutes: minutes) else { throw FanMaclyError.message("Нет данных о вентиляторах — буст не включён.") }
        for _ in 0..<100 {
            // Compare the end time: an already running boost must not count as confirmation.
            if let confirmed = model.helper.status.intent?.boost?.until, abs(confirmed.timeIntervalSince(until)) < 1,
               model.pendingSelection == nil {
                return .result(dialog: "Буст включён на \(minutes) мин.")
            }
            if let error = model.transientError { throw FanMaclyError.message(error) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw FanMaclyError.message("FanMacly не подтвердил включение буста.")
    }
}

struct FanMaclyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetCoolingModeIntent(), phrases: [
            "Режим \(\.$mode) в \(.applicationName)",
            "Включи \(\.$mode) в \(.applicationName)"
        ], shortTitle: "Режим охлаждения", systemImageName: "fanblades")
        AppShortcut(intent: StartBoostIntent(), phrases: [
            "Буст в \(.applicationName)",
            "Раскрути вентиляторы в \(.applicationName)"
        ], shortTitle: "Буст", systemImageName: "bolt.fill")
    }
}

/// Focus filter: e.g. "Не беспокоить" → Тихий.
struct FanMaclyFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Режим вентиляторов"
    static let description: IntentDescription? = IntentDescription("Режим FanMacly, пока включено это Фокусирование.")
    @Parameter(title: "Режим") var mode: CoolingModeOption?
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Вентиляторы", subtitle: mode.map { CoolingModeOption.caseDisplayRepresentations[$0]?.title ?? "" } ?? "Не менять")
    }
    @MainActor func perform() async throws -> some IntentResult {
        let model = try await FanMaclyIntentRouter.waitForModel()
        model.setFocusOverride(mode?.selection)
        return .result()
    }
}
