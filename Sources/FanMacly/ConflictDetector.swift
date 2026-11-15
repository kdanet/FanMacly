import Darwin
import Foundation

/// Other fan-control software writes the same SMC registers. Two writers make
/// the fan mode flip back and forth, which looks like FanMacly "losing" control.
struct FanControlConflict: Identifiable, Equatable, Sendable {
    let name: String
    let process: String
    let detail: String
    var id: String { process }
}

enum ConflictDetector {
    private static let known: [(match: String, name: String, detail: String)] = [
        ("macsfancontrol", "Macs Fan Control", "Служба Macs Fan Control (smcwrite) может переключать вентиляторы в автоматический режим. Закройте Macs Fan Control или удалите его помощник."),
        ("Macs Fan Control", "Macs Fan Control", "Приложение Macs Fan Control управляет теми же вентиляторами."),
        ("TG Pro", "TG Pro", "TG Pro управляет теми же вентиляторами."),
        ("tgpro", "TG Pro", "Служба TG Pro может менять режим вентиляторов."),
        ("smcFanControl", "smcFanControl", "smcFanControl управляет теми же вентиляторами.")
    ]

    /// Runs off the main thread: enumerates processes with libproc.
    static func scan() -> [FanControlConflict] {
        let ownPID = getpid()
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        count = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) }
        guard count > 0 else { return [] }
        var found: [String: FanControlConflict] = [:]
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != ownPID {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(cString: buffer)
            guard !path.contains("FanMacly") else { continue }
            let process = (path as NSString).lastPathComponent
            for entry in known where path.localizedCaseInsensitiveContains(entry.match) {
                if found[entry.name] == nil {
                    found[entry.name] = .init(name: entry.name, process: process, detail: entry.detail)
                }
                break
            }
        }
        return found.values.sorted { $0.name < $1.name }
    }
}
