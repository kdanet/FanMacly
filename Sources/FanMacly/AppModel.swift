import AppKit
import Observation
import FanMaclyCore

private actor HardwareMonitor {
    private let hardware = SMCClient()
    func snapshot() -> HardwareSnapshot { hardware.snapshot() }
}

@MainActor @Observable final class AppModel {
    var snapshot = HardwareSnapshot()
    var loading = true
    var targets: [Int: Double] = [:]
    var curve: CoolingCurve = .balanced
    var profileName = "Сбалансированный"
    var selectedMode: CoolingMode = .system
    private(set) var profileLibrary = ProfileLibrary()
    private(set) var activeProfileID: UUID?
    var menuBarSettings = MenuBarSettings()
    private(set) var hasPendingControl = false
    var exportError: String?
    let helper = HelperClient()
    @ObservationIgnored private let defaults: UserDefaults
    private let reader = HardwareMonitor()
    @ObservationIgnored private var cpuFilter = CPUTemperatureFilter()
    private var localCPUTemperature: Double?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var heartbeatMonitor: Task<Void, Never>?
    @ObservationIgnored private var liveControlTask: Task<Void, Never>?
    @ObservationIgnored private var liveControlID = UUID()
    @ObservationIgnored private var sliderEditing = false
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    var sleeping = false

    init(defaults: UserDefaults = .standard, startMonitoring: Bool = true) {
        self.defaults = defaults
        helper.onDisconnect = { [weak self] in
            self?.cancelPendingControl()
            self?.sliderEditing = false
            self?.selectedMode = .system
        }
        helper.onAutomaticFallback = { [weak self] in
            self?.cancelPendingControl()
            self?.sliderEditing = false
            self?.selectedMode = .system
        }
        helper.onStatusReceived = { [weak self] in self?.reconcileControlState() }
        if let data = defaults.data(forKey: "coolingCurve"),
           let saved = try? JSONDecoder().decode(CoolingCurve.self, from: data), saved.isValid {
            curve = saved
            profileName = defaults.string(forKey: "profileName") ?? "Мой профиль"
        }
        if let data = defaults.data(forKey: "menuBarSettings"), let value = try? JSONDecoder().decode(MenuBarSettings.self, from: data) {
            menuBarSettings = value
        }
        if let data = defaults.data(forKey: "savedCoolingProfiles") {
            do { profileLibrary = try ProfileLibrary(data: data) }
            catch {
                defaults.set(data, forKey: "savedCoolingProfiles.recoveryBackup")
                exportError = "Не удалось прочитать профили. Исходные данные сохранены в резервной копии настроек."
            }
        } else if curve != .balanced && curve != .cool {
            activeProfileID = try? profileLibrary.save(name: profileName, curve: curve)
            if let data = try? profileLibrary.encoded() { defaults.set(data, forKey: "savedCoolingProfiles") }
            defaults.set(activeProfileID?.uuidString, forKey: "activeProfileID")
        }
        if let raw = defaults.string(forKey: "activeProfileID"), let id = UUID(uuidString: raw), profileLibrary.profiles.contains(where: { $0.id == id }) {
            activeProfileID = id
        }
        if let activeSavedProfile { profileName = activeSavedProfile.name }
        guard startMonitoring else { return }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = true; self?.helper.disconnect(); self?.selectedMode = .system
                self?.cancelPendingControl()
                self?.sliderEditing = false
                self?.cpuFilter.reset(); self?.localCPUTemperature = nil
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false }
        }
        // Measure UI-process liveness, independently of a potentially slow
        // IOKit sensor read. The helper performs its own fresh sensor checks.
        // This task still stops when the main actor or the app is suspended.
        heartbeatMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.sleeping { self.helper.refresh() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.sleeping {
                    let value = await self.readSnapshot()
                    guard !self.sleeping else { continue }
                    self.snapshot = value
                    if !self.canControl { self.sliderEditing = false }
                    self.loading = false
                    self.localCPUTemperature = self.cpuFilter.update(reading: value.error == nil ? value.cpuControlReading : nil, now: ProcessInfo.processInfo.systemUptime)
                    if value.error == nil {
                        for fan in value.fans where self.targets[fan.id] == nil {
                            self.targets[fan.id] = max(fan.safeMinimum, min(fan.current ?? fan.safeMinimum, fan.maximum ?? 6000))
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func readSnapshot() async -> HardwareSnapshot {
        await reader.snapshot()
    }
    var hasFans: Bool { !snapshot.fans.isEmpty }
    var activeSavedProfile: SavedCoolingProfile? { profileLibrary.profiles.first { $0.id == activeProfileID } }
    var profileIsModified: Bool { activeSavedProfile.map { $0.curve != curve } ?? false }
    var controlPending: Bool {
        hasPendingControl || helper.busy || helper.status.preparing == true || helper.status.restoring == true
    }
    var cpuTemperature: Double? {
        guard !sleeping, snapshot.error == nil else { return nil }
        if helper.connected, let value = helper.status.controlTemperature { return value }
        return localCPUTemperature
    }
    var cpuSource: String? { helper.connected ? helper.status.temperatureSource ?? snapshot.cpuControlReading?.source : snapshot.cpuControlReading?.source }
    var cpuDiagnosticText: String {
        let reading = snapshot.cpuControlReading
        let source = cpuSource ?? "нет данных"
        let raw = helper.connected ? helper.status.rawControlTemperature : reading?.celsius
        let peak = helper.connected ? helper.status.peakCPUReading : snapshot.cpuPeakReading
        let sampled = helper.connected ? helper.status.temperatureSampleDate : snapshot.date
        let meaning = source == reading?.source ? reading?.description : nil
        return "Источник: \(source). \(meaning ?? "Назначение показания см. в справочнике датчиков.")\n" +
            "Исходное: \(temperature(raw)); сглаженное для профиля: \(temperature(cpuTemperature)).\n" +
            "Мгновенный максимум CPU: \(temperature(peak?.celsius)) (\(peak?.source ?? "нет данных")).\n" +
            "Отсчёт: \(sampled?.formatted(date: .omitted, time: .standard) ?? "нет данных").\n" +
            "Медиана 3 отсчётов; сглаживание 5 с при нагреве и 15 с при охлаждении. При смене источника фильтр сбрасывается. Защита использует исходные значения.\n" +
            "Расшифровка SMC основана на iSMC/OSHI; это не документированный Apple API температуры."
    }
    func saveMenuBarSettings() {
        if let data = try? JSONEncoder().encode(menuBarSettings) { defaults.set(data, forKey: "menuBarSettings") }
    }
    var canControl: Bool {
        helper.connected && helper.status.customControlAllowed != false && snapshot.error == nil && !sleeping &&
        hasFans && snapshot.fans.allSatisfy(\.controllable) && snapshot.hottestCPU != nil
    }
    var modeTitle: String {
        if helper.connected && helper.status.restoring == true { return "Возврат автоматики…" }
        if helper.connected && helper.status.preparing == true { return "Применение настроек…" }
        if helper.connected { return helper.status.mode == .system ? "Управляет macOS" : helper.status.mode.title }
        return "Мониторинг"
    }
    var statusText: String {
        if loading { return "Подключение к датчикам" }
        if sleeping { return "Mac переходит в сон" }
        if snapshot.error != nil { return "Датчики недоступны" }
        return "Данные в реальном времени"
    }
    func performControlCenterAction(_ action: FanModeControlAction) async throws {
        for _ in 0..<50 where !helper.connected || (action != .automatic && loading) {
            helper.refresh()
            try await Task.sleep(for: .milliseconds(100))
        }
        guard helper.connected else { throw FanMaclyError.message(helper.error ?? "Нет связи с помощником FanMacly.") }
        switch action {
        case .automatic: restore()
        case .profile:
            guard canControl else { throw FanMaclyError.message("Температурное управление сейчас недоступно.") }
            selectMode(.curve)
        case .maximum:
            guard canControl else { throw FanMaclyError.message("Ручное управление сейчас недоступно.") }
            for fan in snapshot.fans { setTarget(fan.maximum ?? fan.safeMinimum, fan: fan.id, commit: false) }
            selectMode(.manual)
        }
        let generation = liveControlID
        let expected: CoolingMode = action == .automatic ? .system : action == .profile ? .curve : .manual
        for _ in 0..<220 {
            guard generation == liveControlID else { throw FanMaclyError.message("Режим уже изменён другим действием.") }
            if !controlPending {
                if let error = helper.error ?? helper.status.message { throw FanMaclyError.message(error) }
                if helper.connected && helper.status.mode == expected { return }
            }
            helper.refresh()
            try await Task.sleep(for: .milliseconds(100))
        }
        if generation == liveControlID { restore() }
        throw FanMaclyError.message("FanMacly не подтвердил смену режима. Возвращаем автоматику.")
    }
    func selectMode(_ mode: CoolingMode) {
        guard mode == .system || canControl else { rejectControlSelection(); return }
        selectedMode = mode
        scheduleControl(immediately: true)
    }
    private func reconcileControlState() {
        if !canControl { sliderEditing = false }
        guard helper.connected, !sliderEditing, !controlPending, selectedMode != helper.status.mode else { return }
        let unconfirmed = selectedMode != .system && helper.status.mode == .system
        selectedMode = helper.status.mode
        if unconfirmed {
            helper.error = helper.error ?? helper.status.message ?? helper.status.thermalEvent?.message ??
                "Режим не включён. Управление вентиляторами осталось у macOS."
        }
    }
    private func rejectControlSelection() {
        cancelPendingControl()
        sliderEditing = false
        selectedMode = helper.connected ? helper.status.mode : .system
        helper.error = helper.status.thermalEvent?.message ?? snapshot.error ??
            (helper.connected ? "Помощник пока не разрешает ручное управление. Режим не включён." : "Нет связи с помощником. Режим не включён.")
    }
    func setTarget(_ value: Double, fan: Int, commit: Bool = true) {
        guard value.isFinite, let reading = snapshot.fans.first(where: { $0.id == fan }), let maximum = reading.maximum else { return }
        targets[fan] = value == 0 ? 0 : max(reading.safeMinimum, min(value, maximum))
        if commit && selectedMode == .manual { scheduleControl() }
    }
    func restore() {
        selectMode(.system)
    }
    func setCurvePercent(_ percent: Double, at index: Int, commit: Bool = true) {
        guard percent.isFinite, curve.points.indices.contains(index), index < curve.points.count - 1 else { return }
        let lower = index == 0 ? 0 : curve.points[index - 1].percent
        let upper = index == curve.points.count - 1 ? 100 : curve.points[index + 1].percent
        curve.points[index].percent = max(lower, min(percent, upper))
        profileName = activeSavedProfile?.name ?? "Мой профиль"
        if canControl { selectedMode = .curve }
        if commit {
            commitCurveEdits()
            if canControl { scheduleControl() }
        }
    }
    func setFanStopAllowed(_ allowed: Bool) {
        curve.allowsFanStop = allowed
        profileName = activeSavedProfile?.name ?? "Мой профиль"
        commitCurveEdits()
        if canControl { selectedMode = .curve; scheduleControl(immediately: true) }
    }
    func beginSliderEdit() {
        cancelPendingControl()
        sliderEditing = canControl
    }
    func finishSliderEdit(curveEdit: Bool) {
        sliderEditing = false
        if curveEdit { commitCurveEdits() }
        guard canControl, selectedMode == (curveEdit ? .curve : .manual) else { return }
        scheduleControl(immediately: true)
    }
    private func cancelPendingControl() {
        liveControlTask?.cancel()
        liveControlTask = nil
        liveControlID = UUID()
        hasPendingControl = false
    }
    private func scheduleControl(immediately: Bool = false) {
        cancelPendingControl()
        guard helper.connected, !sleeping, selectedMode == .system || canControl else { rejectControlSelection(); return }
        let request = ControlRequest(mode: selectedMode, targets: targets, curve: curve)
        let id = liveControlID
        hasPendingControl = true
        liveControlTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(immediately ? 0 : 300)) }
            catch { return }
            guard let self, !Task.isCancelled, self.liveControlID == id else { return }
            defer {
                if self.liveControlID == id { self.hasPendingControl = false; self.liveControlTask = nil }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            // Keep only the latest intent while the previous SMC transition
            // settles. Returning to macOS bypasses this hardware wait.
            while self.helper.busy || (request.mode != .system && (self.helper.status.preparing == true || self.helper.status.restoring == true)) {
                guard self.helper.connected, !self.sleeping, !Task.isCancelled else { return }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    self.rejectControlSelection()
                    self.helper.error = "Помощник не завершил предыдущее изменение. Последнее значение не применено."
                    return
                }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard !Task.isCancelled, self.liveControlID == id else { return }
            guard self.helper.connected, !self.sleeping, request.mode == .system || self.canControl else {
                self.rejectControlSelection(); return
            }
            self.helper.apply(request)
        }
    }
    private func commitCurveEdits() {
        if let profile = activeSavedProfile, profile.curve != curve {
            do { try saveProfile(named: profile.name, replacing: profile.id) }
            catch { exportError = error.localizedDescription; saveCurve() }
        } else { saveCurve() }
    }
    func saveCurve() {
        guard curve.isValid, let data = try? JSONEncoder().encode(curve) else { return }
        defaults.set(data, forKey: "coolingCurve")
        defaults.set(profileName, forKey: "profileName")
        defaults.set(activeProfileID?.uuidString, forKey: "activeProfileID")
    }
    func preset(_ name: String, curve: CoolingCurve) {
        commitCurveEdits()
        activeProfileID = nil
        profileName = name; self.curve = curve; saveCurve()
        if canControl { selectedMode = .curve; scheduleControl(immediately: true) }
    }
    func useProfile(_ id: UUID) {
        commitCurveEdits()
        guard let profile = profileLibrary.profiles.first(where: { $0.id == id }) else { return }
        activeProfileID = id; profileName = profile.name; curve = profile.curve
        saveCurve()
        if canControl { selectedMode = .curve; scheduleControl(immediately: true) }
    }
    func saveProfile(named name: String, replacing id: UUID? = nil) throws {
        guard !["Сбалансированный", "Прохладный"].contains(name.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FanMaclyError.message("Выберите название, отличающееся от встроенных профилей.")
        }
        var next = profileLibrary
        let savedID = try next.save(name: name, curve: curve, replacing: id)
        let data = try next.encoded()
        defaults.set(data, forKey: "savedCoolingProfiles")
        profileLibrary = next; activeProfileID = savedID
        profileName = next.profiles.first(where: { $0.id == savedID })!.name
        saveCurve()
    }
    func deleteActiveProfile() {
        guard let id = activeProfileID else { return }
        var next = profileLibrary
        next.remove(id)
        guard let data = try? next.encoded() else { return }
        defaults.set(data, forKey: "savedCoolingProfiles")
        profileLibrary = next; activeProfileID = nil; profileName = "Мой профиль"
        saveCurve()
    }
    func renameActiveProfile(to name: String) throws {
        guard let profile = activeSavedProfile else { return }
        guard !["Сбалансированный", "Прохладный"].contains(name.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FanMaclyError.message("Выберите название, отличающееся от встроенных профилей.")
        }
        var next = profileLibrary
        _ = try next.save(name: name, curve: profile.curve, replacing: profile.id)
        defaults.set(try next.encoded(), forKey: "savedCoolingProfiles")
        profileLibrary = next; profileName = next.profiles.first { $0.id == profile.id }!.name
        saveCurve()
    }
    func exportSnapshot() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FanMacly-sensors.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch { exportError = error.localizedDescription }
    }
}

