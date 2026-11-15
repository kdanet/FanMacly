import Foundation

public struct SavedCoolingProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var curve: CoolingCurve
    public init(id: UUID = UUID(), name: String, curve: CoolingCurve) {
        self.id = id; self.name = name; self.curve = curve
    }
}

/// Value semantics let callers validate and encode the whole library before
/// replacing their previous stored data. Built-in profiles stay immutable.
public struct ProfileLibrary: Codable, Equatable, Sendable {
    public private(set) var version = 1
    public private(set) var profiles: [SavedCoolingProfile] = []
    public init() {}
    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard version == 1, Set(profiles.map(\.id)).count == profiles.count,
              profiles.allSatisfy({ $0.curve.isValid && Self.validName($0.name) }),
              Set(profiles.map { Self.nameKey($0.name) }).count == profiles.count else {
            throw FanMaclyError.message("Библиотека профилей повреждена или имеет неподдерживаемую версию.")
        }
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public mutating func save(name: String, curve: CoolingCurve, replacing id: UUID? = nil) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name) else { throw FanMaclyError.message("Название профиля должно содержать от 1 до 40 символов.") }
        guard curve.isValid else { throw FanMaclyError.message("Некорректная температурная кривая.") }
        guard !profiles.contains(where: { $0.id != id && Self.nameKey($0.name) == Self.nameKey(name) }) else {
            throw FanMaclyError.message("Профиль с таким названием уже существует.")
        }
        if let id {
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw FanMaclyError.message("Профиль больше не существует.") }
            profiles[index].name = name; profiles[index].curve = curve
            return id
        }
        let profile = SavedCoolingProfile(name: name, curve: curve)
        profiles.append(profile)
        return profile.id
    }
    public mutating func remove(_ id: UUID) { profiles.removeAll { $0.id == id } }
    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
            name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
    private static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
