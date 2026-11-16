import AppKit
import SwiftUI
import FanMaclyCore
import Observation
import WidgetKit

/// One status item and a transient popover sized to the current content.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var fanIcon: RotatingFanView?
    private lazy var windows = WindowCoordinator(model: model)
    private var debugWindow: NSWindow?
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
        let panel = PanelView(model: model, openWindow: { [weak self] kind in
            self?.popover.performClose(nil)
            self?.windows.show(kind)
        }, quit: { NSApp.terminate(nil) })
        let host = NSHostingController(rootView: panel)
        host.sizingOptions = [.preferredContentSize]
        if let style = CommandLine.arguments.first(where: { $0.hasPrefix("--preview-appearance=") }) {
            let appearance = NSAppearance(named: style.hasSuffix("light") ? .aqua : .darkAqua)
            popover.appearance = appearance
            NSApp.appearance = appearance
        }
        FanModeControlRouter.handler = { [weak model] action in
            guard let model else { throw FanMaclyError.message("FanMacly завершает работу.") }
            try await model.performControlCenterAction(action)
        }
        FanMaclyIntentRouter.model = model
        if #available(macOS 26.0, *) { ControlCenter.shared.reloadAllControls() }
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        observeStatusItem()
        if CommandLine.arguments.contains("--panel-window") {
            // Debug/screenshot aid: the same panel content in a regular window.
            let window = NSWindow(contentViewController: NSHostingController(rootView: PanelView(model: model, openWindow: { [weak self] in self?.windows.show($0) }, quit: { NSApp.terminate(nil) })))
            window.title = "FanMacly"
            window.isReleasedWhenClosed = false
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
            debugWindow = window
        }
        // Debug/screenshot aid; may be repeated to open several windows.
        for window in CommandLine.arguments.filter({ $0.hasPrefix("--open-window=") }).compactMap({ AppWindow(rawValue: String($0.dropFirst("--open-window=".count))) }) {
            DispatchQueue.main.async { [weak self] in self?.windows.show(window) }
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
        if UserDefaults.standard.string(forKey: "lastPresentedVersion") != version || CommandLine.arguments.contains("--show-panel") {
            UserDefaults.standard.set(version, forKey: "lastPresentedVersion")
            DispatchQueue.main.async { [weak self] in self?.showPopover() }
        }
    }
    private func updateStatusItem(_ snapshot: HardwareSnapshot?) {
        let prefs = model.menuBarSettings
        fanIcon?.setSpeed(FanIndicator.revolutionsPerSecond(for: snapshot,
            animated: prefs.animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, multiplier: prefs.speed.multiplier))
        fanIcon?.tint = prefs.highlightsLostControl ? AppDelegate.statusTint(model.controlState, selection: model.displayedSelection) : nil
        if let button = statusItem.button {
            let title: String
            switch prefs.display {
            case .icon: title = ""
            case .temperature: title = temperature(model.cpuTemperature)
            case .rpm: title = model.averageRPM.map { rpmNumber($0) } ?? "—"
            }
            if button.title != title { button.title = title }
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            let font = button.font ?? .menuBarFont(ofSize: 0)
            let width = { (text: String) in ceil((text as NSString).size(withAttributes: [.font: font]).width) }
            // Reserve the widest value so the item (and the icons to its left)
            // does not jump as the reading changes, e.g. 0 ↔ 1 250 rpm.
            let reserved = prefs.display == .rpm ? width(rpmNumber(8888)) : width("100°")
            // Icon-only mode needs 17 pt for the full rotating glyph. AppKit adds its outer margins.
            let length = title.isEmpty ? 17 : 14 + 2 + max(reserved, width(title))
            if statusItem.length != length { statusItem.length = length }
            layoutStatusIcon()
        }
        let readings = snapshot.map { snapshot in
            snapshot.fans.map { "\(snapshot.fanNames.title($0.id)): \(rpm($0.current))" }.joined(separator: "\n")
        } ?? "Нет текущих данных"
        let mode = model.title(for: model.displayedSelection)
        statusItem?.button?.toolTip = "FanMacly · \(mode)\nCPU: \(temperature(model.cpuTemperature))\n\(readings)"
        statusItem?.button?.setAccessibilityValue("Режим \(mode). CPU \(temperature(model.cpuTemperature)). \(readings)")
    }
    /// Orange while the chosen mode is not in effect; plain otherwise, including a deliberate «Авто».
    static func statusTint(_ state: ControlState, selection: ModeSelection) -> NSColor? {
        switch state {
        case .suspended, .reacquiring: return .systemOrange
        case .macOS, .setupNeeded: return selection == .automatic ? nil : .systemOrange
        // A short startup state; tinting it would flash on every launch.
        case .active, .applying, .connecting: return nil
        }
    }
    private func layoutStatusIcon() {
        guard let button = statusItem?.button, let image = button.cell?.imageRect(forBounds: button.bounds),
              image.width > 0, image.height > 0 else { return }
        fanIcon?.frame = NSRect(x: image.midX - 10, y: image.midY - 10, width: 20, height: 20)
    }
    private func observeStatusItem() {
        withObservationTracking {
            updateStatusItem(model.sleeping ? nil : model.snapshot)
            _ = model.controlState; _ = model.menuBarSettings
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
        // SwiftUI can still pick an initial key view a runloop later.
        DispatchQueue.main.async { [weak self] in self?.popover.contentViewController?.view.window?.makeFirstResponder(nil) }
        model.panelVisible = true
        model.helper.refresh()
        // Install outside-click handlers immediately rather than on didShow.
        installDismissMonitors()
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
    func popoverDidShow(_ notification: Notification) { installDismissMonitors() }
    func popoverWillClose(_ notification: Notification) { removeDismissMonitors() }
    func popoverDidClose(_ notification: Notification) {
        removeDismissMonitors()
        model.panelVisible = false
    }
    private func installDismissMonitors() {
        guard outsideMouseMonitor == nil, localMouseMonitor == nil else { return }
        outsideMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
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
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let statusFrameObserver { NotificationCenter.default.removeObserver(statusFrameObserver) }
        removeDismissMonitors()
        Task { @MainActor in
            await model.prepareForQuit()
            model.helper.disconnect()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
