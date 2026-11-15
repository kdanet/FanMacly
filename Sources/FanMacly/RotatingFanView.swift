import AppKit
import QuartzCore

/// The render server rotates the same SF Symbol used by the panel. No timer, SwiftUI body or
/// image allocation runs per frame, including while the panel is closed.
@MainActor final class RotatingFanView: NSView {
    private let rotor = CALayer()
    private var revolutions = 0.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        rotor.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        rotor.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        rotor.position = CGPoint(x: frameRect.width / 2, y: frameRect.height / 2)
        rotor.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        let symbol = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))!
        let mask = CALayer()
        var symbolRect = CGRect(origin: .zero, size: symbol.size)
        if let image = symbol.cgImage(forProposedRect: &symbolRect, context: nil, hints: nil) {
            mask.contents = FanIconGlyph.centered(image)
        }
        mask.contentsGravity = .resizeAspect
        mask.contentsScale = rotor.contentsScale
        mask.frame = rotor.bounds.insetBy(dx: 1, dy: 1)
        rotor.mask = mask
        layer?.addSublayer(rotor)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 1
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        rotor.speed = 0
        rotor.add(spin, forKey: "spin")
        updateColor()
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rotor.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }
    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            rotor.backgroundColor = NSColor.labelColor.cgColor
            CATransaction.commit()
        }
    }
    func setSpeed(_ revolutionsPerSecond: Double) {
        guard abs(revolutionsPerSecond - revolutions) > 0.005 else { return }
        revolutions = revolutionsPerSecond
        let now = CACurrentMediaTime()
        let phase = rotor.convertTime(now, from: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Preserve local time (and therefore the blade angle) when the speed
        // changes, instead of restarting the animation every telemetry sample.
        rotor.speed = Float(revolutionsPerSecond)
        rotor.timeOffset = phase
        rotor.beginTime = now
        CATransaction.commit()
    }
    var rotationSample: [String: Double] {
        let transform = rotor.presentation()?.transform ?? rotor.transform
        return ["rps": revolutions, "angle": atan2(transform.m12, transform.m11),
                "presentation_available": rotor.presentation() == nil ? 0 : 1]
    }
}
