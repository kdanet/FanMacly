import ServiceManagement
import FanMaclyCore

/// ServiceManagement and Security can synchronously wait for other processes.
/// Keep those calls on this actor's executor, never the AppKit event loop.
actor AppServices {
    static let shared = AppServices()
    private let daemon = SMAppService.daemon(plistName: HelperIdentity.plist)

    func helperState() -> (SMAppService.Status, String?) {
        (daemon.status, HelperIdentity.requirement(identifier: HelperIdentity.helper))
    }
    func registerHelper() throws -> SMAppService.Status {
        guard HelperIdentity.team != nil else {
            throw FanMaclyError.message("Для управления нужна сборка с подписью Apple Development или Developer ID.")
        }
        try daemon.register()
        return daemon.status
    }
    func unregisterHelper() async throws -> SMAppService.Status {
        try await daemon.unregister()
        return daemon.status
    }
    func loginStatus() -> Bool { SMAppService.mainApp.status == .enabled }
    func setLogin(_ enabled: Bool) throws -> Bool {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
        return loginStatus()
    }
}
