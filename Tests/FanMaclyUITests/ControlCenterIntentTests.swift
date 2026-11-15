import XCTest
@testable import FanMacly

final class ControlCenterIntentTests: XCTestCase {
    @MainActor func testEachButtonRoutesTheCorrectActionToTheApp() async throws {
        guard #available(macOS 27.0, *) else { return }
        let previous = FanModeControlRouter.handler
        defer { FanModeControlRouter.handler = previous }
        var received: [FanModeControlAction] = []
        FanModeControlRouter.handler = { received.append($0) }
        for action: FanModeControlAction in [.automatic, .profile, .maximum] {
            _ = try await FanModeControlIntent(action).perform()
        }
        XCTAssertEqual(received, [.automatic, .profile, .maximum])
    }
    @MainActor func testBackendFailureIsReportedInsteadOfAcknowledgedAsSuccess() async throws {
        guard #available(macOS 27.0, *) else { return }
        let previous = FanModeControlRouter.handler
        defer { FanModeControlRouter.handler = previous }
        let failure = NSError(domain: "FanMaclyTests", code: 42)
        FanModeControlRouter.handler = { _ in throw failure }
        do {
            _ = try await FanModeControlIntent(.profile).perform()
            XCTFail("A failed mode switch must not report success to Control Center")
        } catch { XCTAssertEqual(error as NSError, failure) }
    }
}
