import XCTest
import FanMaclyCore
@testable import FanMacly

final class PreferencesAndProfilesTests: XCTestCase {
    @MainActor func testSwitchingProfilesKeepsPendingEditsAndBuiltInsRemainIndependent() async throws {
        let name = "app.fanmacly.tests.\(UUID())"
        let storage = UserDefaults(suiteName: name)!
        defer { storage.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: storage, startMonitoring: false)
        try model.saveProfile(named: "Работа")
        let id = try XCTUnwrap(model.activeProfileID)
        model.setCurvePercent(10, at: 0, commit: false)
        model.preset("Прохладный", curve: .cool)
        XCTAssertEqual(model.profileLibrary.profiles.first?.curve.points[0].percent, 10)
        model.setCurvePercent(25, at: 0)
        XCTAssertNil(model.activeProfileID)
        XCTAssertEqual(model.profileLibrary.profiles.count, 1)
        XCTAssertEqual(model.profileLibrary.profiles.first?.curve.points[0].percent, 10)
        let restored = AppModel(defaults: storage, startMonitoring: false)
        restored.useProfile(id)
        XCTAssertEqual(restored.curve.points[0].percent, 10)
        XCTAssertFalse(restored.profileIsModified)
    }
    @MainActor func testMalformedHelperStatusFailsClosedAndFallbackNotifiesOnlyOnce() async throws {
        let client = HelperClient()
        var fallbacks = 0, disconnects = 0
        client.onAutomaticFallback = { fallbacks += 1 }
        client.onDisconnect = { disconnects += 1 }
        var status = HelperStatus(); status.sequence = 1; status.automaticFallbackID = UUID()
        let data = try JSONEncoder().encode(status)
        client.receive(data); client.receive(data)
        XCTAssertEqual(fallbacks, 1)
        XCTAssertTrue(client.connected)
        client.receive(Data("invalid status".utf8))
        XCTAssertFalse(client.connected)
        XCTAssertNotNil(client.error)
        XCTAssertEqual(disconnects, 1)
    }
    @MainActor func testLegacyCurveMigrationAndSelectedProfileSurviveRelaunch() async throws {
        let name = "app.fanmacly.tests.\(UUID())"
        let storage = UserDefaults(suiteName: name)!
        defer { storage.removePersistentDomain(forName: name) }
        var custom = CoolingCurve.balanced; custom.points[0].percent = 10
        storage.set(try JSONEncoder().encode(custom), forKey: "coolingCurve")
        storage.set("Существующий профиль", forKey: "profileName")
        let first = AppModel(defaults: storage, startMonitoring: false)
        let id = try XCTUnwrap(first.activeProfileID)
        XCTAssertEqual(first.profileLibrary.profiles.count, 1)
        XCTAssertEqual(first.profileLibrary.profiles[0].curve, custom)
        let second = AppModel(defaults: storage, startMonitoring: false)
        XCTAssertEqual(second.activeProfileID, id)
        XCTAssertEqual(second.curve, custom)
        XCTAssertEqual(second.selectedMode, .system)
    }
    @MainActor func testAutomaticSaveRenameAndDeleteDoNotOverwriteOtherProfiles() async throws {
        let name = "app.fanmacly.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: defaults, startMonitoring: false)
        try model.saveProfile(named: "Работа")
        let first = try XCTUnwrap(model.activeProfileID)
        model.preset("Прохладный", curve: .cool)
        try model.saveProfile(named: "Рендер")
        let second = try XCTUnwrap(model.activeProfileID)
        model.useProfile(first)
        model.setCurvePercent(10, at: 0)
        XCTAssertFalse(model.profileIsModified)
        XCTAssertEqual(model.profileLibrary.profiles[0].curve.points[0].percent, 10)
        try model.renameActiveProfile(to: "Работа дома")
        XCTAssertFalse(model.profileIsModified)
        XCTAssertEqual(model.profileLibrary.profiles[0].curve.points[0].percent, 10)
        XCTAssertThrowsError(try model.renameActiveProfile(to: "Прохладный"))
        XCTAssertEqual(model.profileName, "Работа дома")
        model.useProfile(second)
        XCTAssertEqual(model.curve, .cool)
        model.deleteActiveProfile()
        XCTAssertEqual(model.curve, .cool)
        XCTAssertEqual(model.profileLibrary.profiles.map(\.id), [first])
        XCTAssertEqual(try ProfileLibrary(data: XCTUnwrap(defaults.data(forKey: "savedCoolingProfiles"))).profiles, model.profileLibrary.profiles)
    }
    @MainActor func testCorruptLibraryIsBackedUpBeforeNewProfilesCanBeWritten() async throws {
        let name = "app.fanmacly.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let broken = Data("corrupt profiles".utf8)
        defaults.set(broken, forKey: "savedCoolingProfiles")
        let model = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(defaults.data(forKey: "savedCoolingProfiles.recoveryBackup"), broken)
        XCTAssertEqual(defaults.data(forKey: "savedCoolingProfiles"), broken)
        XCTAssertNotNil(model.exportError)
        try model.saveProfile(named: "Новый")
        XCTAssertEqual(defaults.data(forKey: "savedCoolingProfiles.recoveryBackup"), broken)
    }
    @MainActor func testIconPreferencesPersistAndDisconnectCannotLeaveSelectedManualMode() async {
        let name = "app.fanmacly.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: defaults, startMonitoring: false)
        model.menuBarSettings.animated = false
        model.menuBarSettings.showsTemperature = true
        model.menuBarSettings.speed = .fast
        model.saveMenuBarSettings()
        let restored = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(restored.menuBarSettings, model.menuBarSettings)
        model.selectedMode = .manual
        model.helper.disconnect()
        XCTAssertEqual(model.selectedMode, .system)
    }
}
