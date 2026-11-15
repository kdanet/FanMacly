import SwiftUI
import Charts
import FanMaclyCore

/// Profile library and curve editor. Built-in profiles are read-only templates.
struct ProfileEditorView: View {
    let model: AppModel
    @State private var selection: ModeSelection? = .preset(.balanced)
    @State private var draft: CoolingCurve = .balanced
    @State private var name = ""
    @State private var error: String?
    @State private var selectedPoint: Int?

    /// Height shared by the sidebar and editor bottom bars so their dividers line up.
    private static let barHeight: CGFloat = 52
    static let minimumSize = CGSize(width: 780, height: 560)

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider()
            editor.frame(minWidth: 540, maxWidth: .infinity)
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .onAppear {
            let initial: ModeSelection = {
                switch model.displayedSelection { case .preset, .profile: return model.displayedSelection; default: return model.lastNonAutomatic }
            }()
            load(initial)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { selection }, set: { if let value = $0 { load(value) } })) {
            Section("Встроенные") {
                ForEach(CoolingPreset.allCases) { preset in
                    row(.preset(preset), title: preset.title, symbol: preset.symbol)
                }
            }
            Section("Мои профили") {
                if model.profileLibrary.profiles.isEmpty {
                    Text("Пока пусто. Нажмите «+», чтобы создать профиль на основе выбранного.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectionDisabled()
                }
                ForEach(model.profileLibrary.profiles) { profile in
                    row(.profile(profile.id), title: profile.name, symbol: "slider.horizontal.3")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar {
                HStack(spacing: 4) {
                    Button { duplicate() } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                        .help("Новый профиль на основе выбранного")
                        .accessibilityLabel("Новый профиль")
                    Button { deleteSelected() } label: { Image(systemName: "minus").frame(width: 22, height: 22) }
                        .disabled(!isCustom).help("Удалить профиль")
                        .accessibilityLabel("Удалить профиль")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
            }
        }
    }

    private func row(_ value: ModeSelection, title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: symbol).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if model.activeSelection == value {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .help("Активный режим")
                    .accessibilityLabel("Активен")
            }
        }
        .tag(value)
    }

    private func bottomBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Divider()
            content().frame(maxWidth: .infinity, minHeight: Self.barHeight, maxHeight: Self.barHeight)
        }
        .background(.bar)
    }

    // MARK: Editor

    private var isCustom: Bool { if case .profile = selection { return true }; return false }
    private var saved: CoolingCurve? { selection.flatMap(model.curve(for:)) }
    private var modified: Bool { isCustom && (saved != draft || name != model.title(for: selection ?? .automatic)) }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                chartCard
                pointsSection
                optionsSection
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar { actionBar.padding(.horizontal, 24) } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if isCustom {
                    TextField("Название профиля", text: $name)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                } else {
                    Text(model.title(for: selection ?? .automatic)).font(.title2.weight(.semibold))
                }
                Text(subtitle)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isCustom {
                    Label("Встроенный профиль — только просмотр", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if model.activeSelection == selection {
                    Label("Активен", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Button("Включить") { activate() }
                        .controlSize(.large)
                        .disabled(!model.canControl || modified)
                        .help(modified ? "Сначала сохраните изменения" : "Сделать этот профиль текущим режимом")
                }
            }
            .padding(.top, 2)
        }
    }

    private var subtitle: String {
        switch selection {
        case .preset(let preset): return preset.summary
        case .profile: return "Перетаскивайте точки на графике или выберите точку ниже, чтобы задать точные значения."
        default: return ""
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Скорость, %")
                Spacer()
                if model.snapshot.fans.first?.maximum != nil { Text("Обороты, об/мин") }
            }
            .font(.caption).foregroundStyle(.secondary)
            CurveChart(curve: $draft, editable: isCustom, temperature: model.cpuTemperature, selected: $selectedPoint,
                       fan: model.snapshot.fans.first)
                .frame(height: 230)
            Divider()
            preview
        }
        .padding(14)
        .card(cornerRadius: 12)
    }

    private var pointsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Точки кривой").font(.headline)
                Spacer()
                if isCustom {
                    ControlGroup {
                        Button { addPoint() } label: { Label("Добавить точку", systemImage: "plus") }
                            .disabled(draft.points.count >= 8)
                        Button { removePoint() } label: { Label("Удалить точку", systemImage: "minus") }
                            .disabled(selectedPoint == nil || draft.points.count <= 2)
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            HStack(spacing: 8) {
                ForEach(draft.points.indices, id: \.self) { index in pointCell(index) }
            }
            if isCustom {
                if let index = selectedPoint, draft.points.indices.contains(index) {
                    pointEditor(index)
                } else {
                    Text("Выберите точку, чтобы изменить её температуру и скорость.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pointCell(_ index: Int) -> some View {
        let point = draft.points[index]
        let isSelected = isCustom && selectedPoint == index
        return VStack(spacing: 2) {
            Text("\(Int(point.temperature))°").font(.callout.monospacedDigit().weight(.semibold))
            Text("\(Int(point.percent.rounded())) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture { if isCustom { selectedPoint = index } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCustom ? .isButton : [])
    }

    private func pointEditor(_ index: Int) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Температура").foregroundStyle(.secondary)
                Stepper(value: temperatureBinding(index), in: temperatureBounds(index), step: 1) {
                    Text("\(Int(draft.points[index].temperature)) °C").monospacedDigit().frame(minWidth: 56, alignment: .leading)
                }
            }
            GridRow {
                Text("Скорость").foregroundStyle(.secondary)
                Stepper(value: percentBinding(index), in: percentBounds(index), step: 5) {
                    Text("\(Int(draft.points[index].percent.rounded())) %").monospacedDigit().frame(minWidth: 56, alignment: .leading)
                }
            }
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                Text("Скорость каждой точки любая. При CPU от 95 °C FanMacly всё равно включает максимум.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 10)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Останавливать вентиляторы при 0 %", isOn: $draft.allowsFanStop)
                .disabled(!isCustom)
            Text("Без этой настройки 0 % — минимальные обороты. С ней вентиляторы полностью останавливаются и снова запускаются при нагреве.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }

    @ViewBuilder private var actionBar: some View {
        HStack(spacing: 10) {
            if isCustom {
                if modified {
                    Label("Есть несохранённые изменения", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption).foregroundStyle(.secondary)
                        .imageScale(.small)
                }
                Spacer()
                Button("Отменить изменения") { if let selection { load(selection) } }.disabled(!modified)
                Button("Сохранить") { save() }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!modified || !draft.isValid)
            } else {
                Spacer()
                Button("Создать копию для изменения") { duplicate() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var preview: some View {
        let temperature = model.cpuTemperature
        let percent = temperature.flatMap { draft.percent(at: $0) }
        let fan = model.snapshot.fans.first
        let target = temperature.flatMap { t in fan.flatMap { draft.rpm(at: t, fan: $0) } }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(.orange).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            if let temperature, let percent {
                Text("Сейчас CPU \(Int(temperature.rounded()))° → \(Int(percent.rounded())) %\(target.map { " ≈ \(rpm($0))" } ?? "")")
            } else {
                Text("Нет текущей температуры CPU")
            }
            Spacer(minLength: 0)
        }
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    private func load(_ value: ModeSelection) {
        selection = value
        draft = model.curve(for: value) ?? .balanced
        name = model.title(for: value)
        selectedPoint = nil
        error = nil
    }
    private func activate() { if let selection { model.select(selection) } }
    private func save() {
        guard case .profile(let id) = selection else { return }
        // Reload so the trimmed saved name no longer reads as an unsaved change.
        do { _ = try model.saveProfile(name: name, curve: draft, replacing: id); error = nil; load(.profile(id)) }
        catch { self.error = error.localizedDescription }
    }
    private func duplicate() {
        let base = model.title(for: selection ?? .preset(.balanced))
        do {
            let id = try model.saveProfile(name: model.uniqueProfileName("\(base) — копия"), curve: draft)
            load(.profile(id))
        } catch { self.error = error.localizedDescription }
    }
    private func deleteSelected() {
        guard case .profile(let id) = selection else { return }
        model.deleteProfile(id)
        load(.preset(.balanced))
    }
    private func addPoint() {
        let points = draft.points
        guard points.count >= 2 else { return }
        var gapIndex = 1
        for index in 1..<points.count where points[index].temperature - points[index - 1].temperature > points[gapIndex].temperature - points[gapIndex - 1].temperature {
            gapIndex = index
        }
        let a = points[gapIndex - 1], b = points[gapIndex]
        guard b.temperature - a.temperature >= 2 else { return }
        let temperature = ((a.temperature + b.temperature) / 2).rounded()
        draft.points.insert(.init(temperature, ((a.percent + b.percent) / 2).rounded()), at: gapIndex)
        selectedPoint = gapIndex
    }
    private func removePoint() {
        guard let index = selectedPoint, draft.points.count > 2, draft.points.indices.contains(index) else { return }
        draft.points.remove(at: index)
        selectedPoint = nil
    }
    private func temperatureBounds(_ index: Int) -> ClosedRange<Double> {
        let low = index == 0 ? min(CurveChart.editableLow, draft.points[index].temperature) : draft.points[index - 1].temperature + 1
        let high = index == draft.points.count - 1 ? CoolingCurve.temperatureRange.upperBound : draft.points[index + 1].temperature - 1
        return low...max(low, high)
    }
    private func percentBounds(_ index: Int) -> ClosedRange<Double> { 0...100 }
    private func temperatureBinding(_ index: Int) -> Binding<Double> {
        Binding(get: { draft.points[index].temperature }, set: { draft.points[index].temperature = $0.clamped(to: temperatureBounds(index)) })
    }
    private func percentBinding(_ index: Int) -> Binding<Double> {
        Binding(get: { draft.points[index].percent }, set: { draft.points[index].percent = $0.clamped(to: percentBounds(index)) })
    }
}

/// Interactive curve: drag points horizontally (temperature) and vertically (speed).
struct CurveChart: View {
    @Binding var curve: CoolingCurve
    let editable: Bool
    let temperature: Double?
    @Binding var selected: Int?
    let fan: FanReading?
    @State private var dragging: Int?
    /// New points start at 30 °C; an older curve with a lower point widens the axis.
    static let editableLow: Double = 30
    private var xLow: Double {
        min(Self.editableLow, ((curve.points.first?.temperature ?? Self.editableLow) / 10).rounded(.down) * 10)
    }

    private static let ticks: [Double] = [0, 25, 50, 75, 100]

    var body: some View {
        Chart {
            ForEach(Array(curve.points.enumerated()), id: \.offset) { index, point in
                AreaMark(x: .value("Температура", point.temperature), y: .value("Скорость", point.percent))
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.linear)
                LineMark(x: .value("Температура", point.temperature), y: .value("Скорость", point.percent))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                PointMark(x: .value("Температура", point.temperature), y: .value("Скорость", point.percent))
                    .foregroundStyle(selected == index ? Color.orange : Color.accentColor)
                    .symbolSize(editable ? (selected == index ? 160 : 110) : 50)
            }
            // Current CPU temperature: a dashed rule and a dot on the curve.
            // The values are spelled out under the chart instead of in a
            // label that would collide with the plot edge.
            if let temperature, (xLow...100).contains(temperature), let percent = curve.percent(at: temperature) {
                RuleMark(x: .value("CPU", temperature))
                    .foregroundStyle(.orange.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                PointMark(x: .value("CPU", temperature), y: .value("Скорость", percent))
                    .symbol {
                        Circle().fill(.orange).frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    }
            }
        }
        .chartXScale(domain: xLow...100)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: xLow, through: 100.0, by: 10.0))) { value in
                AxisGridLine(); AxisTick()
                // Edge labels are anchored inward so Charts does not drop them.
                let v = value.as(Double.self) ?? 0
                AxisValueLabel(anchor: v <= xLow ? .topLeading : v >= 100 ? .topTrailing : .top) { Text("\(Int(v))°") }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: Self.ticks) { value in
                AxisGridLine(); AxisTick()
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v)) %") } }
            }
            AxisMarks(position: .trailing, values: Self.ticks) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self), let fan, let maximum = fan.maximum {
                        Text(rpmNumber(fan.safeMinimum + (maximum - fan.safeMinimum) * v / 100))
                    }
                }
            }
        }
        .chartXAxisLabel("Температура CPU (сглаженная)", alignment: .center)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard editable, let plot = proxy.plotFrame.map({ geometry[$0] }) else { return }
                        let location = CGPoint(x: value.location.x - plot.minX, y: value.location.y - plot.minY)
                        if dragging == nil {
                            dragging = nearest(to: value.startLocation, proxy: proxy, plot: plot)
                            selected = dragging
                        }
                        guard let index = dragging,
                              let t = proxy.value(atX: location.x, as: Double.self),
                              let p = proxy.value(atY: location.y, as: Double.self) else { return }
                        move(index, temperature: t.rounded(), percent: (p / 5).rounded() * 5)
                    }.onEnded { _ in dragging = nil })
            }
        }
        .accessibilityLabel("Температурная кривая")
    }

    private func nearest(to start: CGPoint, proxy: ChartProxy, plot: CGRect) -> Int? {
        var best: (Int, CGFloat)?
        for (index, point) in curve.points.enumerated() {
            guard let x = proxy.position(forX: point.temperature), let y = proxy.position(forY: point.percent) else { continue }
            let distance = hypot(x + plot.minX - start.x, y + plot.minY - start.y)
            if distance < 24, distance < (best?.1 ?? .infinity) { best = (index, distance) }
        }
        return best?.0
    }

    private func move(_ index: Int, temperature: Double, percent: Double) {
        let points = curve.points
        let lowT = index == 0 ? min(CurveChart.editableLow, points[index].temperature) : points[index - 1].temperature + 1
        let highT = index == points.count - 1 ? CoolingCurve.temperatureRange.upperBound : points[index + 1].temperature - 1
        curve.points[index].temperature = temperature.clamped(to: lowT...max(lowT, highT))
        curve.points[index].percent = percent.clamped(to: 0...100)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
