import Foundation

public protocol SMCRegisters: AnyObject {
    func number(_ key: String) -> Double?
    func writeNumber(_ key: String, _ value: Double) throws
}

public struct SMCWriteFailure: LocalizedError {
    public let key: String
    public let ioReturn: Int32
    public let result: UInt8
    public let status: UInt8
    public var errorDescription: String? {
        String(format: "SMC отклонил запись %@ (IOKit 0x%08x, result 0x%02x, status 0x%02x).", key, UInt32(bitPattern: ioReturn), result, status)
    }
}

/// A retryable transition, never an acknowledgement of manual control.
public struct FanControlPreparing: Error { public init() {} }

/// The fan is no longer in manual mode (macOS, firmware or another app took it
/// back), or its mode register could not be read. The engine re-acquires it.
public struct FanControlLost: LocalizedError, Equatable {
    public let fan: Int
    /// nil when the mode register could not be read at all.
    public let observedMode: Double?
    public let names: FanNames
    public init(fan: Int, observedMode: Double?, names: FanNames = FanNames(count: nil)) {
        self.fan = fan; self.observedMode = observedMode; self.names = names
    }
    public var errorDescription: String? {
        observedMode == nil
            ? "Не удалось прочитать режим \(names.genitive(fan))."
            : "macOS вернула управление \(names.instrumental(fan))."
    }
}

/// Apple Silicon uses case-sensitive mode keys. M1–M4 commonly use `Md`,
/// while newer firmware can expose `md`. Mode 3 requires an Ftst handoff.
public final class FanModeController {
    private unowned let registers: SMCRegisters
    private var managed = Set<Int>()
    private var modeWrites: [Int: (manual: Bool, time: TimeInterval)] = [:]
    private var targetWrites: [Int: (rpm: Double, started: TimeInterval, last: TimeInterval)] = [:]
    private var requestedHandoff = false
    /// When Ftst = 1 was last requested, and when we last cleared it.
    private var handoffRequestedAt: TimeInterval?
    private var handoffReleasedAt: TimeInterval?
    /// thermalmonitord misses an Ftst edge that arrives while it is still
    /// reclaiming the fans (observed on M4 Max: Ftst = 1 about 1 s after a
    /// release left both fans stopped in mode 0 with nobody driving them).
    /// Keep Ftst low this long before raising it again…
    public var handoffSettle: TimeInterval = 5
    /// …and re-pulse it if no fan turned manual this long after raising it.
    public var handoffRetryAfter: TimeInterval = 10
    private var restoringStoppedFans: [Int: TimeInterval] = [:]
    private var startingStoppedFans: [Int: TimeInterval] = [:]
    private let clock: () -> TimeInterval
    public init(registers: SMCRegisters, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.registers = registers; self.clock = clock
    }

    private var names: FanNames { FanNames(count: registers.number("FNum").map { Int($0) }) }
    public func mode(fan: Int) -> (key: String, value: Double)? {
        guard (0..<10).contains(fan) else { return nil }
        for key in ["F\(fan)Md", "F\(fan)md"] {
            if let value = registers.number(key) { return (key, value) }
        }
        return nil
    }

    public func setManual(_ manual: Bool, fan: Int) throws {
        guard let mode = mode(fan: fan) else {
            throw FanMaclyError.message("SMC не сообщает режим \(names.genitive(fan)): ни F\(fan)Md, ни F\(fan)md не доступны.")
        }
        if !manual {
            // Some SMC firmware rejects switching a stopped manual fan back
            // to auto. Give it a short starting pulse first, and
            // retain ownership until the tachometer confirms it has started.
            if mode.value == 1,
               restoringStoppedFans[fan] != nil || registers.number("F\(fan)Ac") == 0 {
                guard let minimum = registers.number("F\(fan)Mn"), minimum.isFinite,
                      let maximum = registers.number("F\(fan)Mx"), maximum.isFinite,
                      max(1200, minimum) <= maximum else {
                    throw FanMaclyError.message("Неизвестен рабочий диапазон для запуска \(names.genitive(fan)) перед возвратом автоматики.")
                }
                if restoringStoppedFans[fan] == nil { restoringStoppedFans[fan] = clock() }
                try setTarget(max(max(1200, minimum), min(2500, maximum)), fan: fan)
                guard registers.number("F\(fan)Ac").map({ $0.isFinite && $0 >= max(1200, minimum) * 0.8 }) == true else {
                    if clock() - (restoringStoppedFans[fan] ?? clock()) >= 12 {
                        throw FanMaclyError.message("Не подтверждён запуск \(names.genitive(fan)) перед возвратом автоматики.")
                    }
                    throw FanControlPreparing()
                }
            }
            // Mode 3 already belongs to macOS; writing 0 there can be rejected.
            // Cancel a queued manual write even if its old readback is still
            // automatic. Otherwise it can land *after* we clear ownership.
            if mode.value != 3 && (mode.value != 0 || modeWrites[fan]?.manual == true) {
                do { try writeMode(false, fan: fan, key: mode.key) }
                catch let error as SMCWriteFailure {
                    if error.ioReturn == 0, error.result == 0x82,
                       let started = restoringStoppedFans[fan], clock() - started < 12 {
                        throw FanControlPreparing()
                    }
                    throw error
                }
                guard let readback = self.mode(fan: fan), readback.value == 0 || readback.value == 3 else {
                    throw FanControlPreparing()
                }
            }
            // Keep the global handoff while another managed fan is manual.
            if managed.subtracting([fan]).isEmpty, let force = registers.number("Ftst"), force != 0 || requestedHandoff {
                try registers.writeNumber("Ftst", 0)
                guard registers.number("Ftst") == 0 else { throw FanControlPreparing() }
                requestedHandoff = false
                handoffRequestedAt = nil
                handoffReleasedAt = clock()
            }
            // A mode-3 readback can still predate an accepted manual write.
            // Retain ownership for a reconciliation interval after cancelling
            // the global handoff; never write an unsupported 0 to mode 3.
            if mode.value == 3, let pending = modeWrites[fan], pending.manual, clock() - pending.time < 2 {
                throw FanControlPreparing()
            }
            managed.remove(fan)
            modeWrites.removeValue(forKey: fan)
            targetWrites.removeValue(forKey: fan)
            restoringStoppedFans.removeValue(forKey: fan)
            startingStoppedFans.removeValue(forKey: fan)
            return
        }

        managed.insert(fan)
        restoringStoppedFans.removeValue(forKey: fan)
        if mode.value == 1 { modeWrites.removeValue(forKey: fan); try keepHandoff(); return }
        // Ask thermalmonitord to yield before taking the fan, on every model
        // that exposes Ftst. Without it the OS can silently switch a manually
        // controlled fan back to automatic (observed on M4 Max with FnMd = 0).
        if registers.number("Ftst") == 0 {
            if let released = handoffReleasedAt, clock() - released < handoffSettle { throw FanControlPreparing() }
            try requestHandoff()
            throw FanControlPreparing()
        }
        if requestedHandoff, let requested = handoffRequestedAt, clock() - requested >= handoffRetryAfter,
           managed.allSatisfy({ self.mode(fan: $0)?.value != 1 }) {
            // The request was not picked up: lower Ftst, let thermalmonitord
            // settle, then raise it again.
            try registers.writeNumber("Ftst", 0)
            handoffRequestedAt = nil
            handoffReleasedAt = clock()
            modeWrites.removeValue(forKey: fan)
            throw FanControlPreparing()
        }
        do {
            try writeMode(true, fan: fan, key: mode.key)
        } catch let error as SMCWriteFailure {
            // The firmware can reject manual mode until thermalmonitord yields.
            guard error.ioReturn == 0, error.result == 0x82, registers.number("Ftst") != nil else { throw error }
            if registers.number("Ftst") == 0,
               handoffReleasedAt.map({ clock() - $0 >= handoffSettle }) ?? true {
                try requestHandoff()
            }
            throw FanControlPreparing()
        }
        guard self.mode(fan: fan)?.value == 1 else {
            throw FanControlPreparing()
        }
    }

    public func setTarget(_ rpm: Double, fan: Int) throws {
        let current = mode(fan: fan)
        guard current?.value == 1 else {
            throw FanControlLost(fan: fan, observedMode: current?.value, names: names)
        }
        try keepHandoff()
        if rpm > 0, startingStoppedFans[fan] != nil || registers.number("F\(fan)Ac") == 0 {
            guard let minimum = registers.number("F\(fan)Mn"), minimum.isFinite,
                  let maximum = registers.number("F\(fan)Mx"), maximum.isFinite,
                  max(1200, minimum) <= maximum else {
                throw FanMaclyError.message("Неизвестен рабочий диапазон для запуска \(names.genitive(fan)).")
            }
            let startingRPM = max(max(1200, minimum), min(2500, maximum))
            if rpm < startingRPM {
                if startingStoppedFans[fan] == nil { startingStoppedFans[fan] = clock() }
                try writeConfirmedTarget(startingRPM, fan: fan)
                guard registers.number("F\(fan)Ac").map({ $0.isFinite && $0 >= max(1200, minimum) * 0.8 }) == true else {
                    if clock() - (startingStoppedFans[fan] ?? clock()) >= 6 {
                        throw FanMaclyError.message("Не подтверждён повторный запуск \(names.genitive(fan)).")
                    }
                    throw FanControlPreparing()
                }
            }
        }
        startingStoppedFans.removeValue(forKey: fan)
        try writeConfirmedTarget(rpm, fan: fan)
    }

    /// Treat the global handoff as just released. A newly started helper
    /// calls this because the previous process may have cleared Ftst a moment ago.
    public func deferHandoff() { handoffReleasedAt = clock() }

    /// Fans a previous helper process left in manual mode (crash journal).
    /// Counting them as managed keeps Ftst raised until the last one is back,
    /// so returning the first fan does not strand the others in manual mode.
    public func adopt(fans: Set<Int>) {
        managed.formUnion(fans.filter { (0..<10).contains($0) })
    }

    /// Give the global handoff back to macOS even while fans are still marked
    /// as managed. Used when returning a fan keeps failing: thermalmonitord
    /// then reclaims the fan itself instead of leaving it on a stale target.
    public func releaseHandoff() throws {
        guard let force = registers.number("Ftst"), force != 0 || requestedHandoff else { return }
        try registers.writeNumber("Ftst", 0)
        requestedHandoff = false
        handoffRequestedAt = nil
        handoffReleasedAt = clock()
    }

    private func requestHandoff() throws {
        requestedHandoff = true
        try registers.writeNumber("Ftst", 1)
        handoffRequestedAt = clock()
    }

    /// Re-assert the global handoff if something cleared it while we still own fans.
    private func keepHandoff() throws {
        guard requestedHandoff, !managed.isEmpty, registers.number("Ftst") == 0 else { return }
        try registers.writeNumber("Ftst", 1)
    }

    /// Forget a fan that was taken back so the next acquisition starts cleanly.
    public func forget(fan: Int) {
        managed.remove(fan)
        modeWrites.removeValue(forKey: fan)
        targetWrites.removeValue(forKey: fan)
        startingStoppedFans.removeValue(forKey: fan)
    }

    private func writeConfirmedTarget(_ rpm: Double, fan: Int) throws {
        let key = "F\(fan)Tg"
        if let readback = registers.number(key), abs(readback - rpm) <= 2 {
            targetWrites.removeValue(forKey: fan)
            return
        }
        let now = clock()
        if let pending = targetWrites[fan], pending.rpm == rpm {
            guard now - pending.started < 4 else { throw FanMaclyError.message("SMC не подтвердил целевые обороты \(names.genitive(fan)) за 4 секунды.") }
            if now - pending.last >= 1 {
                try registers.writeNumber(key, rpm)
                targetWrites[fan] = (rpm, pending.started, now)
            }
        } else {
            try registers.writeNumber(key, rpm)
            targetWrites[fan] = (rpm, now, now)
        }
        guard let readback = registers.number(key), abs(readback - rpm) <= 2 else { throw FanControlPreparing() }
        targetWrites.removeValue(forKey: fan)
    }

    private func writeMode(_ manual: Bool, fan: Int, key: String) throws {
        let now = clock()
        if let pending = modeWrites[fan], pending.manual == manual, now - pending.time < 2 { throw FanControlPreparing() }
        try registers.writeNumber(key, manual ? 1 : 0)
        modeWrites[fan] = (manual, now)
    }
}
