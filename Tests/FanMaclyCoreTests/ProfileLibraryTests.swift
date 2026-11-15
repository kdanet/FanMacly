import XCTest
@testable import FanMaclyCore

final class ProfileLibraryTests: XCTestCase {
    func testIndependentProfilesSurviveSerializationAndUpdatesKeepIdentity() throws {
        var library = ProfileLibrary()
        let first = try library.save(name: "Работа", curve: .balanced)
        let second = try library.save(name: "Рендер", curve: .cool)
        let restored = try ProfileLibrary(data: library.encoded())
        XCTAssertEqual(restored.profiles.map(\.id), [first, second])
        XCTAssertEqual(restored.profiles.map(\.curve), [.balanced, .cool])
        XCTAssertEqual(try library.save(name: "Работа тихо", curve: .cool, replacing: first), first)
        XCTAssertEqual(library.profiles[1].name, "Рендер")
        library.remove(first)
        XCTAssertEqual(library.profiles.map(\.id), [second])
    }
    func testInvalidAndDuplicateNamesNeverOverwriteExistingProfiles() throws {
        var library = ProfileLibrary()
        _ = try library.save(name: "Работа", curve: .balanced)
        let original = library
        for name in ["", "  ", "РАБОТА", "\nРабота", String(repeating: "a", count: 41), "Новая\nкривая"] {
            XCTAssertThrowsError(try library.save(name: name, curve: .cool))
            XCTAssertEqual(library, original)
        }
        XCTAssertThrowsError(try library.save(name: "Новая", curve: .init(points: [])))
        XCTAssertEqual(library, original)
    }
    func testCorruptAndFutureStorageAreRejected() throws {
        XCTAssertThrowsError(try ProfileLibrary(data: Data("{\"version\":2,\"profiles\":[]}".utf8)))
        let id = UUID()
        let records = [SavedCoolingProfile(id: id, name: "A", curve: .balanced), SavedCoolingProfile(id: id, name: "B", curve: .cool)]
        let value: [String: Any] = ["version": 1, "profiles": try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))]
        XCTAssertThrowsError(try ProfileLibrary(data: JSONSerialization.data(withJSONObject: value)))
    }
}
