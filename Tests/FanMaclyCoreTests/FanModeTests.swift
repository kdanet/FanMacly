import XCTest
@testable import FanMaclyCore

private final class Registers: SMCRegisters {
    var values: [String: Double] = ["F0Md": 3, "F1Md": 3, "Ftst": 0, "F0Tg": 0, "F1Tg": 0]
    var writes: [(String, Double)] = []
    var ready = false
    var ignoreTarget = false
    var deferred = Set<String>()
    var queued: [String: Double] = [:]
    func flush() { values.merge(queued) { _, new in new }; queued = [:] }
    func number(_ key: String) -> Double? { values[key] }
    func writeNumber(_ key: String, _ value: Double) throws {
        writes.append((key, value))
        if key.hasSuffix("Md"), value == 1, values[key] == 3, !ready {
            throw SMCWriteFailure(key: key, ioReturn: 0, result: 0x82, status: 0)
        }
        if ignoreTarget && key.hasSuffix("Tg") { return }
        if deferred.contains(key) { queued[key] = value; return }
        values[key] = value
    }
}

private final class UnlockHardware: FanHardware {
    let registers = Registers()
    lazy var modes = FanModeController(registers: registers)
    var temperature = 60.0
    var pressure: ThermalPressure = .nominal
    func snapshot() -> HardwareSnapshot {
        .init(fans: [.init(id: 0, current: 2000, minimum: 1350, maximum: 5777, manual: registers.values["F0Md"] == 1)], sensors: [.init(id: "TC0D", name: "CPU", group: .cpu, celsius: temperature)], fanCount: 1, thermalPressure: pressure)
    }
    func setManual(_ manual: Bool, fan: Int) throws { try modes.setManual(manual, fan: fan) }
    func setTarget(_ rpm: Double, fan: Int) throws { try modes.setTarget(rpm, fan: fan) }
}

final class FanModeTests: XCTestCase {
    func testRestartAtMinimumUsesStartingPulseAndStopCancelsIt() throws {
        let registers = Registers()
        registers.values.merge(["F0Md": 1, "F0Tg": 0, "F0Ac": 0, "F0Mn": 1350, "F0Mx": 5777]) { _, new in new }
        let modes = FanModeController(registers: registers)
        XCTAssertThrowsError(try modes.setTarget(1350, fan: 0)) { XCTAssertTrue($0 is FanControlPreparing) }
        XCTAssertEqual(registers.values["F0Tg"], 2500)
        try modes.setTarget(0, fan: 0)
        XCTAssertEqual(registers.values["F0Tg"], 0)
        XCTAssertThrowsError(try modes.setTarget(1350, fan: 0))
        registers.values["F0Ac"] = 1300
        try modes.setTarget(1350, fan: 0)
        XCTAssertEqual(registers.values["F0Tg"], 1350)
    }
    func testRestoringStoppedFanWakesItBeforeRequestingAuto() throws {
        let registers = Registers()
        registers.values.merge(["F0Md": 1, "F0Tg": 0, "F0Ac": 0, "F0Mn": 1350, "F0Mx": 5777, "Ftst": 1]) { _, new in new }
        let modes = FanModeController(registers: registers)
        XCTAssertThrowsError(try modes.setManual(false, fan: 0)) { XCTAssertTrue($0 is FanControlPreparing) }
        XCTAssertEqual(registers.values["F0Tg"], 2500)
        XCTAssertEqual(registers.values["F0Md"], 1)
        XCTAssertEqual(registers.values["Ftst"], 1)
        registers.values["F0Ac"] = 1300
        try modes.setManual(false, fan: 0)
        XCTAssertEqual(registers.values["F0Md"], 0)
        XCTAssertEqual(registers.values["Ftst"], 0)
    }
    func testStoppedFanRecoveryDoesNotAcknowledgeDeferredWakeup() throws {
        let registers = Registers()
        registers.values.merge(["F0Md": 1, "F0Tg": 0, "F0Ac": 0, "F0Mn": 1350, "F0Mx": 5777]) { _, new in new }
        registers.deferred = ["F0Tg"]
        let modes = FanModeController(registers: registers)
        XCTAssertThrowsError(try modes.setManual(false, fan: 0))
        XCTAssertEqual(registers.values["F0Md"], 1)
        registers.flush()
        XCTAssertThrowsError(try modes.setManual(false, fan: 0))
        registers.values["F0Ac"] = 1300
        try modes.setManual(false, fan: 0)
        XCTAssertEqual(registers.values["F0Md"], 0)
    }
    func testCancellationRetainsModeThreeOwnershipUntilLateManualWriteIsReset() throws {
        let registers = Registers()
        registers.ready = true; registers.values["Ftst"] = 1
        registers.deferred = ["F0Md"]
        var time = 0.0
        let modes = FanModeController(registers: registers, clock: { time })
        XCTAssertThrowsError(try modes.setManual(true, fan: 0))
        XCTAssertThrowsError(try modes.setManual(false, fan: 0))
        XCTAssertEqual(registers.values["Ftst"], 0)
        XCTAssertFalse(registers.writes.contains { $0.0 == "F0Md" && $0.1 == 0 }, "Mode 3 must not receive an unsupported reset write")
        registers.flush(); time = 0.3
        XCTAssertEqual(registers.values["F0Md"], 1)
        XCTAssertThrowsError(try modes.setManual(false, fan: 0))
        registers.flush(); time = 0.6
        try modes.setManual(false, fan: 0)
        XCTAssertEqual(registers.values["F0Md"], 0)
    }
    func testCancellingHandoffSupersedesUnacknowledgedFtstWrite() throws {
        let registers = Registers()
        registers.deferred = ["Ftst"]
        let modes = FanModeController(registers: registers)
        XCTAssertThrowsError(try modes.setManual(true, fan: 0))
        XCTAssertEqual(registers.values["Ftst"], 0)
        XCTAssertEqual(registers.queued["Ftst"], 1)
        try modes.setManual(false, fan: 0)
        registers.flush()
        XCTAssertEqual(registers.values["Ftst"], 0)
    }
    func testCancellingManualSupersedesUnacknowledgedModeWrite() throws {
        let registers = Registers()
        registers.values["F0Md"] = 0
        registers.deferred = ["F0Md"]
        let modes = FanModeController(registers: registers)
        XCTAssertThrowsError(try modes.setManual(true, fan: 0))
        XCTAssertEqual(registers.values["F0Md"], 0)
        XCTAssertEqual(registers.queued["F0Md"], 1)
        try modes.setManual(false, fan: 0)
        registers.flush()
        XCTAssertEqual(registers.values["F0Md"], 0)
        XCTAssertEqual(registers.writes.last?.1, 0)
    }
    func testM4UppercaseKeyUnlocksThenVerifiesModeAndTarget() throws {
        let registers = Registers()
        let modes = FanModeController(registers: registers)
        XCTAssertEqual(modes.mode(fan: 0)?.key, "F0Md")
        XCTAssertThrowsError(try modes.setManual(true, fan: 0)) { XCTAssertTrue($0 is FanControlPreparing) }
        XCTAssertEqual(registers.values["Ftst"], 1)
        XCTAssertEqual(registers.values["F0Md"], 3)
        XCTAssertThrowsError(try modes.setManual(true, fan: 0)) { XCTAssertTrue($0 is FanControlPreparing) }
        registers.ready = true
        try modes.setManual(true, fan: 0)
        try modes.setTarget(2500, fan: 0)
        XCTAssertEqual(registers.values["F0Md"], 1)
        XCTAssertEqual(registers.values["F0Tg"], 2500)
        try modes.setManual(false, fan: 0)
        XCTAssertEqual(registers.values["F0Md"], 0)
        XCTAssertEqual(registers.values["Ftst"], 0)
        XCTAssertFalse(registers.writes.contains { $0.0 == "F0md" })
    }
    func testLowercaseFirmwareWithoutFtstUsesDirectMode() throws {
        let registers = Registers()
        registers.values = ["F0md": 0, "F0Tg": 0]
        let modes = FanModeController(registers: registers)
        try modes.setManual(true, fan: 0)
        try modes.setTarget(3000, fan: 0)
        try modes.setManual(false, fan: 0)
        XCTAssertEqual(registers.values["F0md"], 0)
        XCTAssertFalse(registers.writes.contains { $0.0 == "Ftst" })
    }
    func testSuccessfulWriteWithoutReadbackIsRejected() throws {
        let registers = Registers()
        registers.values["F0Md"] = 0
        let modes = FanModeController(registers: registers)
        try modes.setManual(true, fan: 0)
        registers.ignoreTarget = true
        XCTAssertThrowsError(try modes.setTarget(2500, fan: 0))
    }
    func testSystemModeSkipsRejectedResetAndClearsUnlock() throws {
        let registers = Registers()
        registers.values["Ftst"] = 1
        let modes = FanModeController(registers: registers)
        try modes.setManual(false, fan: 0)
        XCTAssertEqual(registers.values["Ftst"], 0)
        XCTAssertFalse(registers.writes.contains { $0.0 == "F0Md" })
    }
    func testTwoFansRetainUnlockUntilBothReturnToAuto() throws {
        let registers = Registers()
        registers.values["Ftst"] = 1
        registers.ready = true
        let modes = FanModeController(registers: registers)
        try modes.setManual(true, fan: 0)
        try modes.setManual(true, fan: 1)
        try modes.setManual(false, fan: 0)
        XCTAssertEqual(registers.values["Ftst"], 1)
        try modes.setManual(false, fan: 1)
        XCTAssertEqual(registers.values["Ftst"], 0)
    }
    func testPreparationRetriesAndDoesNotClaimSuccessEarly() throws {
        let hardware = UnlockHardware()
        let subject = ControlEngine(hardware: hardware)
        let initial = try subject.apply(.init(mode: .manual, targets: [0: 2500]), now: 0)
        XCTAssertEqual(initial.preparing, true)
        XCTAssertEqual(initial.mode, .system)
        XCTAssertTrue(initial.targets.isEmpty)
        subject.tick(now: 1)
        XCTAssertEqual(subject.status.preparing, true)
        hardware.registers.ready = true
        subject.tick(now: 2)
        XCTAssertEqual(subject.status.preparing, false)
        XCTAssertEqual(subject.status.mode, .manual)
        XCTAssertEqual(hardware.registers.values["F0Md"], 1)
        XCTAssertEqual(subject.status.targets[0], 2500)
    }
    func testPreparationTimeoutResetsForceTest() throws {
        let hardware = UnlockHardware()
        let subject = ControlEngine(hardware: hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 2500]), now: 0)
        _ = subject.heartbeat(now: 7)
        subject.tick(now: 12)
        XCTAssertEqual(subject.status.mode, .system)
        XCTAssertEqual(subject.status.preparing, false)
        XCTAssertEqual(hardware.registers.values["Ftst"], 0)
    }
    func testWatchdogAndThermalProtectionWorkDuringHandoff() throws {
        for hot in [false, true] {
            let hardware = UnlockHardware()
            let subject = ControlEngine(hardware: hardware)
            _ = try subject.apply(.init(mode: .manual, targets: [0: 2500]), now: 0)
            if hot { hardware.pressure = .serious }
            subject.tick(now: hot ? 1 : 8)
            XCTAssertEqual(subject.status.mode, .system)
            XCTAssertEqual(subject.status.preparing, false)
            XCTAssertEqual(hardware.registers.values["Ftst"], 0)
        }
    }
    func testMissingModeNeverWritesBlindKeys() {
        let registers = Registers()
        registers.values = [:]
        let modes = FanModeController(registers: registers)
        XCTAssertThrowsError(try modes.setManual(true, fan: 0))
        XCTAssertTrue(registers.writes.isEmpty)
    }
    func testAsynchronousModeTargetAndResetWaitForReadback() throws {
        let registers = Registers()
        registers.values["F0Md"] = 0
        registers.values["Ftst"] = 1
        registers.deferred = ["F0Md", "F0Tg", "Ftst"]
        let modes = FanModeController(registers: registers)
        XCTAssertThrowsError(try modes.setManual(true, fan: 0)) { XCTAssertTrue($0 is FanControlPreparing) }
        XCTAssertEqual(registers.values["F0Md"], 0)
        registers.flush()
        try modes.setManual(true, fan: 0)
        XCTAssertThrowsError(try modes.setTarget(2500, fan: 0)) { XCTAssertTrue($0 is FanControlPreparing) }
        registers.flush()
        try modes.setTarget(2500, fan: 0)
        XCTAssertThrowsError(try modes.setManual(false, fan: 0)) { XCTAssertTrue($0 is FanControlPreparing) }
        registers.flush()
        XCTAssertThrowsError(try modes.setManual(false, fan: 0)) { XCTAssertTrue($0 is FanControlPreparing) }
        registers.flush()
        try modes.setManual(false, fan: 0)
        XCTAssertEqual(registers.values["F0Md"], 0)
        XCTAssertEqual(registers.values["Ftst"], 0)
    }
    func testChangingCurveKeepsInFlightTargetsUntilConfirmed() throws {
        final class DelayedTargets: FanHardware {
            let mock = MockHardware()
            var ready = false
            var attempts: [Double] = []
            func snapshot() -> HardwareSnapshot { mock.snapshot() }
            func setManual(_ manual: Bool, fan: Int) throws { try mock.setManual(manual, fan: fan) }
            func setTarget(_ rpm: Double, fan: Int) throws {
                attempts.append(rpm)
                if !ready { throw FanControlPreparing() }
                try mock.setTarget(rpm, fan: fan)
            }
        }
        let hardware = DelayedTargets()
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .curve), now: 0)
        let original = try XCTUnwrap(hardware.attempts.first)
        hardware.mock.reading.sensors[0].celsius = 70
        engine.tick(now: 1)
        XCTAssertEqual(hardware.attempts.last, original)
        hardware.ready = true
        engine.tick(now: 2)
        XCTAssertEqual(engine.status.targets[0], original)
        XCTAssertEqual(engine.status.preparing, false)
        engine.tick(now: 3)
        XCTAssertGreaterThan(try XCTUnwrap(engine.status.targets[0]), original)
    }
    func testAsynchronousRestoreIsVisibleAndBlocksNewControl() throws {
        final class DelayedRestore: FanHardware {
            let mock = MockHardware()
            var ready = false
            func snapshot() -> HardwareSnapshot { mock.snapshot() }
            func setManual(_ manual: Bool, fan: Int) throws {
                if !manual && !ready { throw FanControlPreparing() }
                try mock.setManual(manual, fan: fan)
            }
            func setTarget(_ rpm: Double, fan: Int) throws { try mock.setTarget(rpm, fan: fan) }
        }
        let hardware = DelayedRestore()
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 2500]), now: 0)
        try engine.restore(reason: nil)
        XCTAssertEqual(engine.status.restoring, true)
        XCTAssertThrowsError(try engine.apply(.init(mode: .manual, targets: [0: 2500]), now: 1))
        hardware.ready = true
        engine.tick(now: 2)
        XCTAssertEqual(engine.status.restoring, false)
        XCTAssertNoThrow(try engine.apply(.init(mode: .manual, targets: [0: 2500]), now: 3))
    }
}
