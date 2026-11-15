import Foundation
import FanMaclyCore

/// Built-in temperature profiles, calibrated for Apple Silicon.
enum CoolingPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case quiet, balanced, cool
    var id: String { rawValue }
    /// Short label for the mode tiles.
    var shortTitle: String {
        switch self { case .quiet: return "Тихо"; case .balanced: return "Баланс"; case .cool: return "Холод" }
    }
    /// Full profile name.
    var title: String {
        switch self { case .quiet: return "Тихий"; case .balanced: return "Сбалансированный"; case .cool: return "Прохладный" }
    }
    var symbol: String {
        switch self { case .quiet: return "leaf"; case .balanced: return "dial.medium"; case .cool: return "snowflake" }
    }
    var summary: String {
        switch self {
        case .quiet: return "Минимум шума в обычной работе; вентиляторы раскручиваются ближе к 85–95 °C."
        case .balanced: return "Плавный рост оборотов от 60 °C, максимум около 92 °C."
        case .cool: return "Заметно прохладнее под нагрузкой ценой шума."
        }
    }
    var curve: CoolingCurve {
        switch self { case .quiet: return .quiet; case .balanced: return .balanced; case .cool: return .cool }
    }
}

/// What the user chose. Encoded into `ControlRequest.profileID` so the helper
/// can report it back after the app restarts.
enum ModeSelection: Hashable, Codable, Sendable {
    case automatic
    case preset(CoolingPreset)
    case profile(UUID)
    case manual
    case maximum

    var key: String {
        switch self {
        case .automatic: return "auto"
        case .preset(let preset): return preset.rawValue
        case .profile(let id): return id.uuidString
        case .manual: return "manual"
        case .maximum: return "maximum"
        }
    }
    init?(key: String?) {
        guard let key else { return nil }
        switch key {
        case "auto": self = .automatic
        case "manual": self = .manual
        case "maximum": self = .maximum
        default:
            if let preset = CoolingPreset(rawValue: key) { self = .preset(preset) }
            else if let id = UUID(uuidString: key) { self = .profile(id) }
            else { return nil }
        }
    }
    init(from decoder: Decoder) throws {
        let key = try decoder.singleValueContainer().decode(String.self)
        self = ModeSelection(key: key) ?? .automatic
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
    var isCustomControl: Bool { self != .automatic }
}

/// Picker options used by settings, automation rules and intents.
struct SelectionOption: Identifiable, Hashable {
    let selection: ModeSelection
    let title: String
    let symbol: String
    var id: String { selection.key }
}
