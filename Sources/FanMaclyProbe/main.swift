import Foundation
import FanMaclyCore

// Intentionally read-only. Useful for checking hardware support without installing a daemon.
let smc = SMCClient()
// Long-running, read-only observation for soak tests: one line per second.
if let watch = CommandLine.arguments.first(where: { $0.hasPrefix("--watch=") }), let seconds = Int(watch.dropFirst(8)), seconds > 0 {
    setbuf(stdout, nil)
    let formatter = ISO8601DateFormatter()
    for index in 0..<seconds {
        let snapshot = smc.snapshot()
        func value(_ key: String) -> String { smc.number(key).map { String(format: "%.0f", $0) } ?? "-" }
        let fans = snapshot.fans.map { fan in
            "f\(fan.id):md=\(value("F\(fan.id)Md"))/\(value("F\(fan.id)md")) tg=\(value("F\(fan.id)Tg")) ac=\(value("F\(fan.id)Ac"))"
        }.joined(separator: " ")
        let cpu = snapshot.cpuControlReading.map { String(format: "%.1f", $0.celsius) } ?? "-"
        let peak = snapshot.cpuPeakReading.map { String(format: "%.1f@%@", $0.celsius, $0.source) } ?? "-"
        let gpu = snapshot.temperature(.gpu).map { String(format: "%.1f", $0) } ?? "-"
        print("\(formatter.string(from: snapshot.date)) ftst=\(value("Ftst")) \(fans) cpu=\(cpu) peak=\(peak) gpu=\(gpu) pressure=\(snapshot.thermalPressure?.rawValue ?? -1) err=\(snapshot.error ?? "none")")
        if index < seconds - 1 { Thread.sleep(forTimeInterval: 1) }
    }
    exit(0)
}
if CommandLine.arguments.contains("--fan-audit") {
    let count = min(60, max(1, CommandLine.arguments.first { $0.hasPrefix("--samples=") }.flatMap { Int($0.dropFirst(10)) } ?? 1))
    var samples = [[String: Any]]()
    var failed = false
    for index in 0..<count {
        let snapshot = smc.snapshot()
        failed = failed || snapshot.error != nil || snapshot.fans.isEmpty
        let keys = ["FNum", "Ftst"] + snapshot.fans.flatMap { fan in
            ["Md", "md", "Tg", "Ac", "Mn", "Mx"].map { "F\(fan.id)\($0)" }
        }
        var registers = [String: Any]()
        for key in keys {
            if let reading = smc.rawReading(key) {
                registers[key] = ["type": reading.type, "bytes": reading.bytes,
                                  "value": SMCNumber.decode(type: reading.type, bytes: reading.bytes) as Any? ?? NSNull()]
            } else { registers[key] = NSNull() }
        }
        let fans = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.fans))
        samples.append(["date": ISO8601DateFormatter().string(from: snapshot.date),
                        "uptime": ProcessInfo.processInfo.systemUptime,
                        "fans": fans, "registers": registers,
                        "cpuControlCelsius": snapshot.cpuControlReading?.celsius as Any? ?? NSNull(),
                        "cpuPeakCelsius": snapshot.cpuPeakReading?.celsius as Any? ?? NSNull(),
                        "cpuPeakSource": snapshot.cpuPeakReading?.source as Any? ?? NSNull(),
                        "thermalState": snapshot.thermalPressure?.rawValue as Any? ?? NSNull(),
                        "hardwareError": snapshot.error as Any? ?? NSNull()])
        if index < count - 1 { Thread.sleep(forTimeInterval: 1) }
    }
    let report: [String: Any] = ["kind": "read-only SMC fan audit", "samples": samples]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(failed ? 1 : 0)
}
if CommandLine.arguments.contains("--cpu-audit") {
    let count = min(60, max(1, CommandLine.arguments.first { $0.hasPrefix("--samples=") }.flatMap { Int($0.dropFirst(10)) } ?? 20))
    var samples = [[String: Any]]()
    var filter = CPUTemperatureFilter()
    var failed = false
    for index in 0..<count {
        let snapshot = smc.snapshot()
        let control = snapshot.cpuControlReading
        var raw = [[String: Any]]()
        for key in ["TCMb", "TCDX", "TCMz"] {
            guard let value = smc.rawReading(key) else { continue }
            raw.append(["key": key, "type": value.type, "bytes": value.bytes,
                        "decodedCelsius": SMCNumber.decode(type: value.type, bytes: value.bytes) as Any? ?? NSNull()])
        }
        failed = failed || snapshot.error != nil || control == nil
        let cores = snapshot.sensors.filter { $0.id.hasPrefix("Tp") || $0.id.hasPrefix("Te") }
        samples.append([
            "date": ISO8601DateFormatter().string(from: snapshot.date),
            "source": control?.source as Any? ?? NSNull(), "sourceDescription": control?.description as Any? ?? NSNull(),
            "rawControlCelsius": control?.celsius as Any? ?? NSNull(),
            "filteredCelsius": filter.update(reading: control, now: ProcessInfo.processInfo.systemUptime) as Any? ?? NSNull(),
            "peakSource": snapshot.cpuPeakReading?.source as Any? ?? NSNull(),
            "peakCelsius": snapshot.hottestCPU as Any? ?? NSNull(),
            "coreChannels": Dictionary(uniqueKeysWithValues: cores.map { ($0.id, $0.celsius) }),
            "aggregateRawReadings": raw
        ])
        if index < count - 1 { Thread.sleep(forTimeInterval: 1) }
    }
    let report: [String: Any] = ["kind": "read-only SMC CPU audit", "samples": samples,
        "note": "TCMb interpretation follows iSMC and OSHI. Core-channel codes are not assumed to identify unique physical cores.",
        "sources": ["https://github.com/dkorunic/iSMC/blob/master/smc/sensors.go", "https://github.com/oshi/oshi/pull/3535"]]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
    exit(failed ? 1 : 0)
}
if CommandLine.arguments.contains("--power") {
    // Read-only IOReport energy counters (no root, no SMC access). One JSON line per second.
    let sampler = PowerSampler()
    guard sampler.isAvailable else {
        FileHandle.standardError.write(Data("IOReport power sampling is unavailable on this system\n".utf8))
        exit(1)
    }
    _ = sampler.sample() // baseline
    var failed = false
    for _ in 0..<5 {
        Thread.sleep(forTimeInterval: 1)
        guard let reading = sampler.sample() else { failed = true; continue }
        let fields: [String: Any] = [
            "cpuWatts": reading.cpuWatts as Any? ?? NSNull(), "gpuWatts": reading.gpuWatts as Any? ?? NSNull(),
            "aneWatts": reading.aneWatts as Any? ?? NSNull(), "dramWatts": reading.dramWatts as Any? ?? NSNull(),
            "totalWatts": reading.totalWatts as Any? ?? NSNull(), "interval": reading.interval
        ]
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    }
    exit(failed ? 1 : 0)
}
let snapshot = smc.snapshot()
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
if let data = try? encoder.encode(snapshot), let text = String(data: data, encoding: .utf8) { print(text) }
exit(snapshot.error == nil ? 0 : 1)
