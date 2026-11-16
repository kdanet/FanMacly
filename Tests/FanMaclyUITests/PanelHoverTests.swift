import AppKit
import SwiftUI
import XCTest
@testable import FanMacly

/// The panel's content outlives the popover. A footer button that opens a
/// window closes the popover under the cursor, and SwiftUI never sends the
/// hover exit, so the hover has to be dropped when the popover closes.
final class PanelHoverTests: XCTestCase {
    @MainActor private final class Box { var hovering = false }

    @MainActor func testPopoverCloseClearsHover() throws {
        let box = Box()
        let binding = Binding(get: { box.hovering }, set: { box.hovering = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Color.clear.frame(width: 80, height: 40).panelHover(binding))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        box.hovering = true
        // Another app's popover or a window closing must not matter; only a popover close does.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(box.hovering)

        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: NSPopover())
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(box.hovering)
    }
}
