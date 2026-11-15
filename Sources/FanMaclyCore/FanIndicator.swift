import Foundation

/// Visual revolutions per second, scaled down from measured hardware RPM.
/// There is deliberately no target-speed input: an unconfirmed command must
/// never make the indicator pretend that a fan is already spinning faster.
public enum FanIndicator {
    public static func revolutionsPerSecond(for snapshot: HardwareSnapshot?, animated: Bool = true, multiplier: Double = 1) -> Double {
        guard animated, multiplier.isFinite, multiplier > 0 else { return 0 }
        guard let snapshot, snapshot.error == nil else { return 0 }
        let measured = snapshot.fans.compactMap(\.current).filter { $0.isFinite && $0 >= 0 && $0 <= 20000 }.max() ?? 0
        return min(6, measured / 1200 * multiplier)
    }
}
