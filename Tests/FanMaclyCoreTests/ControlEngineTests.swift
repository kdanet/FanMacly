import XCTest
@testable import FanMaclyCore

final class MockHardware: FanHardware {
    var reading = HardwareSnapshot(fans: [FanReading(id: 0, current: 2000, minimum: 1000, maximum: 6000, manual: false)],
                                   sensors: [.init(id: "TC0D", name: "CPU", group: .cpu, celsius: 60)], fanCount: 1)
    var modes: [(Int, Bool)] = []
    var targets: [Int: Double] = [:]
    var targetWriteCount = 0
    var failTarget = false
    var failRestore = false
    /// The handback is still in progress (e.g. a stopped fan is being restarted).
    var deferRestore = false
    /// Fans whose mode was taken back by "macOS".
    var lost = Set<Int>()
    /// Fans that do not turn manual yet (handoff still in progress).
    var slowManual = Set<Int>()
    var handoffReleases = 0
    var forgotten: [Int] = []
    func snapshot() -> HardwareSnapshot { reading }
    func setManual(_ manual: Bool, fan: Int) throws {
        modes.append((fan, manual))
        if manual && slowManual.contains(fan) { throw FanControlPreparing() }
        if manual { lost.remove(fan) }
        if !manual && failRestore { throw FanMaclyError.message("restore failed") }
        if !manual && deferRestore { throw FanControlPreparing() }
    }
    func setTarget(_ rpm: Double, fan: Int) throws {
        if lost.contains(fan) { throw FanControlLost(fan: fan, observedMode: 0) }
        targetWriteCount += 1
        if failTarget { throw FanMaclyError.message("write failed") }
        targets[fan] = rpm
    }
    func forgetFan(_ fan: Int) { forgotten.append(fan) }
    func releaseHandoff() throws { handoffReleases += 1 }
}

private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func callAsFunction() -> Date { now }
}

final class ControlEngineTests: XCTestCase {
    private func engine(_ hardware: MockHardware, store: MemoryIntentStore = .init(), clock: Clock = .init()) -> ControlEngine {
        ControlEngine(hardware: hardware, store: store, date: { clock() })
    }
    private func run(_ engine: ControlEngine, from: Double, to: Double, step: Double = 0.3) {
        var t = from
        while t <= to { engine.tick(now: t); t += step }
    }

    func testAutomaticModeNeverWritesTargets() throws {
        let hardware = MockHardware()
        let subject = engine(hardware)
        run(subject, from: 0, to: 30)
        XCTAssertEqual(subject.status.mode, .system)
        XCTAssertTrue(hardware.modes.isEmpty)
        XCTAssertEqual(hardware.targetWriteCount, 0)
        XCTAssertEqual(subject.status.customControlAllowed, true)
    }

    func testControlSurvivesMissingHeartbeatsAndAppDisconnect() throws {
        let hardware = MockHardware()
        let subject = engine(hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        XCTAssertEqual(subject.status.mode, .manual)
        run(subject, from: 0.3, to: 120)
        XCTAssertEqual(subject.status.mode, .manual)
        XCTAssertEqual(hardware.targets[0], 3000)
        XCTAssertNil(subject.status.suspension)
    }

    func testIntentIsPersistedAndClearedByAutomatic() throws {
        let store = MemoryIntentStore()
        let subject = engine(MockHardware(), store: store)
        _ = try subject.apply(.init(mode: .curve, profileID: "balanced", profileName: "Баланс"), now: 0)
        XCTAssertEqual(store.value?.profileID, "balanced")
        _ = try subject.apply(.init(mode: .system), now: 1)
        XCTAssertNil(store.value)
        XCTAssertNil(subject.status.intent)
    }

    func testSavedIntentResumesAfterHelperRestart() throws {
        let hardware = MockHardware()
        let store = MemoryIntentStore(.init(mode: .manual, targets: [0: 2500], profileName: "Свой"))
        let subject = engine(hardware, store: store)
        XCTAssertEqual(subject.status.suspension?.kind, .startup)
        run(subject, from: 0, to: 4)
        XCTAssertNil(subject.status.suspension)
        XCTAssertEqual(subject.status.mode, .manual)
        XCTAssertEqual(hardware.targets[0], 2500)
    }

    func testTakenBackFanIsReacquiredInsteadOfHandingControlToMacOS() throws {
        let hardware = MockHardware()
        let subject = engine(hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        hardware.lost = [0]
        subject.tick(now: 0.3)
        XCTAssertTrue(subject.status.reacquiring)
        XCTAssertEqual(hardware.forgotten, [0])
        XCTAssertNil(subject.status.suspension)
        run(subject, from: 1.3, to: 5)
        XCTAssertFalse(subject.status.reacquiring)
        XCTAssertEqual(subject.status.mode, .manual)
        XCTAssertEqual(hardware.modes.filter { $0.1 }.count, 2)
        XCTAssertTrue(subject.status.events.contains { $0.kind == .warning })
    }

    func testRepeatedTakeoverSuspendsAsConflict() throws {
        let hardware = MockHardware()
        let subject = engine(hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        var t = 0.3
        for _ in 0..<(subject.policy.reacquireLimit + 1) {
            hardware.lost = [0]
            subject.tick(now: t); t += 1.1
            subject.tick(now: t); t += 1.1
        }
        XCTAssertEqual(subject.status.suspension?.kind, .conflict)
        XCTAssertEqual(subject.status.mode, .system)
        XCTAssertEqual(hardware.modes.last?.1, false)
        XCTAssertNotNil(subject.status.intent)
    }

    func testTransientSensorLossIsToleratedWithinGrace() throws {
        let hardware = MockHardware()
        let subject = engine(hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        let good = hardware.reading
        hardware.reading.fans[0].current = nil
        subject.tick(now: 1); subject.tick(now: 2)
        XCTAssertNil(subject.status.suspension)
        XCTAssertEqual(subject.status.mode, .manual)
        hardware.reading = good
        subject.tick(now: 3)
        XCTAssertEqual(subject.status.mode, .manual)
        hardware.reading.fans[0].current = nil
        for t in stride(from: 4.0, through: 8, by: 1) { subject.tick(now: t) }
        XCTAssertEqual(subject.status.suspension?.kind, .sensors)
        XCTAssertEqual(subject.status.mode, .system)
    }

    func testSuspensionResumesAutomaticallyOnceStable() throws {
        let hardware = MockHardware()
        let clock = Clock()
        let subject = engine(hardware, clock: clock)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        hardware.reading.sensors = []
        for t in stride(from: 1.0, through: 5, by: 1) { subject.tick(now: t) }
        XCTAssertEqual(subject.status.suspension?.kind, .sensors)
        XCTAssertNotNil(subject.status.suspension?.resumeDate)
        hardware.reading.sensors = [.init(id: "TC0D", name: "CPU", group: .cpu, celsius: 60)]
        for t in stride(from: 6.0, through: 60, by: 1) { subject.tick(now: t) }
        XCTAssertEqual(subject.status.mode, .system, "waits for the resume delay")
        for t in stride(from: 61.0, through: 80, by: 1) { subject.tick(now: t) }
        XCTAssertNil(subject.status.suspension)
        XCTAssertEqual(subject.status.mode, .manual)
        XCTAssertTrue(subject.status.events.contains { $0.kind == .resumed })
    }

    func testAutoResumeIsLimitedThenWaitsForUser() throws {
        let hardware = MockHardware()
        let subject = engine(hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        var t = 1.0
        for _ in 0..<subject.policy.autoResumeLimit {
            hardware.failTarget = true
            subject.tick(now: t); t += 1
            XCTAssertEqual(subject.status.suspension?.kind, .hardware)
            hardware.failTarget = false
            while subject.status.suspension != nil && t < 10_000 { subject.tick(now: t); t += 1 }
        }
        hardware.failTarget = true
        subject.tick(now: t)
        XCTAssertEqual(subject.status.suspension?.kind, .hardware)
        XCTAssertNil(subject.status.suspension?.resumeDate)
        hardware.failTarget = false
        for _ in 0..<200 { t += 1; subject.tick(now: t) }
        XCTAssertNotNil(subject.status.suspension)
        // A user action resets the counters and resumes immediately.
        _ = try subject.apply(subject.status.intent!, now: t + 1)
        XCTAssertNil(subject.status.suspension)
        XCTAssertEqual(subject.status.mode, .manual)
    }

    func testCriticalPressureHandsBackButSeriousBoosts() throws {
        let hardware = MockHardware()
        let subject = engine(hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 2000]), now: 0)
        hardware.reading.thermalPressure = .serious
        subject.tick(now: 1)
        XCTAssertEqual(subject.status.mode, .manual)
        XCTAssertTrue(subject.status.coolingBoost)
        XCTAssertEqual(hardware.targets[0], 6000)
        hardware.reading.thermalPressure = .critical
        subject.tick(now: 2)
        XCTAssertEqual(subject.status.suspension?.kind, .thermal)
        XCTAssertEqual(subject.status.mode, .system)
    }

    func testAppleSiliconNormalLoadDoesNotForceMaximum() throws {
        let hardware = MockHardware()
        hardware.reading.sensors = [
            .init(id: "TCMb", name: "CPU", group: .cpu, celsius: 85),
            .init(id: "Tp06", name: "Core", group: .cpu, celsius: 101),
            .init(id: "TPD0", name: "Not a core", group: .cpu, celsius: 110)
        ]
        let subject = engine(hardware)
        _ = try subject.apply(.init(mode: .curve, curve: .quiet), now: 0)
        for t in stride(from: 1.0, through: 20, by: 1) { subject.tick(now: t) }
        XCTAssertFalse(subject.status.coolingBoost)
        XCTAssertEqual(subject.status.mode, .curve)
    }

    func testSustainedHotCoreBoostsThenReleasesWithHysteresis() throws {
        let hardware = MockHardware()
        hardware.reading.sensors = [.init(id: "TCMb", name: "CPU", group: .cpu, celsius: 80), .init(id: "Tp06", name: "Core", group: .cpu, celsius: 107)]
        let subject = engine(hardware)
        _ = try subject.apply(.init(mode: .curve, curve: .balanced), now: 0)
        for t in stride(from: 1.0, through: 4, by: 1) { subject.tick(now: t) }
        XCTAssertFalse(subject.status.coolingBoost, "a short peak is not enough")
        for t in stride(from: 5.0, through: 7, by: 1) { subject.tick(now: t) }
        XCTAssertTrue(subject.status.coolingBoost)
        hardware.reading.sensors[1].celsius = 95
        for t in stride(from: 8.0, through: 16, by: 1) { subject.tick(now: t) }
        XCTAssertTrue(subject.status.coolingBoost, "release needs 10 s below the release thresholds")
        for t in stride(from: 17.0, through: 20, by: 1) { subject.tick(now: t) }
        XCTAssertFalse(subject.status.coolingBoost)
    }

    func testTimedBoostRunsAtMaximumThenReturnsToMacOS() throws {
        let hardware = MockHardware()
        let clock = Clock()
        let subject = engine(hardware, clock: clock)
        let until = clock.now.addingTimeInterval(600)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 6000], profileName: "Буст", boost: .init(until: until, thenSystem: true)), now: 0)
        subject.tick(now: 1)
        XCTAssertTrue(subject.status.coolingBoost)
        XCTAssertEqual(hardware.targets[0], 6000)
        clock.now = until.addingTimeInterval(1)
        subject.tick(now: 2)
        XCTAssertNil(subject.status.intent)
        XCTAssertEqual(subject.status.mode, .system)
        XCTAssertEqual(hardware.modes.last?.1, false)
    }

    func testTimedBoostOverAProfileReturnsToTheProfile() throws {
        let hardware = MockHardware()
        let clock = Clock()
        let subject = engine(hardware, clock: clock)
        let until = clock.now.addingTimeInterval(60)
        _ = try subject.apply(.init(mode: .curve, curve: .quiet, profileName: "Тихо", boost: .init(until: until, thenSystem: false)), now: 0)
        subject.tick(now: 1)
        XCTAssertEqual(hardware.targets[0], 6000)
        clock.now = until.addingTimeInterval(1)
        subject.tick(now: 2)
        XCTAssertEqual(subject.status.intent?.mode, .curve)
        XCTAssertNil(subject.status.intent?.boost)
        XCTAssertEqual(subject.status.mode, .curve)
    }

    func testFailedRestoreIsRetriedOnTicks() throws {
        let hardware = MockHardware()
        let subject = engine(hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 0]), now: 0)
        hardware.failRestore = true
        XCTAssertThrowsError(try subject.apply(.init(mode: .system), now: 1))
        XCTAssertTrue(subject.status.restoring == true)
        hardware.failRestore = false
        subject.tick(now: 2.5)
        XCTAssertFalse(subject.status.restoring == true)
        XCTAssertEqual(hardware.modes.last?.1, false)
    }

    func testNewModeDuringUnfinishedHandbackClearsRestoring() throws {
        let hardware = MockHardware()
        let subject = engine(hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        hardware.deferRestore = true
        _ = try subject.apply(.init(mode: .system), now: 1)
        XCTAssertTrue(subject.status.restoring == true)
        // The user picks a mode again before the handback finished.
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3500]), now: 2)
        run(subject, from: 2.3, to: 10)
        XCTAssertEqual(subject.status.mode, .manual)
        XCTAssertFalse(subject.status.restoring == true, "a superseded handback must not stay pending")
        XCTAssertNotEqual(subject.status.preparing, true)
    }

    func testManualRequestMustCoverEveryFan() {
        let subject = engine(MockHardware())
        XCTAssertThrowsError(try subject.apply(.init(mode: .manual, targets: [1: 3000]), now: 0))
        XCTAssertThrowsError(try subject.apply(.init(mode: .system, boost: .init(until: Date(), thenSystem: true)), now: 0))
    }

    func testIntentStoreRoundTripsOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("intent.json")
        let store = FileIntentStore(url: url)
        let request = ControlRequest(mode: .curve, curve: .cool, profileID: "cool", profileName: "Прохладно",
                                     boost: .init(until: Date(timeIntervalSince1970: 5), thenSystem: false), autoResume: false)
        try store.save(request)
        XCTAssertEqual(store.load(), request)
        try store.save(nil)
        XCTAssertNil(store.load())
    }

    func testBuiltInCurvesAreValidAndReachMaximumBelow100() {
        for curve in [CoolingCurve.quiet, .balanced, .cool] {
            XCTAssertTrue(curve.isValid)
            XCTAssertLessThanOrEqual(curve.points.last!.temperature, 100)
        }
        XCTAssertTrue(CoolingCurve(points: [.init(40, 0), .init(100, 100)]).isValid)
        XCTAssertFalse(CoolingCurve(points: [.init(40, 0), .init(101, 100)]).isValid)
        // Any speed per point: dips and an end below 100 % are allowed.
        let free = CoolingCurve(points: [.init(40, 30), .init(55, 10), .init(70, 60), .init(85, 40)])
        XCTAssertTrue(free.isValid)
        XCTAssertEqual(free.percent(at: 47.5), 20)
        XCTAssertEqual(free.percent(at: 95), 40)
        // Temperatures must still increase.
        XCTAssertFalse(CoolingCurve(points: [.init(50, 0), .init(50, 100)]).isValid)
        XCTAssertFalse(CoolingCurve(points: [.init(60, 0), .init(50, 100)]).isValid)
    }

    func testShutdownWithSlowRestoreNeverReacquiresFans() throws {
        final class SlowRestore: FanHardware {
            let mock = MockHardware()
            var ready = false
            func snapshot() -> HardwareSnapshot { mock.snapshot() }
            func setManual(_ manual: Bool, fan: Int) throws {
                if !manual && !ready { throw FanControlPreparing() }
                try mock.setManual(manual, fan: fan)
            }
            func setTarget(_ rpm: Double, fan: Int) throws { try mock.setTarget(rpm, fan: fan) }
        }
        let hardware = SlowRestore()
        let store = MemoryIntentStore()
        let subject = ControlEngine(hardware: hardware, store: store)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 0]), now: 0)
        let acquisitions = hardware.mock.modes.filter { $0.1 }.count
        try subject.shutdown()
        XCTAssertFalse(subject.isShutDown)
        for t in stride(from: 0.3, through: 5, by: 0.3) { subject.tick(now: t) }
        XCTAssertEqual(hardware.mock.modes.filter { $0.1 }.count, acquisitions, "no manual write after shutdown")
        hardware.ready = true
        subject.tick(now: 5.3)
        XCTAssertTrue(subject.isShutDown)
        XCTAssertEqual(hardware.mock.modes.last?.1, false)
        XCTAssertNotNil(store.value, "the intent survives a helper restart")
        XCTAssertThrowsError(try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 6))
    }

    func testReplanningWhileControllingGetsAFreshTargetDeadline() throws {
        final class Buffered: FanHardware {
            let mock = MockHardware()
            var confirm = true
            func snapshot() -> HardwareSnapshot { mock.snapshot() }
            func setManual(_ manual: Bool, fan: Int) throws { try mock.setManual(manual, fan: fan) }
            func setTarget(_ rpm: Double, fan: Int) throws {
                try mock.setTarget(rpm, fan: fan)
                if !confirm { throw FanControlPreparing() }
            }
        }
        let hardware = Buffered()
        let subject = ControlEngine(hardware: hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        hardware.confirm = false
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3500]), now: 1)
        for t in stride(from: 1.3, through: 5, by: 0.3) { subject.tick(now: t) }
        _ = try subject.apply(.init(mode: .manual, targets: [0: 4000]), now: 5.5)
        for t in stride(from: 5.8, through: 9, by: 0.3) { subject.tick(now: t) }
        XCTAssertNil(subject.status.suspension, "each new batch has its own 6 s window")
        hardware.confirm = true
        subject.tick(now: 9.3)
        XCTAssertEqual(hardware.mock.targets[0], 4000)
    }

    func testFailedHandbackGoesToMaximumWhenHotAndReleasesTheHandoff() throws {
        let hardware = MockHardware()
        let subject = engine(hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3000]), now: 0)
        XCTAssertEqual(hardware.targets[0], 3000)
        hardware.failRestore = true
        XCTAssertThrowsError(try subject.apply(.init(mode: .system), now: 1))
        // Cool: the fan keeps its target, but the handoff is given up after a while.
        run(subject, from: 1.3, to: 15)
        XCTAssertEqual(hardware.targets[0], 3000)
        XCTAssertEqual(hardware.handoffReleases, 0)
        run(subject, from: 15.3, to: 17)
        XCTAssertGreaterThan(hardware.handoffReleases, 0)
        // Hot: nobody else is watching that fan, so it runs at maximum.
        hardware.reading.sensors = [.init(id: "TC0D", name: "CPU", group: .cpu, celsius: 99)]
        run(subject, from: 17.3, to: 20)
        XCTAssertEqual(hardware.targets[0], 6000)
        XCTAssertEqual(subject.status.restoring, true)
        // Once the handback works, the fallback stops.
        hardware.failRestore = false
        run(subject, from: 20.3, to: 22)
        XCTAssertEqual(subject.status.restoring, false)
    }

    func testUnrecoveredFansFromAPreviousHelperAreRetried() throws {
        let hardware = MockHardware()
        hardware.failRestore = true
        let subject = engine(hardware)
        subject.adoptUnrecovered([0])
        XCTAssertEqual(subject.status.restoring, true)
        hardware.reading.sensors = []
        run(subject, from: 0, to: 5)
        XCTAssertEqual(hardware.targets[0], 6000, "no CPU temperature: an unreturned fan runs at maximum")
        hardware.failRestore = false
        run(subject, from: 5.3, to: 6)
        XCTAssertEqual(subject.status.restoring, false)
        XCTAssertEqual(subject.status.mode, .system)
    }

    func testFanThatTurnedManualGetsATargetWhileTheOtherIsStillHandedOver() throws {
        let hardware = MockHardware()
        hardware.reading = HardwareSnapshot(fans: [FanReading(id: 0, current: 2000, minimum: 1000, maximum: 6000, manual: false),
                                                   FanReading(id: 1, current: 2000, minimum: 1000, maximum: 6000, manual: false)],
                                            sensors: [.init(id: "TC0D", name: "CPU", group: .cpu, celsius: 60)], fanCount: 2)
        hardware.slowManual = [1]
        let subject = engine(hardware)
        _ = try subject.apply(.init(mode: .manual, targets: [0: 3000, 1: 3500]), now: 0)
        XCTAssertEqual(subject.status.preparing, true)
        XCTAssertEqual(hardware.targets[0], 3000)
        XCTAssertNil(hardware.targets[1])
        hardware.slowManual = []
        run(subject, from: 1, to: 3)
        XCTAssertEqual(subject.status.mode, .manual)
        XCTAssertEqual(hardware.targets, [0: 3000, 1: 3500])
    }

    func testCorruptJournalRecoversEveryFanInsteadOfFailing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("controlled-fans.json")
        try Data("not json".utf8).write(to: url)
        let mock = MockHardware()
        let journal = try JournaledHardware(hardware: mock, journalURL: url)
        XCTAssertEqual(journal.unrecovered, [0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
        try journal.recover()
        XCTAssertTrue(journal.unrecovered.isEmpty)
        XCTAssertEqual(mock.modes.last?.0, 0)
        XCTAssertEqual(mock.modes.last?.1, false)
    }

    func testRequestFieldsAreBounded() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let subject = ControlEngine(hardware: MockHardware(), date: { start })
        let name = String(repeating: "Очень длинное имя ", count: 20) + "\u{1B}[31m"
        _ = try subject.apply(.init(mode: .curve, curve: .quiet, profileID: "x", profileName: name,
                                    boost: .init(until: .distantFuture, thenSystem: false)), now: 0)
        let intent = try XCTUnwrap(subject.status.intent)
        XCTAssertEqual(intent.boost?.until, start.addingTimeInterval(ControlPolicy.standard.boostLimit))
        XCTAssertEqual(intent.profileName?.count, 64)
        XCTAssertFalse(intent.profileName?.contains("\u{1B}") ?? true)
        XCTAssertThrowsError(try subject.apply(.init(mode: .manual, targets: [42: 3000]), now: 1))
    }
}
