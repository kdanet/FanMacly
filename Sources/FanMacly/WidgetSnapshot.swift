import Foundation

/// Shared between the app and the widget extension (compiled into both).
/// The app writes it into the App Group container; the widget only reads it.
struct WidgetSnapshot: Codable, Equatable {
    var date: Date
    var mode: String
    var symbol: String
    var state: String
    var active: Bool
    var warning: Bool
    var cpu: Double?
    var gpu: Double?
    var fans: [Double]

    static let fileName = "widget-snapshot.json"
    /// `FanMaclyAppGroup` is written into both Info.plists by the build script
    /// when the app is signed with a team identity.
    static var appGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FanMaclyAppGroup") as? String, !group.isEmpty else { return nil }
        return group
    }
    static var url: URL? {
        guard let appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(fileName)
    }
    static func load() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
    func save() {
        guard let url = Self.url else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}
