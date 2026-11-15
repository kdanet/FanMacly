import Foundation
import Observation
import ServiceManagement
import FanMaclyCore

/// XPC client for the privileged helper. The helper owns the control loop and
/// the persisted intent, so losing this connection never changes fan control;
/// it only stops status updates until the client reconnects.
@MainActor @Observable final class HelperClient {
    var status = HelperStatus()
    var connected = false
    /// A request is in flight.
    var busy: Bool { pendingID != nil }
    var error: String?
    var serviceStatus = SMAppService.Status.notRegistered
    /// The helper answered with a different protocol version.
    var needsUpdate = false
    @ObservationIgnored var onStatusReceived: (() -> Void)?
    @ObservationIgnored var onDisconnect: (() -> Void)?
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var lastReply = ProcessInfo.processInfo.systemUptime
    private var pendingID: UUID?
    @ObservationIgnored private var connectionID: UUID?
    @ObservationIgnored private var requirement: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var serviceTask: Task<Void, Never>?
    @ObservationIgnored private var unregistering = false
    @ObservationIgnored private var autoUpdateAttempted = false
    /// Survives relaunches so an interrupted helper update is completed.
    @ObservationIgnored private var updatePending: Bool {
        get { UserDefaults.standard.bool(forKey: "helperUpdatePending") }
        set { UserDefaults.standard.set(newValue, forKey: "helperUpdatePending") }
    }
    @ObservationIgnored private var epoch = UUID()

    var signedForControl: Bool { HelperIdentity.team != nil }

    func refresh() {
        guard serviceTask == nil, !unregistering else { return }
        if connection != nil {
            if ProcessInfo.processInfo.systemUptime - lastReply > 8 {
                disconnect()
                error = "Системный компонент не отвечает. Переподключаемся…"
            } else { sendHeartbeat() }
            return
        }
        guard refreshTask == nil else { return }
        let generation = epoch
        refreshTask = Task { [weak self] in
            let (state, requirement) = await AppServices.shared.helperState()
            guard let self, self.epoch == generation, !Task.isCancelled else { return }
            defer { self.refreshTask = nil }
            self.serviceStatus = state
            self.requirement = requirement
            guard state == .enabled else {
                self.disconnect()
                // An update was interrupted between removing the old helper
                // and registering the new one (app quit, error): finish it.
                if self.updatePending, state == .notRegistered, !self.autoUpdateAttempted {
                    self.autoUpdateAttempted = true
                    self.register()
                }
                return
            }
            self.sendHeartbeat()
        }
    }

    private func sendHeartbeat() {
        guard let remote = proxy(), let connectionID else { return }
        remote.heartbeat { [weak self] data in
            Task { @MainActor in
                guard let self, self.connectionID == connectionID else { return }
                self.receive(data)
            }
        }
    }

    private func proxy() -> FanHelperProtocol? {
        if connection == nil {
            guard let requirement else {
                error = signedForControl ? nil : "Для управления нужна сборка с подписью Apple Development или Developer ID."
                return nil
            }
            let connection = NSXPCConnection(machServiceName: HelperIdentity.helper, options: .privileged)
            let id = UUID()
            connectionID = id
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in if self?.connectionID == id { self?.disconnect() } }
            }
            connection.interruptionHandler = { [weak self] in
                Task { @MainActor in if self?.connectionID == id { self?.disconnect() } }
            }
            connection.resume()
            self.connection = connection
            lastReply = ProcessInfo.processInfo.systemUptime
        }
        let id = connectionID
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                guard let self, self.connectionID == id else { return }
                self.disconnect()
                self.error = "Нет связи с системным компонентом: \(error.localizedDescription)"
            }
        } as? FanHelperProtocol
    }

    /// Latest request wins; the helper serialises them on its own queue.
    func apply(_ request: ControlRequest, completion: ((String?) -> Void)? = nil) {
        guard let remote = proxy(), let data = try? JSONEncoder().encode(request) else {
            completion?("Нет связи с системным компонентом.")
            return
        }
        let id = UUID()
        pendingID = id
        error = nil
        trace("request", data: data)
        // The reply and the timeout race; whichever comes first completes.
        var completed = false
        let finish: (String?) -> Void = { result in
            guard !completed else { return }
            completed = true
            completion?(result)
        }
        remote.apply(data) { [weak self] data, error in
            Task { @MainActor in
                guard let self else { return }
                // A late confirmation supersedes the timeout message.
                if self.pendingID != id, error == nil, self.error == Self.timeoutMessage { self.error = nil }
                if let data { self.receive(data) }
                if self.pendingID == id {
                    self.pendingID = nil
                    if let error { self.error = error }
                }
                finish(error)
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.pendingID == id else { return }
            self.pendingID = nil
            self.error = Self.timeoutMessage
            finish(Self.timeoutMessage)
        }
    }
    static let timeoutMessage = "Системный компонент не подтвердил изменение."

    func register() {
        guard serviceTask == nil else { return }
        serviceTask = Task { [weak self] in
            do {
                let status = try await AppServices.shared.registerHelper()
                guard let self else { return }
                self.serviceStatus = status
                self.serviceTask = nil
                if status == .requiresApproval { self.openApproval() }
                self.refresh()
            } catch {
                self?.error = error.localizedDescription
                self?.serviceTask = nil
            }
        }
    }

    func receive(_ data: Data) {
        // An older helper speaks a different status format or protocol.
        guard let value = try? JSONDecoder().decode(HelperStatus.self, from: data),
              value.version == HelperIdentity.protocolVersion else {
            helperOutdated()
            return
        }
        guard let sequence = value.sequence else { return }
        guard lastSequence.map({ sequence > $0 }) ?? true else { return }
        needsUpdate = false
        updatePending = false
        lastSequence = sequence
        lastReply = ProcessInfo.processInfo.systemUptime
        status = value
        connected = true
        if error?.hasPrefix("Системный компонент не отвечает") == true { error = nil }
        trace("status", data: data)
        onStatusReceived?()
    }

    /// The running helper is from an older FanMacly. Replace it with the
    /// bundled one automatically, once per launch; the banner remains as a
    /// manual fallback if that needs the user's approval or fails.
    private func helperOutdated() {
        needsUpdate = true
        error = "Нужно обновить системный компонент FanMacly."
        disconnect()
        guard !autoUpdateAttempted, serviceStatus == .enabled else { return }
        autoUpdateAttempted = true
        updatePending = true
        reinstall()
    }

    /// Re-register the bundled helper (after an app update).
    func reinstall() {
        Task { [weak self] in
            await self?.unregister()
            // launchd needs a moment to remove the old job; registering
            // immediately can fail and leave no helper at all.
            for attempt in 0..<4 {
                try? await Task.sleep(for: .seconds(attempt == 0 ? 1 : 2))
                guard let self else { return }
                self.register()
                while self.serviceTask != nil { try? await Task.sleep(for: .milliseconds(100)) }
                if self.serviceStatus == .enabled || self.serviceStatus == .requiresApproval { return }
            }
        }
    }

    func unregister() async {
        guard serviceTask == nil, !unregistering else { return }
        unregistering = true
        defer { unregistering = false }
        disconnect()
        do { serviceStatus = try await AppServices.shared.unregisterHelper() }
        catch { self.error = error.localizedDescription }
    }

    func openApproval() { SMAppService.openSystemSettingsLoginItems() }

    func disconnect() {
        epoch = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        pendingID = nil
        lastSequence = nil
        connectionID = nil
        connection?.invalidate()
        connection = nil
        connected = false
        onDisconnect?()
    }

    private func trace(_ event: String, data: Data) {
        guard CommandLine.arguments.contains("--control-diagnostics") else { return }
        let line = "FanMacly \(event): \(String(decoding: data, as: UTF8.self))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
