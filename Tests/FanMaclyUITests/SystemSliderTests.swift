import XCTest
@testable import FanMacly

final class SystemSliderTests: XCTestCase {
    @MainActor func testSafetyDisableCancelsGestureEvenAfterTelemetryRecovers() async {
        let state = SystemSlider.State()
        var writes = 0, commits = 0
        state.onChange = { _, _ in writes += 1 }
        state.onEditingChanged = { if !$0 { commits += 1 } }
        state.edit(true)
        state.synchronize(value: 35, range: 0...100, allowedRange: nil, enabled: false, label: "CPU")
        state.synchronize(value: 35, range: 0...100, allowedRange: nil, enabled: true, label: "CPU")
        state.change(60)
        state.edit(false)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(state.value, 35)
        state.edit(true); state.change(60); state.edit(false)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(commits, 1)
    }
    @MainActor func testTelemetryCannotMoveThumbDuringDrag() async {
        let state = SystemSlider.State()
        state.synchronize(value: 35, range: 0...100, allowedRange: nil, enabled: true, label: "CPU")
        state.edit(true)
        state.change(36.37)
        state.synchronize(value: 35, range: 0...100, allowedRange: nil, enabled: true, label: "CPU")
        XCTAssertEqual(state.value, 36.37)
        state.edit(false)
        state.synchronize(value: 42, range: 0...100, allowedRange: nil, enabled: true, label: "CPU")
        XCTAssertEqual(state.value, 42)
    }
    @MainActor func testContinuousValuesAndOneCommitAfterRelease() async {
        let state = SystemSlider.State()
        var previews = [Double](), commits = 0
        state.onChange = { value, editing in
            if editing { previews.append(value) } else { commits += 1 }
        }
        state.onEditingChanged = { if !$0 { commits += 1 } }
        state.edit(true)
        for value in [35.1, 35.2, 35.3, 36.37] { state.change(value) }
        XCTAssertEqual(previews, [35.1, 35.2, 35.3, 36.37])
        XCTAssertEqual(commits, 0)
        state.edit(false)
        state.edit(false)
        XCTAssertEqual(commits, 1)
    }
    @MainActor func testCurveStopsAtNeighborWithoutQuantizingInterior() async {
        let state = SystemSlider.State()
        state.synchronize(value: 65, range: 0...100, allowedRange: 35...75, enabled: true, label: "CPU")
        state.change(64.17)
        XCTAssertEqual(state.value, 64.17)
        state.change(90)
        XCTAssertEqual(state.value, 75)
        state.change(10)
        XCTAssertEqual(state.value, 35)
    }
    @MainActor func testSafetyDisableStopsWritesDuringGesture() async {
        let state = SystemSlider.State()
        var writes = 0
        state.onChange = { _, _ in writes += 1 }
        state.edit(true)
        state.synchronize(value: 0, range: 0...100, allowedRange: nil, enabled: false, label: "CPU")
        state.change(60)
        XCTAssertEqual(writes, 0)
    }
}
