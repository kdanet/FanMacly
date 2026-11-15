import Foundation

public enum ThermalPressure: Int, Codable, Sendable {
    case nominal, fair, serious, critical
    public var requiresSystemCooling: Bool { self == .serious || self == .critical }
}

public enum ThermalCause: String, Codable, Sendable {
    case systemPressure, controlSensor, criticalPeak, sustainedPeak
}

public struct ThermalEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let cause: ThermalCause
    public let sensor: String?
    public let celsius: Double?
    public var message: String {
        let value = celsius.map { "\(Int($0.rounded()))°" } ?? "—"
        switch cause {
        case .systemPressure: return "macOS сообщает о сильном нагреве. Включена автоматика."
        case .controlSensor: return "Температура CPU \(value). Включена автоматика macOS."
        case .criticalPeak: return "Высокий пик CPU: \(value). Включена автоматика macOS."
        case .sustainedPeak: return "Температурное событие CPU: \(value). Включена автоматика macOS."
        }
    }
    public var detail: String {
        let value = celsius.map { String(format: "%.1f °C", $0) } ?? "—"
        return "\(message)\nДатчик: \(sensor ?? "состояние macOS"), значение: \(value). Время: \(date.formatted(date: .omitted, time: .standard)).\nПоказание CPU в панели сглаживается и может отличаться от мгновенного максимума."
    }
}

struct ThermalLimitReached: Error {
    let event: ThermalEvent
}

/// Raw temperatures can request maximum cooling without cancelling a profile.
/// Only the OS thermal-pressure signal requests a thermal handback to macOS.
/// Numeric thresholds here are cooling preferences, not claimed chip limits.
public struct CPUThermalSafety {
    private var hotSince: TimeInterval?
    private var coolSince: TimeInterval?
    private var previousTime: TimeInterval?
    public private(set) var requiresMaximumCooling = false
    public init() {}
    public mutating func observe(_ snapshot: HardwareSnapshot, now: TimeInterval) -> ThermalEvent? {
        let peak = snapshot.cpuPeakReading
        let control = snapshot.cpuControlReading
        let discontinuity = previousTime.map({ now < $0 || now - $0 > 2.5 }) == true || !now.isFinite
        if discontinuity { hotSince = nil; coolSince = nil }
        let fresh = previousTime != now
        previousTime = now
        if let peak, peak.celsius >= 90, now.isFinite {
            if hotSince == nil { hotSince = now }
        } else { hotSince = nil }
        let boost = control.map { $0.celsius >= 85 } == true || peak.map { $0.celsius >= 100 } == true ||
            hotSince.map { now - $0 >= 2 } == true
        if boost {
            requiresMaximumCooling = true
            coolSince = nil
        } else if fresh, now.isFinite, control.map({ $0.celsius < 80 }) == true, peak.map({ $0.celsius < 90 }) == true {
            if coolSince == nil { coolSince = now }
            if now - (coolSince ?? now) >= 5 { requiresMaximumCooling = false }
        } else if fresh { coolSince = nil }
        if snapshot.thermalPressure?.requiresSystemCooling == true {
            return .init(id: UUID(), date: Date(), cause: .systemPressure, sensor: nil, celsius: nil)
        }
        return nil
    }
}
