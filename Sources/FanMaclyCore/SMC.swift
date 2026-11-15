import Foundation
import SMCBridge

public enum SMCNumber {
    public static func fourCC(_ string: String) -> UInt32 {
        guard string.utf8.count == 4 else { return 0 }
        return string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    public static func name(_ code: UInt32) -> String {
        String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii) ?? ""
    }
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        let result: Double
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
            result = Double(Float(bitPattern: bits))
        case "sp78":
            guard bytes.count == 2 else { return nil }
            result = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            result = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 ", "ui16", "ui32":
            let expected = type == "ui8 " ? 1 : type == "ui16" ? 2 : 4
            guard bytes.count == expected else { return nil }
            result = Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default: return nil
        }
        return result.isFinite ? result : nil
    }
}

/// Confine each instance to a single serial queue. The UI never calls IOKit directly.
public final class SMCClient: SMCRegisters {
    private var connection: OpaquePointer?
    private var temperatureKeys: [String]?
    private lazy var fanModes = FanModeController(registers: self)
    public init() {}
    deinit { fm_close(connection) }
    public func open() throws {
        #if !arch(arm64)
        throw FanMaclyError.message("FanMacly поддерживает только Mac с Apple Silicon.")
        #else
        if connection == nil { connection = fm_open() }
        guard connection != nil else { throw FanMaclyError.message("Не удалось открыть AppleSMC. Датчики недоступны.") }
        #endif
    }
    private func value(_ key: String) -> (String, [UInt8])? {
        guard key.utf8.count == 4 else { return nil }
        var value = FMValue()
        guard fm_read(connection, SMCNumber.fourCC(key), &value) else { return nil }
        let size = Int(value.size)
        return (SMCNumber.name(value.type), withUnsafeBytes(of: value.bytes) { Array($0.prefix(size)) })
    }
    public func number(_ key: String) -> Double? {
        guard let (type, bytes) = value(key) else { return nil }
        return SMCNumber.decode(type: type, bytes: bytes)
    }
    /// Read-only diagnostics: expose the exact bytes so an independent decoder
    /// can verify the number format without reusing SMCNumber.decode.
    public func rawReading(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard let (type, bytes) = value(key) else { return nil }
        return (type, bytes)
    }
    public func writeNumber(_ key: String, _ number: Double) throws {
        guard number.isFinite, let (type, _) = value(key) else { throw FanMaclyError.message("Ключ \(key) недоступен.") }
        let bytes: [UInt8]
        switch type {
        case "flt ":
            var bits = Float(number).bitPattern.littleEndian
            bytes = withUnsafeBytes(of: &bits) { Array($0) }
        case "fpe2":
            guard (0...16383).contains(number) else { throw FanMaclyError.message("Обороты вне диапазона.") }
            let raw = UInt16((number * 4).rounded())
            bytes = [UInt8(raw >> 8), UInt8(raw & 255)]
        case "ui8 ":
            guard (0...255).contains(number) else { throw FanMaclyError.message("Значение вне диапазона.") }
            bytes = [UInt8(number)]
        case "ui16":
            guard (0...65535).contains(number) else { throw FanMaclyError.message("Значение вне диапазона.") }
            let raw = UInt16(number); bytes = [UInt8(raw >> 8), UInt8(raw & 255)]
        default: throw FanMaclyError.message("Формат \(type) для \(key) не поддерживается.")
        }
        guard bytes.withUnsafeBufferPointer({ fm_write(connection, SMCNumber.fourCC(key), $0.baseAddress, UInt32($0.count)) }) else {
            let detail = fm_last_result(connection)
            throw SMCWriteFailure(key: key, ioReturn: detail.io_return, result: detail.result, status: detail.status)
        }
    }
    private func discoverTemperatureKeys() -> [String] {
        guard let count = number("#KEY"), count > 0, count < 30000 else { return [] }
        return (0..<UInt32(count)).compactMap { index in
            let name = SMCNumber.name(fm_key_at(connection, index))
            return name.hasPrefix("T") ? name : nil
        }
    }
    public func snapshot() -> HardwareSnapshot {
        do { try open() } catch { return .init(error: error.localizedDescription) }
        if temperatureKeys == nil || temperatureKeys?.isEmpty == true { temperatureKeys = discoverTemperatureKeys() }
        let sensors = (temperatureKeys ?? []).compactMap { key -> TemperatureSensor? in
            guard let (type, bytes) = value(key), ["flt ", "sp78"].contains(type),
                  let celsius = SMCNumber.decode(type: type, bytes: bytes), celsius > 0, celsius < 125 else { return nil }
            let (name, group) = Self.metadata(key)
            return TemperatureSensor(id: key, name: name, group: group, celsius: celsius)
        }.sorted { $0.id < $1.id }
        let count = number("FNum").flatMap { $0 >= 0 && $0 <= 10 ? Int($0) : nil }
        let fans = (0..<(count ?? 0)).map { index in
            FanReading(id: index, current: number("F\(index)Ac"), minimum: number("F\(index)Mn"), maximum: number("F\(index)Mx"), manual: fanModes.mode(fan: index).map { $0.value == 1 })
        }
        return .init(fans: fans, sensors: sensors, fanCount: count, error: count == nil ? "SMC не сообщает число вентиляторов." : nil,
                     thermalPressure: ThermalPressure(rawValue: ProcessInfo.processInfo.thermalState.rawValue))
    }
    /// May request an asynchronous firmware handoff. The engine retries on ticks.
    public func setManual(_ manual: Bool, fan: Int) throws {
        guard (0..<10).contains(fan) else { throw FanMaclyError.message("Неизвестный вентилятор.") }
        try fanModes.setManual(manual, fan: fan)
    }
    public func setTarget(_ rpm: Double, fan: Int) throws { try fanModes.setTarget(rpm, fan: fan) }
    public func fanDiagnostics() -> String {
        let count = min(10, max(0, Int(number("FNum") ?? 0)))
        let keys = ["Ftst"] + (0..<count).flatMap { ["F\($0)Md", "F\($0)md", "F\($0)Tg", "F\($0)Ac"] }
        return keys.compactMap { key in number(key).map { "\(key)=\(String(format: "%.1f", $0))" } }.joined(separator: " ")
    }
    public static func metadata(_ key: String) -> (String, SensorGroup) {
        let known: [String: (String, SensorGroup)] = [
            "TC0P": ("CPU · рядом с процессором", .cpu), "TC0D": ("CPU · кристалл", .cpu),
            "TCXC": ("CPU · кластер", .cpu), "TCDX": ("CPU · кристалл", .cpu),
            "TCMb": ("CPU · среднее кристалла", .cpu), "TCMz": ("CPU · максимум кристалла", .cpu),
            "TB0T": ("Аккумулятор · общая температура", .battery), "TB1T": ("Аккумулятор · термодатчик 1", .battery),
            "TB2T": ("Аккумулятор · термодатчик 2", .battery), "TBAT": ("Аккумулятор", .battery),
            "TG0D": ("GPU · кристалл", .gpu), "TG0P": ("GPU · рядом с чипом", .gpu),
            "TH0a": ("SSD · канал A", .memory), "TH0b": ("SSD · канал B", .memory),
            "TPMP": ("Память платформы", .memory), "TmMP": ("Модуль памяти", .memory)
        ]
        if let value = known[key] { return value }
        let prefix = String(key.prefix(2))
        let group: SensorGroup
        switch prefix {
        case "TC", "Tc", "Tp", "Te", "TP", "TE": group = .cpu
        case "TG", "Tg": group = .gpu
        case "TB": group = .battery
        case "TH", "Th", "TM", "Tm", "TN": group = .memory
        case "TA", "Ta", "Ts", "TS", "TW": group = .enclosure
        default: group = .other
        }
        return ("\(group.rawValue) · \(key)", group)
    }
}
