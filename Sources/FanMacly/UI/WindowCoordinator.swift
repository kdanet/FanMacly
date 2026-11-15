import AppKit
import SwiftUI

enum AppWindow: String { case profiles, monitor, settings }

/// Regular windows for the profile editor, monitor and settings. The app is an
/// accessory (no Dock icon), so it activates itself when a window opens.
@MainActor final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var windows: [AppWindow: NSWindow] = [:]
    init(model: AppModel) { self.model = model }

    func show(_ kind: AppWindow) {
        if let window = windows[kind] {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let (title, view): (String, AnyView) = {
            switch kind {
            case .profiles: return ("Профили охлаждения", AnyView(ProfileEditorView(model: model)))
            case .monitor: return ("Монитор FanMacly", AnyView(MonitorView(model: model)))
            case .settings: return ("Настройки FanMacly", AnyView(SettingsView(model: model)))
            }
        }()
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = kind == .settings ? [.titled, .closable, .miniaturizable] : [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame FanMacly.\(kind.rawValue)") != nil
        window.setFrameAutosaveName("FanMacly.\(kind.rawValue)")
        if kind == .profiles {
            // A frame saved by an older version can be smaller than the
            // editor needs; SwiftUI would then clip it top and bottom.
            let minimum = ProfileEditorView.minimumSize
            window.contentMinSize = minimum
            let size = window.contentRect(forFrameRect: window.frame).size
            if !hasSavedFrame || size.width < minimum.width || size.height < minimum.height {
                // Everything fits without scrolling at 760 pt where the screen allows.
                let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
                let height = max(minimum.height, min(760, available - 60))
                window.setContentSize(CGSize(width: max(size.width, minimum.width), height: max(size.height, height)))
            }
        }
        if window.frame.width < 200 { window.center() }
        windows[kind] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Don't start with a focus ring on the first control (tabs, pickers).
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}
