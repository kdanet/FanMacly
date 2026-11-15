import AppKit
import FanMaclyCore
import Observation
import WidgetKit

/// One status item and a transient popover sized to the current content.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var fanIcon: RotatingFanView?
    private var diagnostics: FrameDiagnostics?
    private var statusFrameObserver: NSObjectProtocol?
    private var outsideMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var dismissObservers = [NSObjectProtocol]()
    private var workspaceDismissObserver: NSObjectProtocol?
    private var menuTracking = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "FanMacly"
        if let button = statusItem.button {
            button.title = ""
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            // Let AppKit measure and position the actual image/title pair.
            // The blank image reserves the native image rect for the CA rotor.
            let placeholder = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in true }
            placeholder.isTemplate = true
            button.image = placeholder
            button.imageHugsTitle = true
            let icon = RotatingFanView(frame: button.bounds)
            button.addSubview(icon)
            fanIcon = icon
            button.postsFrameChangedNotifications = true
            statusFrameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                object: button, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutStatusIcon() }
            }
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("FanMacly — управление вентиляторами")
            button.setAccessibilityIdentifier("FanMaclyStatusItem")
        }
        let host = NativePanelController(model: model)
        if let style = CommandLine.arguments.first(where: { $0.hasPrefix("--preview-appearance=") }) {
            let appearance = NSAppearance(named: style.hasSuffix("light") ? .aqua : .darkAqua)
            host.view.appearance = appearance
            popover.appearance = appearance
        }
        _ = host.view
        FanModeControlRouter.handler = { [weak model] action in
            guard let model else { throw FanMaclyError.message("FanMacly завершает работу.") }
            try await model.performControlCenterAction(action)
        }
        if #available(macOS 26.0, *) { ControlCenter.shared.reloadAllControls() }
        popover.contentViewController = host
        popover.contentSize = host.preferredContentSize
        host.onPreferredSizeChange = { [weak self, weak host] size in
            guard let self, let host else { return }
            // Keep view geometry and window geometry in the same display
            // transaction. An independently animated NSPopover resize clips
            // the newly selected page against an intermediate window frame.
            let animates = self.popover.animates
            self.popover.animates = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                host.preferredContentSize = size
                self.popover.contentSize = size
                host.view.layoutSubtreeIfNeeded()
            }
            self.popover.animates = animates
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        observeStatusItem()
        if let path = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-diagnostics=") }) {
            diagnostics = FrameDiagnostics(view: host.view, fan: fanIcon, path: String(path.dropFirst("--ui-diagnostics=".count)))
            traceUI("diagnostics ready")
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.5.0"
        if UserDefaults.standard.string(forKey: "lastPresentedVersion") != version || diagnostics != nil || CommandLine.arguments.contains("--show-panel") {
            UserDefaults.standard.set(version, forKey: "lastPresentedVersion")
            DispatchQueue.main.async { [weak self] in self?.showPopover() }
        }
    }
    private func updateStatusItem(_ snapshot: HardwareSnapshot?) {
        let prefs = model.menuBarSettings
        fanIcon?.setSpeed(FanIndicator.revolutionsPerSecond(for: snapshot,
            animated: prefs.animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, multiplier: prefs.speed.multiplier))
        if let button = statusItem.button {
            let title = prefs.showsTemperature ? temperature(model.cpuTemperature) : ""
            if button.title != title { button.title = title }
            button.imagePosition = prefs.showsTemperature ? .imageLeading : .imageOnly
            let textWidth = ceil((title as NSString).size(withAttributes: [.font: button.font!]).width)
            // NSStatusBar adds its own outer margins; don't reserve them twice.
            // Icon-only mode needs 17 pt for the full rotating glyph, rather
            // than the bar-height square (22 pt). AppKit adds its outer margins.
            let length = prefs.showsTemperature ? 14 + 2 + max(22, textWidth) : 17
            if statusItem.length != length { statusItem.length = length }
            layoutStatusIcon()
            traceUI("status length=\(statusItem.length) button=\(button.frame) inWindow=\(button.convert(button.bounds, to: nil)) window=\(String(describing: button.window?.frame)) image=\(String(describing: button.cell?.imageRect(forBounds: button.bounds))) title=\(String(describing: button.cell?.titleRect(forBounds: button.bounds)))")
        }
        let readings = snapshot?.fans.map { "\($0.name): \(rpm($0.current))" }.joined(separator: "\n") ?? "Нет текущих данных"
        statusItem?.button?.toolTip = "FanMacly\nCPU: \(temperature(model.cpuTemperature)) (\(model.cpuSource ?? "нет данных")), сглаженное значение\n\(readings)\nНажмите для управления вентиляторами"
        statusItem?.button?.setAccessibilityValue("CPU \(temperature(model.cpuTemperature)). \(readings)")
    }
    private func layoutStatusIcon() {
        guard let button = statusItem?.button, let image = button.cell?.imageRect(forBounds: button.bounds),
              image.width > 0, image.height > 0 else { return }
        fanIcon?.frame = NSRect(x: image.midX - 10, y: image.midY - 10, width: 20, height: 20)
    }
    private func observeStatusItem() {
        withObservationTracking {
            updateStatusItem(model.sleeping ? nil : model.snapshot)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatusItem() }
        }
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard !popover.isShown, let button = statusItem?.button else { return }
        statusItem.isVisible = true
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.title = "FanMacly"
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
        // A content resize can interrupt the initial show animation, so don't
        // wait for didShow to install the outside-click handlers.
        diagnostics?.start()
        installDismissMonitors()
        traceUI("show returned, isShown=\(popover.isShown)")
    }
    private func installMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Завершить FanMacly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(); editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
    func popoverDidShow(_ notification: Notification) {
        traceUI("popover didShow")
        diagnostics?.start(); installDismissMonitors()
    }
    func popoverWillClose(_ notification: Notification) {
        traceUI("popover willClose")
        diagnostics?.stop(); removeDismissMonitors()
    }
    func popoverDidClose(_ notification: Notification) {
        traceUI("popover didClose")
        diagnostics?.stop(); removeDismissMonitors()
    }
    private func installDismissMonitors() {
        guard outsideMouseMonitor == nil, localMouseMonitor == nil else { return }
        outsideMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.traceUI("external mouse, dismissing")
                self?.popover.performClose(nil)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown, NSApp.modalWindow == nil, self.menuTracking == 0 else { return }
                var window = event.window
                while let current = window {
                    if current == self.popover.contentViewController?.view.window { return }
                    window = current.parent
                }
                if let button = self.statusItem.button, event.window == button.window {
                    let point = button.convert(event.locationInWindow, from: nil)
                    if button.bounds.contains(point) { return }
                }
                self.popover.performClose(nil)
            }
            return event
        }
        traceUI("dismissal monitors global=\(outsideMouseMonitor != nil) local=\(localMouseMonitor != nil)")
        let center = NotificationCenter.default
        dismissObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking += 1 }
        })
        dismissObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.menuTracking = max(0, self.menuTracking - 1) } }
        })
        dismissObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if NSApp.modalWindow == nil { self?.popover.performClose(nil) } }
        })
        workspaceDismissObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard NSApp.modalWindow == nil,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.traceUI("another app activated, dismissing")
                self?.popover.performClose(nil)
            }
        }
    }
    private func removeDismissMonitors() {
        if let outsideMouseMonitor { NSEvent.removeMonitor(outsideMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        outsideMouseMonitor = nil; localMouseMonitor = nil
        for observer in dismissObservers { NotificationCenter.default.removeObserver(observer) }
        if let workspaceDismissObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceDismissObserver) }
        workspaceDismissObserver = nil
        dismissObservers = []; menuTracking = 0
    }
    private func traceUI(_ message: String) {
        guard diagnostics != nil else { return }
        FileHandle.standardError.write(Data("FanMacly UI: \(message)\n".utf8))
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        diagnostics?.stop()
        if let statusFrameObserver { NotificationCenter.default.removeObserver(statusFrameObserver) }
        removeDismissMonitors()
        model.helper.disconnect()
        return .terminateNow
    }
}

func temperature(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))°" } ?? "—" }
func rpm(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) об/мин" } ?? "—" }
