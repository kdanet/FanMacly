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
            if let data = try? Data(contentsOf: journalURL),
               let decoded = try? JSONDecoder().decode([Int].self, from: data),
               decoded.allSatisfy({ (0..<10).contains($0) }) {
                owned = Set(decoded)
            } else {
                // An unreadable journal must not stop the helper from starting
                // (launchd would relaunch it forever and nothing would ever
                // return the fans). Keep a copy and recover every fan instead.
                let aside = journalURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: journalURL, to: aside)
                let snapshot = hardware.snapshot()
                owned = Set(0..<min(10, max(snapshot.fanCount ?? 0, snapshot.fans.count)))
            }
        } else { owned = [] }
    }
    /// Fans the last recovery could not return to macOS.
    public var unrecovered: Set<Int> { owned }
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
    public func forgetFan(_ fan: Int) { hardware.forgetFan(fan) }
    public func releaseHandoff() throws { try hardware.releaseHandoff() }
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
