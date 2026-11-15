import Foundation

/// Every number the helper uses to decide between boosting, retrying and
/// handing control back to macOS. Values are FanMacly cooling preferences
/// calibrated for Apple Silicon, not published Apple temperature limits.
public struct ControlPolicy: Codable, Equatable, Sendable {
    // Maximum cooling (the profile stays active, fans go to the hardware maximum).
    public var boostControlCelsius: Double = 95
    public var boostPeakCelsius: Double = 105
    public var boostPeakSustain: TimeInterval = 5
    public var boostGPUCelsius: Double = 95
    public var boostBatteryCelsius: Double = 45
    // Leaving maximum cooling requires every reading to be below these for `releaseAfter`.
    public var releaseControlCelsius: Double = 88
    public var releasePeakCelsius: Double = 100
    public var releaseGPUCelsius: Double = 90
    public var releaseBatteryCelsius: Double = 42
    public var releaseAfter: TimeInterval = 10
    // Hand control back to macOS only in these cases.
    public var handbackBatteryCelsius: Double = 60
    /// Transient read failures are tolerated for this long before suspending.
    public var dataFaultGrace: TimeInterval = 3
    /// The firmware or another app can take a fan back; re-acquire it this many
    /// times within `reacquireWindow` before suspending.
    public var reacquireLimit = 5
    public var reacquireWindow: TimeInterval = 120
    /// Covers a settle after a recent release plus two Ftst requests
    /// (the firmware typically takes 2–6 s to yield).
    public var handoffTimeout: TimeInterval = 30
    /// A fan that cannot be returned to macOS goes to maximum after this long
    /// while it is hot or the CPU temperature is unknown…
    public var restoreMaximumAfter: TimeInterval = 3
    /// …and the global handoff (Ftst) is cleared after this long regardless.
    public var restoreGiveUp: TimeInterval = 15
    public var targetTimeout: TimeInterval = 6
    /// Automatic resume after a protective handback.
    public var resumeAfter: TimeInterval = 60
    public var resumeStableFor: TimeInterval = 10
    public var autoResumeLimit = 3
    public var autoResumeWindow: TimeInterval = 30 * 60
    public init() {}
    public static let standard = ControlPolicy()
}

public struct ControlEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case info, boost, warning, suspended, resumed, error }
    public var id = UUID()
    public var date: Date
    public var kind: Kind
    public var title: String
    public var detail: String?
    public init(date: Date, kind: Kind, title: String, detail: String? = nil) {
        self.date = date; self.kind = kind; self.title = title; self.detail = detail
    }
}

/// The intent is kept; control is temporarily with macOS.
public struct ControlSuspension: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// macOS thermal pressure is critical, or a battery limit was reached.
        case thermal
        /// Sensors or fan registers could not be read for longer than the grace period.
        case sensors
        /// The fan mode keeps being taken back (macOS or another fan app).
        case conflict
        /// SMC rejected a write or did not confirm it in time.
        case hardware
        /// Helper (re)started with a saved intent and waits for valid data.
        case startup
    }
    public var kind: Kind
    public var message: String
    public var date: Date
    /// When the helper will try again on its own; nil = waits for the user.
    public var resumeDate: Date?
    public init(kind: Kind, message: String, date: Date, resumeDate: Date?) {
        self.kind = kind; self.message = message; self.date = date; self.resumeDate = resumeDate
    }
    public var needsUser: Bool { resumeDate == nil }
}

public struct ThermalAssessment: Equatable, Sendable {
    public var boost = false
    public var boostReason: String?
    /// Non-nil when control must be returned to macOS.
    public var handback: String?
}

/// Raw readings can request maximum cooling without cancelling the profile.
/// Only critical OS pressure or an extreme battery reading hands control back.
public struct ThermalGuard: Sendable {
    public var policy: ControlPolicy
    private var peakHotSince: TimeInterval?
    private var coolSince: TimeInterval?
    private var previousTime: TimeInterval?
    public private(set) var boosting = false
    public private(set) var reason: String?
    public init(policy: ControlPolicy = .standard) { self.policy = policy }

    public mutating func reset() { peakHotSince = nil; coolSince = nil; previousTime = nil; boosting = false; reason = nil }

    public mutating func observe(_ snapshot: HardwareSnapshot, now: TimeInterval) -> ThermalAssessment {
        let control = snapshot.cpuControlReading?.celsius
        let peak = snapshot.cpuPeakReading
        let gpu = snapshot.temperature(.gpu)
        let battery = snapshot.temperature(.battery)
        let pressure = snapshot.thermalPressure
        let discontinuity = previousTime.map({ now < $0 || now - $0 > 2.5 }) == true || !now.isFinite
        if discontinuity { peakHotSince = nil; coolSince = nil }
        let fresh = previousTime != now
        previousTime = now

        if let peak, peak.celsius >= policy.boostPeakCelsius, now.isFinite {
            if peakHotSince == nil { peakHotSince = now }
        } else { peakHotSince = nil }

        var trigger: String?
        if pressure == .serious { trigger = "macOS сообщает о сильном нагреве" }
        else if let control, control >= policy.boostControlCelsius { trigger = "CPU \(Int(control.rounded()))°" }
        else if let since = peakHotSince, now - since >= policy.boostPeakSustain, let peak { trigger = "пик CPU \(Int(peak.celsius.rounded()))° (\(peak.source))" }
        else if let gpu, gpu >= policy.boostGPUCelsius { trigger = "GPU \(Int(gpu.rounded()))°" }
        else if let battery, battery >= policy.boostBatteryCelsius { trigger = "аккумулятор \(Int(battery.rounded()))°" }

        if let trigger {
            boosting = true; reason = trigger; coolSince = nil
        } else if boosting, fresh, now.isFinite {
            let cool = control.map { $0 < policy.releaseControlCelsius } ?? false &&
                (peak?.celsius ?? 0) < policy.releasePeakCelsius &&
                (gpu ?? 0) < policy.releaseGPUCelsius && (battery ?? 0) < policy.releaseBatteryCelsius &&
                pressure?.requiresSystemCooling != true
            if cool {
                if coolSince == nil { coolSince = now }
                if now - (coolSince ?? now) >= policy.releaseAfter { boosting = false; reason = nil; coolSince = nil }
            } else { coolSince = nil }
        }

        var result = ThermalAssessment(boost: boosting, boostReason: boosting ? reason : nil)
        if pressure == .critical { result.handback = "macOS сообщает о критическом нагреве. Управление передано macOS." }
        else if let battery, battery >= policy.handbackBatteryCelsius {
            result.handback = "Аккумулятор нагрелся до \(Int(battery.rounded()))°. Управление передано macOS."
        }
        return result
    }
}

public enum ThermalPressure: Int, Codable, Sendable {
    case nominal, fair, serious, critical
    public var requiresSystemCooling: Bool { self == .serious || self == .critical }
}
