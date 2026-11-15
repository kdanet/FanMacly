import XCTest
@testable import FanMaclyCore

final class MockHardware: FanHardware {
    var reading = HardwareSnapshot(fans: [FanReading(id: 0, current: 2000, minimum: 1000, maximum: 6000, manual: false)], sensors: [.init(id: "TC0D", name: "CPU", group: .cpu, celsius: 60)], fanCount: 1)
    var modes: [(Int, Bool)] = []
    var targets: [Int: Double] = [:]
    var targetWriteCount = 0
    var failTarget = false
    var failRestore = false
    func snapshot() -> HardwareSnapshot { reading }
    func setManual(_ manual: Bool, fan: Int) throws {
        modes.append((fan, manual))
        if !manual && failRestore { throw FanMaclyError.message("restore failed") }
    }
    func setTarget(_ rpm: Double, fan: Int) throws {
        targetWriteCount += 1
        if failTarget { throw FanMaclyError.message("write failed") }
        targets[fan] = rpm
    }
}

final class ControlEngineTests: XCTestCase {
    func testSettledAutomaticModeNeverWritesTargetsOrReacquiresFans() throws {
        for previouslyManual in [false, true] {
            let hardware = MockHardware()
            let engine = ControlEngine(hardware: hardware)
            if previouslyManual {
                _ = try engine.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
                _ = try engine.apply(.init(mode: .system), now: 1)
                XCTAssertEqual(hardware.modes.map(\.1), [true, false])
            }
            let modeWrites = hardware.modes.count
            let targetWrites = hardware.targetWriteCount
            for second in 2...32 {
                _ = engine.heartbeat(now: Double(second))
                engine.tick(now: Double(second))
            }
            XCTAssertEqual(engine.status.mode, .system)
            XCTAssertFalse(engine.status.restoring == true)
            XCTAssertTrue(engine.status.targets.isEmpty)
            XCTAssertEqual(hardware.modes.count, modeWrites)
            XCTAssertEqual(hardware.targetWriteCount, targetWrites)
        }
    }
    func testOverdueHeartbeatExpiresLeaseBeforeTimerRuns() throws {
        for mode in [CoolingMode.manual, .curve] {
            let hardware = MockHardware()
            let engine = ControlEngine(hardware: hardware)
            _ = try engine.apply(.init(mode: mode, targets: [0: 3000]), now: 100)
            let status = engine.heartbeat(now: 108)
            XCTAssertEqual(status.mode, .system)
            XCTAssertNotNil(status.automaticFallbackID)
            XCTAssertEqual(hardware.modes.last?.1, false)
            _ = engine.heartbeat(now: 110)
            engine.tick(now: 111)
            XCTAssertEqual(engine.status.mode, .system)
        }
    }
    func testOverdueRequestCannotRenewLeaseBeforeTimerRuns() throws {
        let hardware = MockHardware()
        let engine = ControlEngine(hardware: hardware)
        let request = ControlRequest(mode: .manual, targets: [0: 3000])
        _ = try engine.apply(request, now: 100)
        let result = try engine.apply(request, now: 108)
        XCTAssertEqual(result.mode, .system)
        XCTAssertNotNil(result.automaticFallbackID)
        XCTAssertEqual(hardware.modes.map(\.1), [true, false])
    }
    func testHeartbeatBeforeDeadlineKeepsLeaseAlive() throws {
        let hardware = MockHardware()
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 3000]), now: 100)
        XCTAssertEqual(engine.heartbeat(now: 107.9).mode, .manual)
        engine.tick(now: 108)
        XCTAssertEqual(engine.status.mode, .manual)
        engine.tick(now: 115.9)
        XCTAssertEqual(engine.status.mode, .system)
    }
    func testOverdueHeartbeatRetriesFailedResetAndRejectsStaleCommands() throws {
        let hardware = MockHardware()
        let engine = ControlEngine(hardware: hardware)
        let stale = ControlRequest(mode: .manual, targets: [0: 0])
        _ = try engine.apply(stale, now: 0)
        hardware.failRestore = true
        let status = engine.heartbeat(now: 8)
        XCTAssertEqual(status.mode, .system)
        XCTAssertTrue(status.restoring == true)
        XCTAssertNotNil(status.automaticFallbackID)
        hardware.failRestore = false
        engine.tick(now: 8.3)
        XCTAssertFalse(engine.status.restoring == true)
        XCTAssertEqual(try engine.apply(stale, now: 9).mode, .system)
        XCTAssertEqual(hardware.modes.last?.1, false)
    }
    func testSuccessfulRestoreClearsRetryErrorButPreservesOriginalReason() throws {
        for reason in [nil, "watchdog"] as [String?] {
            let hardware = MockHardware()
            let engine = ControlEngine(hardware: hardware)
            _ = try engine.apply(.init(mode: .manual, targets: [0: 0]), now: 0)
            hardware.failRestore = true
            XCTAssertThrowsError(try engine.restore(reason: reason))
            XCTAssertTrue(engine.status.message?.contains("restore failed") == true)
            hardware.failRestore = false
            engine.tick(now: 1)
            XCTAssertFalse(engine.status.restoring == true)
            XCTAssertEqual(engine.status.message, reason)
        }
    }
    func testEveryProtectiveRestorePublishesAStableFallbackGeneration() throws {
        for reason in ["watchdog", "sensor", "battery", "target"] {
            let hardware = MockHardware()
            let subject = ControlEngine(hardware: hardware)
            _ = try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
            if reason == "sensor" { hardware.reading.sensors = [] }
            if reason == "battery" { hardware.reading.sensors.append(.init(id: "TB0T", name: "Battery", group: .battery, celsius: 50)) }
            if reason == "target" { hardware.failTarget = true }
            subject.tick(now: reason == "watchdog" ? 8 : 2)
            let id = try XCTUnwrap(subject.status.automaticFallbackID)
            XCTAssertEqual(subject.status.mode, .system)
            subject.tick(now: 9)
            XCTAssertEqual(subject.status.automaticFallbackID, id)
        }
    }
    func testLateRequestCannotRestartAfterWatchdogFallback() throws {
        let hardware = MockHardware()
        let subject = ControlEngine(hardware: hardware)
        let stale = ControlRequest(mode: .manual, targets: [0: 3000])
        _ = try subject.apply(stale, now: 0)
        subject.tick(now: 8)
        let writes = hardware.modes.count
        let result = try subject.apply(stale, now: 9)
        XCTAssertEqual(result.mode, .system)
        XCTAssertEqual(hardware.modes.count, writes)
        let fresh = ControlRequest(mode: .manual, targets: [0: 3500], expectedFallbackID: result.automaticFallbackID)
        XCTAssertEqual(try subject.apply(fresh, now: 10).mode, .manual)
    }
    func testFailedValidationOfNewRequestImmediatelyStopsOldManualControl() throws {
        let hardware = MockHardware()
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        hardware.reading.sensors = []
        XCTAssertThrowsError(try engine.apply(.init(mode: .curve), now: 0.2))
        XCTAssertEqual(engine.status.mode, .system)
        XCTAssertEqual(hardware.modes.last?.1, false)
        XCTAssertNotNil(engine.status.automaticFallbackID)
    }
    func testMissingTachometerStopsCustomControlAndInvalidTachometerCannotAcquire() throws {
        let hardware = MockHardware()
        let subject = ControlEngine(hardware: hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        hardware.reading.fans[0].current = nil
        subject.tick(now: 1)
        XCTAssertEqual(subject.status.mode, .system)
        XCTAssertNotNil(subject.status.automaticFallbackID)
        for bad in [Double.nan, -1, 20001] {
            let other = MockHardware(); other.reading.fans[0].current = bad
            XCTAssertThrowsError(try ControlEngine(hardware: other).apply(.init(mode: .manual, targets: [0: 3000]), now: 0))
            XCTAssertTrue(other.modes.isEmpty)
        }
    }
    func testManualClampsToSafeHardwareRange() throws {
        let hardware = MockHardware()
        let subject = ControlEngine(hardware: hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 50]), now: 0)
        XCTAssertEqual(hardware.targets[0], 1200)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 99999]), now: 1)
        XCTAssertEqual(hardware.targets[0], 6000)
    }
    func testWatchdogRestoresDespiteWallClockChanges() throws {
        let hardware = MockHardware()
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 3000]), now: 100)
        engine.tick(now: 107.9)
        XCTAssertEqual(engine.status.mode, .manual)
        engine.tick(now: 108)
        XCTAssertEqual(engine.status.mode, .system)
        XCTAssertEqual(hardware.modes.last?.1, false)
    }
    func testWriteFailureRollsBackMode() {
        let hardware = MockHardware(); hardware.failTarget = true
        let engine = ControlEngine(hardware: hardware)
        XCTAssertThrowsError(try engine.apply(.init(mode: .manual, targets: [0: 3000]), now: 0))
        XCTAssertEqual(hardware.modes.map(\.1), [true, false])
        XCTAssertEqual(engine.status.mode, .system)
    }
    func testRestoreFailureRetriesAndBlocksNewControl() throws {
        let hardware = MockHardware()
        let subject = ControlEngine(hardware: hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        hardware.failRestore = true
        XCTAssertThrowsError(try subject.restore(reason: nil))
        XCTAssertThrowsError(try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 1))
        hardware.failRestore = false
        subject.tick(now: 2)
        XCTAssertNoThrow(try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 3))
    }
    func testSystemThermalPressureAndMissingSensorRestoreControl() throws {
        for missing in [false, true] {
            let hardware = MockHardware()
            let subject = ControlEngine(hardware: hardware)
            _ = try subject.apply(.init(mode: .curve), now: 0)
            if missing { hardware.reading.sensors = [] } else { hardware.reading.thermalPressure = .serious }
            subject.tick(now: 2)
            XCTAssertEqual(subject.status.mode, .system)
            XCTAssertEqual(hardware.modes.last?.1, false)
        }
    }
    func testRejectsNaNAndUnknownFanBeforeModeWrite() {
        let hardware = MockHardware()
        let subject = ControlEngine(hardware: hardware)
        XCTAssertThrowsError(try subject.apply(.init(mode: .manual, targets: [0: .nan]), now: 0))
        XCTAssertThrowsError(try subject.apply(.init(mode: .manual, targets: [9: 3000]), now: 0))
        XCTAssertTrue(hardware.modes.isEmpty)
    }
    func testCurveFiltersBriefDropsAndReducesSpeedGradually() throws {
        let hardware = MockHardware()
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .curve), now: 0)
        let initial = try XCTUnwrap(hardware.targets[0])
        hardware.reading.sensors[0].celsius = 59
        engine.tick(now: 2)
        XCTAssertEqual(hardware.targets[0], initial)
        hardware.reading.sensors[0].celsius = 61
        engine.tick(now: 4)
        XCTAssertGreaterThan(try XCTUnwrap(hardware.targets[0]), initial)
        hardware.reading.sensors[0].celsius = 55
        engine.tick(now: 6)
        let beforeCooling = try XCTUnwrap(hardware.targets[0])
        XCTAssertGreaterThan(beforeCooling, initial)
        hardware.reading.sensors[0].celsius = 40
        for second in 7...35 { _ = engine.heartbeat(now: Double(second)); engine.tick(now: Double(second)) }
        XCTAssertLessThan(try XCTUnwrap(hardware.targets[0]), beforeCooling)
    }
    func testBatteryAndGPUOverheatRestore() throws {
        for (group, degrees) in [(SensorGroup.battery, 50.0), (.gpu, 95.0)] {
            let hardware = MockHardware()
            let engine = ControlEngine(hardware: hardware)
            _ = try engine.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
            hardware.reading.sensors.append(.init(id: "test", name: "test", group: group, celsius: degrees))
            engine.tick(now: 2)
            XCTAssertEqual(engine.status.mode, .system)
        }
    }
    func testHardwareChangeStopsAllControlledFans() throws {
        let hardware = MockHardware()
        hardware.reading.fans.append(.init(id: 1, current: 2000, minimum: 1000, maximum: 6000, manual: false))
        hardware.reading.fanCount = 2
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .curve), now: 0)
        hardware.reading.fans.removeLast()
        hardware.reading.fanCount = 1
        engine.tick(now: 2)
        XCTAssertEqual(engine.status.mode, .system)
        XCTAssertEqual(Set(hardware.modes.filter { !$0.1 }.map(\.0)), [0, 1])
    }
    func testSecondFanWriteFailureRestoresBothFans() {
        final class FailingSecondFan: FanHardware {
            let mock = MockHardware()
            var restored = Set<Int>()
            func snapshot() -> HardwareSnapshot {
                var value = mock.snapshot()
                value.fans.append(.init(id: 1, current: 2000, minimum: 1000, maximum: 6000, manual: false))
                value.fanCount = 2
                return value
            }
            func setManual(_ manual: Bool, fan: Int) throws { if !manual { restored.insert(fan) } }
            func setTarget(_ rpm: Double, fan: Int) throws { if fan == 1 { throw FanMaclyError.message("second write failed") } }
        }
        let hardware = FailingSecondFan()
        let engine = ControlEngine(hardware: hardware)
        XCTAssertThrowsError(try engine.apply(.init(mode: .curve), now: 0))
        XCTAssertEqual(hardware.restored, [0, 1])
    }
}

final class RecoveryTests: XCTestCase {
    func testFailedFirstFanDoesNotBlockOtherFanRecovery() throws {
        final class Hardware: FanHardware {
            var failFirst = true
            var restored = [Int]()
            func snapshot() -> HardwareSnapshot { MockHardware().snapshot() }
            func setTarget(_ rpm: Double, fan: Int) throws {}
            func setManual(_ manual: Bool, fan: Int) throws {
                guard !manual else { return }
                if fan == 0 && failFirst { throw FanControlPreparing() }
                restored.append(fan)
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owned.json")
        let hardware = Hardware()
        let first = try JournaledHardware(hardware: hardware, journalURL: url)
        try first.setManual(true, fan: 0)
        try first.setManual(true, fan: 1)
        let restarted = try JournaledHardware(hardware: hardware, journalURL: url)
        XCTAssertThrowsError(try restarted.recover())
        XCTAssertEqual(hardware.restored, [1])
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: Data(contentsOf: url)), [0])
        hardware.failFirst = false
        try restarted.recover()
        XCTAssertEqual(hardware.restored, [1, 0])
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: Data(contentsOf: url)), [])
    }
    func testNewDaemonRecoversPersistedOwnership() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owned.json")
        let hardware = MockHardware()
        let first = try JournaledHardware(hardware: hardware, journalURL: url)
        try first.setManual(true, fan: 0)
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: Data(contentsOf: url)), [0])
        let restarted = try JournaledHardware(hardware: hardware, journalURL: url)
        try restarted.recover()
        XCTAssertEqual(hardware.modes.last?.1, false)
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: Data(contentsOf: url)), [])
    }
    func testFailedRecoveryRetainsJournalForNextAttempt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owned.json")
        let hardware = MockHardware()
        let first = try JournaledHardware(hardware: hardware, journalURL: url)
        try first.setManual(true, fan: 0)
        hardware.failRestore = true
        let restarted = try JournaledHardware(hardware: hardware, journalURL: url)
        XCTAssertThrowsError(try restarted.recover())
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: Data(contentsOf: url)), [0])
        hardware.failRestore = false
        XCTAssertNoThrow(try restarted.recover())
    }
}

final class DataTests: XCTestCase {
    func testSMCFormatsAndInvalidValues() {
        XCTAssertEqual(SMCNumber.decode(type: "flt ", bytes: [0, 0, 112, 66]), 60)
        XCTAssertEqual(SMCNumber.decode(type: "sp78", bytes: [255, 128]), -0.5)
        XCTAssertEqual(SMCNumber.decode(type: "fpe2", bytes: [31, 66]), 2000.5)
        XCTAssertEqual(SMCNumber.decode(type: "ui16", bytes: [1, 0]), 256)
        XCTAssertNil(SMCNumber.decode(type: "flt ", bytes: [0, 0, 128, 127]))
        XCTAssertNil(SMCNumber.decode(type: "sp78", bytes: [0]))
        XCTAssertEqual(SMCNumber.name(SMCNumber.fourCC("F0Ac")), "F0Ac")
    }
    func testCurveBoundariesInterpolationAndValidation() {
        XCTAssertEqual(CoolingCurve.balanced.percent(at: 0), 0)
        XCTAssertEqual(CoolingCurve.balanced.percent(at: 60), 32.5)
        XCTAssertEqual(CoolingCurve.balanced.percent(at: 100), 100)
        XCTAssertNil(CoolingCurve.balanced.percent(at: .nan))
        XCTAssertFalse(CoolingCurve(points: [.init(50, 60), .init(40, 100)]).isValid)
        XCTAssertFalse(CoolingCurve(points: [.init(40, 0), .init(90, 100)]).isValid)
        XCTAssertFalse(CoolingCurve(points: [.init(40, 80), .init(60, 20), .init(85, 100)]).isValid)
    }
}
