import Foundation

public protocol FanHardware: AnyObject {
    func snapshot() -> HardwareSnapshot
    func setManual(_ manual: Bool, fan: Int) throws
    func setTarget(_ rpm: Double, fan: Int) throws
}
extension SMCClient: FanHardware {}

/// All methods run on the helper's serial queue. No persisted control lease.
public final class ControlEngine {
    public static let timeout: TimeInterval = 8
    private let hardware: FanHardware
    private var request = ControlRequest(mode: .system)
    private var touched = Set<Int>()
    private var acquired = Set<Int>()
    private var pendingTargets: [Int: Double] = [:]
    private var preparationDeadline: TimeInterval?
    private var lastHeartbeat: TimeInterval = 0
    private var temperatureFilter = CPUTemperatureFilter()
    private var curveGovernor = CurveFanGovernor()
    private var thermalSafety = CPUThermalSafety()
    private var thermalEventTime: TimeInterval?
    private var coolSince: TimeInterval?
    private var lastRecoverySample: TimeInterval?
    private var lastSensorCheck: TimeInterval = -.infinity
    private var controlledFans: Set<Int> = []
    private var restorationReason: String?
    public private(set) var status = HelperStatus()
    public init(hardware: FanHardware) { self.hardware = hardware }

    public func heartbeat(now: TimeInterval) -> HelperStatus {
        // An overdue heartbeat must not renew an expired lease just because
        // its XPC callback was scheduled ahead of the watchdog timer.
        expireControlLease(now: now)
        lastHeartbeat = now
        return status
    }

    @discardableResult private func expireControlLease(now: TimeInterval) -> Bool {
        guard request.mode != .system, now - lastHeartbeat >= Self.timeout else { return false }
        try? restore(reason: "Связь с приложением потеряна. Управление возвращено macOS.")
        return true
    }

    public func apply(_ next: ControlRequest, now: TimeInterval) throws -> HelperStatus {
        if next.mode == .system {
            restorationReason = nil
            try restore(reason: nil)
            status.thermalEvent = nil
            thermalEventTime = nil; coolSince = nil
            return status
        }
        expireControlLease(now: now)
        // Reject an in-flight intent created before a protective fallback.
        // The client must first receive the new generation and explicitly edit
        // again; a delayed packet cannot restart control after protection.
        guard next.expectedFallbackID == status.automaticFallbackID else { return status }
        guard touched.isEmpty || request.mode != .system else {
            throw FanMaclyError.message("Не удалось вернуть автоматику. Повторите сброс управления.")
        }
        let snapshot = hardware.snapshot()
        do { try validate(snapshot, now: now) }
        catch let trip as ThermalLimitReached {
            try restoreForThermalEvent(trip.event, now: now)
            return status
        } catch {
            // A new request must not leave an older manual command running
            // after its telemetry has already failed validation.
            try? restore(reason: error.localizedDescription)
            throw error
        }
        sampleTemperature(snapshot, now: now)
        guard next.mode != .curve || next.curve.isValid else { throw FanMaclyError.message("Некорректная температурная кривая.") }
        let ids = Set(snapshot.fans.map(\.id))
        if next.mode == .manual {
            guard Set(next.targets.keys) == ids, next.targets.values.allSatisfy({ $0.isFinite }) else {
                throw FanMaclyError.message("Укажите обороты для каждого обнаруженного вентилятора.")
            }
        }
        request = next
        if next.mode == .curve { curveGovernor.reset(fans: snapshot.fans, targets: status.targets, now: now, allowsFanStop: next.curve.allowsFanStop) }
        controlledFans = ids
        lastHeartbeat = now
        status.message = nil
        status.thermalEvent = nil
        thermalEventTime = nil; coolSince = nil
        pendingTargets = [:]
        status.preparationStage = .handoff
        preparationDeadline = now + 12
        lastSensorCheck = now
        do {
            try update(snapshot: snapshot, now: now)
            status.mode = next.mode
            status.preparing = false
            preparationDeadline = nil
            status.preparationStage = nil
            return status
        } catch is FanControlPreparing {
            status.preparing = true
            return status
        } catch {
            let original = error
            try? restore(reason: original.localizedDescription)
            throw original
        }
    }

    public func tick(now: TimeInterval) {
        if request.mode == .system {
            if !touched.isEmpty { try? restore(reason: restorationReason) }
            if now - lastSensorCheck >= 1 {
                let snapshot = hardware.snapshot()
                sampleTemperature(snapshot, now: now)
                let trip = thermalSafety.observe(snapshot, now: now)
                status.customControlAllowed = snapshot.error == nil && snapshot.cpuControlReading != nil && trip == nil && touched.isEmpty &&
                    !snapshot.fans.isEmpty && snapshot.fans.allSatisfy(\.controllable) && snapshot.fanCount == snapshot.fans.count &&
                    snapshot.temperature(.battery).map({ $0 < 50 }) != false && snapshot.temperature(.gpu).map({ $0 < 95 }) != false
                clearRecoveredThermalEvent(snapshot, now: now)
                lastSensorCheck = now
            }
            return
        }
        if expireControlLease(now: now) { return }
        if status.preparing == true, let deadline = preparationDeadline, now >= deadline {
            let reason = status.preparationStage == .handoff
                ? "macOS не передала управление вентиляторами за 12 секунд. Возвращаем автоматический режим."
                : "SMC не подтвердил новые обороты за 6 секунд. Возвращаем автоматический режим."
            try? restore(reason: reason)
            return
        }
        do {
            if now - lastSensorCheck >= 1 {
                let snapshot = hardware.snapshot()
                try validate(snapshot, now: now)
                sampleTemperature(snapshot, now: now)
                lastSensorCheck = now
                try update(snapshot: snapshot, now: now)
                status.mode = request.mode
                status.preparing = false
                preparationDeadline = nil
                status.preparationStage = nil
            } else {
                // Pending commands take precedence over the previously confirmed
                // targets. Reasserting the old values here cancels a new write.
                let targets = pendingTargets.isEmpty ? status.targets : pendingTargets
                var waiting = false
                for (fan, target) in targets {
                    do { try hardware.setTarget(target, fan: fan) }
                    catch is FanControlPreparing { waiting = true }
                }
                if waiting { throw FanControlPreparing() }
            }
        } catch is FanControlPreparing {
            status.preparing = true
            if preparationDeadline == nil {
                status.preparationStage = .targets
                preparationDeadline = now + 6
            }
        } catch let trip as ThermalLimitReached {
            try? restoreForThermalEvent(trip.event, now: now)
        } catch { try? restore(reason: error.localizedDescription) }
    }

    public func restore(reason: String?) throws {
        if status.restoring != true { restorationReason = reason }
        if reason != nil && (request.mode != .system || !touched.isEmpty), status.restoring != true {
            status.automaticFallbackID = UUID()
        }
        request = .init(mode: .system)
        status.mode = .system
        status.preparing = false
        status.coolingBoost = false
        status.restoring = !touched.isEmpty
        status.targets = [:]
        controlledFans = []
        acquired = []
        pendingTargets = [:]
        preparationDeadline = nil
        status.preparationStage = nil
        var failures: [String] = []
        for fan in touched.sorted() {
            do { try hardware.setManual(false, fan: fan); touched.remove(fan) }
            catch is FanControlPreparing { continue }
            catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty {
            let message = "Не удалось восстановить автоматику: " + failures.joined(separator: "; ")
            status.message = message
            throw FanMaclyError.message(message)
        }
        status.restoring = !touched.isEmpty
        status.message = restorationReason
    }

    private func restoreForThermalEvent(_ event: ThermalEvent, now: TimeInterval) throws {
        // Keep real restoration errors actionable. Thermal events are separate
        // from errors so an old event can't stick in HelperClient.error forever.
        status.automaticFallbackID = event.id
        status.customControlAllowed = false
        try restore(reason: nil)
        status.thermalEvent = event
        thermalEventTime = now
        coolSince = nil; lastRecoverySample = nil
    }

    private func clearRecoveredThermalEvent(_ snapshot: HardwareSnapshot, now: TimeInterval) {
        guard status.thermalEvent != nil, touched.isEmpty, status.restoring != true else { return }
        if lastRecoverySample.map({ now <= $0 || now - $0 > 2.5 }) == true { coolSince = nil }
        lastRecoverySample = now
        let cool = snapshot.error == nil && snapshot.hottestCPU.map { $0 < 88 } == true &&
            snapshot.cpuControlReading.map { $0.celsius < 85 } == true &&
            snapshot.thermalPressure?.requiresSystemCooling != true
        if cool { if coolSince == nil { coolSince = now } } else { coolSince = nil }
        // Clear after confirmed cooling, or retire a past event after 30 s once
        // macOS has confirmed ownership. This never resumes custom control.
        if coolSince.map({ now - $0 >= 5 }) == true || thermalEventTime.map({ now - $0 >= 30 }) == true {
            status.thermalEvent = nil
            thermalEventTime = nil; coolSince = nil
        }
    }

    private func validate(_ snapshot: HardwareSnapshot, now: TimeInterval) throws {
        status.customControlAllowed = false
        guard snapshot.error == nil, !snapshot.fans.isEmpty, snapshot.fans.allSatisfy(\.controllable),
              snapshot.fanCount == snapshot.fans.count else { throw FanMaclyError.message("Данные вентиляторов недоступны. Управление остановлено.") }
        guard controlledFans.isEmpty || controlledFans == Set(snapshot.fans.map(\.id)) else {
            throw FanMaclyError.message("Список вентиляторов изменился. Управление остановлено.")
        }
        guard let hottest = snapshot.hottestCPU, hottest.isFinite else {
            throw FanMaclyError.message("Датчики CPU недоступны. Управление остановлено.")
        }
        if let trip = thermalSafety.observe(snapshot, now: now) {
            status.customControlAllowed = false
            throw ThermalLimitReached(event: trip)
        }
        guard snapshot.temperature(.battery).map({ $0 < 50 }) ?? true else {
            throw FanMaclyError.message("Аккумулятор достиг 50 °C. Управление возвращено macOS.")
        }
        guard snapshot.temperature(.gpu).map({ $0 < 95 }) ?? true else {
            throw FanMaclyError.message("GPU достиг 95 °C. Управление возвращено macOS.")
        }
        status.customControlAllowed = true
    }

    private func update(snapshot: HardwareSnapshot, now: TimeInterval) throws {
        guard let temperature = status.controlTemperature else { throw FanMaclyError.message("Температура CPU недоступна.") }
        var waitingForMode = false
        for fan in snapshot.fans where !acquired.contains(fan.id) {
            // Acquire both fans concurrently across timer ticks, while tracking
            // every attempted handoff for rollback and crash recovery.
            touched.insert(fan.id)
            do {
                try hardware.setManual(true, fan: fan.id)
                acquired.insert(fan.id)
            } catch is FanControlPreparing { waitingForMode = true }
        }
        if waitingForMode { throw FanControlPreparing() }
        if status.preparationStage != .targets {
            status.preparationStage = .targets
            preparationDeadline = now + 6
        }
        // Freeze a complete batch until every fan confirms it. Updating an
        // already-confirmed fan from a new temperature sample can otherwise
        // prevent two asynchronous fans from ever finishing the same batch.
        let emergency = thermalSafety.requiresMaximumCooling
        status.coolingBoost = emergency
        if pendingTargets.isEmpty || emergency {
            var desired: [Int: Double] = [:]
            for fan in snapshot.fans {
                guard let maximum = fan.maximum else { throw FanMaclyError.message("Максимум оборотов неизвестен.") }
                if emergency { desired[fan.id] = maximum; continue }
                if request.mode == .curve {
                    guard let percent = request.curve.percent(at: temperature) else { throw FanMaclyError.message("Некорректная кривая.") }
                    desired[fan.id] = request.curve.allowsFanStop && percent == 0
                        ? 0 : fan.safeMinimum + (maximum - fan.safeMinimum) * percent / 100
                } else {
                    guard let value = request.targets[fan.id] else { throw FanMaclyError.message("Целевые обороты не заданы.") }
                    desired[fan.id] = value == 0 ? 0 : max(fan.safeMinimum, min(value, maximum))
                }
            }
            let nextTargets = request.mode == .curve
                ? curveGovernor.propose(fans: snapshot.fans, desired: desired, now: now, emergency: emergency, allowsFanStop: request.curve.allowsFanStop)
                : desired
            if emergency && pendingTargets != nextTargets && status.targets != nextTargets { preparationDeadline = now + 6 }
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
        if request.mode == .curve { curveGovernor.confirm(pendingTargets, now: now) }
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
}
