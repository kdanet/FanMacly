import Foundation

struct MenuBarSettings: Codable, Equatable {
    enum AnimationSpeed: String, Codable, CaseIterable {
        case calm, normal, fast
        var title: String {
            switch self { case .calm: return "Спокойная"; case .normal: return "Обычная"; case .fast: return "Быстрая" }
        }
        var multiplier: Double {
            switch self { case .calm: return 0.6; case .normal: return 1; case .fast: return 1.5 }
        }
    }
    enum Display: String, Codable, CaseIterable {
        case icon, temperature, rpm
        var title: String {
            switch self { case .icon: return "Только значок"; case .temperature: return "Температура CPU"; case .rpm: return "Обороты" }
        }
    }
    var animated = true
    var display: Display = .icon
    var speed: AnimationSpeed = .normal
    /// Tint the icon orange while the chosen mode is not in effect. Replaces
    /// `tintsWhenActive` (accent while in control), whose stored value is ignored.
    var highlightsLostControl = true

    init() {}
    private enum CodingKeys: String, CodingKey { case animated, display, speed, highlightsLostControl, showsTemperature }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        animated = try values.decodeIfPresent(Bool.self, forKey: .animated) ?? true
        speed = try values.decodeIfPresent(AnimationSpeed.self, forKey: .speed) ?? .normal
        highlightsLostControl = try values.decodeIfPresent(Bool.self, forKey: .highlightsLostControl) ?? true
        if let display = try values.decodeIfPresent(Display.self, forKey: .display) { self.display = display }
        else if try values.decodeIfPresent(Bool.self, forKey: .showsTemperature) == true { display = .temperature }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(animated, forKey: .animated)
        try values.encode(display, forKey: .display)
        try values.encode(speed, forKey: .speed)
        try values.encode(highlightsLostControl, forKey: .highlightsLostControl)
        // Keeps older FanMacly versions able to read the setting after a downgrade.
        try values.encode(display == .temperature, forKey: .showsTemperature)
    }
}

struct AppSettings: Codable, Equatable {
    /// Re-apply the last chosen mode when FanMacly starts.
    var restoreOnLaunch = true
    /// Let the helper resume the mode by itself after a protective handback.
    var autoResume = true
    /// Give control back to macOS when FanMacly quits.
    var releaseOnQuit = true
    var notifyOnSuspension = true
    var notifyOnResume = true
    var notifyOnConflict = true
    init() {}
    init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        restoreOnLaunch = try values.decodeIfPresent(Bool.self, forKey: .restoreOnLaunch) ?? defaults.restoreOnLaunch
        autoResume = try values.decodeIfPresent(Bool.self, forKey: .autoResume) ?? defaults.autoResume
        releaseOnQuit = try values.decodeIfPresent(Bool.self, forKey: .releaseOnQuit) ?? defaults.releaseOnQuit
        notifyOnSuspension = try values.decodeIfPresent(Bool.self, forKey: .notifyOnSuspension) ?? defaults.notifyOnSuspension
        notifyOnResume = try values.decodeIfPresent(Bool.self, forKey: .notifyOnResume) ?? defaults.notifyOnResume
        notifyOnConflict = try values.decodeIfPresent(Bool.self, forKey: .notifyOnConflict) ?? defaults.notifyOnConflict
    }
}

/// Rules that pick a mode for the user. App rules win over power rules.
struct AutomationSettings: Codable, Equatable {
    struct AppRule: Codable, Equatable, Identifiable {
        var id = UUID()
        var bundleID: String
        var name: String
        var selection: ModeSelection
    }
    var enabled = false
    var onPower: ModeSelection?
    var onBattery: ModeSelection?
    var lowPowerMode: ModeSelection?
    var appRules: [AppRule] = []
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        onPower = try values.decodeIfPresent(ModeSelection.self, forKey: .onPower)
        onBattery = try values.decodeIfPresent(ModeSelection.self, forKey: .onBattery)
        lowPowerMode = try values.decodeIfPresent(ModeSelection.self, forKey: .lowPowerMode)
        appRules = try values.decodeIfPresent([AppRule].self, forKey: .appRules) ?? []
    }
}
