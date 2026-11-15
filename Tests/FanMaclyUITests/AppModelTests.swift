import XCTest
import FanMaclyCore
@testable import FanMacly

@MainActor final class AppModelTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
    }
    private func storage() -> UserDefaults {
        let name = "app.fanmacly.tests.\(UUID())"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }
    private let fans = [FanReading(id: 0, current: 2000, minimum: 1350, maximum: 5777, manual: false),
                        FanReading(id: 1, current: 2100, minimum: 1350, maximum: 6000, manual: false)]

    func testSelectionKeysRoundTrip() {
        let id = UUID()
        for selection: ModeSelection in [.automatic, .preset(.quiet), .preset(.balanced), .preset(.cool), .profile(id), .manual, .maximum] {
            XCTAssertEqual(ModeSelection(key: selection.key), selection)
        }
        XCTAssertNil(ModeSelection(key: "nonsense"))
    }

    func testRequestsCarryProfileIdentityForTheHelper() throws {
        let model = AppModel(defaults: storage(), startMonitoring: false)
        model.snapshot = HardwareSnapshot(fans: fans, fanCount: 2)
        let quiet = try XCTUnwrap(model.request(for: .preset(.quiet)))
        XCTAssertEqual(quiet.mode, .curve)
        XCTAssertEqual(quiet.curve, .quiet)
        XCTAssertEqual(quiet.profileID, "quiet")
        let maximum = try XCTUnwrap(model.request(for: .maximum))
        XCTAssertEqual(maximum.targets, [0: 5777, 1: 6000])
        XCTAssertEqual(model.request(for: .automatic)?.mode, .system)
        let boosted = try XCTUnwrap(model.request(for: .automatic, boost: .init(until: Date().addingTimeInterval(60), thenSystem: true)))
        XCTAssertEqual(boosted.mode, .manual)
        XCTAssertEqual(boosted.boost?.thenSystem, true)
        XCTAssertEqual(boosted.profileID, "auto")
    }

    func testLinkedManualTargetsMoveTogetherAndAreRemembered() throws {
        let defaults = storage()
        let model = AppModel(defaults: defaults, startMonitoring: false)
        model.snapshot = HardwareSnapshot(fans: fans, fanCount: 2)
        model.setManualTarget(5777, fan: 0, commit: false)
        XCTAssertEqual(model.manualTargets[0], 5777)
        XCTAssertEqual(try XCTUnwrap(model.manualTargets[1]), 6000, accuracy: 0.001)
        model.manualLinked = false
        model.setManualTarget(0, fan: 1, commit: false)
        XCTAssertEqual(model.manualTargets[1], 0)
        XCTAssertEqual(model.manualTargets[0], 5777)
        let restored = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(restored.manualTargets[1], 0)
    }

    func testProfilesSaveRenameDeleteAndReservedNames() throws {
        let defaults = storage()
        let model = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertThrowsError(try model.saveProfile(name: "Тихий", curve: .quiet))
        let id = try model.saveProfile(name: "Работа", curve: .cool)
        XCTAssertEqual(model.uniqueProfileName("Работа"), "Работа 2")
        try model.saveProfile(name: "Работа ночью", curve: .quiet, replacing: id)
        let restored = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(restored.profileLibrary.profiles.first?.name, "Работа ночью")
        XCTAssertEqual(restored.curve(for: .profile(id)), .quiet)
        restored.deleteProfile(id)
        XCTAssertTrue(restored.profileLibrary.profiles.isEmpty)
    }

    func testLegacyCustomCurveBecomesAProfileAndBuiltInMapsToPreset() throws {
        let legacy = storage()
        var custom = CoolingCurve(points: [.init(40, 0), .init(55, 20), .init(65, 45), .init(75, 75), .init(85, 100)])
        custom.points[0].percent = 10
        legacy.set(try JSONEncoder().encode(custom), forKey: "coolingCurve")
        legacy.set("Мой старый", forKey: "profileName")
        let model = AppModel(defaults: legacy, startMonitoring: false)
        XCTAssertEqual(model.profileLibrary.profiles.map(\.name), ["Мой старый"])
        XCTAssertEqual(model.profileLibrary.profiles.first?.curve, custom)
        XCTAssertEqual(model.userSelection, .automatic)
        guard case .profile = model.lastNonAutomatic else { return XCTFail("expected migrated profile") }

        let builtIn = storage()
        builtIn.set(try JSONEncoder().encode(custom), forKey: "coolingCurve")
        builtIn.set("Прохладный", forKey: "profileName")
        let second = AppModel(defaults: builtIn, startMonitoring: false)
        XCTAssertTrue(second.profileLibrary.profiles.isEmpty)
        XCTAssertEqual(second.lastNonAutomatic, .preset(.cool))
    }

    func testHelperStatusDrivesStateAndOldHelpersAskForUpdate() throws {
        let model = AppModel(defaults: storage(), startMonitoring: false)
        model.helper.serviceStatus = .enabled
        var status = HelperStatus()
        status.sequence = 1
        status.mode = .curve
        status.intent = ControlRequest(mode: .curve, curve: .cool, profileID: "cool", profileName: "Прохладный")
        model.helper.receive(try JSONEncoder().encode(status))
        XCTAssertEqual(model.activeSelection, .preset(.cool))
        XCTAssertEqual(model.controlState, .active)
        XCTAssertEqual(model.userSelection, .preset(.cool), "adopts the helper's intent after an app restart")

        // Target steps of a running curve and a superseded handback are not "applying".
        status.sequence = 2
        status.preparing = true
        status.restoring = true
        model.helper.receive(try JSONEncoder().encode(status))
        XCTAssertEqual(model.controlState, .active)
        // Taking the fans from macOS is.
        status.sequence = 3
        status.mode = .system
        status.restoring = false
        model.helper.receive(try JSONEncoder().encode(status))
        XCTAssertEqual(model.controlState, .applying)
        status.preparing = false

        status.sequence = 4
        status.mode = .system
        status.suspension = .init(kind: .conflict, message: "test", date: Date(), resumeDate: nil)
        model.helper.receive(try JSONEncoder().encode(status))
        if case .suspended(let suspension) = model.controlState { XCTAssertTrue(suspension.needsUser) } else { XCTFail() }

        // Keep the test from re-registering the real helper (that only runs
        // for an enabled service).
        model.helper.serviceStatus = .notRegistered
        var old = status
        old.sequence = 5
        old.version = "0.8.0"
        model.helper.receive(try JSONEncoder().encode(old))
        XCTAssertTrue(model.helper.needsUpdate)
        XCTAssertFalse(model.helper.connected)
    }

    func testSettingsDecodeWithDefaultsForMissingKeys() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{\"releaseOnQuit\":false}".utf8))
        XCTAssertFalse(decoded.releaseOnQuit)
        XCTAssertTrue(decoded.autoResume)
        let legacyMenu = try JSONDecoder().decode(MenuBarSettings.self, from: Data("{\"animated\":true,\"showsTemperature\":true,\"speed\":\"fast\"}".utf8))
        XCTAssertEqual(legacyMenu.display, .temperature)
        XCTAssertEqual(legacyMenu.speed, .fast)
    }

    func testHistoryKeepsAFixedWindow() {
        var history = HistoryStore(capacity: 3)
        for index in 0..<5 {
            history.append(.init(date: Date(timeIntervalSinceNow: Double(index - 5)), cpu: Double(index), gpu: nil, fans: [1000], targets: [nil], cpuWatts: nil, gpuWatts: nil))
        }
        XCTAssertEqual(history.samples.count, 3)
        XCTAssertEqual(history.samples.first?.cpu, 2)
        XCTAssertEqual(history.fanSeries(0, duration: 60).count, 3)
    }

    func testRuleChosenIntentIsNotAdoptedAsTheUsersChoice() throws {
        let defaults = storage()
        let first = AppModel(defaults: defaults, startMonitoring: false)
        first.select(.preset(.quiet))
        let model = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(model.userSelection, .preset(.quiet))
        model.helper.serviceStatus = .enabled
        var status = HelperStatus()
        status.sequence = 1
        status.mode = .curve
        status.intent = ControlRequest(mode: .curve, curve: .cool, profileID: "cool", profileName: "Прохладный", fromRule: true)
        model.helper.receive(try JSONEncoder().encode(status))
        XCTAssertEqual(model.userSelection, .preset(.quiet))
    }

    func testOnlyTemperatureProfilesAreRememberedAsTheProfile() throws {
        let defaults = storage()
        let model = AppModel(defaults: defaults, startMonitoring: false)
        model.snapshot = HardwareSnapshot(fans: fans, fanCount: 2)
        let id = try model.saveProfile(name: "Работа", curve: .cool)
        model.select(.profile(id))
        model.select(.manual)
        model.select(.maximum)
        XCTAssertEqual(model.lastNonAutomatic, .profile(id))
        model.select(.automatic)
        model.deleteProfile(id)
        XCTAssertEqual(AppModel(defaults: defaults, startMonitoring: false).lastNonAutomatic, .preset(.balanced),
                       "a deleted profile is not offered after a restart")
    }
}
