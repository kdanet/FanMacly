import FanMaclyCore

/// Presentation only: reference labels never change the classifications or
/// thermal inputs used by the helper. Key matching is deliberately case-sensitive.
struct SensorGuide {
    enum Confidence: String {
        case reference = "По справочнику"
        case family = "Предположение по коду"
        case unknown = "Назначение неизвестно"
        case application = "Использование в FanMacly"
    }
    let title: String
    let explanation: String
    let location: String
    let confidence: Confidence
    let source: String?
    var details: String { "\(explanation)\nОбласть: \(location)." }
    var priority: Int {
        switch confidence { case .application: return 0; case .reference: return 1; case .family: return 2; case .unknown: return 3 }
    }
    static let stats = "https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift"
    static let virtualSMC = "https://github.com/acidanthera/VirtualSMC/blob/master/Docs/SMCSensorKeys.txt"
    static let iSMC = "https://github.com/dkorunic/iSMC/blob/master/smc/sensors.go"

    static func describe(_ key: String) -> SensorGuide {
        func entry(_ title: String, _ explanation: String, _ location: String, _ confidence: Confidence = .reference, _ source: String? = stats) -> SensorGuide {
            .init(title: title, explanation: explanation, location: location, confidence: confidence, source: source)
        }
        switch key {
        case "TCMb":
            return entry("CPU · среднее кристалла", "В iSMC/OSHI — CPU Die Average. Основной источник профиля FanMacly; в панели сглаживается, здесь показано исходное значение. Это справочная расшифровка SMC, а не публичная спецификация Apple.", "агрегированное показание кристалла CPU по справочнику", .reference, iSMC)
        case "TCMz":
            return entry("CPU · максимум кристалла", "В iSMC/OSHI — CPU Die Max. Максимальное исходное показание отличается от усреднённого TCMb и участвует в защите от перегрева.", "агрегированный максимум кристалла CPU по справочнику", .reference, iSMC)
        case "TCDX":
            return entry("CPU · сводное показание", "В iSMC — CPU Die Aggregate. Резервный источник профиля при отсутствии корректного TCMb.", "агрегированное показание CPU по справочнику", .reference, iSMC)
        case "TB0T":
            return entry("Аккумулятор · общая температура", "Температура аккумулятора. Канал не обозначает номер отдельной ячейки.", "аккумуляторный блок; точная точка зависит от модели", .reference, virtualSMC)
        case "TB1T", "TB2T":
            let number = key == "TB1T" ? 1 : 2
            return entry("Аккумулятор · термодатчик \(number)", "Температурный канал аккумулятора. Номер канала не равен номеру ячейки и не задаёт её положение.", "аккумуляторный блок; точная точка зависит от модели")
        case "TH0a", "TH0b":
            let channel = key == "TH0a" ? "A" : "B"
            return entry("SSD · канал \(channel)", "Температурный канал накопителя \(channel). Разделение на контроллер и NAND для этой модели не подтверждено.", "накопитель SSD; точное место неизвестно", .reference, virtualSMC)
        case "TH0x":
            return entry("SSD · сводное показание", "В справочнике VirtualSMC — максимальная температура накопителя. Это может быть сводный канал, а не отдельный физический датчик.", "накопитель SSD", .reference, virtualSMC)
        case "TW0P":
            return entry("Wi-Fi · рядом с модулем", "В справочниках обозначен как Airport / Wireless proximity: температура в области беспроводного модуля.", "область Wi-Fi; точная точка зависит от модели")
        case "TaLP", "TaRF":
            let side = key == "TaLP" ? "слева" : "справа"
            return entry("Воздушный поток · \(side)", "В справочнике Stats — Airflow \(key == "TaLP" ? "left" : "right"). Не следует сравнивать это показание с температурой кристалла CPU.", "левая/правая зона охлаждения по справочнику; точная точка не подтверждена")
        case "Ts0P":
            return entry("Корпус · зона трекпада", "В справочнике встречается как Trackpad или Palm Rest. Точное назначение зависит от модели Mac.", "трекпад / область под ладонями", .reference, virtualSMC)
        default: break
        }
        if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("TC") || key.hasPrefix("Tc") {
            return entry("CPU · канал \(key)", "Вероятно относится к процессору по семейству кода. Соответствие конкретному ядру и тип показания для этой модели не подтверждены.", "предположительно процессор; точное место неизвестно", .family, nil)
        }
        if key.hasPrefix("Tg") || key.hasPrefix("TG") {
            return entry("GPU · канал \(key)", "Вероятно относится к графическому блоку по семейству кода. Нельзя считать каждый канал отдельным ядром GPU.", "предположительно графический блок; точное место неизвестно", .family, nil)
        }
        return entry("Канал SMC · \(key)", "Для этого кода нет проверенной расшифровки в справочнике FanMacly. Это может быть датчик, расчётное значение или служебный канал; считать его температурой конкретной детали нельзя.", "неизвестна", .unknown, nil)
    }
}
