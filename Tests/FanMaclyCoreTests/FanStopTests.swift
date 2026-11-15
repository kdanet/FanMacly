import XCTest
@testable import FanMaclyCore

final class FanStopTests: XCTestCase {
    private var stoppingCurve: CoolingCurve {
        .init(points: [.init(40, 0), .init(80, 0), .init(85, 100)], allowsFanStop: true)
    }
    func testLegacyCurvesKeepTheirMeaningAndStopOptInRoundTrips() throws {
        let legacy = Data(#"{"points":[{"temperature":40,"percent":0},{"temperature":85,"percent":100}]}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(CoolingCurve.self, from: legacy).allowsFanStop)
        XCTAssertEqual(try JSONDecoder().decode(CoolingCurve.self, from: JSONEncoder().encode(stoppingCurve)), stoppingCurve)
        XCTAssertTrue(stoppingCurve.isValid)
    }
    func testCurveZeroOnlyStopsWithExplicitOptIn() throws {
        for allowed in [false, true] {
            let hardware = MockHardware()
            let engine = ControlEngine(hardware: hardware)
            var curve = stoppingCurve; curve.allowsFanStop = allowed
            _ = try engine.apply(.init(mode: .curve, curve: curve), now: 0)
            for time in [3.0, 6, 9, 12] { _ = engine.heartbeat(now: time); engine.tick(now: time) }
            XCTAssertEqual(hardware.targets[0], allowed ? 0 : hardware.reading.fans[0].safeMinimum)
        }
    }
    func testManualZeroStopsOnlyTheChosenFanAndCanRestart() throws {
        let hardware = MockHardware()
        hardware.reading.fans.append(.init(id: 1, current: 1800, minimum: 1350, maximum: 6000, manual: false))
        hardware.reading.fanCount = 2
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 0, 1: 2500]), now: 0)
        XCTAssertEqual(hardware.targets, [0: 0, 1: 2500])
        hardware.reading.fans[0].current = 0
        engine.tick(now: 1)
        XCTAssertEqual(engine.status.mode, .manual)
        XCTAssertEqual(hardware.targets[0], 0)
        _ = try engine.apply(.init(mode: .manual, targets: [0: 3000, 1: 2500]), now: 2)
        XCTAssertEqual(hardware.targets, [0: 3000, 1: 2500])
    }
    func testManualNonzeroTargetsStillClampToRunningRange() throws {
        for requested in [1.0, 500, 100000] {
            let hardware = MockHardware()
            let engine = ControlEngine(hardware: hardware)
            _ = try engine.apply(.init(mode: .manual, targets: [0: requested]), now: 0)
            XCTAssertEqual(hardware.targets[0], requested > 6000 ? 6000 : hardware.reading.fans[0].safeMinimum)
        }
        XCTAssertThrowsError(try ControlEngine(hardware: MockHardware()).apply(.init(mode: .manual, targets: [0: -1]), now: 0))
    }
    func testManualStopIsOverriddenByHeatAndSuspendedOnMissingSensors() throws {
        for reason in ["sensor", "serious", "critical"] {
            let hardware = MockHardware()
            let engine = ControlEngine(hardware: hardware)
            _ = try engine.apply(.init(mode: .manual, targets: [0: 0]), now: 0)
            if reason == "sensor" { hardware.reading.sensors = [] }
            if reason == "serious" { hardware.reading.thermalPressure = .serious }
            if reason == "critical" { hardware.reading.thermalPressure = .critical }
            for t in stride(from: 1.0, through: 4.5, by: 1) { engine.tick(now: t) }
            if reason == "serious" {
                XCTAssertEqual(engine.status.mode, .manual)
                XCTAssertEqual(hardware.targets[0], 6000, "heat overrides a stopped fan")
            } else {
                XCTAssertEqual(engine.status.mode, .system)
                XCTAssertEqual(hardware.modes.last?.1, false)
            }
        }
    }
    func testStoppedFanRestartsWhenCurveCallsForCooling() throws {
        let hardware = MockHardware()
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .curve, curve: stoppingCurve), now: 0)
        engine.tick(now: 3)
        XCTAssertEqual(hardware.targets[0], 0)
        hardware.reading.fans[0].current = 0
        var cooling = stoppingCurve; cooling.points[0].percent = 10; cooling.points[1].percent = 10
        _ = try engine.apply(.init(mode: .curve, curve: cooling), now: 4)
        XCTAssertGreaterThan(try XCTUnwrap(hardware.targets[0]), hardware.reading.fans[0].safeMinimum)
    }
    func testSensorFailureRestoresAutomationAfterStopOnceGraceExpires() throws {
        let hardware = MockHardware()
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .curve, curve: stoppingCurve), now: 0)
        engine.tick(now: 3)
        XCTAssertEqual(hardware.targets[0], 0)
        hardware.reading.sensors = []
        engine.tick(now: 4)
        XCTAssertEqual(engine.status.mode, .curve)
        engine.tick(now: 5); engine.tick(now: 7.1)
        XCTAssertEqual(engine.status.mode, .system)
        XCTAssertEqual(hardware.modes.last?.1, false)
    }
    func testSustainedHotspotOverridesStopWithMaximumCooling() throws {
        let hardware = MockHardware()
        hardware.reading.sensors = [.init(id: "TCMb", name: "CPU", group: .cpu, celsius: 60)]
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .curve, curve: stoppingCurve), now: 0)
        engine.tick(now: 3)
        XCTAssertEqual(hardware.targets[0], 0)
        hardware.reading.sensors.append(.init(id: "Tp01", name: "Hotspot", group: .cpu, celsius: 107))
        for t in stride(from: 4.0, through: 10, by: 1) { engine.tick(now: t) }
        XCTAssertEqual(hardware.targets[0], hardware.reading.fans[0].maximum)
    }
    func testGovernorDoesNotLeaveAnUncommandedLowRPMAtTheStopBoundary() {
        let fan = FanReading(id: 0, current: 1450, minimum: 1350, maximum: 5777, manual: true)
        var governor = CurveFanGovernor()
        governor.reset(fans: [fan], targets: [:], now: 0, allowsFanStop: true)
        XCTAssertEqual(governor.propose(fans: [fan], desired: [0: 0], now: 2, emergency: false, allowsFanStop: true)[0], 1450)
        XCTAssertEqual(governor.propose(fans: [fan], desired: [0: 0], now: 3, emergency: false, allowsFanStop: true)[0], 0)
        XCTAssertEqual(governor.propose(fans: [fan], desired: [0: -1], now: 3, emergency: false, allowsFanStop: true)[0], 1450)
    }
}
