import XCTest
@testable import FanMaclyCore

final class FanIndicatorTests: XCTestCase {
    private func snapshot(_ speeds: [Double?], error: String? = nil) -> HardwareSnapshot {
        HardwareSnapshot(fans: speeds.enumerated().map { .init(id: $0.offset, current: $0.element, minimum: 1200, maximum: 6000, manual: nil) }, error: error)
    }
    func testRotationTracksFastestMeasuredFanProportionally() {
        XCTAssertEqual(FanIndicator.revolutionsPerSecond(for: snapshot([1350, 1000])), 1.125)
        XCTAssertEqual(FanIndicator.revolutionsPerSecond(for: snapshot([2700, 5400])), 4.5)
    }
    func testStopsWithoutValidCurrentTelemetry() {
        for value in [nil, snapshot([]), snapshot([0]), snapshot([nil]), snapshot([.nan, .infinity, -1, 20001]), snapshot([2700], error: "SMC unavailable")] {
            XCTAssertEqual(FanIndicator.revolutionsPerSecond(for: value), 0)
        }
        XCTAssertEqual(FanIndicator.revolutionsPerSecond(for: snapshot([nil, 2700])), 2.25)
    }
    func testAnimationSettingsAndUpperBound() {
        let value = snapshot([5777])
        XCTAssertEqual(FanIndicator.revolutionsPerSecond(for: value, animated: false), 0)
        XCTAssertEqual(FanIndicator.revolutionsPerSecond(for: value, multiplier: 1.5), 6)
        XCTAssertGreaterThan(FanIndicator.revolutionsPerSecond(for: value), 4.8)
        XCTAssertLessThan(FanIndicator.revolutionsPerSecond(for: value, multiplier: 0.6), 3)
        XCTAssertEqual(FanIndicator.revolutionsPerSecond(for: value, multiplier: .nan), 0)
    }
}
