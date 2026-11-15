import AppKit
import Observation
import WidgetKit
import FanMaclyCore

private actor HardwareMonitor {
    private let hardware = SMCClient()
    private let power = PowerSampler()
    func read() -> (HardwareSnapshot, PowerReading?) { (hardware.snapshot(), power.sample()) }
    func fanDiagnostics() -> String { hardware.fanDiagnostics() }
}

/// High-level state shown in the header, menu bar and banners.
enum ControlState: Equatable {
    case setupNeeded
    case connecting
    case macOS
    case applying
    case active
    case reacquiring
    case suspended(ControlSuspension)
}

enum TemperatureLevel {
    case cool, normal, warm, hot
    static func cpu(_ value: Double?) -> TemperatureLevel {
        guard let value else { return .normal }
        switch value { case ..<60: return .cool; case ..<90: return .normal; case ..<100: return .warm; default: return .hot }
    }
    static func gpu(_ value: Double?) -> TemperatureLevel { cpu(value) }
    static func battery(_ value: Double?) -> TemperatureLevel {
        guard let value else { return .normal }
        switch value { case ..<30: return .cool; case ..<40: return .normal; case ..<45: return .warm; default: return .hot }
    }
}

@MainActor @Observable final class AppModel {
    // MARK: Telemetry
    var snapshot = HardwareSnapshot()
    var power: PowerReading?
    var loading = true
    var sleeping = false
    private(set) var history = HistoryStore()
    private var localCPUTemperature: Double?
    @ObservationIgnored private var cpuFilter = CPUTemperatureFilter()

    // MARK: Control
    let helper = HelperClient()
    /// The mode the user (or a power rule) picked. Persisted.
    private(set) var userSelection: ModeSelection = .automatic
    private(set) var appOverride: AutomationController.Decision?
    private(set) var focusOverride: ModeSelection?
    private(set) var ruleReason: String?
    @ObservationIgnored private var suppressedOverride: AutomationController.Decision?
    /// Optimistic UI until the helper confirms the new intent.
    private(set) var pendingSelection: ModeSelection?
    private(set) var lastNonAutomatic: ModeSelection = .preset(.balanced)
    var manualTargets: [Int: Double] = [:]
    var manualLinked = true
    var transientError: String?

    // MARK: Profiles & settings
    private(set) var profileLibrary = ProfileLibrary()
    var settings = AppSettings() { didSet { save(settings, "appSettings") } }
    var menuBarSettings = MenuBarSettings() { didSet { save(menuBarSettings, "menuBarSettings") } }
    var automationSettings = AutomationSettings() {
        didSet { save(automationSettings, "automationSettings"); automation.settings = automationSettings }
    }
    var conflicts: [FanControlConflict] = []
    private(set) var dismissedConflicts: Set<String> = []
    var panelVisible = false

    @ObservationIgnored let automation = AutomationController()
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let reader = HardwareMonitor()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var manualCommit: Task<Void, Never>?
    @ObservationIgnored private var seenEvents = Set<UUID>()
    @ObservationIgnored private var adoptedHelperState = false
    @ObservationIgnored private var applyMissedWhileDisconnected = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var notifiedConflicts = Set<String>()

    init(defaults: UserDefaults = .standard, startMonitoring: Bool = true) {
        self.defaults = defaults
        loadSettings()
        helper.onStatusReceived = { [weak self] in self?.helperStatusChanged() }
        helper.onDisconnect = { [weak self] in self?.pendingSelection = nil }
        guard startMonitoring else { return }
        notifier.configure()
        notifier.onResume = { [weak self] in self?.resume() }
        automation.onAppOverride = { [weak self] decision in self?.appOverrideChanged(decision) }
        automation.onPowerRule = { [weak self] decision in
            guard let self else { return }
            self.ruleReason = decision.reason
            self.setUserSelection(decision.selection)
        }
        automation.settings = automationSettings
        automation.start()
        startMonitoringLoops()
    }

    // MARK: - Derived state

    var hasFans: Bool { !snapshot.fans.isEmpty }
    var canControl: Bool { helper.connected && hasFans && !sleeping }

    /// The selection that should be active once automation and Focus are applied.
    var effectiveSelection: ModeSelection {
        if let focusOverride { return focusOverride }
        if let appOverride, appOverride != suppressedOverride { return appOverride.selection }
        return userSelection
    }
    /// What the helper reports as the user's intent.
    var activeSelection: ModeSelection {
        guard helper.connected else { return effectiveSelection }
        guard let intent = helper.status.intent else { return .automatic }
        return ModeSelection(key: intent.profileID) ?? (intent.mode == .manual ? .manual : .preset(.balanced))
    }
    var displayedSelection: ModeSelection { pendingSelection ?? activeSelection }

    var overrideReason: String? {
        if focusOverride != nil { return "Фокусирование" }
        if let appOverride, appOverride != suppressedOverride { return appOverride.reason }
        return nil
    }

    var boostUntil: Date? {
        guard let until = helper.status.intent?.boost?.until, until > Date() else { return nil }
        return until
    }

    var controlState: ControlState {
        if !helper.connected {
            if helper.needsUpdate || helper.serviceStatus != .enabled || !helper.signedForControl { return .setupNeeded }
            return .connecting
        }
        if let suspension = helper.status.suspension { return .suspended(suspension) }
        if helper.status.reacquiring { return .reacquiring }
        // `preparing` and `restoring` only matter while the fans are not yet
        // (or no longer) ours. Once in control, `preparing` also flips on for a
        // second at every target step of a curve, which is not "applying".
        let inTransition = helper.status.mode == .system &&
            (helper.status.preparing == true || helper.status.restoring == true)
        if pendingSelection != nil || inTransition { return .applying }
        return helper.status.mode == .system ? .macOS : .active
    }

    func title(for selection: ModeSelection) -> String {
        switch selection {
        case .automatic: return "Авто"
        case .preset(let preset): return preset.title
        case .profile(let id): return profileLibrary.profiles.first { $0.id == id }?.name ?? "Профиль"
        case .manual: return "Вручную"
        case .maximum: return "Максимум"
        }
    }
    func symbol(for selection: ModeSelection) -> String {
        switch selection {
        case .automatic: return "a.circle"
        case .preset(let preset): return preset.symbol
        case .profile: return "slider.horizontal.3"
        case .manual: return "hand.point.up.left"
        case .maximum: return "wind"
        }
    }

    /// All options for pickers (settings, rules, intents).
    var selectionOptions: [SelectionOption] {
        var options: [SelectionOption] = [.init(selection: .automatic, title: "Авто (macOS)", symbol: symbol(for: .automatic))]
        options += CoolingPreset.allCases.map { .init(selection: .preset($0), title: $0.title, symbol: $0.symbol) }
        options += profileLibrary.profiles.map { .init(selection: .profile($0.id), title: $0.name, symbol: "slider.horizontal.3") }
        options.append(.init(selection: .maximum, title: "Максимум", symbol: symbol(for: .maximum)))
        return options
    }

    var cpuTemperature: Double? {
        guard !sleeping, snapshot.error == nil else { return nil }
        if helper.connected, let value = helper.status.controlTemperature { return value }
        return localCPUTemperature
    }
    var cpuSource: String? { helper.connected ? helper.status.temperatureSource ?? snapshot.cpuControlReading?.source : snapshot.cpuControlReading?.source }
    var averageRPM: Double? {
        let values = snapshot.fans.compactMap(\.current)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    var cpuDiagnosticText: String {
        let reading = snapshot.cpuControlReading
        let source = cpuSource ?? "нет данных"
        let raw = helper.connected ? helper.status.rawControlTemperature : reading?.celsius
        let peak = helper.connected ? helper.status.peakCPUReading : snapshot.cpuPeakReading
        let meaning = source == reading?.source ? reading?.description : nil
        return "Источник: \(source). \(meaning ?? "")\n" +
            "Исходное: \(temperature(raw)); сглаженное для профиля: \(temperature(cpuTemperature)).\n" +
            "Самое горячее ядро: \(temperature(peak?.celsius)) (\(peak?.source ?? "нет данных")).\n" +
            "Профиль использует сглаженное значение (медиана 3 отсчётов, 5\u{00A0}с на нагреве, 15\u{00A0}с на охлаждении). " +
            "Максимальное охлаждение включается при CPU ≥ 95°, ядре ≥ 105° дольше 5\u{00A0}с, GPU ≥ 95° или сильном нагреве по оценке macOS.\n" +
            "Расшифровка ключей SMC основана на iSMC/OSHI; это не документированный API Apple."
    }

    // MARK: - Selection

    func select(_ selection: ModeSelection) {
        transientError = nil
        focusOverride = nil
        if let appOverride { suppressedOverride = appOverride }
        ruleReason = nil
        // Picking the suspended mode again is an explicit "try again".
        setUserSelection(selection, force: helper.status.suspension != nil && selection == activeSelection)
    }

    private func setUserSelection(_ selection: ModeSelection, force: Bool = false) {
        userSelection = selection
        rememberAsProfile(selection)
        save(selection, "selection")
        save(lastNonAutomatic, "lastNonAutomatic")
        applyEffective(force: force)
    }

    /// «Профиль» (Control Center, the profile editor) means a temperature
    /// profile, never Авто, Макс or manual speeds.
    private func rememberAsProfile(_ selection: ModeSelection) {
        switch selection {
        case .preset, .profile: lastNonAutomatic = selection
        default: break
        }
    }

    func setFocusOverride(_ selection: ModeSelection?) {
        focusOverride = selection
        applyEffective()
    }

    private func appOverrideChanged(_ decision: AutomationController.Decision?) {
        if decision != appOverride { suppressedOverride = nil }
        appOverride = decision
        applyEffective()
    }

    /// Send the effective selection to the helper if it differs from its intent.
    func applyEffective(force: Bool = false) {
        // A choice made while the helper is reconnecting is sent once it is back.
        guard helper.connected else { applyMissedWhileDisconnected = adoptedHelperState; return }
        applyMissedWhileDisconnected = false
        let selection = effectiveSelection
        // A running boost carries over; it returns to macOS only if the new mode is Авто.
        guard var request = request(for: selection, boost: boostUntil.map { BoostRequest(until: $0, thenSystem: selection == .automatic) }) else { return }
        request.fromRule = overrideReason != nil
        let current = helper.status.intent
        if !force {
            if request.mode == .system && current == nil { return }
            // A suspension waiting for the user is only retried through resume()/select().
            if let current, current.profileID == request.profileID, current.mode == request.mode,
               current.curve == request.curve, current.targets == request.targets, current.boost == request.boost,
               current.autoResume == request.autoResume, current.fromRule == request.fromRule { return }
        }
        send(request, showing: selection)
    }

    private func send(_ request: ControlRequest, showing selection: ModeSelection) {
        pendingSelection = selection
        helper.apply(request) { [weak self] error in
            guard let self else { return }
            if self.pendingSelection == selection { self.pendingSelection = nil }
            if let error { self.transientError = error }
        }
    }

    func request(for selection: ModeSelection, boost: BoostRequest? = nil) -> ControlRequest? {
        let resume = settings.autoResume
        switch selection {
        case .automatic:
            guard let boost else { return ControlRequest(mode: .system) }
            guard let targets = maximumTargets() else { return nil }
            return ControlRequest(mode: .manual, targets: targets, profileID: selection.key, profileName: "Авто",
                                  boost: BoostRequest(until: boost.until, thenSystem: true), autoResume: resume)
        case .preset(let preset):
            return ControlRequest(mode: .curve, curve: preset.curve, profileID: selection.key, profileName: preset.title, boost: boost, autoResume: resume)
        case .profile(let id):
            guard let profile = profileLibrary.profiles.first(where: { $0.id == id }) else {
                return request(for: .preset(.balanced), boost: boost)
            }
            return ControlRequest(mode: .curve, curve: profile.curve, profileID: selection.key, profileName: profile.name, boost: boost, autoResume: resume)
        case .manual:
            guard hasFans else { return nil }
            var targets: [Int: Double] = [:]
            for fan in snapshot.fans {
                targets[fan.id] = manualTargets[fan.id] ?? max(fan.safeMinimum, min(fan.current ?? fan.safeMinimum, fan.maximum ?? fan.safeMinimum))
            }
            return ControlRequest(mode: .manual, targets: targets, profileID: selection.key, profileName: "Вручную", boost: boost, autoResume: resume)
        case .maximum:
            guard let targets = maximumTargets() else { return nil }
            return ControlRequest(mode: .manual, targets: targets, profileID: selection.key, profileName: "Максимум", boost: boost, autoResume: resume)
        }
    }

    private func maximumTargets() -> [Int: Double]? {
        guard hasFans else { return nil }
        return Dictionary(uniqueKeysWithValues: snapshot.fans.map { ($0.id, $0.maximum ?? $0.safeMinimum) })
    }

    /// Re-send the current intent after a suspension that needs the user.
    func resume() {
        transientError = nil
        applyEffective(force: true)
    }

    // MARK: - Boost

    /// Returns false when nothing could be sent (no helper or no fan data).
    @discardableResult func startBoost(minutes: Int) -> Bool {
        guard helper.connected else { return false }
        let until = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        let base = effectiveSelection
        guard let request = request(for: base, boost: BoostRequest(until: until, thenSystem: base == .automatic)) else { return false }
        transientError = nil
        send(request, showing: base)
        return true
    }

    func cancelBoost() {
        guard helper.connected, let request = request(for: effectiveSelection, boost: nil) else { return }
        send(request, showing: effectiveSelection)
    }

    // MARK: - Manual

    func setManualTarget(_ rpm: Double, fan id: Int, commit: Bool) {
        guard let reading = snapshot.fans.first(where: { $0.id == id }), let maximum = reading.maximum else { return }
        let value = rpm == 0 ? 0 : max(reading.safeMinimum, min(rpm, maximum))
        manualTargets[id] = value
        if manualLinked {
            let position = ManualFanSpeedScale(fan: reading).position(for: value)
            for other in snapshot.fans where other.id != id {
                manualTargets[other.id] = ManualFanSpeedScale(fan: other).rpm(at: position)
            }
        }
        save(manualTargets.map { ManualTarget(fan: $0.key, rpm: $0.value) }, "manualTargets")
        guard commit else { return }
        manualCommit?.cancel()
        manualCommit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            if self.effectiveSelection == .manual { self.applyEffective() } else { self.select(.manual) }
        }
    }

    // MARK: - Profiles

    func curve(for selection: ModeSelection) -> CoolingCurve? {
        switch selection {
        case .preset(let preset): return preset.curve
        case .profile(let id): return profileLibrary.profiles.first { $0.id == id }?.curve
        default: return nil
        }
    }

    @discardableResult
    func saveProfile(name: String, curve: CoolingCurve, replacing id: UUID? = nil) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !CoolingPreset.allCases.map(\.title).contains(trimmed) else {
            throw FanMaclyError.message("Выберите название, отличающееся от встроенных профилей.")
        }
        var next = profileLibrary
        let saved = try next.save(name: trimmed, curve: curve, replacing: id)
        defaults.set(try next.encoded(), forKey: "savedCoolingProfiles")
        profileLibrary = next
        if case .profile(let active) = effectiveSelection, active == saved { applyEffective() }
        return saved
    }

    func deleteProfile(_ id: UUID) {
        var next = profileLibrary
        next.remove(id)
        guard let data = try? next.encoded() else { return }
        defaults.set(data, forKey: "savedCoolingProfiles")
        profileLibrary = next
        if userSelection == .profile(id) { setUserSelection(.preset(.balanced)) }
        if lastNonAutomatic == .profile(id) {
            lastNonAutomatic = .preset(.balanced)
            save(lastNonAutomatic, "lastNonAutomatic")
        }
    }

    func uniqueProfileName(_ base: String) -> String {
        let names = Set(profileLibrary.profiles.map(\.name) + CoolingPreset.allCases.map(\.title))
        if !names.contains(base) { return base }
        for index in 2...999 where !names.contains("\(base) \(index)") { return "\(base) \(index)" }
        return base + " " + UUID().uuidString.prefix(4)
    }

    // MARK: - Conflicts

    func dismissConflict(_ conflict: FanControlConflict) {
        dismissedConflicts.insert(conflict.name)
        defaults.set(Array(dismissedConflicts), forKey: "dismissedConflicts")
    }
    var visibleConflicts: [FanControlConflict] { conflicts.filter { !dismissedConflicts.contains($0.name) } }

    // MARK: - Lifecycle

    /// Return control to macOS on quit (if enabled), waiting briefly for the helper.
    func prepareForQuit() async {
        guard settings.releaseOnQuit else { return }
        if !helper.connected && helper.serviceStatus == .enabled {
            // Briefly reconnect so quitting still hands control back to macOS.
            for _ in 0..<15 where !helper.connected {
                helper.refresh()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard helper.connected, helper.status.intent != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            helper.apply(ControlRequest(mode: .system)) { _ in
                if !resumed { resumed = true; continuation.resume() }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if !resumed { resumed = true; continuation.resume() }
            }
        }
        // The widget must not keep showing «FanMacly управляет» after quitting.
        publishWidgetSnapshot(force: true)
    }

    func performControlCenterAction(_ action: FanModeControlAction) async throws {
        let selection: ModeSelection
        switch action {
        case .automatic: selection = .automatic
        case .profile: selection = lastNonAutomatic
        case .maximum: selection = .maximum
        }
        try await perform(selection)
    }

    /// Used by App Intents and Control Center: select and wait for confirmation.
    func perform(_ selection: ModeSelection) async throws {
        for _ in 0..<50 where !helper.connected || (selection != .automatic && !hasFans) {
            helper.refresh()
            try await Task.sleep(for: .milliseconds(100))
        }
        guard helper.connected else { throw FanMaclyError.message(helper.error ?? "Нет связи с системным компонентом FanMacly.") }
        select(selection)
        for _ in 0..<100 {
            // Without a connection activeSelection is only the local choice.
            if helper.connected, activeSelection == selection, pendingSelection == nil { return }
            if let error = transientError { throw FanMaclyError.message(error) }
            helper.refresh()
            try await Task.sleep(for: .milliseconds(100))
        }
        throw FanMaclyError.message("FanMacly не подтвердил смену режима.")
    }

    func diagnosticReport() async -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let status = (try? encoder.encode(helper.status)).map { String(decoding: $0, as: UTF8.self) } ?? "—"
        let registers = await reader.fanDiagnostics()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return """
        FanMacly \(version) · протокол \(HelperIdentity.protocolVersion) · \(ProcessInfo.processInfo.operatingSystemVersionString)
        Компонент: \(helper.serviceStatus.rawValue), подключён: \(helper.connected)
        Выбор: \(effectiveSelection.key), активно: \(activeSelection.key), правило: \(overrideReason ?? ruleReason ?? "нет")
        Конфликты: \(conflicts.map(\.name).joined(separator: ", ").ifEmpty("нет"))
        SMC: \(registers)
        \(cpuDiagnosticText)

        Состояние помощника:
        \(status)
        """
    }

    func exportSnapshot() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FanMacly-sensors.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch { transientError = error.localizedDescription }
    }

    // MARK: - Private

    private func startMonitoringLoops() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The helper keeps the intent across sleep; only pause polling.
                self?.sleeping = true
                self?.cpuFilter.reset(); self?.localCPUTemperature = nil
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleeping = false
                self?.helper.refresh()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.sleeping { self.helper.refresh() }
                try? await Task.sleep(for: .seconds(self.panelVisible ? 1 : 2))
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.sleeping {
                    let (value, power) = await self.reader.read()
                    if !self.sleeping { self.receive(value, power: power) }
                }
                try? await Task.sleep(for: .seconds(self.panelVisible ? 1 : 2))
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) { ConflictDetector.scan() }.value
                guard let self else { return }
                self.conflictsChanged(found)
                try? await Task.sleep(for: .seconds(60))
            }
        })
    }

    private func receive(_ value: HardwareSnapshot, power: PowerReading?) {
        snapshot = value
        if let power { self.power = power }
        loading = false
        localCPUTemperature = cpuFilter.update(reading: value.error == nil ? value.cpuControlReading : nil, now: ProcessInfo.processInfo.systemUptime)
        history.append(HistorySample(date: value.date, cpu: cpuTemperature, gpu: value.temperature(.gpu),
                                     fans: value.fans.map(\.current),
                                     targets: value.fans.map { helper.connected ? helper.status.targets[$0.id] : nil },
                                     cpuWatts: power?.cpuWatts, gpuWatts: power?.gpuWatts))
        publishWidgetSnapshot()
        // A manual/maximum intent waits for fan data on a cold start.
        if helper.connected, adoptedHelperState, pendingSelection == nil, helper.status.intent == nil,
           effectiveSelection != .automatic, !helper.busy, value.error == nil, !value.fans.isEmpty,
           helper.status.suspension == nil, launchApplyPending {
            launchApplyPending = false
            applyEffective()
        }
    }
    @ObservationIgnored private var launchApplyPending = false

    @ObservationIgnored private var lastWidgetWrite = Date.distantPast
    @ObservationIgnored private var lastWidgetKey = ""

    /// Share a small summary with the desktop widget (App Group container).
    private func publishWidgetSnapshot(force: Bool = false) {
        guard WidgetSnapshot.appGroup != nil else { return }
        let selection = displayedSelection
        let warning: Bool = {
            switch controlState { case .suspended, .reacquiring: return true; default: return helper.status.coolingBoost || boostUntil != nil }
        }()
        let state: String = {
            switch controlState {
            case .setupNeeded: return "Только мониторинг"
            case .connecting: return "Подключение…"
            case .macOS: return boostUntil != nil ? "Буст" : "Управляет macOS"
            case .applying: return "Применяем…"
            case .reacquiring: return "Возвращаем управление"
            case .suspended: return "Временно у macOS"
            case .active: return helper.status.coolingBoost ? "Максимальное охлаждение" : "FanMacly управляет"
            }
        }()
        let key = "\(selection.key)|\(state)|\(warning)"
        let now = Date()
        guard force || key != lastWidgetKey || now.timeIntervalSince(lastWidgetWrite) >= 60 else { return }
        WidgetSnapshot(date: now, mode: title(for: selection), symbol: symbol(for: selection), state: state,
                       active: controlState == .active, warning: warning, cpu: cpuTemperature,
                       gpu: snapshot.temperature(.gpu), fans: snapshot.fans.compactMap(\.current)).save()
        if force || key != lastWidgetKey { WidgetCenter.shared.reloadTimelines(ofKind: "app.fanmacly.widget.status") }
        lastWidgetKey = key
        lastWidgetWrite = now
    }

    private func helperStatusChanged() {
        let status = helper.status
        if !adoptedHelperState {
            adoptedHelperState = true
            if let intent = status.intent {
                // The helper kept a mode while the app was not running. A mode
                // chosen by a rule is not the user's own choice.
                if intent.fromRule {
                    if appOverride == nil && focusOverride == nil { applyEffective() }
                } else if let selection = ModeSelection(key: intent.profileID), focusOverride == nil, appOverride == nil {
                    userSelection = selection
                    rememberAsProfile(selection)
                }
            } else if settings.restoreOnLaunch && effectiveSelection != .automatic {
                launchApplyPending = true
                if hasFans { launchApplyPending = false; applyEffective() }
            } else if !settings.restoreOnLaunch, appOverride == nil {
                userSelection = .automatic
            }
            // Mark old events as seen so a relaunch does not re-notify.
            seenEvents.formUnion(status.events.map(\.id))
        } else if appOverride != nil || focusOverride != nil || applyMissedWhileDisconnected {
            applyEffective()
        }
        // The helper confirmed a request late (HelperClient cleared its timeout).
        if transientError == HelperClient.timeoutMessage, helper.error != HelperClient.timeoutMessage { transientError = nil }
        if let pending = pendingSelection, activeSelection == pending { pendingSelection = nil }
        for event in status.events where !seenEvents.contains(event.id) {
            seenEvents.insert(event.id)
            switch event.kind {
            case .suspended where settings.notifyOnSuspension:
                notifier.post(title: "Режим приостановлен", body: [event.title, event.detail].compactMap { $0 }.joined(separator: " "),
                              resumable: status.suspension?.needsUser == true)
            case .resumed where settings.notifyOnResume:
                notifier.post(title: event.title, body: event.detail ?? "FanMacly снова управляет вентиляторами.")
            default: break
            }
        }
    }

    private func conflictsChanged(_ found: [FanControlConflict]) {
        conflicts = found
        for conflict in found where !notifiedConflicts.contains(conflict.name) && !dismissedConflicts.contains(conflict.name) {
            notifiedConflicts.insert(conflict.name)
            if settings.notifyOnConflict {
                notifier.post(title: "Обнаружено: \(conflict.name)", body: conflict.detail)
            }
        }
    }

    private func loadSettings() {
        settings = load("appSettings") ?? AppSettings()
        menuBarSettings = load("menuBarSettings") ?? MenuBarSettings()
        automationSettings = load("automationSettings") ?? AutomationSettings()
        dismissedConflicts = Set(defaults.stringArray(forKey: "dismissedConflicts") ?? [])
        if let data = defaults.data(forKey: "savedCoolingProfiles") {
            do { profileLibrary = try ProfileLibrary(data: data) }
            catch {
                defaults.set(data, forKey: "savedCoolingProfiles.recoveryBackup")
                transientError = "Не удалось прочитать профили. Исходные данные сохранены в резервной копии настроек."
            }
        }
        if let targets: [ManualTarget] = load("manualTargets") {
            manualTargets = Dictionary(targets.map { ($0.fan, $0.rpm) }, uniquingKeysWith: { $1 })
        }
        lastNonAutomatic = load("lastNonAutomatic") ?? .preset(.balanced)
        switch lastNonAutomatic {
        case .preset: break
        case .profile(let id) where profileLibrary.profiles.contains(where: { $0.id == id }): break
        default: lastNonAutomatic = .preset(.balanced)
        }
        if let selection: ModeSelection = load("selection") {
            userSelection = selection
        } else {
            userSelection = migrateLegacySelection()
            save(userSelection, "selection")
        }
        if case .profile(let id) = userSelection, !profileLibrary.profiles.contains(where: { $0.id == id }) {
            userSelection = .preset(.balanced)
        }
    }

    /// Versions before 1.0 stored a working curve and an active profile ID.
    private func migrateLegacySelection() -> ModeSelection {
        if let raw = defaults.string(forKey: "activeProfileID"), let id = UUID(uuidString: raw),
           profileLibrary.profiles.contains(where: { $0.id == id }) {
            lastNonAutomatic = .profile(id)
            return .automatic
        }
        if let data = defaults.data(forKey: "coolingCurve"), let curve = try? JSONDecoder().decode(CoolingCurve.self, from: data), curve.isValid {
            let name = defaults.string(forKey: "profileName") ?? "Мой профиль"
            switch name {
            case "Прохладный": lastNonAutomatic = .preset(.cool)
            case "Сбалансированный": lastNonAutomatic = .preset(.balanced)
            default:
                if let id = try? saveProfile(name: uniqueProfileName(name == "Тихий" ? "Мой профиль" : name), curve: curve) {
                    lastNonAutomatic = .profile(id)
                }
            }
        }
        save(lastNonAutomatic, "lastNonAutomatic")
        return .automatic
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    private func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

struct ManualTarget: Codable { let fan: Int; let rpm: Double }

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

func temperature(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))°" } ?? "—" }
func rpm(_ value: Double?) -> String { value.map { "\(Int($0.rounded()).formatted()) об/мин" } ?? "—" }
func rpmNumber(_ value: Double?) -> String { value.map { Int($0.rounded()).formatted() } ?? "—" }
func watts(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value < 10 ? String(format: "%.1f Вт", value) : "\(Int(value.rounded())) Вт"
}
