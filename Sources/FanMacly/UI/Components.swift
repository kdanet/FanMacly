import SwiftUI
import FanMaclyCore

extension TemperatureLevel {
    var color: Color {
        switch self {
        case .cool: return .teal
        case .normal: return .primary
        case .warm: return .orange
        case .hot: return .red
        }
    }
    var label: String {
        switch self { case .cool: return "прохладно"; case .normal: return "норма"; case .warm: return "горячо"; case .hot: return "очень горячо" }
    }
}

/// Rounded card used throughout the panel. On macOS 26+ it uses Liquid Glass.
struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 12
    var tint: Color? = nil
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background {
            shape.fill(tint.map { $0.opacity(0.14) } ?? Color.primary.opacity(0.055))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }
}

extension View {
    func card(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius, tint: tint))
    }
}

struct MetricView: View {
    let title: String
    let value: String
    var level: TemperatureLevel = .normal
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(level.color)
                .contentTransition(.numericText())
            if let detail {
                Text(detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .card(cornerRadius: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value), \(level.label)")
    }
}

struct ModeTile: View {
    let title: String
    let symbol: String
    let selected: Bool
    let pending: Bool
    var disabled = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .opacity(pending ? 0 : 1)
                    if pending { ProgressView().controlSize(.small).scaleEffect(0.7) }
                }
                .frame(height: 18)
                Text(title)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.1 : 0.055))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = .accentColor
    var body: some View {
        GeometryReader { geometry in
            let points = normalized(in: geometry.size)
            if points.count > 1 {
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points.last!.x, y: geometry.size.height))
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.25), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { path in path.addLines(points) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
    private func normalized(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let low = values.min(), let high = values.max() else { return [] }
        let span = max(high - low, 300)
        let floor = low - (span - (high - low)) / 2
        return values.enumerated().map { index, value in
            CGPoint(x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: size.height - size.height * CGFloat((value - floor) / span))
        }
    }
}

struct Banner: View {
    enum Style { case info, warning, error }
    let style: Style
    let title: String
    var message: String? = nil
    var actions: [(String, () -> Void)] = []
    var onDismiss: (() -> Void)? = nil
    private var color: Color { switch style { case .info: return .accentColor; case .warning: return .orange; case .error: return .red } }
    private var symbol: String {
        switch style { case .info: return "info.circle.fill"; case .warning: return "exclamationmark.triangle.fill"; case .error: return "xmark.octagon.fill" }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 14)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                            if index == 0 {
                                Button(action.0, action: action.1).buttonStyle(.borderedProminent).controlSize(.small)
                            } else {
                                Button(action.0, action: action.1).buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Скрыть")
            }
        }
        .padding(10)
        .card(cornerRadius: 10, tint: color)
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.4)
            Spacer()
            if let trailing { trailing }
        }
    }
}

/// Rotating fan glyph for the panel; speed follows measured RPM.
///
/// Uses the same Core Animation rotor as the menu bar icon. A SwiftUI
/// timeline recomputing `time × speed` jumped whenever the RPM sample changed
/// and strobed at 30 fps (≈30° per frame for three blades at 3500 об/мин).
struct FanGlyph: View {
    let rpm: Double?
    var color: Color = .secondary
    /// Symbol point size. The rotor pads the glyph so it can spin, so this is
    /// a few points larger than the equivalent SwiftUI font size.
    var size: CGFloat = 17
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        // About one turn per second at 2000 об/мин, at most three.
        SpinningFan(revolutions: reduceMotion ? 0 : min(3, max(0, rpm ?? 0) / 2000), tint: nsColor, size: size)
            .frame(width: size + 3, height: size + 3)
            .accessibilityHidden(true)
    }
    private var nsColor: NSColor {
        switch color {
        case .secondary: return .secondaryLabelColor
        case .accentColor: return .controlAccentColor
        case .primary: return .labelColor
        default: return NSColor(color)
        }
    }
}

private struct SpinningFan: NSViewRepresentable {
    let revolutions: Double
    let tint: NSColor
    let size: CGFloat
    func makeNSView(context: Context) -> RotatingFanView {
        RotatingFanView(frame: CGRect(x: 0, y: 0, width: size + 3, height: size + 3), pointSize: size)
    }
    func updateNSView(_ view: RotatingFanView, context: Context) {
        view.tint = tint
        view.setSpeed(revolutions)
    }
}
