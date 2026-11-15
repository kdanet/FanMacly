import AppKit
import QuartzCore

/// Explicit development mode, absent from a normal launch. Measures display
/// callback pacing on the main thread; this is not a GPU frame-render counter.
@MainActor final class FrameDiagnostics: NSObject {
    private let view: NSView
    private let path: String
    private let fan: RotatingFanView?
    private var link: CADisplayLink?
    private var intervals = [Double]()
    private var previous = 0.0
    private var rotorSamples = [[String: Double]]()
    private var lastRotorSample = 0.0
    init(view: NSView, fan: RotatingFanView?, path: String) { self.view = view; self.fan = fan; self.path = path }
    func start() {
        guard link == nil else { return }
        previous = 0
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if previous > 0 { intervals.append((now - previous) * 1000) }
        previous = now
        if now - lastRotorSample > 0.03, let fan {
            var sample = fan.rotationSample
            sample["time"] = now
            rotorSamples.append(sample)
            lastRotorSample = now
        }
    }
    func stop() {
        guard link != nil else { return }
        link?.invalidate(); link = nil
        let sorted = intervals.sorted()
        guard !sorted.isEmpty else { return }
        let percentile: (Double) -> Double = { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * $0))] }
        let report: [String: Any] = [
            "kind": "main-thread display callback intervals; not rendered-frame FPS",
            "samples": sorted.count, "median_ms": percentile(0.5), "p95_ms": percentile(0.95),
            "p99_ms": percentile(0.99), "maximum_ms": sorted.last!,
            "over_16_7_ms": sorted.filter { $0 > 16.7 }.count,
            "over_50_ms": sorted.filter { $0 > 50 }.count,
            "display_max_hz": view.window?.screen?.maximumFramesPerSecond ?? 0,
            "rotor_samples": rotorSamples
        ]
        // File I/O stays off the event loop even in diagnostics mode.
        let output = path
        Task.detached(priority: .utility) {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
        }
    }
}
