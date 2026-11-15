import AppKit
import XCTest
import FanMaclyCore
@testable import FanMacly

final class ConfirmedControlStateTests: XCTestCase {
    @MainActor func testCoolingBoostStaysActiveAndIsVisibleInBothViews() async {
        let model = model()
        model.helper.connected = true
        model.helper.status.mode = .curve
        model.helper.status.coolingBoost = true
        model.selectedMode = .curve
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        XCTAssertTrue(labels(NativeCurveControls(model: model)).contains("Активен · Макс."))
        XCTAssertTrue(labels(NativeFanControls(model: model)).contains("Макс. охлаждение"))
        XCTAssertNil(model.helper.status.thermalEvent)
    }
    @MainActor func testProfileViewLabelsConfirmedStateInsteadOfSelection() async {
        let model = model()
        model.helper.connected = true
        model.selectedMode = .curve
        let view = NativeCurveControls(model: model)
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        XCTAssertTrue(labels(view).contains("Не активен"))
        model.helper.status.mode = .curve
        view.update()
        XCTAssertTrue(labels(view).contains("Активен"))
        model.helper.status.mode = .system
        view.update()
        XCTAssertTrue(labels(view).contains("Не активен"))
    }
    @MainActor private func model() -> AppModel {
        let result = AppModel(defaults: UserDefaults(suiteName: "app.fanmacly.tests.\(UUID())")!, startMonitoring: false)
        result.snapshot = .init(fans: [.init(id: 0, current: 1800, minimum: 1350, maximum: 5777, manual: false)],
                                sensors: [.init(id: "TCMb", name: "CPU", group: .cpu, celsius: 75)], fanCount: 1)
        return result
    }
    @MainActor func testBlockedProfileCannotLookActive() async {
        let model = model()
        model.helper.connected = true
        model.helper.status.customControlAllowed = false
        model.selectMode(.curve)
        XCTAssertEqual(model.selectedMode, .system)
        XCTAssertFalse(model.hasPendingControl)
        XCTAssertNotNil(model.helper.error)
    }
    @MainActor func testDisconnectedProfileCannotLookActive() async {
        let model = model()
        model.selectMode(.curve)
        XCTAssertEqual(model.selectedMode, .system)
        XCTAssertFalse(model.hasPendingControl)
        XCTAssertNotNil(model.helper.error)
    }
    @MainActor func testStableAutomaticAcknowledgementCorrectsUnconfirmedProfile() async throws {
        let model = model()
        var status = HelperStatus()
        status.sequence = 1; status.automaticFallbackID = UUID()
        model.helper.receive(try JSONEncoder().encode(status))
        model.selectedMode = .curve
        status.sequence = 2
        model.helper.receive(try JSONEncoder().encode(status))
        XCTAssertEqual(model.selectedMode, .system)
        XCTAssertNotNil(model.helper.error)
    }
    @MainActor func testPreparingProfileRetainsIntentUntilConfirmed() async throws {
        let model = model()
        model.selectedMode = .curve
        var status = HelperStatus()
        status.sequence = 1; status.preparing = true
        model.helper.receive(try JSONEncoder().encode(status))
        XCTAssertEqual(model.selectedMode, .curve)
        XCTAssertTrue(model.controlPending)
        status.sequence = 2; status.preparing = false; status.mode = .curve; status.targets = [0: 5000]
        model.helper.receive(try JSONEncoder().encode(status))
        XCTAssertEqual(model.selectedMode, .curve)
        XCTAssertFalse(model.controlPending)
        XCTAssertNil(model.helper.error)
    }
    @MainActor func testProtectionWhileRequestIsQueuedCancelsItsOptimisticMode() async throws {
        let model = model()
        var status = HelperStatus()
        status.sequence = 1; status.customControlAllowed = true
        model.helper.receive(try JSONEncoder().encode(status))
        model.selectMode(.curve)
        XCTAssertTrue(model.hasPendingControl)
        status.sequence = 2; status.customControlAllowed = false
        model.helper.receive(try JSONEncoder().encode(status))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.selectedMode, .system)
        XCTAssertFalse(model.hasPendingControl)
        XCTAssertNotNil(model.helper.error)
    }
    @MainActor func testHeartbeatDoesNotDiscardAnActiveCurveSliderGesture() async throws {
        let model = model()
        var status = HelperStatus(); status.sequence = 1; status.customControlAllowed = true
        model.helper.receive(try JSONEncoder().encode(status))
        model.beginSliderEdit()
        model.setCurvePercent(10, at: 0, commit: false)
        status.sequence = 2
        model.helper.receive(try JSONEncoder().encode(status))
        XCTAssertEqual(model.selectedMode, .curve)
        model.finishSliderEdit(curveEdit: true)
        XCTAssertTrue(model.hasPendingControl)
        model.helper.disconnect()
    }
    @MainActor func testLateHeartbeatCannotOverwriteNewerAutomaticFallback() async throws {
        let client = HelperClient()
        var fresh = HelperStatus()
        fresh.sequence = 20; fresh.automaticFallbackID = UUID()
        client.receive(try JSONEncoder().encode(fresh))
        var stale = HelperStatus()
        stale.sequence = 19; stale.mode = .curve; stale.targets = [0: 5000]
        client.receive(try JSONEncoder().encode(stale))
        XCTAssertEqual(client.status.mode, .system)
        XCTAssertEqual(client.status.automaticFallbackID, fresh.automaticFallbackID)
        XCTAssertTrue(client.status.targets.isEmpty)
    }
    @MainActor func testNewConnectionCanAcceptRestartedSequence() async throws {
        let client = HelperClient()
        var status = HelperStatus(); status.sequence = 20
        client.receive(try JSONEncoder().encode(status))
        client.disconnect()
        status.sequence = 1
        client.receive(try JSONEncoder().encode(status))
        XCTAssertTrue(client.connected)
        XCTAssertEqual(client.status.sequence, 1)
    }
    @MainActor func testMissingSequenceFailsClosed() async throws {
        let client = HelperClient()
        client.receive(try JSONEncoder().encode(HelperStatus()))
        XCTAssertFalse(client.connected)
        XCTAssertNotNil(client.error)
    }
}
