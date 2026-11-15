import AppKit

/// Real system Liquid Glass, with the existing AppKit layout on older macOS.
@MainActor enum LiquidGlass {
    static var available: Bool { if #available(macOS 26, *) { return true }; return false }
    static func button(_ button: NSButton) {
        if #available(macOS 26, *) { button.bezelStyle = .glass }
        else { button.bezelStyle = .rounded }
    }
    static func menu(_ button: NSPopUpButton) {
        if #available(macOS 26, *) {
            button.bezelStyle = .glass
            button.isBordered = true
        }
    }
    static func surface(content: NSView, size: NSSize) -> NSView {
        if #available(macOS 26, *) {
            let glass = GlassPanel(frame: NSRect(origin: .zero, size: size))
            glass.style = .regular
            glass.cornerRadius = 12
            content.frame = glass.bounds
            content.autoresizingMask = [.width, .height]
            glass.contentView = content
            glass.normalizeContentAppearance()
            return glass
        }
        return content
    }
    static func group(_ content: NSView, height: CGFloat) -> NSView {
        if #available(macOS 26, *) {
            let group = NSGlassEffectContainerView(frame: NSRect(x: 0, y: 0, width: 322, height: height))
            group.spacing = 0
            content.translatesAutoresizingMaskIntoConstraints = true
            content.frame = group.bounds
            content.autoresizingMask = [.width, .height]
            group.contentView = content
            NativeUI.size(group, height: height)
            return group
        }
        return content
    }
    static func tab(_ button: NSButton, selected: Bool) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 104, height: 32))
            glass.style = .regular
            glass.cornerRadius = 16
            if #available(macOS 27, *) { glass.effectIsInteractive = true }
            button.isBordered = false
            button.frame = glass.bounds
            button.autoresizingMask = [.width, .height]
            glass.contentView = button
            selectTab(glass, selected: selected)
            NativeUI.size(glass, height: 32)
            return glass
        }
        return button
    }
    static func selectTab(_ view: NSView, selected: Bool) {
        if #available(macOS 26, *), let glass = view as? NSGlassEffectView {
            glass.tintColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.25) : nil
        }
    }
}

@available(macOS 26, *)
@MainActor private final class GlassPanel: NSGlassEffectView {
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        normalizeContentAppearance()
    }
    func normalizeContentAppearance() {
        if let name = effectiveAppearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua]) {
            contentView?.appearance = NSAppearance(named: name)
        }
    }
}
