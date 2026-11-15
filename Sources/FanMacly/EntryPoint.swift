import Foundation
import AppKit
import ServiceManagement
import FanMaclyCore
import AppIntents

@main enum EntryPoint {
    @MainActor static func main() {
        if let action = CommandLine.arguments.dropFirst().first, ["--unregister-helper", "--register-helper", "--check-fans", "--check-controls"].contains(action) {
            setbuf(stdout, nil)
            Task { @MainActor in
                do {
                    let service = SMAppService.daemon(plistName: HelperIdentity.plist)
                    switch action {
                    case "--check-controls":
                        if #available(macOS 27.0, *) { try await ControlActionsCheck.run() }
                        else { throw FanMaclyError.message("Элементы управления требуют macOS 27.") }
                    case "--unregister-helper":
                        try await service.unregister()
                        print("Helper unregistered")
                    case "--register-helper":
                        try service.register()
                        print("Helper service status: \(service.status.rawValue)")
                    default:
                        try await HardwareCheck.run()
                    }
                    exit(0)
                } catch {
                    fputs("\(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            RunLoop.main.run()
        } else {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.delegate = delegate
            application.run()
            withExtendedLifetime(delegate) {}
        }
    }
}

@available(macOS 27.0, *)
@MainActor private enum ControlActionsCheck {
    static func run() async throws {
        let model = AppModel()
        FanModeControlRouter.handler = { action in try await model.performControlCenterAction(action) }
        defer { FanModeControlRouter.handler = nil; model.helper.disconnect() }
        var failure: Error?
        do {
            for action: FanModeControlAction in [.maximum, .profile, .automatic] {
                _ = try await FanModeControlIntent(action).perform()
                print("Control intent verified: \(action.rawValue) mode=\(model.helper.status.mode.rawValue) targets=\(model.helper.status.targets)")
                if action == .maximum {
                    let smc = SMCClient()
                    var reached = false
                    for _ in 0..<12 {
                        let fans = smc.snapshot().fans
                        if !fans.isEmpty && fans.allSatisfy({ ($0.current ?? -1) >= ($0.maximum ?? 6000) * 0.9 }) { reached = true; break }
                        try await Task.sleep(for: .seconds(1))
                    }
                    guard reached else { throw FanMaclyError.message("Максимальные обороты не подтверждены тахометрами.") }
                    print("Maximum RPM verified by tachometers")
                }
            }
        } catch { failure = error }
        // Always restore even when the intent/action check fails.
        try await model.performControlCenterAction(.automatic)
        let smc = SMCClient()
        let restored = smc.snapshot().fans
        guard !restored.isEmpty, restored.allSatisfy({ $0.manual == false }),
              smc.number("Ftst").map({ $0 == 0 }) != false else {
            throw FanMaclyError.message("После проверки не подтверждена автоматика SMC.")
        }
        print("All control intents finished; automatic mode and Ftst=0 verified")
        if let failure { throw failure }
    }
}

/// A bounded, opt-in hardware check for this signed app. Uses the exact same
/// authenticated helper, thermal limits and watchdog as the window.
@MainActor private enum HardwareCheck {
    static func run() async throws {
        let client = HelperClient()
        defer { client.disconnect() }
        let smc = SMCClient()
        let initial = smc.snapshot()
        guard !initial.fans.isEmpty, initial.error == nil else { throw FanMaclyError.message("Нет данных вентиляторов.") }
        client.refresh()
        for _ in 0..<20 where !client.connected { try await Task.sleep(for: .milliseconds(100)) }
        guard client.connected, client.status.version == HelperIdentity.protocolVersion else { throw FanMaclyError.message("Нужен обновлённый помощник \(HelperIdentity.protocolVersion).") }
        var failure: Error?
        do {
            let profileOnly = CommandLine.arguments.contains("--profile-only")
            let manualStopTest = CommandLine.arguments.contains("--manual-stop-test")
            let stopTest = CommandLine.arguments.contains("--stop-test") || manualStopTest
            let extended = CommandLine.arguments.contains("--extended") || profileOnly
            if stopTest {
                guard initial.cpuControlReading.map({ $0.celsius < 75 }) == true,
                      initial.hottestCPU.map({ $0 < 90 }) == true,
                      initial.temperature(.gpu).map({ $0 < 75 }) != false else {
                    throw FanMaclyError.message("Для короткой проверки остановки дождитесь охлаждения CPU/GPU ниже 75 °C.")
                }
                let curve = CoolingCurve(points: [.init(40, 0), .init(80, 0), .init(85, 100)], allowsFanStop: true)
                let stopMode: CoolingMode = manualStopTest ? .manual : .curve
                print("Checking zero RPM in \(stopMode.rawValue) mode; maximum 30 seconds, then restart and automatic restore")
                let zeros = Dictionary(uniqueKeysWithValues: initial.fans.map { ($0.id, 0.0) })
                client.apply(.init(mode: stopMode, targets: zeros, curve: curve))
                var consecutive = 0
                for index in 0..<30 {
                    try await poll(client)
                    let snapshot = smc.snapshot()
                    guard snapshot.cpuControlReading.map({ $0.celsius < 75 }) == true,
                          snapshot.temperature(.gpu).map({ $0 < 75 }) != false else {
                        throw FanMaclyError.message("Проверка остановлена: температура превысила предел проверки.")
                    }
                    print("Stop sample \(index + 1): targets=\(client.status.targets) actual=\(snapshot.fans.map { $0.current ?? -1 })")
                    let stopped = client.status.mode == stopMode && client.status.preparing != true &&
                        snapshot.fans.allSatisfy { fan in fan.manual == true && client.status.targets[fan.id] == 0 && fan.current == 0 }
                    consecutive = stopped ? consecutive + 1 : 0
                    if consecutive >= 3 { break }
                }
                guard consecutive >= 3 else { throw FanMaclyError.message("Полная остановка не подтверждена фактическими оборотами.") }
                print("Zero RPM verified for every fan in three consecutive readings")
                if manualStopTest {
                    client.apply(.init(mode: .system))
                    var released = false
                    for _ in 0..<20 {
                        try await poll(client)
                        let fans = smc.snapshot().fans
                        if client.status.mode == .system, client.status.restoring != true,
                           !fans.isEmpty, fans.allSatisfy({ $0.manual == false }),
                           smc.number("Ftst").map({ $0 == 0 }) != false { released = true; break }
                    }
                    guard released else { throw FanMaclyError.message("Прямой возврат из остановки в автоматику не подтверждён.") }
                    print("Direct zero-to-auto transition verified without a separate manual restart")
                }
            }
            // A stop check always verifies restart at 2500 RPM before restoring.
            let levels: [Double?] = stopTest ? [2500] : profileOnly ? [] : extended ? [nil, 3000, 1800] : [2500]
            for level in levels {
                let targets = Dictionary(uniqueKeysWithValues: initial.fans.map { fan in
                    (fan.id, max(fan.safeMinimum, min(level ?? fan.safeMinimum, fan.maximum ?? 6000)))
                })
                print("Checking manual targets: \(targets)")
                client.apply(.init(mode: .manual, targets: targets))
                var verified = false
                for _ in 0..<26 {
                    try await poll(client)
                    let snapshot = smc.snapshot()
                    let effectiveTargets = client.status.coolingBoost ? client.status.targets : targets
                    if client.status.mode == .manual, client.status.preparing != true,
                       snapshot.fans.allSatisfy({ fan in fan.manual == true && fan.current.map { abs($0 - effectiveTargets[fan.id, default: 0]) < 250 } == true }) {
                        print("Manual RPM verified\(client.status.coolingBoost ? " (maximum cooling override)" : ""): " + snapshot.fans.map { "fan \($0.id): \(Int($0.current ?? 0)) / \(Int(effectiveTargets[$0.id, default: 0]))" }.joined(separator: ", "))
                        verified = true
                        break
                    }
                }
                guard verified else { throw FanMaclyError.message("Фактические обороты не достигли цели за отведённое время.") }
                for _ in 0..<3 { try await poll(client) }
            }
            if extended {
                let saved = UserDefaults.standard.data(forKey: "coolingCurve").flatMap { try? JSONDecoder().decode(CoolingCurve.self, from: $0) }
                let curve = saved.flatMap { $0.isValid ? $0 : nil } ?? .balanced
                print("Checking temperature profile with live CPU samples")
                client.apply(.init(mode: .curve, curve: curve))
                var verified = false
                let requestedDuration = CommandLine.arguments.first(where: { $0.hasPrefix("--seconds=") }).flatMap { Int($0.dropFirst("--seconds=".count)) } ?? 24
                let duration = min(120, max(24, requestedDuration))
                for index in 0..<duration {
                    try await poll(client)
                    let snapshot = smc.snapshot()
                    if client.status.mode == .curve, client.status.preparing != true,
                       snapshot.fans.allSatisfy({ fan in fan.manual == true && fan.current.map { abs($0 - client.status.targets[fan.id, default: 0]) < 400 } == true }) { verified = true }
                    if index % 2 == 0 { print("Curve sample: t=\(index + 1) mode=\(client.status.mode.rawValue) pending=\(client.status.preparing == true) filtered=\(client.status.controlTemperature ?? -1) rawPeak=\(snapshot.hottestCPU ?? -1) source=\(client.status.temperatureSource ?? "none") \(smc.fanDiagnostics())") }
                }
                guard verified else { throw FanMaclyError.message("Температурный профиль не подтверждён.") }
                print("Temperature profile verified for \(duration) seconds")
            }
        } catch { failure = error }
        // Restoration is mandatory even after a failed check.
        for _ in 0..<60 where client.busy {
            client.refresh()
            try await Task.sleep(for: .milliseconds(100))
        }
        client.apply(.init(mode: .system))
        var restorationConfirmed = false
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            client.refresh()
            let restored = smc.snapshot()
            if !client.busy, client.status.mode == .system, client.status.restoring != true,
               restored.fans.allSatisfy({ $0.manual == false }), smc.number("Ftst").map({ $0 == 0 }) ?? true {
                restorationConfirmed = true
                break
            }
        }
        guard client.error == nil, restorationConfirmed else {
            throw FanMaclyError.message("Возврат автоматики не подтверждён: \(client.error ?? "проверьте SMC").")
        }
        print("Automatic mode restored for all fans")
        if let failure { throw failure }
    }

    private static func poll(_ client: HelperClient) async throws {
        client.refresh()
        try await Task.sleep(for: .seconds(1))
        if let error = client.error ?? client.status.message { throw FanMaclyError.message(error) }
        if let event = client.status.thermalEvent { throw FanMaclyError.message(event.detail) }
        guard client.connected else { throw FanMaclyError.message("Нет связи с помощником.") }
    }
}
