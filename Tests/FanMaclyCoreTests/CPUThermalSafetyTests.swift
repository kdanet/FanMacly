import XCTest
@testable import FanMaclyCore

final class CPUThermalSafetyTests: XCTestCase {
    private func hardware() -> MockHardware {
        let hardware = MockHardware()
        hardware.reading.sensors = [
            .init(id: "TCMb", name: "CPU", group: .cpu, celsius: 68),
            .init(id: "TCMz", name: "Hotspot", group: .cpu, celsius: 75)
        ]
        hardware.reading.thermalPressure = .nominal
        return hardware
    }
    func testSingleNinetyFourDegreeHotspotDoesNotCancelEitherMode() throws {
        for mode in [CoolingMode.curve, .manual] {
            let hardware = hardware(); let engine = ControlEngine(hardware: hardware)
            _ = try engine.apply(.init(mode: mode, targets: [0: 3000]), now: 0)
            hardware.reading.sensors[1].celsius = 94
            engine.tick(now: 1)
            XCTAssertEqual(engine.status.mode, mode)
            XCTAssertNil(engine.status.thermalEvent)
            XCTAssertEqual(engine.status.controlTemperature, 68)
            hardware.reading.sensors[1].celsius = 75
            engine.tick(now: 2)
            XCTAssertEqual(engine.status.mode, mode)
            XCTAssertNil(engine.status.message)
        }
    }
    func testPersistentHotspotBoostsCoolingWithoutCancellingProfile() throws {
        let hardware = hardware(); let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .curve), now: 0)
        hardware.reading.sensors[1].celsius = 96
        for second in 1...20 {
            _ = engine.heartbeat(now: Double(second)); engine.tick(now: Double(second))
            XCTAssertEqual(engine.status.mode, .curve)
            XCTAssertNil(engine.status.thermalEvent)
            XCTAssertNil(engine.status.automaticFallbackID)
        }
        XCTAssertEqual(hardware.targets[0], 6000)
        XCTAssertTrue(engine.status.coolingBoost)
    }
    func testRawControlAndCriticalHotspotBoostBothCustomModesImmediately() throws {
        for mode in [CoolingMode.curve, .manual] {
            for controlHot in [false, true] {
                let hardware = hardware(); let engine = ControlEngine(hardware: hardware)
                _ = try engine.apply(.init(mode: mode, targets: [0: 0]), now: 0)
                hardware.reading.sensors[controlHot ? 0 : 1].celsius = controlHot ? 90 : 105
                engine.tick(now: 1)
                XCTAssertEqual(engine.status.mode, mode)
                XCTAssertEqual(hardware.targets[0], 6000)
                XCTAssertTrue(engine.status.coolingBoost)
                XCTAssertNil(engine.status.thermalEvent)
            }
        }
    }
    func testOnlySystemThermalPressureImmediatelyHandsBackToMacOS() throws {
        for state in [ThermalPressure.serious, .critical] {
            let hardware = hardware(); let engine = ControlEngine(hardware: hardware)
            _ = try engine.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
            hardware.reading.thermalPressure = state
            engine.tick(now: 1)
            XCTAssertEqual(engine.status.mode, .system)
            XCTAssertEqual(engine.status.thermalEvent?.cause, .systemPressure)
            XCTAssertNotNil(engine.status.automaticFallbackID)
            XCTAssertEqual(hardware.modes.last?.1, false)
        }
    }
    func testUnknownModelUsesMaximumCoolingInsteadOfAnInventedChipLimit() throws {
        let hardware = MockHardware(); let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 0]), now: 0)
        hardware.reading.sensors[0].celsius = 90
        engine.tick(now: 1)
        XCTAssertEqual(engine.status.mode, .manual)
        XCTAssertEqual(hardware.targets[0], 6000)
        XCTAssertNil(engine.status.thermalEvent)
    }
    func testDuplicatesAndGapsCannotConfirmBoostOrCooling() {
        let hardware = hardware(); hardware.reading.sensors[1].celsius = 96
        var guardrail = CPUThermalSafety()
        XCTAssertNil(guardrail.observe(hardware.reading, now: 0))
        for _ in 0..<10 { _ = guardrail.observe(hardware.reading, now: 0) }
        XCTAssertFalse(guardrail.requiresMaximumCooling)
        _ = guardrail.observe(hardware.reading, now: 3)
        _ = guardrail.observe(hardware.reading, now: 4)
        XCTAssertFalse(guardrail.requiresMaximumCooling)
        XCTAssertNil(guardrail.observe(hardware.reading, now: 5))
        XCTAssertTrue(guardrail.requiresMaximumCooling)
        hardware.reading.sensors[1].celsius = 75
        _ = guardrail.observe(hardware.reading, now: 6)
        for _ in 0..<10 { _ = guardrail.observe(hardware.reading, now: 6) }
        _ = guardrail.observe(hardware.reading, now: 11)
        XCTAssertTrue(guardrail.requiresMaximumCooling)
        for second in 12...16 { _ = guardrail.observe(hardware.reading, now: Double(second)) }
        XCTAssertFalse(guardrail.requiresMaximumCooling)
    }
    func testMovingHotspotNeverProducesASustainedPeakWarning() throws {
        let hardware = hardware(); let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .curve), now: 0)
        for second in 1...8 {
            hardware.reading.sensors[1].id = second.isMultiple(of: 2) ? "Tp01" : "Tp02"
            hardware.reading.sensors[1].celsius = 96
            _ = engine.heartbeat(now: Double(second)); engine.tick(now: Double(second))
            XCTAssertEqual(engine.status.mode, .curve)
            XCTAssertNil(engine.status.thermalEvent)
        }
        XCTAssertEqual(hardware.targets[0], 6000)
    }
    func testHotApplyStartsCoolingInsteadOfRejectingProfile() throws {
        let hardware = hardware(); hardware.reading.sensors[0].celsius = 97
        let engine = ControlEngine(hardware: hardware)
        let status = try engine.apply(.init(mode: .curve), now: 0)
        XCTAssertEqual(status.mode, .curve)
        XCTAssertTrue(status.coolingBoost)
        XCTAssertEqual(hardware.targets[0], 6000)
        XCTAssertNil(status.thermalEvent)
    }
    func testAutomaticModeDoesNotWriteFansEvenWhenHot() {
        let hardware = hardware(); hardware.reading.sensors[0].celsius = 97
        let engine = ControlEngine(hardware: hardware)
        for second in 0...10 { engine.tick(now: Double(second)) }
        XCTAssertEqual(engine.status.mode, .system)
        XCTAssertFalse(engine.status.coolingBoost)
        XCTAssertTrue(hardware.modes.isEmpty)
        XCTAssertEqual(hardware.targetWriteCount, 0)
    }
    func testBoostTemporarilyOverridesStopAndThenRestoresRequestedZero() throws {
        let hardware = hardware(); let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 0]), now: 0)
        hardware.reading.sensors[1].celsius = 105
        engine.tick(now: 1)
        XCTAssertEqual(hardware.targets[0], 6000)
        hardware.reading.sensors[1].celsius = 75
        for second in 2...6 {
            _ = engine.heartbeat(now: Double(second)); engine.tick(now: Double(second))
            XCTAssertEqual(hardware.targets[0], 6000)
        }
        engine.tick(now: 7)
        XCTAssertFalse(engine.status.coolingBoost)
        XCTAssertEqual(engine.status.mode, .manual)
        XCTAssertEqual(hardware.targets[0], 0)
        XCTAssertNil(engine.status.thermalEvent)
    }
    func testWatchdogStillReturnsToAutoDuringMaximumCooling() throws {
        let hardware = hardware(); hardware.reading.sensors[0].celsius = 97
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .curve), now: 0)
        XCTAssertTrue(engine.status.coolingBoost)
        engine.tick(now: 8)
        XCTAssertEqual(engine.status.mode, .system)
        XCTAssertFalse(engine.status.coolingBoost)
        XCTAssertTrue(engine.status.targets.isEmpty)
        XCTAssertEqual(hardware.modes.last?.1, false)
    }
    func testThermalNoticeClearsAfterCoolingWithoutResumingOldRequest() throws {
        let hardware = hardware(); let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .curve), now: 0)
        hardware.reading.thermalPressure = .serious; engine.tick(now: 1)
        let id = engine.status.automaticFallbackID
        hardware.reading.thermalPressure = .nominal
        hardware.reading.sensors[1].celsius = 75
        for second in 2...6 { engine.tick(now: Double(second)); XCTAssertNotNil(engine.status.thermalEvent) }
        engine.tick(now: 7)
        XCTAssertNil(engine.status.thermalEvent)
        XCTAssertNil(engine.status.message)
        XCTAssertEqual(engine.status.automaticFallbackID, id)
        XCTAssertEqual(engine.status.mode, .system)
        XCTAssertTrue(engine.status.targets.isEmpty)
        XCTAssertEqual(engine.status.customControlAllowed, true)
    }
    func testOldNoticeRetiresEvenIfMacOSIsStillCooling() throws {
        let hardware = hardware(); let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .curve), now: 0)
        hardware.reading.thermalPressure = .serious; engine.tick(now: 1)
        for second in 2...30 { engine.tick(now: Double(second)) }
        XCTAssertNotNil(engine.status.thermalEvent)
        engine.tick(now: 31)
        XCTAssertNil(engine.status.thermalEvent)
        XCTAssertEqual(engine.status.mode, .system)
        XCTAssertEqual(engine.status.customControlAllowed, false)
    }
    func testSystemPressureDuringApplyReturnsStructuredFallback() throws {
        let hardware = hardware(); let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        hardware.reading.thermalPressure = .serious
        let status = try engine.apply(.init(mode: .curve), now: 0.2)
        XCTAssertEqual(status.mode, .system)
        XCTAssertEqual(status.thermalEvent?.cause, .systemPressure)
        XCTAssertNil(status.message)
        XCTAssertEqual(hardware.modes.last?.1, false)
    }
    func testRestorationFailureIsNeverHiddenAsAnExpiredNotice() throws {
        let hardware = hardware(); let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        hardware.failRestore = true; hardware.reading.thermalPressure = .serious
        engine.tick(now: 1)
        hardware.reading.sensors[1].celsius = 75
        engine.tick(now: 40)
        XCTAssertEqual(engine.status.restoring, true)
        XCTAssertNotNil(engine.status.message)
        XCTAssertNil(engine.status.thermalEvent)
        XCTAssertNotNil(engine.status.automaticFallbackID)
    }
    func testNoticeCannotExpireBeforeHardwareConfirmsAutomaticMode() throws {
        final class DeferredRestore: FanHardware {
            let base: MockHardware
            var ready = false
            init(_ base: MockHardware) { self.base = base }
            func snapshot() -> HardwareSnapshot { base.snapshot() }
            func setTarget(_ rpm: Double, fan: Int) throws { try base.setTarget(rpm, fan: fan) }
            func setManual(_ manual: Bool, fan: Int) throws {
                if !manual && !ready { throw FanControlPreparing() }
                try base.setManual(manual, fan: fan)
            }
        }
        let base = hardware(); let deferred = DeferredRestore(base)
        let engine = ControlEngine(hardware: deferred)
        _ = try engine.apply(.init(mode: .curve), now: 0)
        base.reading.thermalPressure = .serious
        engine.tick(now: 1)
        XCTAssertEqual(engine.status.restoring, true)
        XCTAssertNotNil(engine.status.thermalEvent)
        base.reading.thermalPressure = .nominal
        base.reading.sensors[1].celsius = 75
        engine.tick(now: 40)
        XCTAssertNotNil(engine.status.thermalEvent)
        XCTAssertEqual(engine.status.customControlAllowed, false)
        deferred.ready = true
        engine.tick(now: 41)
        XCTAssertEqual(engine.status.restoring, false)
        XCTAssertNil(engine.status.thermalEvent)
        XCTAssertEqual(engine.status.mode, .system)
    }
}
