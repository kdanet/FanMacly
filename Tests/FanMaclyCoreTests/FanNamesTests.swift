import XCTest
@testable import FanMaclyCore

final class FanNamesTests: XCTestCase {
    func testTwoFanLaptopUsesSides() {
        let names = FanNames(count: 2, laptop: true)
        XCTAssertEqual(names.title(0), "Левый")
        XCTAssertEqual(names.title(1), "Правый")
        XCTAssertEqual(names.genitive(0), "левого вентилятора")
        XCTAssertEqual(names.instrumental(1), "правым вентилятором")
        XCTAssertEqual(names.subject(1), "Правый вентилятор")
    }
    func testSingleFanHasNoNumber() {
        let names = FanNames(count: 1, laptop: true)
        XCTAssertNil(names.side(0))
        XCTAssertEqual(names.title(0), "Вентилятор")
        XCTAssertEqual(names.genitive(0), "вентилятора")
    }
    func testDesktopsAndUnknownLayoutsKeepNumbers() {
        // A desktop's fan positions are unknown even with two fans.
        XCTAssertEqual(FanNames(count: 2, laptop: false).title(1), "Вентилятор 2")
        XCTAssertEqual(FanNames(count: 3, laptop: true).nominative(2), "вентилятор 3")
        XCTAssertEqual(FanNames(count: nil, laptop: true).subject(0), "Вентилятор 1")
    }
    func testLostFanMessageNamesTheSide() {
        let lost = FanControlLost(fan: 0, observedMode: 0, names: FanNames(count: 2, laptop: true))
        XCTAssertEqual(lost.errorDescription, "macOS вернула управление левым вентилятором.")
    }
}
