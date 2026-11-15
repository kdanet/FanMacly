import Foundation

public struct CPUControlReading: Codable, Sendable {
    public let source: String
    public let celsius: Double
    public var description: String {
        switch source {
        case "TCMb": return "Среднее кристалла CPU (по справочнику iSMC)"
        case "TCMz": return "Максимум кристалла CPU (по справочнику iSMC)"
        case "TCDX": return "Сводное показание CPU (по справочнику iSMC)"
        default: return "Резервный максимум доступных каналов CPU; назначение ключа не подтверждено"
        }
    }
}

extension HardwareSnapshot {
    public var cpuPeakReading: CPUControlReading? {
        sensors.filter { $0.group == .cpu && $0.celsius.isFinite && (15..<125).contains($0.celsius) }
            .max(by: { $0.celsius < $1.celsius }).map { .init(source: $0.id, celsius: $0.celsius) }
    }
    /// Prefer a slower package reading over an instantaneous hotspot. Unknown
    /// models retain the peak fallback; raw sensors are never replaced in export.
    public var cpuControlReading: CPUControlReading? {
        let valid = sensors.filter { $0.group == .cpu && $0.celsius.isFinite && (15..<125).contains($0.celsius) }
        for key in ["TCMb", "TCDX", "TCMz"] {
            if let sensor = valid.first(where: { $0.id == key }) { return .init(source: key, celsius: sensor.celsius) }
        }
        return valid.max(by: { $0.celsius < $1.celsius }).map { .init(source: $0.id, celsius: $0.celsius) }
    }
}

/// Time-normalized filtering: reject isolated samples with a 3-sample median,
/// then smooth with a faster rise (5 s) and slower fall (15 s).
public struct CPUTemperatureFilter: Sendable {
    private var samples: [Double] = []
    private var previousTime: TimeInterval?
    private var source: String?
    public private(set) var value: Double?
    public init() {}
    public mutating func reset() { self = .init() }
    @discardableResult public mutating func update(reading: CPUControlReading?, now: TimeInterval) -> Double? {
        // Values from different physical/aggregate channels must not share a
        // median window or smoothing history after a sensor disappears.
        if source != reading?.source { reset(); source = reading?.source }
        return update(reading?.celsius, now: now)
    }
    @discardableResult public mutating func update(_ input: Double?, now: TimeInterval) -> Double? {
        guard let input, input.isFinite, (15..<125).contains(input), now.isFinite else { reset(); return nil }
        guard let previousTime, let previous = value, now > previousTime else {
            if self.previousTime == now { return value }
            samples = [input]; value = input; self.previousTime = now; return input
        }
        let elapsed = now - previousTime
        if elapsed > 10 { reset(); return update(input, now: now) }
        samples.append(input)
        if samples.count > 3 { samples.removeFirst() }
        let sorted = samples.sorted()
        let median = sorted.count == 2 ? (sorted[0] + sorted[1]) / 2 : sorted[sorted.count / 2]
        let tau = median >= previous ? 5.0 : 15.0
        let alpha = 1 - exp(-elapsed / tau)
        let change = (median - previous) * alpha
        value = previous + max(-elapsed, min(1.5 * elapsed, change))
        self.previousTime = now
        return value
    }
}

/// Restricts normal curve changes, independently of the temperature estimator.
/// A sustained hotspot bypasses dwell, deadband and ramp limits.
public struct CurveFanGovernor {
    private var confirmed: [Int: Double] = [:]
    private var confirmedAt: TimeInterval = 0
    public init() {}
    public mutating func reset(fans: [FanReading], targets: [Int: Double], now: TimeInterval, allowsFanStop: Bool = false) {
        confirmed = Dictionary(uniqueKeysWithValues: fans.map { fan in
            let target = targets[fan.id] ?? fan.current ?? fan.safeMinimum
            return (fan.id, allowsFanStop && target == 0 ? 0 : max(fan.safeMinimum, min(target, fan.maximum ?? fan.safeMinimum)))
        })
        confirmedAt = now
    }
    public func propose(fans: [FanReading], desired: [Int: Double], now: TimeInterval, emergency: Bool, allowsFanStop: Bool = false) -> [Int: Double] {
        let elapsed = max(0, now - confirmedAt)
        return Dictionary(uniqueKeysWithValues: fans.map { fan in
            let maximum = fan.maximum ?? fan.safeMinimum
            if emergency { return (fan.id, maximum) }
            let previous = confirmed[fan.id] ?? fan.safeMinimum
            // Stop is discrete: don't ramp through unsupported low RPM, or
            // let the deadband leave the fan at a small nonzero target.
            if allowsFanStop && desired[fan.id] == 0 {
                return (fan.id, elapsed >= 3 ? 0 : previous)
            }
            let wanted = max(fan.safeMinimum, min(desired[fan.id] ?? previous, maximum))
            if previous == 0 && wanted > 0 { return (fan.id, wanted) }
            guard elapsed >= 3, abs(wanted - previous) >= 150 else { return (fan.id, previous) }
            let difference = wanted - previous
            let limit = elapsed * (difference > 0 ? 150 : 75)
            let limited = previous + max(-limit, min(difference, limit))
            // Quantize the change toward zero, preserving the ramp bound even
            // when the hardware minimum is not a multiple of 100 RPM.
            let steps = ((limited - previous) / 100).rounded(.towardZero)
            return (fan.id, max(fan.safeMinimum, min(previous + steps * 100, maximum)))
        })
    }
    public mutating func confirm(_ targets: [Int: Double], now: TimeInterval) {
        if targets != confirmed { confirmed = targets; confirmedAt = now }
    }
}
