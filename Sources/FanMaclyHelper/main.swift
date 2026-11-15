import Foundation
import OSLog
import FanMaclyCore

let log = Logger(subsystem: "app.fanmacly.helper", category: "control")

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

    init(hardware: FanHardware, store: ControlIntentStore, diagnostics: @escaping () -> String) {
        engine = ControlEngine(hardware: hardware, store: store)
        self.diagnostics = diagnostics
        super.init()
        engine.onEvent = { event in
            log.notice("event \(event.kind.rawValue, privacy: .public): \(event.title, privacy: .public) \(event.detail ?? "", privacy: .public) | \(diagnostics(), privacy: .public)")
        }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(300), leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.engine.tick(now: ProcessInfo.processInfo.systemUptime)
            self.logState()
            if self.terminating && self.engine.isShutDown { exit(0) }
        }
        timer.resume()
        self.timer = timer
    }

    private func logState(force: Bool = false) {
        let status = engine.status
        let state = "mode=\(status.mode.rawValue) intent=\(status.intent?.displayName ?? "macOS") preparing=\(status.preparing == true) restoring=\(status.restoring == true) reacquiring=\(status.reacquiring) stage=\(status.preparationStage?.rawValue ?? "none") boost=\(status.coolingBoost) targets=\(status.targets) suspension=\(status.suspension?.kind.rawValue ?? "none") message=\(status.message ?? "none")"
        let now = ProcessInfo.processInfo.systemUptime
        if force || state != lastTrace || ((status.preparing == true || status.restoring == true) && now - lastTraceTime >= 1) {
            log.info("state \(state, privacy: .public) | \(self.diagnostics(), privacy: .public)")
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
            // The helper owns the persisted intent and its own safety checks,
            // so an app that quits, crashes or sleeps does not cancel control.
            log.info("app connection closed; intent kept")
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
                log.notice("request mode=\(request.mode.rawValue, privacy: .public) profile=\(request.displayName, privacy: .public) targets=\(String(describing: request.targets), privacy: .public) boost=\(request.boost != nil)")
                let result = try self.engine.apply(request, now: ProcessInfo.processInfo.systemUptime)
                self.logState(force: true)
                reply(try self.encodeStatus(result), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }
    func restore(reply: @escaping (String?) -> Void) {
        queue.async {
            do { _ = try self.engine.apply(.init(mode: .system), now: ProcessInfo.processInfo.systemUptime); reply(nil) }
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
// The helper being replaced may have just cleared Ftst.
smc.deferHandoff()
do {
    try smc.open()
    hardware = try JournaledHardware(hardware: smc, journalURL: URL(fileURLWithPath: "/var/db/app.fanmacly/controlled-fans.json"))
} catch {
    // Without AppleSMC there is nothing to control or recover.
    log.fault("could not open SMC: \(error.localizedDescription, privacy: .public)")
    exit(1)
}
// A stopped fan is restarted before it can return to automatic mode, so
// recovery may need a few seconds of retries. If it still fails, start anyway:
// exiting would make launchd relaunch the helper forever while the fans stay
// manual and unwatched. The control loop keeps retrying with a safe fallback.
let recoveryDeadline = ProcessInfo.processInfo.systemUptime + 15
while true {
    do { try hardware.recover(); break }
    catch is FanControlPreparing where ProcessInfo.processInfo.systemUptime < recoveryDeadline {
        Thread.sleep(forTimeInterval: 0.3)
    } catch {
        log.fault("could not recover fan ownership: \(error.localizedDescription, privacy: .public)")
        break
    }
}
let service = HelperService(hardware: hardware,
                            store: FileIntentStore(url: URL(fileURLWithPath: "/var/db/app.fanmacly/intent.json")),
                            diagnostics: { smc.fanDiagnostics() })
service.engine.adoptUnrecovered(hardware.unrecovered)
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
            try service.engine.shutdown()
            if service.engine.isShutDown { exit(0) }
        }
        catch { log.error("restore failed: \(error.localizedDescription, privacy: .public)") }
        // Stay alive to retry the reset instead of abandoning a failed restore.
    }
    source.resume()
    return source
}
listener.resume()
RunLoop.main.run()
