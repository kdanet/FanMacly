import CoreFoundation
import Darwin
import Foundation

/// Average SoC power over one sampling interval, derived from IOReport "Energy Model" counters.
public struct PowerReading: Codable, Sendable, Equatable {
    public var cpuWatts: Double?
    public var gpuWatts: Double?
    public var aneWatts: Double?
    public var dramWatts: Double?
    public var totalWatts: Double?   // sum of available components (or package if exposed)
    public var interval: TimeInterval

    public init(cpuWatts: Double?, gpuWatts: Double?, aneWatts: Double?, dramWatts: Double?, totalWatts: Double?, interval: TimeInterval) {
        self.cpuWatts = cpuWatts
        self.gpuWatts = gpuWatts
        self.aneWatts = aneWatts
        self.dramWatts = dramWatts
        self.totalWatts = totalWatts
        self.interval = interval
    }
}

/// Reads CPU/GPU/ANE/DRAM energy counters through Apple's private `libIOReport.dylib` without root,
/// the same way macmon / socpowerbud / asitop's non-root paths do. Everything is resolved at runtime with
/// `dlopen`/`dlsym`, so a missing library or symbol only makes the sampler unavailable.
///
/// Channels seen in the "Energy Model" group on an M4 Max (T6041), macOS 27.0.1:
/// - Driver `AppleT6041PMGR`, unit mJ:
///   per-core `EACC_CPU0…3`, `PACC0_CPU0…5`, `PACC1_CPU0…5` (+ `…_SRAM` variants), `EACC_CPM`, `PACC0_CPM`,
///   `PACC1_CPM` (+ `_SRAM`), per-cluster `EACC_CPU`, `PACC0_CPU`, `PACC1_CPU`, aggregate `CPU Energy`
///   (equals the sum of the three cluster channels), ~280 `ECPUDTLxx` / `PCPUDTLxx` / `PCPU1DTLxx` sub-channels,
///   `GPU`, `GPU SRAM`, `AFR`, `ANE`, `ISP`, `AVE`, `MSR`, `AMCC`, `DCS`, `DRAM`, `DISP`, `DISPEXT`.
/// - PCIe drivers, unit uJ: `PCIe Port 0 Energy`, `PCIe Port 1 Energy`, `apciec0/1/2 Energy`.
/// - Driver `AGXAcceleratorG16X`, unit nJ: `GPU Energy`.
///
/// Mapping: CPU = channels ending in "CPU Energy" (fallback: per-cluster `*_CPU`); GPU = "GPU Energy" (fallback:
/// PMGR "GPU"); ANE = names starting with "ANE"; DRAM = names starting with "DRAM".
///
/// Caveat observed on that machine: the PMGR energy counters can stop advancing for unprivileged readers (their
/// sample timestamp freezes while other PMGR groups such as "CPU Stats" keep updating). CPU and DRAM can never
/// consume exactly zero energy while the system is awake, so a zero CPU delta marks every channel from the
/// same driver as stale and the affected components are reported as `nil` rather than as 0 W.
/// The GPU driver's counter shows the same pattern on its own. When the counters resume they jump by the energy of the whole frozen stretch at once (thousands of watts
/// over one interval), so the first delta after a freeze is discarded as well. Any component above
/// `PowerPlausibility.maximumWatts` is treated as a counter glitch.
///
/// Not thread-safe; confine to one actor/queue. Returns nil on the first call (baseline) and whenever IOReport is unavailable.
public final class PowerSampler {
    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> UnsafeMutableRawPointer?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UInt64, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias CreateSamples = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias CreateSamplesDelta = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias ChannelGetString = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias ChannelGetFormat = @convention(c) (UnsafeMutableRawPointer?) -> UInt8
    private typealias ChannelGetDriverID = @convention(c) (UnsafeMutableRawPointer?) -> UInt64
    private typealias SimpleGetIntegerValue = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int64

    private struct API {
        let createSamples: CreateSamples
        let createSamplesDelta: CreateSamplesDelta
        let getGroup: ChannelGetString
        let getSubGroup: ChannelGetString
        let getChannelName: ChannelGetString
        let getUnitLabel: ChannelGetString
        let getFormat: ChannelGetFormat?
        let getDriverID: ChannelGetDriverID?
        let getIntegerValue: SimpleGetIntegerValue
    }

    private enum Component { case cpu, cpuCluster, gpu, gpuPMGR, ane, dram }

    private static let group = "Energy Model"
    private static let simpleFormat: UInt8 = 1  // kIOReportFormatSimple

    private let api: API?
    private let subscription: CFTypeRef?
    private let subscribedChannels: CFMutableDictionary?
    private var previous: CFDictionary?
    private var previousTime: UInt64 = 0
    private var freeze = CounterFreeze()
    private var gpuFreeze = CounterFreeze()

    public var isAvailable: Bool { api != nil && subscription != nil && subscribedChannels != nil }

    public init() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_LOCAL) else {
            api = nil; subscription = nil; subscribedChannels = nil
            return
        }
        func load<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copyChannels = load("IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self),
              let createSubscription = load("IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = load("IOReportCreateSamples", as: CreateSamples.self),
              let createDelta = load("IOReportCreateSamplesDelta", as: CreateSamplesDelta.self),
              let getGroup = load("IOReportChannelGetGroup", as: ChannelGetString.self),
              let getSubGroup = load("IOReportChannelGetSubGroup", as: ChannelGetString.self),
              let getName = load("IOReportChannelGetChannelName", as: ChannelGetString.self),
              let getUnit = load("IOReportChannelGetUnitLabel", as: ChannelGetString.self),
              let getInteger = load("IOReportSimpleGetIntegerValue", as: SimpleGetIntegerValue.self)
        else {
            api = nil; subscription = nil; subscribedChannels = nil
            return
        }
        let api = API(createSamples: createSamples, createSamplesDelta: createDelta,
                      getGroup: getGroup, getSubGroup: getSubGroup, getChannelName: getName, getUnitLabel: getUnit,
                      getFormat: load("IOReportChannelGetFormat", as: ChannelGetFormat.self),
                      getDriverID: load("IOReportChannelGetDriverID", as: ChannelGetDriverID.self),
                      getIntegerValue: getInteger)

        // Copy rule: the returned channel dictionary is +1.
        guard let rawChannels = copyChannels(Self.group as CFString, nil, 0, 0, 0) else {
            self.api = nil; subscription = nil; subscribedChannels = nil
            return
        }
        let channels = Unmanaged<CFDictionary>.fromOpaque(rawChannels).takeRetainedValue()
        guard CFDictionaryGetCount(channels) > 0,
              let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(channels), channels)
        else {
            self.api = nil; subscription = nil; subscribedChannels = nil
            return
        }
        var rawSubscribed: UnsafeMutableRawPointer?
        // Create rule: both the subscription and the subscribed-channels out parameter are +1.
        let rawSubscription = createSubscription(nil, Unmanaged.passUnretained(desired).toOpaque(), &rawSubscribed, 0, nil)
        let subscription = rawSubscription.map { Unmanaged<CFTypeRef>.fromOpaque($0).takeRetainedValue() }
        let subscribed = rawSubscribed.map { Unmanaged<CFMutableDictionary>.fromOpaque($0).takeRetainedValue() }
        guard let subscription, let subscribed else {
            self.api = nil; self.subscription = nil; subscribedChannels = nil
            return
        }
        self.api = api
        self.subscription = subscription
        self.subscribedChannels = subscribed
        // The dylib handle is intentionally never dlclose'd: the function pointers above must stay valid.
    }

    /// Average power since the previous call. The first call only records a baseline and returns nil.
    public func sample() -> PowerReading? {
        guard let api, let subscription, let subscribedChannels else { return nil }
        guard let rawCurrent = api.createSamples(Unmanaged.passUnretained(subscription).toOpaque(),
                                                 Unmanaged.passUnretained(subscribedChannels).toOpaque(), nil)
        else { return nil }
        let current = Unmanaged<CFDictionary>.fromOpaque(rawCurrent).takeRetainedValue()
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { previous = current; previousTime = now }
        guard let previous, now > previousTime else { return nil }
        let interval = TimeInterval(now - previousTime) / 1e9

        guard let rawDelta = api.createSamplesDelta(Unmanaged.passUnretained(previous).toOpaque(),
                                                    Unmanaged.passUnretained(current).toOpaque(), nil)
        else { return nil }
        let delta = Unmanaged<CFDictionary>.fromOpaque(rawDelta).takeRetainedValue()
        return reading(from: delta, interval: interval, api: api)
    }

    private func reading(from delta: CFDictionary, interval: TimeInterval, api: API) -> PowerReading? {
        let key = "IOReportChannels" as CFString
        guard let rawArray = withExtendedLifetime(key, { CFDictionaryGetValue(delta, Unmanaged.passUnretained(key).toOpaque()) })
        else { return nil }
        let array = Unmanaged<CFArray>.fromOpaque(rawArray).takeUnretainedValue()
        guard CFGetTypeID(array) == CFArrayGetTypeID() else { return nil }

        var joules = [Component: Double]()
        var drivers = [Component: Set<UInt64>]()
        for index in 0..<CFArrayGetCount(array) {
            guard let element = CFArrayGetValueAtIndex(array, index) else { continue }
            let channel = UnsafeMutableRawPointer(mutating: element)
            guard CFGetTypeID(Unmanaged<CFTypeRef>.fromOpaque(channel).takeUnretainedValue()) == CFDictionaryGetTypeID(),
                  Self.string(api.getGroup(channel)) == Self.group,
                  api.getFormat.map({ $0(channel) == Self.simpleFormat }) ?? true,
                  let name = Self.string(api.getChannelName(channel)),
                  let scale = Self.joulesPerUnit(Self.string(api.getUnitLabel(channel)))
            else { continue }
            let energy = Double(api.getIntegerValue(channel, 0)) * scale
            let driver = api.getDriverID?(channel) ?? 0
            guard let component = Self.component(for: name) else { continue }
            joules[component, default: 0] += energy
            drivers[component, default: []].insert(driver)
        }

        // Prefer aggregate channels; fall back only when the aggregate is absent on this SoC.
        let cpuKey: Component = joules[.cpu] != nil ? .cpu : .cpuCluster
        let gpuKey: Component = joules[.gpu] != nil ? .gpu : .gpuPMGR

        // A frozen driver yields an exact zero delta for all of its channels. CPU energy is never truly zero over
        // an interval, so use it as the staleness probe for its driver (normally the PMGR, which also owns ANE/DRAM).
        var cpuDriver: Set<Component> = [cpuKey]
        if api.getDriverID != nil, let cpuDrivers = drivers[cpuKey] {
            for (component, sources) in drivers where sources.isSubset(of: cpuDrivers) { cpuDriver.insert(component) }
        }
        var stale = freeze.isStale(frozen: joules[cpuKey] == 0) ? cpuDriver : []
        // The GPU driver (AGX) skips updates the same way: an exact zero, then a double-sized delta.
        // A fully power-gated GPU also reads zero; it is shown as "no data" rather than 0 W.
        if !cpuDriver.contains(gpuKey), gpuFreeze.isStale(frozen: joules[gpuKey] == 0) { stale.insert(gpuKey) }
        func watts(_ key: Component) -> Double? {
            guard let energy = joules[key], !stale.contains(key) else { return nil }
            return PowerPlausibility.watts(joules: energy, interval: interval)
        }

        let cpu = watts(cpuKey), gpu = watts(gpuKey), ane = watts(.ane), dram = watts(.dram)
        let parts = [cpu, gpu, ane, dram].compactMap { $0 }
        return PowerReading(cpuWatts: cpu, gpuWatts: gpu, aneWatts: ane, dramWatts: dram,
                            totalWatts: parts.isEmpty ? nil : parts.reduce(0, +), interval: interval)
    }

    private static func component(for name: String) -> Component? {
        if name.hasSuffix("CPU Energy") { return .cpu }
        if name == "GPU Energy" { return .gpu }
        if name == "GPU" { return .gpuPMGR }
        if name.hasPrefix("ANE") { return .ane }
        if name.hasPrefix("DRAM") { return .dram }
        // Cluster-level CPU channels (EACC_CPU, PACC0_CPU, ECPU, PCPU, ...), used only if no "CPU Energy" exists.
        if name.range(of: #"^([EPM]ACC\d*_CPU|[EPM]CPU\d*)$"#, options: .regularExpression) != nil { return .cpuCluster }
        return nil
    }

    private static func joulesPerUnit(_ label: String?) -> Double? {
        switch label?.trimmingCharacters(in: .whitespaces) {
        case "J": return 1
        case "mJ": return 1e-3
        case "uJ", "µJ", "μJ": return 1e-6
        case "nJ": return 1e-9
        case "pJ": return 1e-12
        default: return nil
        }
    }

    /// Get rule: IOReport channel accessors return borrowed strings.
    private static func string(_ pointer: UnsafeMutableRawPointer?) -> String? {
        guard let pointer else { return nil }
        let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return unsafeBitCast(value, to: CFString.self) as String
    }
}

/// Tracks a counter that can freeze: the frozen deltas and the catch-up jump right after them are both unusable.
struct CounterFreeze {
    private var frozenBefore = false
    /// Call once per delta with whether this delta is an exact zero.
    mutating func isStale(frozen: Bool) -> Bool {
        defer { frozenBefore = frozen }
        return frozen || frozenBefore
    }
}

public enum PowerPlausibility {
    /// Far above any Apple Silicon component (an M-series Max/Ultra draws well under 300 W in total).
    public static let maximumWatts = 500.0
    /// Average power, or nil for an impossible value.
    public static func watts(joules: Double, interval: TimeInterval) -> Double? {
        guard interval > 0, joules.isFinite else { return nil }
        let watts = max(0, joules) / interval
        return watts <= maximumWatts ? watts : nil
    }
}
