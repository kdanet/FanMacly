import AppKit
import XCTest
import FanMaclyCore
@testable import FanMacly

final class ManualFanSpeedTests: XCTestCase {
    private let fan = FanReading(id: 0, current: 1800, minimum: 1350, maximum: 5777, manual: true)
    func testTrackHasStopAndAnInvertibleRunningRangeWithoutUnsupportedRPM() {
        let scale = ManualFanSpeedScale(fan: fan)
        XCTAssertEqual(scale.rpm(at: 0), 0)
        for position in [0.0, 0.5, 1, 3, 5, 6] { XCTAssertEqual(scale.rpm(at: position), 0) }
        XCTAssertEqual(scale.rpm(at: 8), 1350)
        XCTAssertEqual(scale.rpm(at: 100), 5777)
        XCTAssertEqual(scale.position(for: 0), 0)
        for rpm in [1350.0, 1800.25, 3200, 5777] {
            XCTAssertEqual(scale.rpm(at: scale.position(for: rpm)), rpm, accuracy: 0.000001)
        }
        var previous = 0.0
        for step in 0...1000 {
            let rpm = scale.rpm(at: Double(step) / 10)
            XCTAssertTrue(rpm == 0 || (1350...5777).contains(rpm))
            XCTAssertGreaterThanOrEqual(rpm, previous)
            previous = rpm
        }
    }
}
