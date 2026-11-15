import Foundation

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
}

public struct FanReading: Identifiable, Codable, Sendable {
    public var id: Int
    public var current: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var manual: Bool?
    public var name: String { "Вентилятор \(id + 1)" }
    public var safeMinimum: Double { max(minimum ?? 1200, 1200) }
    public var controllable: Bool {
        guard let minimum, let maximum, let current, current.isFinite, (0...20000).contains(current) else { return false }
        return minimum.isFinite && maximum.isFinite && minimum >= 0 && maximum - safeMinimum >= 50 && maximum <= 20000
    }
    public init(id: Int, current: Double?, minimum: Double?, maximum: Double?, manual: Bool?) {
        self.id = id; self.current = current; self.minimum = minimum; self.maximum = maximum; self.manual = manual
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
    public func temperature(_ group: SensorGroup) -> Double? { sensors.filter { $0.group == group }.map(\.celsius).max() }
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
    public static let balanced = CoolingCurve(points: [.init(40, 0), .init(55, 20), .init(65, 45), .init(75, 75), .init(85, 100)])
    public static let cool = CoolingCurve(points: [.init(40, 20), .init(55, 45), .init(65, 65), .init(75, 90), .init(85, 100)])
    public var isValid: Bool {
        guard points.count >= 2, points.count <= 12 else { return false }
        for (index, point) in points.enumerated() {
            guard point.temperature.isFinite, point.percent.isFinite, (20...90).contains(point.temperature), (0...100).contains(point.percent) else { return false }
            if index > 0, point.temperature <= points[index - 1].temperature || point.percent < points[index - 1].percent { return false }
        }
        return points.last!.temperature <= 85 && points.last!.percent == 100
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
}

public struct ControlRequest: Codable, Sendable {
    public var mode: CoolingMode
    public var targets: [Int: Double]
    public var curve: CoolingCurve
    public var expectedFallbackID: UUID?
    public init(mode: CoolingMode, targets: [Int: Double] = [:], curve: CoolingCurve = .balanced, expectedFallbackID: UUID? = nil) {
        self.mode = mode; self.targets = targets; self.curve = curve
        self.expectedFallbackID = expectedFallbackID
    }
}

public enum CoolingPreparation: String, Codable, Sendable { case handoff, targets }

public struct HelperStatus: Codable, Sendable {
    public var version = HelperIdentity.protocolVersion
    public var sequence: UInt64?
    public var coolingBoost = false
    public var mode: CoolingMode = .system
    public var targets: [Int: Double] = [:]
    public var message: String?
    public var connected = true
    public var preparing: Bool? = false
    public var restoring: Bool? = false
    public var preparationStage: CoolingPreparation?
    public var controlTemperature: Double?
    public var temperatureSource: String?
    public var rawControlTemperature: Double?
    public var peakCPUReading: CPUControlReading?
    public var temperatureSampleDate: Date?
    public var thermalEvent: ThermalEvent?
    public var automaticFallbackID: UUID?
    public var customControlAllowed: Bool?
    public init() {}
}

public enum FanMaclyError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
