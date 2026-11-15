import AppKit
import SwiftUI
import Observation

/// Keep the system's current Slider implementation and its gesture state alive.
/// Telemetry may update the surrounding AppKit page while the pointer is down;
/// those updates must never write a rounded/model value back into the gesture.
@MainActor final class SystemSlider: NSView {
    @Observable final class State {
        var value = 0.0
        var range = 0.0...100.0
        var allowedRange = 0.0...100.0
        var enabled = true
        var label = ""
        var valueDescription: String?
        var editing = false
        @ObservationIgnored private var cancelled = false
        @ObservationIgnored var onChange: ((Double, Bool) -> Void)?
        @ObservationIgnored var onEditingChanged: ((Bool) -> Void)?

        func synchronize(value: Double, range: ClosedRange<Double>, allowedRange: ClosedRange<Double>?, enabled: Bool, label: String) {
            if editing && (!enabled || self.range != range) { cancelled = true }
            if self.range != range { self.range = range }
            let allowed = allowedRange ?? range
            if self.allowedRange != allowed { self.allowedRange = allowed }
            if self.enabled != enabled { self.enabled = enabled }
            if self.label != label { self.label = label }
            if (!editing || cancelled) && self.value != value { self.value = value }
        }
        func change(_ proposed: Double) {
            guard enabled, !cancelled, proposed.isFinite else { return }
            let next = max(allowedRange.lowerBound, min(proposed, allowedRange.upperBound))
            value = next
            onChange?(next, editing)
        }
        func edit(_ active: Bool) {
            guard editing != active else { return }
            editing = active
            if active { cancelled = !enabled }
            else if cancelled { cancelled = false; return }
            onEditingChanged?(active)
        }
    }
    private let state = State()
    var onChange: ((Double, Bool) -> Void)? {
        get { state.onChange }
        set { state.onChange = newValue }
    }
    var onEditingChanged: ((Bool) -> Void)? {
        get { state.onEditingChanged }
        set { state.onEditingChanged = newValue }
    }
    init() {
        super.init(frame: .zero)
        let hosting = NSHostingView(rootView: Control(state: state))
        hosting.sizingOptions = []
        NativeUI.fill(hosting, in: self)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

    func update(value: Double, range: ClosedRange<Double>, allowedRange: ClosedRange<Double>? = nil, enabled: Bool, label: String, valueDescription: String? = nil) {
        if state.valueDescription != valueDescription { state.valueDescription = valueDescription }
        state.synchronize(value: value, range: range, allowedRange: allowedRange, enabled: enabled, label: label)
    }

    private struct Control: View {
        let state: State
        var body: some View {
            Slider(value: Binding(get: { state.value }, set: { state.change($0) }), in: state.range,
                   onEditingChanged: { state.edit($0) })
                .controlSize(.regular)
                .disabled(!state.enabled)
                .accessibilityLabel(state.label)
                .accessibilityValue(state.valueDescription ?? "\(Int(state.value.rounded())) %")
                .transaction { $0.animation = nil }
        }
    }
}
