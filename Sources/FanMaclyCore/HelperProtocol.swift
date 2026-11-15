import Foundation
import Security

public enum HelperIdentity {
    /// Versions the app–helper contract (XPC messages, status format, launchd
    /// plist), independent of the app version. A mismatch makes the app
    /// replace the installed helper with the bundled one.
    public static let protocolVersion = "1.0.6"
    public static let app = "app.fanmacly"
    public static let helper = "app.fanmacly.helper"
    public static let plist = "app.fanmacly.helper.plist"

    public static let team: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return team
    }()
    public static func requirement(identifier: String) -> String? {
        guard let team else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

@objc public protocol FanHelperProtocol {
    func heartbeat(reply: @escaping (Data) -> Void)
    func apply(_ data: Data, reply: @escaping (Data?, String?) -> Void)
    func restore(reply: @escaping (String?) -> Void)
}
