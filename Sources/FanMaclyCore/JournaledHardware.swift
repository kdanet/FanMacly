import Foundation

/// Records ownership before writing to SMC so a relaunched daemon can recover
/// after a crash. The production journal lives in a root-owned directory.
public final class JournaledHardware: FanHardware {
    private let hardware: FanHardware
    private let url: URL
    private var owned: Set<Int>
    public init(hardware: FanHardware, journalURL: URL) throws {
        self.hardware = hardware
        self.url = journalURL
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let decoded = try JSONDecoder().decode([Int].self, from: Data(contentsOf: journalURL))
            guard decoded.allSatisfy({ (0..<10).contains($0) }) else { throw FanMaclyError.message("Журнал восстановления повреждён.") }
            owned = Set(decoded)
        } else { owned = [] }
    }
    public func recover() throws {
        // One failed fan must not prevent independent fans from returning to
        // macOS. Failed entries stay journaled for the next recovery attempt.
        var failure: Error?
        for fan in owned.sorted() {
            do { try setManual(false, fan: fan) }
            catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }
    public func snapshot() -> HardwareSnapshot { hardware.snapshot() }
    public func setTarget(_ rpm: Double, fan: Int) throws { try hardware.setTarget(rpm, fan: fan) }
    public func setManual(_ manual: Bool, fan: Int) throws {
        if manual {
            let next = owned.union([fan])
            try persist(next)
            owned = next
            try hardware.setManual(true, fan: fan)
        } else {
            try hardware.setManual(false, fan: fan)
            let next = owned.subtracting([fan])
            try persist(next)
            owned = next
        }
    }
    private func persist(_ fans: Set<Int>) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(fans.sorted()).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
