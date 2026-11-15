import XCTest
@testable import FanMaclyCore

final class SensorReadingTests: XCTestCase {
    func testGroupTemperatureIgnoresPlaceholders() {
        let gated = HardwareSnapshot(sensors: [
            TemperatureSensor(id: "Tg04", name: "GPU", group: .gpu, celsius: 1.5),
            TemperatureSensor(id: "Tg05", name: "GPU", group: .gpu, celsius: 2)
        ])
        XCTAssertNil(gated.temperature(.gpu), "a power-gated GPU must not read as 2 °C")
        let mixed = HardwareSnapshot(sensors: gated.sensors + [TemperatureSensor(id: "Tg0K", name: "GPU", group: .gpu, celsius: 58)])
        XCTAssertEqual(mixed.temperature(.gpu), 58)
    }

    func testPowerCatchUpAfterFreezeIsDiscarded() {
        var freeze = CounterFreeze()
        XCTAssertFalse(freeze.isStale(frozen: false))
        XCTAssertTrue(freeze.isStale(frozen: true))
        XCTAssertTrue(freeze.isStale(frozen: true))
        XCTAssertTrue(freeze.isStale(frozen: false), "the first delta after a freeze holds the whole frozen stretch")
        XCTAssertFalse(freeze.isStale(frozen: false))
    }

    func testImpossiblePowerIsRejected() {
        XCTAssertEqual(PowerPlausibility.watts(joules: 30, interval: 2), 15)
        XCTAssertEqual(PowerPlausibility.watts(joules: -1, interval: 1), 0)
        XCTAssertNil(PowerPlausibility.watts(joules: 7900, interval: 2), "3 950 W is a counter jump, not a reading")
        XCTAssertNil(PowerPlausibility.watts(joules: 1, interval: 0))
    }
}
