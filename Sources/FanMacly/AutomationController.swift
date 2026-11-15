import AppKit
import IOKit.ps

/// Watches power source, Low Power Mode and running apps and reports which
/// automatic rule (if any) should pick the mode.
@MainActor final class AutomationController {
    struct Decision: Equatable {
        var selection: ModeSelection
        var reason: String
    }
    var settings = AutomationSettings() { didSet { if settings != oldValue { evaluate(powerChanged: true) } } }
    /// Called with a power-rule selection when the power state changes; it
    /// becomes the user's base selection.
    var onPowerRule: ((Decision) -> Void)?
    /// Called whenever the app-rule override changes (nil = no override).
    var onAppOverride: ((Decision?) -> Void)?
    private(set) var appOverride: Decision?
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var lastPowerKey: String?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate(powerChanged: false) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate(powerChanged: true) }
        })
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<AutomationController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.evaluate(powerChanged: true) }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        evaluate(powerChanged: true)
        if let appOverride { onAppOverride?(appOverride) }
    }

    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }

    var powerDescription: String {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "Режим энергосбережения" }
        return Self.onBattery ? "От аккумулятора" : "От сети"
    }

    func evaluate(powerChanged: Bool) {
        guard settings.enabled else {
            if appOverride != nil { appOverride = nil; onAppOverride?(nil) }
            return
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let rule = settings.appRules.first { running.contains($0.bundleID) }
        let next = rule.map { Decision(selection: $0.selection, reason: "приложение «\($0.name)»") }
        if next != appOverride { appOverride = next; onAppOverride?(next) }

        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let battery = Self.onBattery
        let key = "\(lowPower)-\(battery)"
        guard powerChanged, key != lastPowerKey else { return }
        let first = lastPowerKey == nil
        lastPowerKey = key
        let decision: Decision?
        if lowPower, let mode = settings.lowPowerMode { decision = .init(selection: mode, reason: "режим энергосбережения") }
        else if battery, let mode = settings.onBattery { decision = .init(selection: mode, reason: "питание от аккумулятора") }
        else if !battery, let mode = settings.onPower { decision = .init(selection: mode, reason: "питание от сети") }
        else { decision = nil }
        // On launch the remembered selection wins; rules apply on changes.
        if let decision, !first { onPowerRule?(decision) }
    }
}
