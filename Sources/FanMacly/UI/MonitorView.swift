import SwiftUI
import Charts
import FanMaclyCore

/// History charts, a curated sensor list and the helper's event journal.
struct MonitorView: View {
    let model: AppModel
    enum Tab: String, CaseIterable, Identifiable { case history = "История", sensors = "Датчики", events = "События"; var id: String { rawValue } }
    @State private var tab: Tab = .history

    var body: some View {
        VStack(spacing: 0) {
            Picker("Раздел", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .focusEffectDisabled()
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
            Divider()
            Group {
                switch tab {
                case .history: HistoryView(model: model)
                case .sensors: SensorsView(model: model)
                case .events: EventsView(model: model)
                }
            }
            // Short content (an empty state) must not pull the tab bar down;
            // it is centred in the content area instead.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}

// MARK: - History

/// One value of one line in a history chart.
private struct SeriesPoint: Identifiable {
    let series: String
    let date: Date
    let value: Double
    var id: String { "\(series)-\(date.timeIntervalSinceReferenceDate)" }
}

private struct HistoryView: View {
    let model: AppModel
    @State private var range: TimeInterval = 600

    var body: some View {
        let samples = model.history.window(range)
        // Until the history covers the whole period, fit the axis to the data.
        let end = samples.last?.date ?? Date()
        let start = max(samples.first?.date ?? end, end.addingTimeInterval(-range))
        let domain = start...max(end, start.addingTimeInterval(10))
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    Picker("Период", selection: $range) {
                        Text("5 мин").tag(TimeInterval(300))
                        Text("10 мин").tag(TimeInterval(600))
                        Text("30 мин").tag(TimeInterval(1800))
                        Text("1 час").tag(TimeInterval(3600))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .focusEffectDisabled()
                    Spacer(minLength: 8)
                    Label("История хранится, пока FanMacly запущен", systemImage: "memorychip")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                if samples.count < 2 {
                    ContentUnavailableView("Пока мало данных", systemImage: "chart.xyaxis.line",
                                           description: Text("История появится через несколько секунд."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    HistoryChart(title: "Температура", unit: "°C", range: range, domain: domain,
                                 series: [("CPU", Color.accentColor), ("GPU", Color.purple)],
                                 points: points(samples, [("CPU", \.cpu), ("GPU", \.gpu)]),
                                 format: { "\(Int($0.rounded()))°" }, axisStep: 10, minimumSpan: 30)
                    HistoryChart(title: "Обороты вентиляторов", unit: "об/мин", range: range, domain: domain,
                                 series: fanSeries(samples),
                                 points: fanPoints(samples),
                                 format: { rpmNumber($0) }, axisStep: 1000, minimumSpan: 2000, includesZero: true)
                    if samples.contains(where: { $0.cpuWatts != nil || $0.gpuWatts != nil }) {
                        HistoryChart(title: "Мощность", unit: "Вт", range: range, domain: domain,
                                     series: [("CPU", Color.accentColor), ("GPU", Color.purple)],
                                     points: points(samples, [("CPU", \.cpuWatts), ("GPU", \.gpuWatts)]),
                                     format: { String(format: $0 < 10 ? "%.1f" : "%.0f", $0) }, axisStep: 5, minimumSpan: 5, includesZero: true)
                    }
                }
            }
            .padding(20)
        }
    }

    private func points(_ samples: [HistorySample], _ series: [(String, KeyPath<HistorySample, Double?>)]) -> [SeriesPoint] {
        series.flatMap { name, path in samples.compactMap { sample in sample[keyPath: path].map { SeriesPoint(series: name, date: sample.date, value: $0) } } }
    }
    private func fanSeries(_ samples: [HistorySample]) -> [(String, Color)] {
        let count = samples.map(\.fans.count).max() ?? 0
        let palette: [Color] = [.teal, .orange, .pink, .indigo]
        return (0..<count).map { ("Вентилятор \($0 + 1)", palette[$0 % palette.count]) }
    }
    private func fanPoints(_ samples: [HistorySample]) -> [SeriesPoint] {
        samples.flatMap { sample in
            sample.fans.enumerated().compactMap { index, value in
                value.map { SeriesPoint(series: "Вентилятор \(index + 1)", date: sample.date, value: $0) }
            }
        }
    }
}

/// A titled card with a line chart, a legend that shows the latest value of
/// every series, minute-aligned time grid and a y-scale fitted to the data.
private struct HistoryChart: View {
    let title: String
    let unit: String
    let range: TimeInterval
    let domain: ClosedRange<Date>
    let series: [(String, Color)]
    let points: [SeriesPoint]
    let format: (Double) -> String
    let axisStep: Double
    let minimumSpan: Double
    var includesZero = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(title).font(.headline)
                Text(unit).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ForEach(visibleSeries, id: \.0) { name, color in
                    HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(name).foregroundStyle(.secondary)
                        Text(latest(name).map(format) ?? "—").monospacedDigit().fontWeight(.semibold)
                    }
                    .font(.caption)
                    .fixedSize()
                }
            }
            Chart(points) { point in
                LineMark(x: .value("Время", point.date), y: .value(unit, point.value), series: .value("Ряд", point.series))
                    .foregroundStyle(by: .value("Ряд", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(domain: series.map(\.0), range: series.map(\.1))
            .chartLegend(.hidden)
            .chartXScale(domain: domain)
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: ticks) { _ in
                    AxisGridLine()
                    if tickStep < 60 {
                        AxisValueLabel(format: .dateTime.hour().minute().second(), anchor: .top)
                    } else {
                        AxisValueLabel(format: .dateTime.hour().minute(), anchor: .top)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .stride(by: axisStep)) { value in
                    AxisGridLine()
                    // Same label width on every chart keeps their time grids aligned.
                    AxisValueLabel { if let v = value.as(Double.self) { Text(format(v)).frame(width: 40, alignment: .leading) } }
                }
            }
            .frame(height: 160)
        }
        .padding(14)
        .card(cornerRadius: 12)
    }

    private var span: TimeInterval { domain.upperBound.timeIntervalSince(domain.lowerBound) }
    /// About four to six labels for the visible span.
    private var tickStep: TimeInterval {
        [15, 30, 60, 120, 300, 600, 900].first { span / $0 <= 6 } ?? 1800
    }
    /// Ticks on round clock values (…:00, :15, :30), not offsets from the first sample.
    private var ticks: [Date] {
        let step = tickStep
        let first = (domain.lowerBound.timeIntervalSince1970 / step).rounded(.up) * step
        return stride(from: first, through: domain.upperBound.timeIntervalSince1970, by: step).map { Date(timeIntervalSince1970: $0) }
    }

    /// Series without any data (e.g. CPU power where the counters are unavailable) are left out.
    private var visibleSeries: [(String, Color)] { series.filter { name, _ in points.contains { $0.series == name } } }

    private func latest(_ name: String) -> Double? { points.last(where: { $0.series == name })?.value }

    /// Rounded to the axis step around the data, never narrower than `minimumSpan`.
    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard var low = values.min(), var high = values.max() else { return 0...minimumSpan }
        if includesZero { low = 0 }
        if high - low < minimumSpan {
            let middle = (high + low) / 2
            low = includesZero ? 0 : middle - minimumSpan / 2
            high = includesZero ? minimumSpan : middle + minimumSpan / 2
        }
        low = (low / axisStep).rounded(.down) * axisStep
        // A quarter step of headroom so a line never sits on the top edge.
        high = ((high + axisStep / 4) / axisStep).rounded(.up) * axisStep
        if high <= low { high = low + axisStep }
        return low...high
    }
}

// MARK: - Sensors

private struct SensorRow: Identifiable {
    let sensor: TemperatureSensor
    let guide: SensorGuide
    var id: String { sensor.id }
}

private struct SensorsView: View {
    let model: AppModel
    @State private var search = ""
    @State private var showAll = false
    @State private var selection: String?

    var body: some View {
        let rows = filtered
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    TextField("Поиск по названию или ключу", text: $search).textFieldStyle(.roundedBorder)
                    Toggle("Все ключи SMC", isOn: $showAll).toggleStyle(.switch).controlSize(.small)
                }
                .padding(10)
                Table(rows, selection: $selection) {
                    // The title already starts with the group ("CPU ·", "Аккумулятор ·").
                    TableColumn("Датчик") { row in Text(row.guide.title).lineLimit(1).help(row.guide.title) }
                    TableColumn("Ключ") { row in Text(row.sensor.id).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                        .width(56)
                    TableColumn("°C") { row in
                        Text(String(format: "%.1f", row.sensor.celsius)).monospacedDigit()
                            .foregroundStyle(TemperatureLevel.cpu(row.sensor.celsius).color)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(48)
                }
                HStack {
                    Text("\(rows.count) из \(model.snapshot.sensors.count) датчиков").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Экспорт JSON…") { model.exportSnapshot() }.controlSize(.small)
                }
                .padding(8)
            }
            Divider()
            detail.frame(width: 230)
        }
    }

    private var filtered: [SensorRow] {
        let all = model.snapshot.sensors.map { SensorRow(sensor: $0, guide: SensorGuide.describe($0.id)) }
        let visible = showAll ? all : all.filter { $0.guide.confidence != .unknown && !SensorsView.noise($0.sensor) }
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? visible : visible.filter {
            $0.sensor.id.localizedCaseInsensitiveContains(query) || $0.guide.title.localizedCaseInsensitiveContains(query)
        }
        return matching.sorted { ($0.guide.priority, $0.sensor.group.rawValue, $0.sensor.id) < ($1.guide.priority, $1.sensor.group.rawValue, $1.sensor.id) }
    }

    /// Channels that read like placeholders (e.g. 2–5 °C) are hidden by default.
    static func noise(_ sensor: TemperatureSensor) -> Bool { sensor.celsius < 10 }

    @ViewBuilder private var detail: some View {
        if let id = selection, let sensor = model.snapshot.sensors.first(where: { $0.id == id }) {
            let guide = SensorGuide.describe(sensor.id)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(guide.title).font(.headline)
                    Text(String(format: "%.1f °C", sensor.celsius)).font(.title2.monospacedDigit())
                    Label(guide.confidence.rawValue, systemImage: guide.confidence == .unknown ? "questionmark.circle" : "checkmark.seal")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(guide.details).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if let source = guide.source, let url = URL(string: source) {
                        Link("Справочник", destination: url).font(.callout)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Выберите датчик", systemImage: "thermometer.medium", description: Text("Здесь появится его описание и надёжность расшифровки."))
        }
    }
}

// MARK: - Events

private struct EventsView: View {
    let model: AppModel
    var body: some View {
        let events = model.helper.status.events.reversed()
        if events.isEmpty {
            ContentUnavailableView(model.helper.connected ? "Событий пока нет" : "Нет связи с системным компонентом",
                                   systemImage: "list.bullet.rectangle",
                                   description: Text("Здесь видно, когда и почему менялся режим вентиляторов."))
        } else {
            List(Array(events)) { event in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(event.kind)).foregroundStyle(color(event.kind)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.body.weight(.medium))
                        if let detail = event.detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(event.date.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
        }
    }
    private func symbol(_ kind: ControlEvent.Kind) -> String {
        switch kind {
        case .info: return "info.circle"
        case .boost: return "bolt.fill"
        case .warning: return "exclamationmark.triangle"
        case .suspended: return "pause.circle"
        case .resumed: return "play.circle"
        case .error: return "xmark.octagon"
        }
    }
    private func color(_ kind: ControlEvent.Kind) -> Color {
        switch kind {
        case .info, .resumed: return .accentColor
        case .boost, .warning, .suspended: return .orange
        case .error: return .red
        }
    }
}
