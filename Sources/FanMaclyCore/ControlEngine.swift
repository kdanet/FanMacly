import Foundation

public protocol FanHardware: AnyObject {
    func snapshot() -> HardwareSnapshot
    func setManual(_ manual: Bool, fan: Int) throws
    func setTarget(_ rpm: Double, fan: Int) throws
    /// Drop cached write state for a fan that was taken back by the system.
    func forgetFan(_ fan: Int)
    /// Clear the global handoff (Ftst) regardless of which fans are managed.
    func releaseHandoff() throws
}
public extension FanHardware {
    func forgetFan(_ fan: Int) {}
    func releaseHandoff() throws {}
}
extension SMCClient: FanHardware {}

/// Persists the user's intent so the helper can keep or resume it without the
/// app (app restart, hang, sleep/wake, helper restart).
public protocol ControlIntentStore: AnyObject {
    func load() -> ControlRequest?
    func save(_ request: ControlRequest?) throws
}

public final class MemoryIntentStore: ControlIntentStore {
    public var value: ControlRequest?
    public init(_ value: ControlRequest? = nil) { self.value = value }
    public func load() -> ControlRequest? { value }
    public func save(_ request: ControlRequest?) throws { value = request }
}

public final class FileIntentStore: ControlIntentStore {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func load() -> ControlRequest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ControlRequest.self, from: data)
    }
    public func save(_ request: ControlRequest?) throws {
        guard let request else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(request).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// All methods run on the helper's serial queue.
///
/// The helper owns the control loop. The app only states an intent; the
/// helper keeps it while the app is closed, suspended or asleep. Unsafe or
/// unreadable conditions hand control to macOS *temporarily* and the intent
/// resumes automatically once conditions are stable again.
public final class ControlEngine {
    public let policy: ControlPolicy
    private let hardware: FanHardware
    private let store: ControlIntentStore
    private let date: () -> Date
    public var onEvent: ((ControlEvent) -> Void)?

    private var intent: ControlRequest?
    private var touched = Set<Int>()
    private var acquired = Set<Int>()
    private var pendingTargets: [Int: Double] = [:]
    private var preparationDeadline: TimeInterval?
    private var temperatureFilter = CPUTemperatureFilter()
    private var curveGovernor = CurveFanGovernor()
    private var thermal: ThermalGuard
    private var lastSensorCheck: TimeInterval = -.infinity
    private var controlledFans: Set<Int> = []
    private var dataFaultSince: TimeInterval?
    private var reacquireTimes: [TimeInterval] = []
    private var autoResumeTimes: [TimeInterval] = []
    private var resumeAt: TimeInterval?
    private var resumeStableSince: TimeInterval?
    private var events: [ControlEvent] = []
    private var shuttingDown = false
    /// When returning the fans to macOS started failing (see `retryRestore`).
    private var restoreFailingSince: TimeInterval?
    public private(set) var status = HelperStatus()
    /// Helper exit: fans are only being returned to macOS (intent is kept on disk).
    public var isShutDown: Bool { shuttingDown && status.restoring != true }

    public init(hardware: FanHardware, store: ControlIntentStore = MemoryIntentStore(),
                policy: ControlPolicy = .standard, date: @escaping () -> Date = Date.init) {
        self.hardware = hardware
        self.store = store
        self.policy = policy
        self.date = date
        thermal = ThermalGuard(policy: policy)
        if let saved = store.load(), saved.mode != .system, saved.mode != .curve || saved.curve.isValid {
            intent = saved
            status.intent = saved
            status.suspension = .init(kind: .startup, message: "Восстанавливаем режим «\(saved.displayName)»…", date: date(), resumeDate: date())
            resumeAt = -.infinity
            record(.info, "Помощник запущен", detail: "Сохранённый режим «\(saved.displayName)» будет восстановлен.")
        }
    }

    // MARK: - Commands

    public func heartbeat(now: TimeInterval) -> HelperStatus { status }

    /// Fans a previous helper process left in manual mode and startup recovery
    /// could not return: keep retrying (with the same fallback) from the loop.
    public func adoptUnrecovered(_ fans: Set<Int>) {
        guard !fans.isEmpty else { return }
        touched.formUnion(fans)
        status.restoring = true
        record(.warning, "Не удалось сразу вернуть вентиляторы macOS", detail: "Повторяем попытки.")
    }

    /// Throws only for an invalid request. Runtime conditions (heat, sensors,
    /// SMC) are reported through `status.suspension`.
    public func apply(_ next: ControlRequest, now: TimeInterval) throws -> HelperStatus {
        guard !shuttingDown else { throw FanMaclyError.message("Системный компонент завершает работу.") }
        if next.mode == .system {
            guard next.boost == nil else { throw FanMaclyError.message("Буст требует режима вентиляторов.") }
            let hadIntent = intent != nil
            setIntent(nil)
            status.suspension = nil
            resumeAt = nil
            reacquireTimes = []; autoResumeTimes = []
            try restoreHardware(reason: nil)
            if hadIntent { record(.info, "Управление передано macOS") }
            return status
        }
        guard next.mode != .curve || next.curve.isValid else { throw FanMaclyError.message("Некорректная температурная кривая.") }
        if next.mode == .manual {
            let snapshot = hardware.snapshot()
            if snapshot.error == nil, !snapshot.fans.isEmpty {
                guard Set(next.targets.keys) == Set(snapshot.fans.map(\.id)) else {
                    throw FanMaclyError.message("Укажите обороты для каждого обнаруженного вентилятора.")
                }
            }
            guard next.targets.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw FanMaclyError.message("Некорректные обороты.")
            }
        }
        let modeChanged = intent?.profileID != next.profileID || intent?.mode != next.mode || intent?.boost != next.boost
        setIntent(next)
        reacquireTimes = []; autoResumeTimes = []
        if modeChanged {
            if let boost = next.boost {
                record(.boost, "Буст до \(boost.until.formatted(date: .omitted, time: .shortened))")
            } else {
                record(.info, "Включён режим «\(next.displayName)»")
            }
        }
        if status.suspension != nil || acquired.isEmpty || status.mode == .system {
            status.suspension = nil
            resumeAt = nil
            activate(now: now)
        } else {
            // Already controlling: re-plan targets on the next sensor tick.
            if next.mode == .curve { curveGovernor.reset(fans: hardware.snapshot().fans, targets: status.targets, now: now - 3, allowsFanStop: next.curve.allowsFanStop) }
            pendingTargets = [:]
            // A new batch gets its own confirmation deadline, unless a fan is
            // still being taken back: that keeps the longer handoff deadline.
            if !status.reacquiring {
                preparationDeadline = nil
                status.preparationStage = nil
            }
            lastSensorCheck = -.infinity
            tick(now: now)
        }
        return status
    }

    /// Helper exit: return the fans to macOS and stop controlling, without
    /// forgetting the intent. Later ticks only retry an incomplete restore.
    public func shutdown() throws {
        shuttingDown = true
        try restoreHardware(reason: nil)
    }

    // MARK: - Timer

    public func tick(now: TimeInterval) {
        if shuttingDown {
            retryRestore(now: now, snapshot: nil)
            return
        }
        if let boost = intent?.boost, date() >= boost.until { endBoost(now: now) }
        guard let intent else { idleTick(now: now); return }
        if status.suspension != nil { suspendedTick(now: now, intent: intent); return }

        if status.preparing == true, let deadline = preparationDeadline, now >= deadline {
            let reason = status.preparationStage == .handoff
                ? "macOS не передала управление вентиляторами за \(Int(policy.handoffTimeout)) с."
                : "SMC не подтвердил новые обороты за \(Int(policy.targetTimeout)) с."
            suspend(.hardware, reason, now: now)
            return
        }
        do {
            if now - lastSensorCheck >= 1 {
                let snapshot = hardware.snapshot()
                lastSensorCheck = now
                sampleTemperature(snapshot, now: now)
                let assessment = thermal.observe(snapshot, now: now)
                if let handback = assessment.handback { suspend(.thermal, handback, now: now); return }
                if let fault = dataFault(snapshot) {
                    if dataFaultSince == nil { dataFaultSince = now }
                    if now - (dataFaultSince ?? now) >= policy.dataFaultGrace {
                        suspend(.sensors, fault + " Управление временно передано macOS.", now: now)
                    } else { try reassertTargets() }
                    return
                }
                dataFaultSince = nil
                try update(snapshot: snapshot, assessment: assessment, now: now)
                confirmControl()
            } else {
                try reassertTargets()
            }
        } catch is FanControlPreparing {
            status.preparing = true
            if preparationDeadline == nil {
                status.preparationStage = .targets
                preparationDeadline = now + policy.targetTimeout
            }
        } catch let lost as FanControlLost {
            handleLost(lost, now: now)
        } catch {
            suspend(.hardware, error.localizedDescription, now: now)
        }
    }

    // MARK: - States

    private func idleTick(now: TimeInterval) {
        guard now - lastSensorCheck >= 1 else { retryRestore(now: now, snapshot: nil); return }
        let snapshot = hardware.snapshot()
        lastSensorCheck = now
        sampleTemperature(snapshot, now: now)
        let assessment = thermal.observe(snapshot, now: now)
        retryRestore(now: now, snapshot: snapshot, hot: assessment.boost)
        status.coolingBoost = false
        status.boostReason = nil
        status.customControlAllowed = dataFault(snapshot) == nil && assessment.handback == nil && touched.isEmpty
    }

    private func suspendedTick(now: TimeInterval, intent: ControlRequest) {
        guard now - lastSensorCheck >= 1 else { retryRestore(now: now, snapshot: nil); return }
        let snapshot = hardware.snapshot()
        lastSensorCheck = now
        sampleTemperature(snapshot, now: now)
        let assessment = thermal.observe(snapshot, now: now)
        retryRestore(now: now, snapshot: snapshot, hot: assessment.boost)
        let ready = dataFault(snapshot, ignoringFanSet: true) == nil && assessment.handback == nil &&
            touched.isEmpty && status.restoring != true
        status.customControlAllowed = ready
        guard let resumeAt, now >= resumeAt else { resumeStableSince = nil; return }
        guard ready else { resumeStableSince = nil; return }
        if resumeStableSince == nil { resumeStableSince = now }
        let startup = status.suspension?.kind == .startup
        let required = startup ? 2 : policy.resumeStableFor
        guard now - (resumeStableSince ?? now) >= required else { return }
        if !startup { autoResumeTimes.append(now) }
        record(.resumed, startup ? "Режим «\(intent.displayName)» восстановлен" : "Режим «\(intent.displayName)» возобновлён",
               detail: startup ? nil : "Условия стабильны \(Int(required)) с.")
        status.suspension = nil
        self.resumeAt = nil
        resumeStableSince = nil
        activate(now: now)
    }

    private func activate(now: TimeInterval) {
        guard let intent else { return }
        // A new mode supersedes an unfinished handback: the fans are being
        // taken again, so nothing is "returning to macOS" any more. If the
        // checks below suspend instead, `restoreHardware` recomputes this.
        status.restoring = false
        restoreFailingSince = nil
        let snapshot = hardware.snapshot()
        lastSensorCheck = now
        sampleTemperature(snapshot, now: now)
        let assessment = thermal.observe(snapshot, now: now)
        if let handback = assessment.handback { suspend(.thermal, handback, now: now); return }
        controlledFans = []
        if let fault = dataFault(snapshot) { suspend(.sensors, fault, now: now); return }
        let ids = Set(snapshot.fans.map(\.id))
        if intent.mode == .manual, Set(intent.targets.keys) != ids {
            suspend(.sensors, "Список вентиляторов изменился. Выберите режим заново.", now: now, allowAutoResume: false)
            return
        }
        controlledFans = ids
        dataFaultSince = nil
        reacquireTimes = reacquireTimes.filter { now - $0 < policy.reacquireWindow }
        if intent.mode == .curve { curveGovernor.reset(fans: snapshot.fans, targets: status.targets, now: now, allowsFanStop: intent.curve.allowsFanStop) }
        status.message = nil
        pendingTargets = [:]
        status.preparing = true
        status.preparationStage = .handoff
        preparationDeadline = now + policy.handoffTimeout
        do {
            try update(snapshot: snapshot, assessment: assessment, now: now)
            confirmControl()
        } catch is FanControlPreparing {
            status.preparing = true
        } catch let lost as FanControlLost {
            handleLost(lost, now: now)
        } catch {
            suspend(.hardware, error.localizedDescription, now: now)
        }
    }

    private func confirmControl() {
        guard let intent else { return }
        if status.reacquiring { record(.info, "Вентиляторы снова под управлением FanMacly") }
        status.mode = intent.mode
        status.customControlAllowed = true
        status.preparing = false
        status.reacquiring = false
        preparationDeadline = nil
        status.preparationStage = nil
    }

    private func handleLost(_ lost: FanControlLost, now: TimeInterval) {
        reacquireTimes = reacquireTimes.filter { now - $0 < policy.reacquireWindow } + [now]
        if reacquireTimes.count > policy.reacquireLimit {
            suspend(.conflict, "Вентилятор \(lost.fan + 1) постоянно возвращается под управление macOS. Возможно, вентиляторами управляет другое приложение.", now: now)
            return
        }
        acquired.remove(lost.fan)
        hardware.forgetFan(lost.fan)
        pendingTargets = [:]
        status.reacquiring = true
        status.preparing = true
        status.preparationStage = .handoff
        preparationDeadline = now + policy.handoffTimeout
        record(.warning, lost.observedMode == nil ? "Не прочитан режим вентилятора \(lost.fan + 1)" : "macOS забрала вентилятор \(lost.fan + 1)",
               detail: "Забираем обратно (\(reacquireTimes.count) из \(policy.reacquireLimit) за \(Int(policy.reacquireWindow / 60)) мин).")
    }

    private func suspend(_ kind: ControlSuspension.Kind, _ message: String, now: TimeInterval, allowAutoResume: Bool = true) {
        autoResumeTimes = autoResumeTimes.filter { now - $0 < policy.autoResumeWindow }
        let automatic = allowAutoResume && (intent?.autoResume ?? false) && autoResumeTimes.count < policy.autoResumeLimit
        let delay = policy.resumeAfter
        do { try restoreHardware(reason: nil) } catch { status.message = error.localizedDescription }
        status.suspension = .init(kind: kind, message: message, date: date(),
                                  resumeDate: automatic ? date().addingTimeInterval(delay) : nil)
        resumeAt = automatic ? now + delay : nil
        resumeStableSince = nil
        reacquireTimes = []
        dataFaultSince = nil
        record(.suspended, message, detail: automatic
               ? "FanMacly попробует вернуть режим через \(Int(delay)) с, если условия будут стабильны."
               : "Режим вернётся после нажатия «Вернуть».")
    }

    private func endBoost(now: TimeInterval) {
        guard var current = intent, let boost = current.boost else { return }
        if boost.thenSystem {
            setIntent(nil)
            status.suspension = nil
            resumeAt = nil
            try? restoreHardware(reason: nil)
            record(.info, "Буст завершён", detail: "Управление передано macOS.")
        } else {
            current.boost = nil
            setIntent(current)
            pendingTargets = [:]
            // Leaving a timed boost is not a thermal event; don't log one.
            status.coolingBoost = false
            status.boostReason = nil
            record(.info, "Буст завершён", detail: "Продолжает работать «\(current.displayName)».")
        }
    }

    private func setIntent(_ next: ControlRequest?) {
        intent = next
        status.intent = next
        do { try store.save(next) }
        catch { record(.error, "Не удалось сохранить режим", detail: error.localizedDescription) }
    }

    // MARK: - Hardware

    /// Keep returning fans that are still ours to macOS. If that keeps failing,
    /// nobody would be watching them. While it is hot (or the CPU temperature
    /// is unknown) drive the ones still in manual mode to maximum, and after
    /// `restoreGiveUp` clear the global handoff so macOS reclaims them itself.
    private func retryRestore(now: TimeInterval, snapshot: HardwareSnapshot?, hot: Bool = false) {
        guard !touched.isEmpty else { restoreFailingSince = nil; return }
        try? restoreHardware(reason: status.message)
        guard !touched.isEmpty else { restoreFailingSince = nil; return }
        if restoreFailingSince == nil { restoreFailingSince = now }
        let failingFor = now - (restoreFailingSince ?? now)
        if failingFor >= policy.restoreMaximumAfter, let snapshot,
           hot || snapshot.error != nil || snapshot.cpuControlReading == nil {
            for fan in snapshot.fans where touched.contains(fan.id) {
                if let maximum = fan.maximum { try? hardware.setTarget(maximum, fan: fan.id) }
            }
        }
        if failingFor >= policy.restoreGiveUp, (try? hardware.releaseHandoff()) == nil {
            status.message = "Не удалось вернуть управление вентиляторами macOS."
        }
    }

    private func restoreHardware(reason: String?) throws {
        status.mode = .system
        status.preparing = false
        status.reacquiring = false
        status.coolingBoost = false
        status.boostReason = nil
        status.targets = [:]
        controlledFans = []
        acquired = []
        pendingTargets = [:]
        preparationDeadline = nil
        status.preparationStage = nil
        status.restoring = !touched.isEmpty
        var failures: [String] = []
        for fan in touched.sorted() {
            do { try hardware.setManual(false, fan: fan); touched.remove(fan) }
            catch is FanControlPreparing { continue }
            catch { failures.append(error.localizedDescription) }
        }
        status.restoring = !touched.isEmpty
        if !failures.isEmpty {
            let message = "Не удалось вернуть автоматику: " + failures.joined(separator: "; ")
            status.message = message
            throw FanMaclyError.message(message)
        }
        status.message = reason
    }

    private func dataFault(_ snapshot: HardwareSnapshot, ignoringFanSet: Bool = false) -> String? {
        if let error = snapshot.error { return error }
        guard !snapshot.fans.isEmpty, snapshot.fans.allSatisfy(\.controllable), snapshot.fanCount == snapshot.fans.count else {
            return "Данные вентиляторов недоступны."
        }
        if !ignoringFanSet, !controlledFans.isEmpty, controlledFans != Set(snapshot.fans.map(\.id)) {
            return "Список вентиляторов изменился."
        }
        guard snapshot.cpuControlReading != nil else { return "Датчики CPU недоступны." }
        return nil
    }

    private func reassertTargets() throws {
        // Pending commands take precedence over the previously confirmed
        // targets. Reasserting the old values here cancels a new write.
        let targets = pendingTargets.isEmpty ? status.targets : pendingTargets
        var waiting = false
        for (fan, target) in targets where acquired.contains(fan) {
            do { try hardware.setTarget(target, fan: fan) }
            catch is FanControlPreparing { waiting = true }
        }
        if waiting { throw FanControlPreparing() }
    }

    private func update(snapshot: HardwareSnapshot, assessment: ThermalAssessment, now: TimeInterval) throws {
        guard let intent else { return }
        guard let temperature = status.controlTemperature else { throw FanMaclyError.message("Температура CPU недоступна.") }
        let boostActive = intent.boost.map { date() < $0.until } ?? false
        let emergency = assessment.boost || boostActive
        var waitingForMode = false
        for fan in snapshot.fans where !acquired.contains(fan.id) {
            // Track every attempted handoff for rollback and crash recovery.
            touched.insert(fan.id)
            do {
                try hardware.setManual(true, fan: fan.id)
                acquired.insert(fan.id)
            } catch is FanControlPreparing { waitingForMode = true }
        }
        if waitingForMode {
            // A fan that is already manual must not idle on whatever target it
            // had while the others are still being handed over.
            for fan in snapshot.fans where acquired.contains(fan.id) {
                guard let maximum = fan.maximum else { continue }
                let rpm: Double?
                if emergency { rpm = maximum }
                else if intent.mode == .curve { rpm = intent.curve.rpm(at: temperature, fan: fan) }
                else { rpm = intent.targets[fan.id].map { $0 == 0 ? 0 : max(fan.safeMinimum, min($0, maximum)) } }
                if let rpm { try? hardware.setTarget(rpm, fan: fan.id) }
            }
            throw FanControlPreparing()
        }
        if status.preparationStage != .targets {
            status.preparationStage = .targets
            preparationDeadline = now + policy.targetTimeout
        }
        if emergency != status.coolingBoost, !boostActive {
            if emergency { record(.boost, "Максимальное охлаждение", detail: assessment.boostReason.map { "Причина: \($0). Режим не отключается." }) }
            else { record(.info, "Максимальное охлаждение выключено", detail: "Температуры снизились.") }
        }
        status.coolingBoost = emergency
        status.boostReason = boostActive ? "Буст до \(intent.boost!.until.formatted(date: .omitted, time: .shortened))" : assessment.boostReason
        // Freeze a complete batch until every fan confirms it. Updating an
        // already-confirmed fan from a new temperature sample can otherwise
        // prevent two asynchronous fans from ever finishing the same batch.
        if pendingTargets.isEmpty || emergency {
            var desired: [Int: Double] = [:]
            for fan in snapshot.fans {
                guard let maximum = fan.maximum else { throw FanMaclyError.message("Максимум оборотов неизвестен.") }
                if emergency { desired[fan.id] = maximum; continue }
                if intent.mode == .curve {
                    guard let rpm = intent.curve.rpm(at: temperature, fan: fan) else { throw FanMaclyError.message("Некорректная кривая.") }
                    desired[fan.id] = rpm
                } else {
                    guard let value = intent.targets[fan.id] else { throw FanMaclyError.message("Целевые обороты не заданы.") }
                    desired[fan.id] = value == 0 ? 0 : max(fan.safeMinimum, min(value, maximum))
                }
            }
            let nextTargets = intent.mode == .curve
                ? curveGovernor.propose(fans: snapshot.fans, desired: desired, now: now, emergency: emergency, allowsFanStop: intent.curve.allowsFanStop)
                : desired
            if emergency && pendingTargets != nextTargets && status.targets != nextTargets { preparationDeadline = now + policy.targetTimeout }
            pendingTargets = nextTargets
        }
        var waitingForTarget = false
        for fan in snapshot.fans {
            guard let inFlight = pendingTargets[fan.id] else { throw FanMaclyError.message("Целевые обороты не заданы.") }
            do {
                try hardware.setTarget(inFlight, fan: fan.id)
                status.targets[fan.id] = inFlight
            } catch is FanControlPreparing { waitingForTarget = true }
        }
        if waitingForTarget { throw FanControlPreparing() }
        if intent.mode == .curve { curveGovernor.confirm(pendingTargets, now: now) }
        pendingTargets = [:]
    }

    private func sampleTemperature(_ snapshot: HardwareSnapshot, now: TimeInterval) {
        let reading = snapshot.error == nil ? snapshot.cpuControlReading : nil
        status.controlTemperature = temperatureFilter.update(reading: reading, now: now)
        status.temperatureSource = reading?.source
        status.rawControlTemperature = reading?.celsius
        status.peakCPUReading = snapshot.error == nil ? snapshot.cpuPeakReading : nil
        status.temperatureSampleDate = snapshot.date
    }

    private func record(_ kind: ControlEvent.Kind, _ title: String, detail: String? = nil) {
        let event = ControlEvent(date: date(), kind: kind, title: title, detail: detail)
        events.append(event)
        if events.count > 50 { events.removeFirst(events.count - 50) }
        status.events = events
        onEvent?(event)
    }
}

public extension ControlRequest {
    var displayName: String {
        if let profileName, !profileName.isEmpty { return profileName }
        switch mode {
        case .system: return "Авто"
        case .manual: return "Вручную"
        case .curve: return "По температуре"
        }
    }
}
