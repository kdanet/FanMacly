import AppKit

/// A reserved slot in the existing control row. Quick acknowledgements stay
/// silent; longer operations get an indicator without changing page geometry.
@MainActor final class InlineControlActivity: NSProgressIndicator {
    private var active = false
    private var shownAt: TimeInterval?
    private var transition: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        style = .spinning
        controlSize = .small
        isDisplayedWhenStopped = true
        alphaValue = 0
        setAccessibilityLabel("Применение настроек")
        setAccessibilityElement(false)
        NativeUI.size(self, width: 14, height: 14)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(active: Bool) {
        guard self.active != active else { return }
        self.active = active
        transition?.cancel()
        let delay: Double
        if active {
            if shownAt != nil { return }
            delay = 0.4
        } else {
            guard let shownAt else { return }
            delay = max(0, 0.4 - (ProcessInfo.processInfo.systemUptime - shownAt))
        }
        transition = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, self.active == active else { return }
            if active {
                self.shownAt = ProcessInfo.processInfo.systemUptime
                self.startAnimation(nil)
                self.alphaValue = 1
                self.setAccessibilityElement(true)
            } else {
                self.alphaValue = 0
                self.stopAnimation(nil)
                self.shownAt = nil
                self.setAccessibilityElement(false)
            }
            self.transition = nil
        }
    }
}
