import AppKit
import FanMaclyCore

@MainActor final class NativeFanControls: NSView {
    private let model: AppModel
    private let mode = NSPopUpButton()
    private let activity = InlineControlActivity()
    private let controlCaption = NativeUI.label("Управление", size: 11, secondary: true)
    private let body = NativeUI.stack(.vertical, spacing: 10)
    private let rows = NativeUI.stack(.vertical, spacing: 8)
    private let empty = NativeUI.label("Читаем датчики…", size: 12, secondary: true)
    private var fanRows: [Int: NativeFanRow] = [:]
    private var fanIDs = [Int]()

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        mode.addItems(withTitles: ["Автоматически", "Вручную", "По температуре"])
        mode.target = self
        mode.action = #selector(selectMode)
        mode.setAccessibilityLabel("Режим охлаждения")
        mode.controlSize = .small
        mode.font = .systemFont(ofSize: 12)
        mode.isBordered = false
        LiquidGlass.menu(mode)
        controlCaption.toolTip = "При высоких исходных показаниях CPU помощник временно задаёт максимум охлаждения."
        let top = NativeUI.stack(.horizontal, spacing: 8, views: [controlCaption, activity, NativeUI.spacer(), mode])
        NativeUI.size(top, height: LiquidGlass.available ? 28 : 22)
        rows.alignment = .leading
        NativeUI.append(top, to: body)
        NativeUI.append(rows, to: body)
        NativeUI.fill(body, in: self)
        empty.alignment = .center
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var contentHeight: CGFloat {
        // Don't measure against the previous page frame: newly revealed slider
        // rows may still be constrained to its old (shorter) height this turn.
        let count = fanRows.count
        let rowsHeight = count == 0 ? max(14, empty.intrinsicContentSize.height) :
            fanRows.values.reduce(CGFloat(0)) { $0 + $1.contentHeight } + CGFloat(max(0, count - 1)) * 17
        return max(72, ceil((LiquidGlass.available ? 28 : 22) + 10 + rowsHeight))
    }
    func update() {
        activity.update(active: model.controlPending)
        NativeUI.text(controlCaption, model.helper.status.coolingBoost && model.helper.status.mode != .system ? "Макс. охлаждение" : "Управление")
        let index = CoolingMode.allCases.firstIndex(of: model.selectedMode) ?? 0
        if mode.indexOfSelectedItem != index { mode.selectItem(at: index) }
        mode.isEnabled = model.helper.connected && model.hasFans && !model.sleeping
        mode.item(at: 1)?.isEnabled = model.canControl
        mode.item(at: 2)?.isEnabled = model.canControl
        let fans = model.snapshot.fans
        if fanIDs != fans.map(\.id) {
            for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
            fanIDs = fans.map(\.id)
            fanRows = [:]
            for (index, fan) in fans.enumerated() {
                if index > 0 { NativeUI.append(NativeUI.separator(), to: rows) }
                let row = NativeFanRow(model: model, id: fan.id)
                fanRows[fan.id] = row
                NativeUI.append(row, to: rows)
            }
        }
        if fans.isEmpty {
            if empty.superview == nil { NativeUI.append(empty, to: rows) }
            NativeUI.text(empty, model.loading ? "Читаем датчики…" : model.snapshot.fanCount == 0 ? "В этом Mac нет вентиляторов." : "Вентиляторы недоступны.")
        } else if empty.superview != nil { rows.removeArrangedSubview(empty); empty.removeFromSuperview() }
        for fan in fans { fanRows[fan.id]?.update(fan) }
    }
    @objc private func selectMode() {
        guard CoolingMode.allCases.indices.contains(mode.indexOfSelectedItem) else { return }
        model.selectMode(CoolingMode.allCases[mode.indexOfSelectedItem])
    }
}

@MainActor private final class NativeFanRow: NSView {
    private let model: AppModel
    private let id: Int
    private var fan: FanReading?
    private let name = NativeUI.label("")
    private let current = NativeUI.label("—", size: 13, weight: .medium, numeric: true)
    private let range = NativeUI.label("", size: 11, secondary: true)
    private let target = NativeUI.label("—", size: 11, numeric: true)
    private let slider = SystemSlider()
    private lazy var stop = NSButton(title: "Стоп", target: self, action: #selector(setStopped))
    private lazy var maximum = NSButton(title: "Макс.", target: self, action: #selector(setMaximum))
    private var manualRow: NSStackView!

    init(model: AppModel, id: Int) {
        self.model = model
        self.id = id
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "fanblades", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        NativeUI.size(icon, width: 15, height: 15)
        let reading = NativeUI.stack(.horizontal, spacing: 4, views: [current, NativeUI.label("об/мин", size: 11, secondary: true)])
        let header = NativeUI.stack(.horizontal, spacing: 7, views: [icon, name, NativeUI.spacer(), reading])
        slider.onChange = { [weak self] value, editing in
            guard let self, let fan = self.fan, self.model.canControl else { return }
            let rpm = ManualFanSpeedScale(fan: fan).rpm(at: value)
            self.model.setTarget(rpm, fan: self.id, commit: !editing)
            NativeUI.text(self.target, "\(Int(rpm.rounded()))")
        }
        slider.onEditingChanged = { [weak self] editing in
            guard let self else { return }
            if editing { self.model.beginSliderEdit() }
            else { self.model.finishSliderEdit(curveEdit: false) }
        }
        NativeUI.size(target, width: 37)
        target.alignment = .right
        maximum.controlSize = .small
        maximum.bezelStyle = .rounded
        LiquidGlass.button(maximum)
        maximum.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        maximum.setAccessibilityLabel("Максимум вентилятора \(id + 1)")
        stop.controlSize = .small
        stop.bezelStyle = .rounded
        LiquidGlass.button(stop)
        stop.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stop.setAccessibilityLabel("Остановить вентилятор \(id + 1)")
        stop.toolTip = "Задать 0 об/мин"
        manualRow = NativeUI.stack(.horizontal, spacing: 6, views: [slider, target, stop, maximum])
        let stack = NativeUI.stack(.vertical, spacing: 5, views: [header, manualRow, range])
        stack.alignment = .leading
        NativeUI.fill(stack, in: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var contentHeight: CGFloat {
        let header = max(15, max(name.intrinsicContentSize.height, current.intrinsicContentSize.height))
        let caption = max(14, range.intrinsicContentSize.height)
        guard !manualRow.isHidden else { return ceil(header + 5 + caption) }
        let controls = max(18, max(slider.intrinsicContentSize.height, maximum.intrinsicContentSize.height))
        return ceil(header + 5 + controls + 5 + caption)
    }
    func update(_ fan: FanReading) {
        self.fan = fan
        NativeUI.text(name, fan.name)
        NativeUI.text(current, fan.current.map { "\(Int($0.rounded()))" } ?? "—")
        let manual = model.selectedMode == .manual && fan.controllable
        manualRow.isHidden = !manual
        maximum.isEnabled = model.canControl
        stop.isEnabled = model.canControl && manual
        stop.toolTip = model.helper.status.coolingBoost
            ? "Временно включено максимальное охлаждение. Ноль будет применён после охлаждения."
            : "Задать 0 об/мин"
        let desired = model.targets[fan.id] ?? fan.safeMinimum
        slider.update(value: ManualFanSpeedScale(fan: fan).position(for: desired), range: 0...100,
                      enabled: model.canControl, label: "Обороты вентилятора \(id + 1)",
                      valueDescription: "\(Int(desired.rounded())) об/мин")
        slider.toolTip = "Левая область или кнопка «Стоп» — 0 об/мин. Дальше — от \(Int(fan.safeMinimum)) до \(Int(fan.maximum ?? 6000)) об/мин."
        NativeUI.text(target, "\(Int(desired.rounded()))")
        let runningRange = "\(Int(fan.minimum ?? fan.safeMinimum))–\(Int(fan.maximum ?? 6000)) об/мин"
        let allowsStop = manual || (model.selectedMode == .curve && model.curve.allowsFanStop)
        let bounds = allowsStop ? "0 или \(runningRange)" : runningRange
        let value = model.selectedMode == .curve || model.helper.status.coolingBoost ? model.helper.status.targets[fan.id] : nil
        NativeUI.text(range, value.map { "Цель: \(rpm($0)) · \(bounds)" } ?? bounds)
        maximum.toolTip = "Максимум: \(rpm(fan.maximum))"
    }
    @objc private func setStopped() {
        guard model.canControl, model.selectedMode == .manual else { return }
        model.setTarget(0, fan: id)
    }
    @objc private func setMaximum() {
        guard model.canControl, let value = fan?.maximum else { return }
        model.setTarget(value, fan: id)
    }
}
