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
    @MainActor func testStopButtonsIndependentlySetZeroAndRespectSafetyDisable() async throws {
        let name = "app.fanmacly.tests.\(UUID())"
        let storage = UserDefaults(suiteName: name)!
        defer { storage.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: storage, startMonitoring: false)
        model.snapshot = .init(fans: [fan, .init(id: 1, current: 2200, minimum: 1350, maximum: 5777, manual: true)],
                               sensors: [.init(id: "TCMb", name: "CPU", group: .cpu, celsius: 60)], fanCount: 2)
        model.helper.connected = true
        model.selectedMode = .manual
        model.targets = [0: 1800, 1: 2200]
        let view = NativeFanControls(model: model)
        let stops = descendants(view, of: NSButton.self).filter { $0.title == "Стоп" }
        XCTAssertEqual(stops.count, 2)
        XCTAssertTrue(stops[0].sendAction(stops[0].action, to: stops[0].target))
        XCTAssertEqual(model.targets, [0: 0, 1: 2200])
        XCTAssertTrue(model.hasPendingControl)
        view.update()
        XCTAssertTrue(stops[1].sendAction(stops[1].action, to: stops[1].target))
        XCTAssertEqual(model.targets, [0: 0, 1: 0])
        model.helper.connected = false
        view.update()
        XCTAssertTrue(stops.allSatisfy { !$0.isEnabled })
        model.targets[0] = 1800
        _ = stops[0].sendAction(stops[0].action, to: stops[0].target)
        XCTAssertEqual(model.targets[0], 1800)
    }
    @MainActor private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        let matches = (view as? T).map { [$0] } ?? []
        return matches + view.subviews.flatMap { descendants($0, of: type) }
    }
    @MainActor func testManualSliderPassesZeroThroughModelAndTelemetryUpdates() async throws {
        let name = "app.fanmacly.tests.\(UUID())"
        let storage = UserDefaults(suiteName: name)!
        defer { storage.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: storage, startMonitoring: false)
        model.snapshot = .init(fans: [fan], sensors: [.init(id: "TCMb", name: "CPU", group: .cpu, celsius: 60)], fanCount: 1)
        model.helper.connected = true
        model.selectedMode = .manual
        let view = NativeFanControls(model: model)
        let slider = try XCTUnwrap(descendants(view, of: SystemSlider.self).first)
        slider.onChange?(0, true)
        XCTAssertEqual(model.targets[0], 0)
        model.snapshot.fans[0].current = 1355
        view.update()
        XCTAssertEqual(model.targets[0], 0)
        XCTAssertTrue(descendants(view, of: NSTextField.self).contains { $0.stringValue == "0" })
        XCTAssertTrue(descendants(view, of: NSTextField.self).contains { $0.stringValue == "0 или 1350–5777 об/мин" })
        slider.onChange?(100, true)
        XCTAssertEqual(model.targets[0], 5777)
        model.helper.connected = false
        slider.onEditingChanged?(false)
    }
}
