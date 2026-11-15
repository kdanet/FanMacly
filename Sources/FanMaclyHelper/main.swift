import Foundation
import FanMaclyCore

final class HelperService: NSObject, FanHelperProtocol, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "app.fanmacly.helper.hardware")
    let engine: ControlEngine
    var timer: DispatchSourceTimer?
    var connection: NSXPCConnection?
    var connectionID: UUID?
    var terminating = false
    let diagnostics: () -> String
    private var lastTrace = ""
    private var lastTraceTime: TimeInterval = 0
    private var responseSequence: UInt64 = 0

    init(hardware: FanHardware, diagnostics: @escaping () -> String) {
        engine = ControlEngine(hardware: hardware)
        self.diagnostics = diagnostics
        super.init()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(300), leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.engine.tick(now: ProcessInfo.processInfo.systemUptime)
            self.logState()
            if self.terminating && self.engine.status.restoring != true { exit(0) }
        }
        timer.resume()
        self.timer = timer
    }

    private func logState(force: Bool = false) {
        let status = engine.status
        let state = "mode=\(status.mode.rawValue) preparing=\(status.preparing == true) restoring=\(status.restoring == true) stage=\(status.preparationStage?.rawValue ?? "none") targets=\(status.targets) message=\(status.message ?? "none") thermal=\(status.thermalEvent?.detail ?? "none")"
        let now = ProcessInfo.processInfo.systemUptime
        if force || state != lastTrace || ((status.preparing == true || status.restoring == true) && now - lastTraceTime >= 1) {
            NSLog("FanMacly control: %@ | %@", state, diagnostics())
            lastTrace = state
            lastTraceTime = now
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection candidate: NSXPCConnection) -> Bool {
        guard let requirement = HelperIdentity.requirement(identifier: HelperIdentity.app) else { return false }
        let id = UUID()
        let accepted = queue.sync { () -> Bool in
            guard connection == nil, !terminating else { return false }
            connection = candidate
            connectionID = id
            return true
        }
        guard accepted else { return false }
        candidate.setCodeSigningRequirement(requirement)
        candidate.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        candidate.exportedObject = self
        candidate.invalidationHandler = { [weak self] in self?.lostConnection(id) }
        candidate.interruptionHandler = { [weak self, weak candidate] in candidate?.invalidate(); self?.lostConnection(id) }
        candidate.resume()
        return true
    }

    func lostConnection(_ id: UUID) {
        queue.async {
            guard self.connectionID == id else { return }
            let active = self.engine.status.mode != .system || self.engine.status.preparing == true || self.engine.status.restoring == true
            try? self.engine.restore(reason: active ? "Приложение отключено. Управление возвращено macOS." : nil)
            self.connection = nil
            self.connectionID = nil
        }
    }

    func heartbeat(reply: @escaping (Data) -> Void) {
        queue.async {
            let status = self.engine.heartbeat(now: ProcessInfo.processInfo.systemUptime)
            reply((try? self.encodeStatus(status)) ?? Data())
        }
    }
    private func encodeStatus(_ status: HelperStatus) throws -> Data {
        var status = status
        responseSequence &+= 1
        status.sequence = responseSequence
        return try JSONEncoder().encode(status)
    }
    func apply(_ data: Data, reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                guard !self.terminating else { throw FanMaclyError.message("Помощник завершает работу. Управление возвращается macOS.") }
                guard data.count < 16384 else { throw FanMaclyError.message("Слишком большой запрос.") }
                let request = try JSONDecoder().decode(ControlRequest.self, from: data)
                NSLog("FanMacly request: mode=%@ targets=%@", request.mode.rawValue, String(describing: request.targets))
                let result = try self.engine.apply(request, now: ProcessInfo.processInfo.systemUptime)
                self.logState(force: true)
                reply(try self.encodeStatus(result), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }
    func restore(reply: @escaping (String?) -> Void) {
        queue.async {
            do { try self.engine.restore(reason: nil); reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }
}

guard getuid() == 0, HelperIdentity.team != nil else {
    fputs("FanMaclyHelper must be signed and started as a system daemon by macOS.\n", stderr)
    exit(1)
}
let hardware: JournaledHardware
let smc = SMCClient()
do {
    try smc.open()
    hardware = try JournaledHardware(hardware: smc, journalURL: URL(fileURLWithPath: "/var/db/app.fanmacly/controlled-fans.json"))
    try hardware.recover()
} catch {
    NSLog("FanMacly could not recover fan ownership: %@", error.localizedDescription)
    exit(1)
}
let service = HelperService(hardware: hardware, diagnostics: { smc.fanDiagnostics() })
let listener = NSXPCListener(machServiceName: HelperIdentity.helper)
if let requirement = HelperIdentity.requirement(identifier: HelperIdentity.app) {
    listener.setConnectionCodeSigningRequirement(requirement)
}
listener.delegate = service
service.start()
let signalSources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: service.queue)
    source.setEventHandler {
        service.terminating = true
        do {
            try service.engine.restore(reason: nil)
            if service.engine.status.restoring != true { exit(0) }
        }
        catch { NSLog("FanMacly restore failed: %@", error.localizedDescription) }
        // Stay alive to retry the reset instead of abandoning a failed restore.
    }
    source.resume()
    return source
}
listener.resume()
RunLoop.main.run()
