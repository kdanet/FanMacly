import XCTest
@testable import FanMaclyCore

private final class BufferedTargets: FanHardware {
    var temperature = 60.0
    var reported: [Int: Double] = [0: 2500, 1: 2500]
    var queued: [Int: Double] = [:]
    var attempts: [(Int, Double)] = []
    var fanCount = 1
    func snapshot() -> HardwareSnapshot {
        .init(fans: (0..<fanCount).map { .init(id: $0, current: reported[$0], minimum: 1350, maximum: 5777, manual: true) }, sensors: [.init(id: "TC0D", name: "CPU", group: .cpu, celsius: temperature)], fanCount: fanCount)
    }
    func setManual(_ manual: Bool, fan: Int) throws {}
    func setTarget(_ rpm: Double, fan: Int) throws {
        attempts.append((fan, rpm))
        guard abs((reported[fan] ?? 0) - rpm) <= 2 else {
            queued[fan] = rpm
            throw FanControlPreparing()
        }
    }
    func flush(_ fan: Int) { if let value = queued.removeValue(forKey: fan) { reported[fan] = value } }
}

final class TargetTransitionTests: XCTestCase {
    func testReconciliationNeverRewritesOldManualTargetDuringChange() throws {
        let hardware = BufferedTargets()
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 2500]), now: 0)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 4000]), now: 2)
        hardware.flush(0)
        engine.tick(now: 2.3)
        XCTAssertEqual(hardware.attempts.last?.1, 4000)
        XCTAssertNil(hardware.queued[0], "The confirmed old target must never overwrite the new command")
        engine.tick(now: 3.2)
        XCTAssertEqual(engine.status.targets[0], 4000)
        XCTAssertEqual(engine.status.preparing, false)
    }

    func testCurveWaitsForWholeBatchWhenFansConfirmAtDifferentTimes() throws {
        let hardware = BufferedTargets(); hardware.fanCount = 2
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .curve), now: 0)
        engine.tick(now: 3)
        let batch = hardware.queued
        XCTAssertEqual(batch.count, 2)
        hardware.flush(0)
        engine.tick(now: 4)
        hardware.temperature = 75
        hardware.flush(1)
        hardware.attempts = []
        engine.tick(now: 5)
        XCTAssertEqual(hardware.attempts.first { $0.0 == 0 }?.1, batch[0])
        XCTAssertEqual(engine.status.preparing, false, "A new curve sample must not prevent the previous batch from completing")
        _ = engine.heartbeat(now: 7)
        engine.tick(now: 9)
        XCTAssertGreaterThan(hardware.queued[0] ?? 0, batch[0] ?? 0)
    }

    func testTargetTimeoutReportsTargetStageAndRestores() throws {
        let hardware = BufferedTargets()
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 4000]), now: 0)
        XCTAssertEqual(engine.status.preparationStage, .targets)
        _ = engine.heartbeat(now: 5)
        engine.tick(now: 6)
        XCTAssertEqual(engine.status.mode, .system)
        XCTAssertTrue(engine.status.message?.contains("новые обороты") == true)
        XCTAssertNil(engine.status.preparationStage)
    }

    func testTargetConfirmationGetsOwnDeadlineAfterSlowModeHandoff() throws {
        final class SlowHandoff: FanHardware {
            let mock = MockHardware()
            var modeReady = false
            var targetReady = false
            func snapshot() -> HardwareSnapshot { mock.snapshot() }
            func setManual(_ manual: Bool, fan: Int) throws { if manual && !modeReady { throw FanControlPreparing() } }
            func setTarget(_ rpm: Double, fan: Int) throws { if !targetReady { throw FanControlPreparing() } }
        }
        let hardware = SlowHandoff()
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 4000]), now: 0)
        XCTAssertEqual(engine.status.preparationStage, .handoff)
        _ = engine.heartbeat(now: 7)
        hardware.modeReady = true
        engine.tick(now: 11)
        XCTAssertEqual(engine.status.preparationStage, .targets)
        engine.tick(now: 12.2)
        XCTAssertEqual(engine.status.preparing, true)
        XCTAssertNil(engine.status.message)
        hardware.targetReady = true
        engine.tick(now: 14)
        XCTAssertEqual(engine.status.mode, .manual)
        XCTAssertEqual(engine.status.preparing, false)
    }
}
