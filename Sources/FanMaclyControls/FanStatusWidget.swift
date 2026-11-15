import WidgetKit
import SwiftUI
import AppIntents

struct FanStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct FanStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> FanStatusEntry {
        .init(date: Date(), snapshot: .init(date: Date(), mode: "Сбалансированный", symbol: "dial.medium", state: "FanMacly управляет",
                                            active: true, warning: false, cpu: 72, gpu: 61, fans: [2400, 2450]))
    }
    func getSnapshot(in context: Context, completion: @escaping (FanStatusEntry) -> Void) {
        completion(.init(date: Date(), snapshot: WidgetSnapshot.load() ?? placeholder(in: context).snapshot))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FanStatusEntry>) -> Void) {
        let entry = FanStatusEntry(date: Date(), snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
    }
}

struct FanStatusWidgetView: View {
    let entry: FanStatusEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        if let snapshot = entry.snapshot {
            content(snapshot)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "fanblades").font(.title2)
                Text("Откройте FanMacly").font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func content(_ snapshot: WidgetSnapshot) -> some View {
        // The app refreshes the snapshot every minute while it runs.
        let stale = entry.date.timeIntervalSince(snapshot.date) > 10 * 60
        let tint: Color = stale ? .secondary : snapshot.warning ? .orange : snapshot.active ? .accentColor : .secondary
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: snapshot.symbol).foregroundStyle(tint)
                Text(snapshot.mode).font(.headline).lineLimit(1)
            }
            Text(stale ? "FanMacly не запущен" : snapshot.state).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                metric("CPU", snapshot.cpu.map { "\(Int($0.rounded()))°" } ?? "—")
                if family != .systemSmall { metric("GPU", snapshot.gpu.map { "\(Int($0.rounded()))°" } ?? "—") }
                metric("об/мин", snapshot.fans.isEmpty ? "—" : "\(Int((snapshot.fans.reduce(0, +) / Double(snapshot.fans.count)).rounded()))")
            }
            if family != .systemSmall {
                HStack(spacing: 6) {
                    Button(intent: FanModeControlIntent(.automatic)) { Label("Авто", image: "FanAutomatic") }
                    Button(intent: FanModeControlIntent(.profile)) { Label("Профиль", image: "FanProfile") }
                    Button(intent: FanModeControlIntent(.maximum)) { Label("Макс", image: "FanMaximum") }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
            Text("Обновлено \(snapshot.date.formatted(Calendar.current.isDateInToday(snapshot.date) ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute()))").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct FanStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.fanmacly.widget.status", provider: FanStatusProvider()) { entry in
            FanStatusWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("FanMacly")
        .description("Режим вентиляторов, температура и обороты.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
