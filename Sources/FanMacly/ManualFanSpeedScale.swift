import FanMaclyCore

/// Give stop a reachable detent, then use the rest of the track for running RPM.
/// A linear 0...max RPM track would waste a large section on unsupported speeds.
struct ManualFanSpeedScale {
    let minimum: Double
    let maximum: Double
    private let stopThreshold = 6.0
    private let runningStart = 8.0
    init(fan: FanReading) {
        minimum = fan.safeMinimum
        maximum = fan.maximum ?? fan.safeMinimum
    }
    func rpm(at position: Double) -> Double {
        guard position.isFinite else { return minimum }
        if position <= stopThreshold { return 0 }
        return minimum + (maximum - minimum) * max(0, min(100 - runningStart, position - runningStart)) / (100 - runningStart)
    }
    func position(for rpm: Double) -> Double {
        guard rpm.isFinite else { return runningStart }
        if rpm == 0 { return 0 }
        guard maximum > minimum else { return runningStart }
        return runningStart + (100 - runningStart) * max(0, min(1, (rpm - minimum) / (maximum - minimum)))
    }
}
