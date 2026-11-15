import Foundation
import IOKit

public enum SensorGroup: String, Codable, CaseIterable, Sendable {
    case cpu = "CPU", gpu = "GPU", battery = "Аккумулятор", memory = "Память и SSD", enclosure = "Корпус", other = "Другие"
    public var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.3.layers.3d"
        case .battery: return "battery.75percent"
        case .memory: return "internaldrive"
        case .enclosure: return "laptopcomputer"
        case .other: return "thermometer.medium"
        }
    }
}

public struct TemperatureSensor: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var group: SensorGroup
    public var celsius: Double
    public init(id: String, name: String, group: SensorGroup, celsius: Double) {
        self.id = id; self.name = name; self.group = group; self.celsius = celsius
    }
    /// Some SMC channels report a placeholder (1–5 °C) instead of a reading,
    /// e.g. GPU sensors while the GPU is power-gated. No part of a running Mac
    /// is that cold, so such values are not temperatures.
    public static let placeholderBelow = 10.0
    public var isPlaceholder: Bool { celsius < Self.placeholderBelow }
}

public struct FanReading: Identifiable, Codable, Sendable {
    public var id: Int
    public var current: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var manual: Bool?
    public var safeMinimum: Double { max(minimum ?? 1200, 1200) }
    public var controllable: Bool {
        guard let minimum, let maximum, let current, current.isFinite, (0...20000).contains(current) else { return false }
        return minimum.isFinite && maximum.isFinite && minimum >= 0 && maximum - safeMinimum >= 50 && maximum <= 20000
    }
    public init(id: Int, current: Double?, minimum: Double?, maximum: Double?, manual: Bool?) {
        self.id = id; self.current = current; self.minimum = minimum; self.maximum = maximum; self.manual = manual
    }
}

/// Human names of fans. Apple Silicon SMC does not say where a fan sits
/// (there is no `F0ID`), so the side is inferred: a MacBook Pro with two fans
/// has `F0` on the left and `F1` on the right, as seen from the keyboard.
/// Other Macs keep numbers; a single fan is just "вентилятор".
public struct FanNames: Equatable, Sendable {
    public enum Side: Sendable { case left, right }
    public let count: Int
    public let laptop: Bool
    public init(count: Int?, laptop: Bool = FanNames.isLaptop) {
        self.count = count ?? 0; self.laptop = laptop
    }
    /// Laptops have an internal battery; desktops do not.
    public static let isLaptop: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { if service != 0 { IOObjectRelease(service) } }
        return service != 0
    }()
    public func side(_ fan: Int) -> Side? {
        guard laptop, count == 2, (0..<2).contains(fan) else { return nil }
        return fan == 0 ? .left : .right
    }
    /// Short label for a fan row or a chart legend: "Левый", "Вентилятор 3".
    public func title(_ fan: Int) -> String {
        switch side(fan) {
        case .left: return "Левый"
        case .right: return "Правый"
        case nil: return count == 1 ? "Вентилятор" : "Вентилятор \(fan + 1)"
        }
    }
    /// "левый вентилятор" (also the accusative: «macOS забрала …»).
    public func nominative(_ fan: Int) -> String { form(fan, "левый", "правый", "вентилятор") }
    /// "Левый вентилятор", to start a sentence.
    public func subject(_ fan: Int) -> String {
        let text = nominative(fan)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    /// "левого вентилятора" («режим …»).
    public func genitive(_ fan: Int) -> String { form(fan, "левого", "правого", "вентилятора") }
    /// "левым вентилятором" («управление …»).
    public func instrumental(_ fan: Int) -> String { form(fan, "левым", "правым", "вентилятором") }
    private func form(_ fan: Int, _ left: String, _ right: String, _ noun: String) -> String {
        switch side(fan) {
        case .left: return "\(left) \(noun)"
        case .right: return "\(right) \(noun)"
        case nil: return count == 1 ? noun : "\(noun) \(fan + 1)"
        }
    }
}

public struct HardwareSnapshot: Codable, Sendable {
    public var date: Date
    public var fans: [FanReading]
    public var sensors: [TemperatureSensor]
    public var fanCount: Int?
    public var error: String?
    public var thermalPressure: ThermalPressure?
    public var hottestCPU: Double? { cpuPeakReading?.celsius }
    public var fanNames: FanNames { FanNames(count: fanCount ?? fans.count) }
    /// The hottest real reading of a group; placeholders are ignored.
    public func temperature(_ group: SensorGroup) -> Double? {
        sensors.filter { $0.group == group && !$0.isPlaceholder }.map(\.celsius).max()
    }
    public init(date: Date = Date(), fans: [FanReading] = [], sensors: [TemperatureSensor] = [], fanCount: Int? = nil, error: String? = nil, thermalPressure: ThermalPressure? = nil) {
        self.date = date; self.fans = fans; self.sensors = sensors; self.fanCount = fanCount; self.error = error
        self.thermalPressure = thermalPressure
    }
}

public enum CoolingMode: String, CaseIterable, Codable, Sendable {
    case system, manual, curve
    public var title: String {
        switch self { case .system: return "Автоматически"; case .manual: return "Вручную"; case .curve: return "По температуре" }
    }
}

public struct CurvePoint: Codable, Identifiable, Equatable, Sendable {
    public var temperature: Double
    public var percent: Double
    public var id: Double { temperature }
    public init(_ temperature: Double, _ percent: Double) { self.temperature = temperature; self.percent = percent }
}

public struct CoolingCurve: Codable, Equatable, Sendable {
    /// Apple Silicon routinely runs at 85–100 °C under sustained load, so the
    /// editable range reaches 100 °C. Speeds are free per point (a curve may
    /// dip or end below 100 %): the helper's thermal guard still forces
    /// maximum cooling at 95 °C regardless of the curve.
    public static let temperatureRange: ClosedRange<Double> = 20...100
    public var points: [CurvePoint]
    public var allowsFanStop: Bool
    public init(points: [CurvePoint], allowsFanStop: Bool = false) {
        self.points = points; self.allowsFanStop = allowsFanStop
    }
    private enum CodingKeys: String, CodingKey { case points, allowsFanStop }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        points = try values.decode([CurvePoint].self, forKey: .points)
        // Existing profiles retain their minimum-RPM meaning until opted in.
        allowsFanStop = try values.decodeIfPresent(Bool.self, forKey: .allowsFanStop) ?? false
    }
    /// Quiet: stays near the minimum through everyday work.
    public static let quiet = CoolingCurve(points: [.init(50, 0), .init(65, 10), .init(75, 25), .init(85, 50), .init(95, 100)])
    public static let balanced = CoolingCurve(points: [.init(45, 0), .init(60, 15), .init(70, 35), .init(80, 60), .init(92, 100)])
    public static let cool = CoolingCurve(points: [.init(40, 15), .init(55, 35), .init(65, 55), .init(75, 80), .init(88, 100)])
    public var isValid: Bool {
        guard points.count >= 2, points.count <= 12 else { return false }
        for (index, point) in points.enumerated() {
            guard point.temperature.isFinite, point.percent.isFinite, Self.temperatureRange.contains(point.temperature),
                  (0...100).contains(point.percent) else { return false }
            if index > 0, point.temperature <= points[index - 1].temperature { return false }
        }
        return true
    }
    public func percent(at temperature: Double) -> Double? {
        guard isValid, temperature.isFinite else { return nil }
        if temperature <= points[0].temperature { return points[0].percent }
        for index in 1..<points.count where temperature <= points[index].temperature {
            let a = points[index - 1], b = points[index]
            return a.percent + (b.percent - a.percent) * (temperature - a.temperature) / (b.temperature - a.temperature)
        }
        return points.last!.percent
    }
    /// Target RPM for one fan, honouring the optional full stop at 0 %.
    public func rpm(at temperature: Double, fan: FanReading) -> Double? {
        guard let percent = percent(at: temperature), let maximum = fan.maximum else { return nil }
        if allowsFanStop && percent == 0 { return 0 }
        return fan.safeMinimum + (maximum - fan.safeMinimum) * percent / 100
    }
}

/// Temporary maximum cooling. It survives app restarts because the helper
/// persists it together with the rest of the intent.
public struct BoostRequest: Codable, Equatable, Sendable {
    public var until: Date
    /// Return control to macOS when the boost ends (boost started from "Авто").
    public var thenSystem: Bool
    public init(until: Date, thenSystem: Bool) { self.until = until; self.thenSystem = thenSystem }
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public var mode: CoolingMode
    public var targets: [Int: Double]
    public var curve: CoolingCurve
    /// Stable identifier of what the user picked (preset key or profile UUID).
    public var profileID: String?
    public var profileName: String?
    public var boost: BoostRequest?
    /// Resume this intent automatically after a protective handback.
    public var autoResume: Bool
    /// Chosen by an automation rule or Focus, not directly by the user.
    public var fromRule: Bool
    public init(mode: CoolingMode, targets: [Int: Double] = [:], curve: CoolingCurve = .balanced,
                profileID: String? = nil, profileName: String? = nil, boost: BoostRequest? = nil, autoResume: Bool = true,
                fromRule: Bool = false) {
        self.mode = mode; self.targets = targets; self.curve = curve
        self.profileID = profileID; self.profileName = profileName; self.boost = boost; self.autoResume = autoResume
        self.fromRule = fromRule
    }
    private enum CodingKeys: String, CodingKey { case mode, targets, curve, profileID, profileName, boost, autoResume, fromRule }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decode(CoolingMode.self, forKey: .mode)
        targets = try values.decodeIfPresent([Int: Double].self, forKey: .targets) ?? [:]
        curve = try values.decodeIfPresent(CoolingCurve.self, forKey: .curve) ?? .balanced
        profileID = try values.decodeIfPresent(String.self, forKey: .profileID)
        profileName = try values.decodeIfPresent(String.self, forKey: .profileName)
        boost = try values.decodeIfPresent(BoostRequest.self, forKey: .boost)
        autoResume = try values.decodeIfPresent(Bool.self, forKey: .autoResume) ?? true
        fromRule = try values.decodeIfPresent(Bool.self, forKey: .fromRule) ?? false
    }
}

public enum CoolingPreparation: String, Codable, Sendable { case handoff, targets }

public struct HelperStatus: Codable, Sendable {
    public var version = HelperIdentity.protocolVersion
    public var sequence: UInt64?
    /// Effective mode currently applied to the hardware.
    public var mode: CoolingMode = .system
    /// What the user asked for; persisted by the helper. nil means macOS.
    public var intent: ControlRequest?
    /// Why the intent is not applied right now, if it isn't.
    public var suspension: ControlSuspension?
    public var coolingBoost = false
    public var boostReason: String?
    public var targets: [Int: Double] = [:]
    public var message: String?
    public var preparing: Bool? = false
    public var restoring: Bool? = false
    public var reacquiring = false
    public var preparationStage: CoolingPreparation?
    public var controlTemperature: Double?
    public var temperatureSource: String?
    public var rawControlTemperature: Double?
    public var peakCPUReading: CPUControlReading?
    public var temperatureSampleDate: Date?
    public var customControlAllowed: Bool?
    public var events: [ControlEvent] = []
    public init() {}
}

public enum FanMaclyError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
