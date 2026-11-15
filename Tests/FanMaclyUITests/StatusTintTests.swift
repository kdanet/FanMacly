import XCTest
import AppKit
import FanMaclyCore
@testable import FanMacly

@MainActor final class StatusTintTests: XCTestCase {
    func testIconIsOrangeOnlyWhileTheChosenModeIsNotInEffect() {
        let balanced = ModeSelection.preset(.balanced)
        let paused = ControlSuspension(kind: .conflict, message: "", date: Date(), resumeDate: nil)
        XCTAssertNil(AppDelegate.statusTint(.active, selection: balanced), "in control: plain icon")
        XCTAssertNil(AppDelegate.statusTint(.applying, selection: balanced))
        XCTAssertNil(AppDelegate.statusTint(.connecting, selection: balanced), "no flash at every launch")
        XCTAssertNil(AppDelegate.statusTint(.macOS, selection: .automatic), "«Авто» is the user's choice")
        XCTAssertEqual(AppDelegate.statusTint(.suspended(paused), selection: balanced), .systemOrange)
        XCTAssertEqual(AppDelegate.statusTint(.reacquiring, selection: balanced), .systemOrange)
        XCTAssertEqual(AppDelegate.statusTint(.macOS, selection: balanced), .systemOrange)
        XCTAssertEqual(AppDelegate.statusTint(.setupNeeded, selection: balanced), .systemOrange)
        XCTAssertNil(AppDelegate.statusTint(.setupNeeded, selection: .automatic))
    }

    func testOldAccentSettingIsNotCarriedOver() throws {
        let old = try JSONDecoder().decode(MenuBarSettings.self, from: Data("{\"tintsWhenActive\":false}".utf8))
        XCTAssertTrue(old.highlightsLostControl, "the old switch meant the opposite, so it is not reused")
    }
}
