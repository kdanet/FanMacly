import XCTest
@testable import FanMaclyCore

final class ThermalRegulationTests: XCTestCase {
    func testSourceChangeAndLossResetFilterHistory() {
        var filter = CPUTemperatureFilter()
        XCTAssertEqual(filter.update(reading: .init(source: "TCMb", celsius: 50), now: 0), 50)
        XCTAssertEqual(filter.update(reading: .init(source: "TCMb", celsius: 50), now: 1), 50)
        XCTAssertEqual(filter.update(reading: .init(source: "TCDX", celsius: 70), now: 2), 70)
        XCTAssertNil(filter.update(reading: nil, now: 3))
        XCTAssertEqual(filter.update(reading: .init(source: "TCMb", celsius: 45), now: 4), 45)
    }
    func testPrimaryReadingExcludesMemoryBatteryAndInvalidAggregates() {
        let snapshot = HardwareSnapshot(sensors: [
            .init(id: "TB0T", name: "Battery", group: .battery, celsius: 110),
            .init(id: "TPMP", name: "Memory", group: .memory, celsius: 115),
            .init(id: "TCMb", name: "Invalid", group: .cpu, celsius: .nan),
            .init(id: "TCMz", name: "Peak", group: .cpu, celsius: 74),
            .init(id: "Tp01", name: "Core", group: .cpu, celsius: 80)
        ])
        XCTAssertEqual(snapshot.cpuControlReading?.source, "TCMz")
        XCTAssertEqual(snapshot.cpuControlReading?.celsius, 74)
        XCTAssertEqual(snapshot.hottestCPU, 80)
    }
    func testHelperPublishesRawFilteredAndSourceFromItsActualSample() throws {
        let hardware = MockHardware()
        hardware.reading.sensors = [.init(id: "TCMb", name: "CPU", group: .cpu, celsius: 50)]
        let engine = ControlEngine(hardware: hardware)
        engine.tick(now: 0)
        hardware.reading.sensors[0].celsius = 70
        engine.tick(now: 1)
        XCTAssertEqual(engine.status.rawControlTemperature, 70)
        XCTAssertEqual(engine.status.temperatureSource, "TCMb")
        XCTAssertLessThan(try XCTUnwrap(engine.status.controlTemperature), 52)
        XCTAssertEqual(engine.status.peakCPUReading?.celsius, 70)
        XCTAssertEqual(engine.status.temperatureSampleDate, hardware.reading.date)
    }
    func testStablePackageReadingIsIndependentOfHotspot() throws {
        let snapshot = HardwareSnapshot(sensors: [
            .init(id: "TCMz", name: "Hotspot", group: .cpu, celsius: 76),
            .init(id: "TCMb", name: "Package", group: .cpu, celsius: 51),
            .init(id: "TCDX", name: "Die", group: .cpu, celsius: 43)
        ])
        XCTAssertEqual(snapshot.hottestCPU, 76)
        XCTAssertEqual(snapshot.cpuControlReading?.source, "TCMb")
        XCTAssertEqual(snapshot.cpuControlReading?.celsius, 51)
    }
    func testUnknownHardwareFallsBackAndInvalidPackageIsIgnored() {
        let snapshot = HardwareSnapshot(sensors: [
            .init(id: "TCMb", name: "Invalid", group: .cpu, celsius: 1.9),
            .init(id: "Tp1o", name: "Core", group: .cpu, celsius: 61)
        ])
        XCTAssertEqual(snapshot.cpuControlReading?.celsius, 61)
    }
    func testSingleSpikeDoesNotChangeWarmedFilter() {
        var filter = CPUTemperatureFilter()
        for t in 0...4 { filter.update(51, now: Double(t)) }
        XCTAssertEqual(filter.update(76, now: 5), 51)
        XCTAssertEqual(filter.update(51, now: 6), 51)
    }
    func testSustainedHeatIsFollowedAndCoolingIsSlower() throws {
        var filter = CPUTemperatureFilter()
        filter.update(50, now: 0)
        for t in 1...10 { filter.update(75, now: Double(t)) }
        let heated = try XCTUnwrap(filter.value)
        XCTAssertGreaterThan(heated, 60)
        XCTAssertLessThanOrEqual(heated, 65)
        for t in 11...14 { filter.update(50, now: Double(t)) }
        XCTAssertGreaterThan(try XCTUnwrap(filter.value), heated - 4.1)
    }
    func testFilterUsesElapsedTimeAndDoesNotHoldStaleData() throws {
        var filter = CPUTemperatureFilter()
        filter.update(50, now: 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(filter.update(76, now: 1)), 51.5)
        XCTAssertNil(filter.update(nil, now: 2))
        XCTAssertEqual(filter.update(60, now: 3), 60)
        XCTAssertEqual(filter.update(45, now: 30), 45)
        XCTAssertNil(filter.update(.nan, now: 31))
    }
    func testGovernorDwellRampDeadbandAndEmergency() throws {
        let fan = FanReading(id: 0, current: 2000, minimum: 1350, maximum: 5777, manual: true)
        var governor = CurveFanGovernor()
        governor.reset(fans: [fan], targets: [:], now: 0)
        XCTAssertEqual(governor.propose(fans: [fan], desired: [0: 5000], now: 2, emergency: false)[0], 2000)
        let up = governor.propose(fans: [fan], desired: [0: 5000], now: 3, emergency: false)
        XCTAssertEqual(up[0], 2400)
        governor.confirm(up, now: 3)
        XCTAssertEqual(governor.propose(fans: [fan], desired: [0: 2490], now: 10, emergency: false)[0], 2400)
        let down = governor.propose(fans: [fan], desired: [0: 1350], now: 6, emergency: false)
        XCTAssertEqual(down[0], 2200)
        XCTAssertEqual(governor.propose(fans: [fan], desired: [0: 1350], now: 3.1, emergency: true)[0], 5777)
    }
    func testIsolatedHotspotDoesNotRaceProfileButSustainedHotspotDoes() throws {
        let hardware = MockHardware()
        hardware.reading.sensors = [
            .init(id: "TCMb", name: "Stable", group: .cpu, celsius: 50),
            .init(id: "TCMz", name: "Peak", group: .cpu, celsius: 60)
        ]
        let engine = ControlEngine(hardware: hardware)
        _ = try engine.apply(.init(mode: .curve), now: 0)
        let initial = hardware.targets[0]
        hardware.reading.sensors[1].celsius = 76
        engine.tick(now: 1)
        XCTAssertEqual(hardware.targets[0], initial)
        XCTAssertEqual(engine.status.controlTemperature, 50)
        hardware.reading.sensors[1].celsius = 90
        engine.tick(now: 2)
        XCTAssertNotEqual(hardware.targets[0], 6000)
        hardware.reading.sensors[1].celsius = 60
        engine.tick(now: 3)
        XCTAssertNotEqual(hardware.targets[0], 6000)
        hardware.reading.sensors[1].celsius = 90
        engine.tick(now: 4)
        engine.tick(now: 6)
        XCTAssertEqual(hardware.targets[0], 6000)
    }
    func testSystemPressureAndSensorLossStillRestoreImmediately() throws {
        for missing in [false, true] {
            let hardware = MockHardware()
            hardware.reading.sensors = [
                .init(id: "TCMb", name: "Stable", group: .cpu, celsius: 50),
                .init(id: "TCMz", name: "Peak", group: .cpu, celsius: 60)
            ]
            let engine = ControlEngine(hardware: hardware)
            _ = try engine.apply(.init(mode: .curve), now: 0)
            if missing { hardware.reading.sensors = [] } else { hardware.reading.thermalPressure = .critical }
            engine.tick(now: 1)
            XCTAssertEqual(engine.status.mode, .system)
            XCTAssertEqual(hardware.modes.last?.1, false)
        }
    }
}
