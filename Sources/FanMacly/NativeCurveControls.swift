import AppKit
import FanMaclyCore

@MainActor final class NativeCurveControls: NSView {
    private let model: AppModel
    private let preset = NSPopUpButton()
    private let activity = InlineControlActivity()
    private let profileState = NativeUI.label("Не активен", size: 11, secondary: true)
    private let graph = NativeCurveGraph()
    private let points = NativeUI.stack(.vertical, spacing: 3)
    private var sliders = [SystemSlider]()
    private var values = [NSTextField]()
    private var temperatures = [NSTextField]()
    private var menuSignature = ""
    private lazy var caption = NSButton(checkboxWithTitle: "Останавливать вентиляторы при 0 %", target: self, action: #selector(toggleFanStop))
    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        caption.controlSize = .small
        caption.font = .systemFont(ofSize: 11)
        caption.setAccessibilityIdentifier("allowProfileFanStop")
        preset.target = self
        preset.action = #selector(selectProfileMenuItem)
        preset.setAccessibilityLabel("Температурный профиль")
        preset.toolTip = "Изменения именованного профиля сохраняются автоматически. Копия и переименование — в меню."
        preset.controlSize = .small
        preset.font = .systemFont(ofSize: 12)
        preset.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preset.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        preset.cell?.lineBreakMode = .byTruncatingTail
        preset.isBordered = false
        LiquidGlass.menu(preset)
        profileState.toolTip = "Состояние подтверждается системным помощником. Расчёт на графике сам по себе не включает управление."
        let top = NativeUI.stack(.horizontal, spacing: 8, views: [profileState, activity, NativeUI.spacer(), preset])
        NativeUI.size(top, height: LiquidGlass.available ? 28 : 22)
        NativeUI.size(graph, height: NativeCurveGraph.height)
        graph.toolTip = "Обороты в зависимости от сглаженной температуры CPU."
        points.alignment = .leading
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = points
        scroll.borderType = .noBorder
        points.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        points.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        NativeUI.size(scroll, height: 152)
        let stack = NativeUI.stack(.vertical, spacing: 7, views: [top, graph, scroll, caption])
        stack.alignment = .leading
        stack.setContentHuggingPriority(.defaultHigh, for: .vertical)
        translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: 0)
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var contentHeight: CGFloat {
        ceil((LiquidGlass.available ? 28 : 22) + NativeCurveGraph.height + 152 + max(14, caption.intrinsicContentSize.height) + 21)
    }
    func update() {
        activity.update(active: model.controlPending)
        let active = model.helper.connected && model.helper.status.mode == .curve
        NativeUI.text(profileState, active ? (model.helper.status.coolingBoost ? "Активен · Макс." : "Активен") : model.controlPending && model.selectedMode == .curve ? "Включаем…" : "Не активен")
        profileState.toolTip = active && model.helper.status.coolingBoost
            ? "Временно задан максимум по исходным показаниям CPU. Профиль продолжает работать; обороты снизятся после охлаждения."
            : "Состояние подтверждается системным помощником. Расчёт на графике сам по себе не включает управление."
        updateProfileMenu()
        caption.state = model.curve.allowsFanStop ? .on : .off
        caption.isEnabled = !model.helper.connected || model.helper.status.version == HelperIdentity.protocolVersion
        caption.toolTip = caption.isEnabled
            ? "Без этой настройки 0 % — минимум оборотов. С ней 0 % запрашивает полную остановку. При 85 °C — максимум; защита и возврат к macOS остаются активны."
            : "Для остановки нужен обновлённый помощник \(HelperIdentity.protocolVersion)."
        if sliders.count != model.curve.points.count { buildPoints() }
        for index in model.curve.points.indices {
            let point = model.curve.points[index]
            let slider = sliders[index]
            let lower = index == 0 ? 0 : model.curve.points[index - 1].percent
            let upper = index == model.curve.points.count - 1 ? 100 : model.curve.points[index + 1].percent
            slider.update(value: point.percent, range: 0...100, allowedRange: lower...upper,
                          enabled: model.canControl && index != model.curve.points.count - 1,
                          label: "Скорость при \(Int(point.temperature)) градусах")
            NativeUI.text(values[index], "\(Int(point.percent.rounded())) %")
            NativeUI.text(temperatures[index], "\(Int(point.temperature))°")
        }
        graph.update(curve: model.curve, temperature: model.cpuTemperature, active: active)
    }
    @objc private func toggleFanStop() {
        model.setFanStopAllowed(caption.state == .on)
        update()
    }
    private func buildPoints() {
        for view in points.arrangedSubviews { points.removeArrangedSubview(view); view.removeFromSuperview() }
        sliders = []; values = []; temperatures = []
        for index in model.curve.points.indices {
            let temperature = NativeUI.label("", size: 11, secondary: true, numeric: true)
            NativeUI.size(temperature, width: 30)
            let value = NativeUI.label("", size: 11, numeric: true)
            value.alignment = .right
            NativeUI.size(value, width: 37)
            let slider = SystemSlider()
            slider.onChange = { [weak self] value, editing in
                guard let self, self.model.canControl else { return }
                self.model.setCurvePercent(value, at: index, commit: !editing)
                self.update()
            }
            slider.onEditingChanged = { [weak self] editing in
                guard let self else { return }
                if editing { self.model.beginSliderEdit() }
                else { self.model.finishSliderEdit(curveEdit: true) }
            }
            let row = NativeUI.stack(.horizontal, spacing: 8, views: [temperature, slider, value])
            NativeUI.size(row, height: 28)
            NativeUI.append(row, to: points)
            sliders.append(slider); values.append(value); temperatures.append(temperature)
        }
    }
    private func updateProfileMenu() {
        let signature = model.profileLibrary.profiles.map { "\($0.id):\($0.name)" }.joined(separator: "|") +
            "|\(model.activeProfileID?.uuidString ?? model.profileName)|\(model.profileIsModified)"
        guard signature != menuSignature else { return }
        menuSignature = signature
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ name: String, tag: Int, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.tag = tag; item.isEnabled = enabled; menu.addItem(item)
            return item
        }
        let balanced = item("Сбалансированный", tag: 0)
        let cool = item("Прохладный", tag: 1)
        var selected: NSMenuItem?
        if model.activeProfileID == nil {
            if model.profileName == "Сбалансированный" { selected = balanced }
            else if model.profileName == "Прохладный" { selected = cool }
        }
        if !model.profileLibrary.profiles.isEmpty { menu.addItem(.separator()) }
        for profile in model.profileLibrary.profiles {
            let active = profile.id == model.activeProfileID
            let entry = item(profile.name, tag: 100)
            entry.representedObject = profile.id.uuidString
            if active { selected = entry }
        }
        if selected == nil {
            menu.addItem(.separator())
            // The selected item's enabled state also controls the appearance
            // of the closed pop-up. A draft is selectable, not unavailable.
            selected = item("Своя кривая", tag: -1)
        }
        menu.addItem(.separator())
        _ = item(model.activeProfileID == nil ? "Создать профиль…" : "Создать копию…", tag: -10)
        if model.activeProfileID != nil && model.profileIsModified { _ = item("Сохранить изменения", tag: -11) }
        _ = item("Переименовать…", tag: -12, enabled: model.activeProfileID != nil)
        _ = item("Удалить сохранённый профиль…", tag: -13, enabled: model.activeProfileID != nil)
        preset.menu = menu
        if let selected { preset.select(selected) }
    }
    @objc private func selectProfileMenuItem() {
        guard let sender = preset.selectedItem else { return }
        let tag = sender.tag, id = (sender.representedObject as? String).flatMap(UUID.init(uuidString:))
        menuSignature = ""; update()
        switch tag {
        case 0: model.preset("Сбалансированный", curve: .balanced)
        case 1: model.preset("Прохладный", curve: .cool)
        case 100: if let id { model.useProfile(id) }
        case -10: saveAs()
        case -11: saveChanges()
        case -12: renameProfile()
        case -13: deleteProfile()
        default: break
        }
        update()
    }
    private func askName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Сохранённый профиль можно выбрать в списке. Название — от 1 до 40 символов."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.setAccessibilityLabel("Название профиля")
        alert.accessoryView = field
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        let result = alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        menuSignature = ""
        update()
        return result
    }
    @objc private func saveAs() {
        let locale = Locale(identifier: "en_US_POSIX")
        let names = Set(model.profileLibrary.profiles.map { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale) })
        var initial = "Новый профиль", suffix = 2
        while names.contains(initial.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)) {
            initial = "Новый профиль \(suffix)"; suffix += 1
        }
        guard let name = askName(title: "Сохранить профиль", initial: initial) else { return }
        do { try model.saveProfile(named: name) } catch { model.exportError = error.localizedDescription }
        update()
    }
    @objc private func saveChanges() {
        guard let profile = model.activeSavedProfile else { return }
        do { try model.saveProfile(named: profile.name, replacing: profile.id) } catch { model.exportError = error.localizedDescription }
        update()
    }
    @objc private func renameProfile() {
        guard let profile = model.activeSavedProfile, let name = askName(title: "Переименовать профиль", initial: profile.name) else { return }
        do { try model.renameActiveProfile(to: name) } catch { model.exportError = error.localizedDescription }
        update()
    }
    @objc private func deleteProfile() {
        guard let profile = model.activeSavedProfile else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить профиль «\(profile.name)»?"
        alert.informativeText = "Текущая кривая останется рабочим вариантом."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn { model.deleteActiveProfile() }
        menuSignature = ""; update()
    }
}

/// Only the data plot is custom drawn; surrounding controls use AppKit as-is.
@MainActor private final class NativeCurveGraph: NSView {
    static let height: CGFloat = 144
    private var curve = CoolingCurve.balanced
    private var temperature: Double?
    private var active = false
    override var isFlipped: Bool { true }
    func update(curve: CoolingCurve, temperature: Double?, active: Bool) {
        guard self.curve != curve || self.temperature != temperature || self.active != active else { return }
        self.curve = curve; self.temperature = temperature; self.active = active; needsDisplay = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Температурная кривая вентилятора")
        setAccessibilityValue(curve.points.map { "\(Int($0.temperature)) °C: \(Int($0.percent.rounded())) %" }.joined(separator: "; "))
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let first = curve.points.first, let last = curve.points.last else { return }
        let area = NSRect(x: 33, y: 21, width: max(1, bounds.width - 42), height: max(1, bounds.height - 57))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        func label(_ text: String, x: CGFloat, y: CGFloat, alignment: NSTextAlignment = .left, width: CGFloat = 60, emphasized: Bool = false) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            (text as NSString).draw(in: NSRect(x: x, y: y, width: width, height: 14), withAttributes: [
                .font: font, .foregroundColor: emphasized ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ])
        }
        label(active ? "Кривая, %" : "Расчёт, %", x: 0, y: 0, width: 110)
        if let temperature, let percent = curve.percent(at: temperature) {
            label("CPU \(Int(temperature.rounded()))° · \(Int(percent.rounded())) %", x: bounds.width - 145, y: 0, alignment: .right, width: 145, emphasized: active)
        }
        func point(_ value: CurvePoint) -> CGPoint {
            CGPoint(x: area.minX + (value.temperature - first.temperature) / max(1, last.temperature - first.temperature) * area.width, y: area.minY + (1 - value.percent / 100) * area.height)
        }
        let grid = NSBezierPath()
        for percent in [0.0, 25, 50, 75, 100] {
            let y = area.minY + (1 - percent / 100) * area.height
            grid.move(to: CGPoint(x: area.minX, y: y)); grid.line(to: CGPoint(x: area.maxX, y: y))
            if percent == 0 || percent == 50 || percent == 100 {
                label("\(Int(percent))", x: 0, y: y - 6, alignment: .right, width: 26)
            }
        }
        NSColor.separatorColor.setStroke(); grid.lineWidth = 0.5; grid.stroke()
        for value in curve.points {
            let x = point(value).x
            label("\(Int(value.temperature))°", x: min(bounds.width - 28, max(0, x - 14)), y: area.maxY + 5, alignment: .center, width: 28)
        }
        label("Температура CPU, °C", x: area.minX, y: bounds.height - 14, alignment: .center, width: area.width)
        let fill = NSBezierPath()
        fill.move(to: CGPoint(x: area.minX, y: area.maxY))
        for value in curve.points { fill.line(to: point(value)) }
        fill.line(to: CGPoint(x: area.maxX, y: area.maxY)); fill.close()
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill(); fill.fill()
        let line = NSBezierPath(); line.move(to: point(first))
        for value in curve.points.dropFirst() { line.line(to: point(value)) }
        NSColor.controlAccentColor.setStroke(); line.lineWidth = 2; line.lineJoinStyle = .round; line.stroke()
        NSColor.controlAccentColor.setFill()
        for value in curve.points { let p = point(value); NSBezierPath(ovalIn: NSRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)).fill() }
        if let temperature, (first.temperature...last.temperature).contains(temperature), let percent = curve.percent(at: temperature) {
            let p = point(CurvePoint(temperature, percent))
            let guide = NSBezierPath()
            guide.move(to: CGPoint(x: p.x, y: p.y)); guide.line(to: CGPoint(x: p.x, y: area.maxY))
            guide.setLineDash([2, 3], count: 2, phase: 0)
            NSColor.secondaryLabelColor.withAlphaComponent(0.4).setStroke(); guide.lineWidth = 0.5; guide.stroke()
            NSColor.labelColor.setFill()
            let marker = NSBezierPath(ovalIn: NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            marker.fill()
            NSColor.controlAccentColor.setStroke(); marker.lineWidth = 1.5; marker.stroke()
        }
    }
}
