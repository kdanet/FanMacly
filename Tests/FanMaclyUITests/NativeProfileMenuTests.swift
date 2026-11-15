import AppKit
import XCTest
import FanMaclyCore
@testable import FanMacly

final class NativeProfileMenuTests: XCTestCase {
    @MainActor func testFanStopCheckboxIsSavedWithTheProfileAndBlockedForOldHelper() async throws {
        let name = "app.fanmacly.tests.\(UUID())"
        let storage = UserDefaults(suiteName: name)!
        defer { storage.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: storage, startMonitoring: false)
        try model.saveProfile(named: "Тишина")
        let view = NativeCurveControls(model: model)
        let checkbox = try XCTUnwrap(descendants(view, of: NSButton.self).first { $0.title == "Останавливать вентиляторы при 0 %" })
        checkbox.state = .on
        XCTAssertTrue(checkbox.sendAction(checkbox.action, to: checkbox.target))
        XCTAssertTrue(model.curve.allowsFanStop)
        XCTAssertFalse(model.profileIsModified)
        XCTAssertTrue(try XCTUnwrap(model.activeSavedProfile).curve.allowsFanStop)
        XCTAssertTrue(AppModel(defaults: storage, startMonitoring: false).curve.allowsFanStop)
        model.helper.connected = true; model.helper.status.version = "0.6.0"
        view.update()
        XCTAssertFalse(checkbox.isEnabled)
    }
    @MainActor private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        let matches = (view as? T).map { [$0] } ?? []
        return matches + view.subviews.flatMap { descendants($0, of: type) }
    }
    @MainActor func testUnsavedCurveKeepsTheProfilePickerAvailable() async throws {
        _ = NSApplication.shared
        let name = "app.fanmacly.tests.\(UUID())"
        let storage = UserDefaults(suiteName: name)!
        defer { storage.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: storage, startMonitoring: false)
        model.setCurvePercent(10, at: 0, commit: false)
        let view = NativeCurveControls(model: model)
        let picker = try XCTUnwrap(descendants(view, of: NSPopUpButton.self).first)
        XCTAssertTrue(picker.isEnabled)
        XCTAssertTrue(try XCTUnwrap(picker.selectedItem).isEnabled,
                      "A disabled selected item makes the whole picker look unavailable")
        XCTAssertEqual(picker.title, "Своя кривая")
        XCTAssertTrue(try XCTUnwrap(picker.menu?.item(withTag: -10)).isEnabled)
        XCTAssertFalse(descendants(view, of: NSButton.self).contains { $0.identifier?.rawValue == "saveCoolingProfile" })
        XCTAssertFalse(descendants(view, of: NSTextField.self).contains { $0.stringValue == "Есть изменения" })
        picker.selectItem(at: 1)
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        XCTAssertEqual(model.curve, .cool)
        XCTAssertEqual(picker.title, "Прохладный")
    }
    @MainActor func testSliderReleaseAutomaticallyPersistsEditsToTheSelectedProfileOnly() async throws {
        _ = NSApplication.shared
        let name = "app.fanmacly.tests.\(UUID())"
        let storage = UserDefaults(suiteName: name)!
        defer { storage.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: storage, startMonitoring: false)
        try model.saveProfile(named: "Работа")
        let work = try XCTUnwrap(model.activeProfileID)
        model.preset("Прохладный", curve: .cool)
        try model.saveProfile(named: "Игры")
        let other = try XCTUnwrap(model.activeSavedProfile)
        model.useProfile(work)
        model.setCurvePercent(10, at: 0, commit: false)
        let view = NativeCurveControls(model: model)
        XCTAssertTrue(model.profileIsModified)
        XCTAssertEqual(model.activeSavedProfile?.curve, .balanced, "Don't save each preview during a drag")
        let slider = try XCTUnwrap(descendants(view, of: SystemSlider.self).first)
        slider.onEditingChanged?(false)
        XCTAssertFalse(model.profileIsModified)
        XCTAssertEqual(model.activeSavedProfile?.curve.points[0].percent, 10)
        XCTAssertEqual(model.profileLibrary.profiles.first { $0.id == other.id }, other)
        XCTAssertFalse(descendants(view, of: NSButton.self).contains { $0.identifier?.rawValue == "saveCoolingProfile" })
        let restored = AppModel(defaults: storage, startMonitoring: false)
        XCTAssertEqual(restored.activeProfileID, work)
        XCTAssertEqual(restored.curve, model.curve)
        XCTAssertFalse(restored.profileIsModified)
    }
    @MainActor func testNativePopUpActionLoadsTheChosenProfile() async throws {
        _ = NSApplication.shared
        let name = "app.fanmacly.tests.\(UUID())"
        let storage = UserDefaults(suiteName: name)!
        defer { storage.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: storage, startMonitoring: false)
        let view = NativeCurveControls(model: model)
        func findMenu(_ view: NSView) -> NSPopUpButton? {
            if let menu = view as? NSPopUpButton { return menu }
            for child in view.subviews { if let menu = findMenu(child) { return menu } }
            return nil
        }
        let menu = try XCTUnwrap(findMenu(view))
        menu.selectItem(at: 1)
        XCTAssertTrue(menu.sendAction(menu.action, to: menu.target))
        XCTAssertEqual(model.curve, .cool)
        XCTAssertEqual(model.profileName, "Прохладный")
        XCTAssertEqual(menu.selectedItem?.title, "Прохладный")
        XCTAssertEqual(model.selectedMode, .system, "Offline profile selection must not start hardware control")
    }
}
