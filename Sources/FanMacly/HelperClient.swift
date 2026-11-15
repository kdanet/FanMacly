import Foundation
import Observation
import ServiceManagement
import FanMaclyCore

@MainActor @Observable final class HelperClient {
    var status = HelperStatus()
    var connected = false
    var busy = false
    var error: String?
    var serviceStatus = SMAppService.Status.notRegistered
    @ObservationIgnored var onDisconnect: (() -> Void)?
    @ObservationIgnored var onAutomaticFallback: (() -> Void)?
    @ObservationIgnored var onStatusReceived: (() -> Void)?
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var lastFallbackID: UUID?
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var lastReply = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var pendingID: UUID?
    @ObservationIgnored private var connectionID: UUID?
    @ObservationIgnored private var requirement: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var serviceTask: Task<Void, Never>?
    @ObservationIgnored private var unregistering = false
    @ObservationIgnored private var epoch = UUID()

    func refresh() {
        guard serviceTask == nil, !unregistering else { return }
        // An established authenticated connection doesn't need a synchronous
        // ServiceManagement/Security query before every heartbeat. Those calls
        // can stall while macOS is busy and must not hold the control lease.
        if connection != nil {
            if ProcessInfo.processInfo.systemUptime - lastReply > 6 {
                disconnect()
                error = "Помощник не отвечает. Ручное управление остановлено по тайм-ауту."
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
            guard state == .enabled else { self.disconnect(); return }
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
                error = "Для управления нужна сборка, подписанная Apple Development или Developer ID."
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
                self.error = "Нет связи с системным помощником: \(error.localizedDescription)"
            }
        } as? FanHelperProtocol
    }
    func apply(_ request: ControlRequest) {
        var request = request
        request.expectedFallbackID = status.automaticFallbackID
        guard connected, !busy, let remote = proxy(), let data = try? JSONEncoder().encode(request) else { return }
        let id = UUID()
        pendingID = id
        busy = true
        error = nil
        trace("request", data: data)
        remote.apply(data) { [weak self] data, error in
            Task { @MainActor in
                guard let self, self.pendingID == id else { return }
                self.pendingID = nil
                self.busy = false
                if let error { self.error = error }
                if let data { self.receive(data) }
                else if error == nil {
                    self.error = "Помощник не прислал подтверждение. Управление возвращается macOS."
                    self.disconnect()
                }
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.pendingID == id else { return }
            self.error = "Помощник не подтвердил изменение. Соединение закрыто для возврата к автоматике."
            self.disconnect()
        }
    }
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
        guard let value = try? JSONDecoder().decode(HelperStatus.self, from: data) else {
            error = "Некорректный ответ помощника. Управление возвращается macOS."
            disconnect()
            return
        }
        guard value.version == HelperIdentity.protocolVersion else {
            error = "Нужен обновлённый системный помощник FanMacly."
            disconnect()
            return
        }
        guard let sequence = value.sequence else {
            error = "Помощник не подтвердил порядок состояния. Управление возвращается macOS."
            disconnect()
            return
        }
        guard lastSequence.map({ sequence > $0 }) ?? true else { return }
        lastSequence = sequence
        lastReply = ProcessInfo.processInfo.systemUptime
        status = value
        connected = true
        trace("status", data: data)
        if let id = value.automaticFallbackID, lastFallbackID != id {
            lastFallbackID = id
            onAutomaticFallback?()
        }
        onStatusReceived?()
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
        busy = false
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
