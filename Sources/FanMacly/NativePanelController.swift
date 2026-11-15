import AppKit
import Observation
import QuartzCore
import ServiceManagement
import FanMaclyCore

/// AppKit owns the controls, drawing, keyboard behavior, accessibility and
/// appearance. This controller only supplies data and handles actions.
@MainActor final class NativePanelController: NSViewController {
    static let size = NSSize(width: 350, height: 284)
    var onPreferredSizeChange: ((NSSize) -> Void)?
    private let model: AppModel
    private var helper: HelperClient { model.helper }
    private let pageContainer = NativePanelSurface()
    private let navigation = NSSegmentedControl(labels: ["Вентиляторы", "Профиль", "Датчики"], trackingMode: .selectOne, target: nil, action: nil)
    private var glassTabs = [NSButton]()
    private var glassTabSurfaces = [NSView]()
    private var page = 0
    private var pages = [NSView]()
    private var lastContentSize = NativePanelController.size
    private var contentHeight: NSLayoutConstraint!
    private var rootStack: NSStackView!
    private var footer: NSStackView!
    private var footerDivider: NSView!
    private let cpu = NativeUI.label("—", size: 19, weight: .medium, numeric: true)
    private let gpu = NativeUI.label("—", size: 19, weight: .medium, numeric: true)
    private let battery = NativeUI.label("—", size: 19, weight: .medium, numeric: true)
    private let fans: NativeFanControls
    private let curve: NativeCurveControls
    private let sensors = NativeSensorList()
    private let status = NativeUI.label("Подключение…", size: 11, secondary: true)
    private let statusIcon = NSImageView()
    private let progress = NSProgressIndicator()
    private lazy var helperButton = NSButton(title: "Включить", target: self, action: #selector(enableHelper))
    private lazy var dismissButton = NSButton(title: "Скрыть", target: self, action: #selector(dismissMessage))
    private let settings = NSPopUpButton(frame: .zero, pullsDown: true)
    private var loginItem: NSMenuItem!
    private var helperItem: NSMenuItem!
    private var animationItem: NSMenuItem!
    private var temperatureItem: NSMenuItem!
    private var speedItems = [NSMenuItem]()
    private var loginEnabled = false
    private var loginBusy = false
    private var updateScheduled = false
    private var dismissedThermalEventID: UUID?

    init(model: AppModel) {
        self.model = model
        fans = NativeFanControls(model: model)
        curve = NativeCurveControls(model: model)
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.size
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let surface = NativePanelSurface(frame: NSRect(origin: .zero, size: Self.size))
        view = LiquidGlass.surface(content: surface, size: Self.size)
        view.frame = NSRect(origin: .zero, size: Self.size)

        let icon = NSImageView(image: NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        icon.setAccessibilityElement(false)
        NativeUI.size(icon, width: 18, height: 18)
        let header = NativeUI.stack(.horizontal, spacing: 8, views: [icon, NativeUI.label("FanMacly", size: 14, weight: .semibold), NativeUI.spacer(), settings])
        NativeUI.size(header, height: LiquidGlass.available ? 28 : 20)
        configureSettings()

        let readings = NativeUI.stack(.horizontal, spacing: 16, views: [
            metric("CPU", field: cpu), metric("GPU", field: gpu), metric("Батарея", field: battery)
        ])
        readings.distribution = .fillEqually
        NativeUI.size(readings, height: 42)

        navigation.target = self
        navigation.action = #selector(selectPage)
        navigation.selectedSegment = 0
        navigation.segmentDistribution = .fillEqually
        navigation.controlSize = .small
        navigation.font = .systemFont(ofSize: 12)
        navigation.setAccessibilityLabel("Раздел панели")
        NativeUI.size(navigation, height: 24)
        let navigationView: NSView
        if LiquidGlass.available {
            let row = NativeUI.stack(.horizontal, spacing: 6)
            row.distribution = .fillEqually
            for (index, title) in ["Вентиляторы", "Профиль", "Датчики"].enumerated() {
                let button = NSButton(title: title, target: self, action: #selector(selectGlassPage(_:)))
                button.setButtonType(.pushOnPushOff)
                button.tag = index
                button.font = .systemFont(ofSize: 12, weight: .medium)
                button.state = index == 0 ? .on : .off
                LiquidGlass.button(button)
                button.bezelColor = index == 0 ? .controlAccentColor : nil
                button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
                glassTabs.append(button)
                let tab = LiquidGlass.tab(button, selected: index == 0)
                glassTabSurfaces.append(tab)
                row.addArrangedSubview(tab)
            }
            navigationView = LiquidGlass.group(row, height: 32)
        } else { navigationView = navigation }
        // Cache the actual views, but mount exactly one. AppKit's crossfade of
        // live vibrant controls while NSPopover resizes produces ghost text and
        // overlapping editors, especially when another tab is clicked mid-fade.
        pages = [fans, curve, sensors]
        pageContainer.wantsLayer = true
        pageContainer.layer?.masksToBounds = true
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        NativeUI.fill(fans, in: pageContainer)
        contentHeight = pageContainer.heightAnchor.constraint(equalToConstant: 124)
        contentHeight.isActive = true

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        NativeUI.size(progress, width: 14, height: 14)
        NativeUI.size(statusIcon, width: 14, height: 14)
        status.maximumNumberOfLines = 2
        status.usesSingleLineMode = false
        status.lineBreakMode = .byWordWrapping
        status.cell?.wraps = true
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [helperButton, dismissButton] {
            LiquidGlass.button(button)
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        footer = NativeUI.stack(.horizontal, spacing: 7, views: [progress, statusIcon, status, NativeUI.spacer(), helperButton, dismissButton])
        NativeUI.size(footer, height: 30)
        footerDivider = NativeUI.separator()
        footer.isHidden = true
        footerDivider.isHidden = true
        let stack = NativeUI.stack(.vertical, spacing: 12, views: [header, readings, navigationView, pageContainer, footerDivider, footer])
        rootStack = stack
        stack.alignment = .leading
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 12)
        ])
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        observeModel()
        Task { [weak self] in
            let enabled = await AppServices.shared.loginStatus()
            self?.loginEnabled = enabled
            self?.refreshSettings()
        }
    }
    private func metric(_ title: String, field: NSTextField) -> NSView {
        let caption = NativeUI.label(title, size: 11, secondary: true)
        let stack = NativeUI.stack(.vertical, spacing: 3, views: [caption, field])
        field.setAccessibilityLabel("Температура: \(title)")
        return stack
    }
    private func observeModel() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleUpdate() }
        }
    }
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.observeModel()
        }
    }
    private func render() {
        NativeUI.text(cpu, temperature(model.cpuTemperature))
        NativeUI.text(gpu, temperature(model.snapshot.temperature(.gpu)))
        NativeUI.text(battery, temperature(model.snapshot.temperature(.battery)))
        cpu.toolTip = model.cpuDiagnosticText
        fans.update()
        curve.update()
        sensors.update(model.snapshot)
        let pending = model.controlPending
        let event = helper.status.thermalEvent.flatMap { $0.id == dismissedThermalEventID ? nil : $0 }
        let thermalRestoring = event != nil && helper.status.restoring == true
        let message = helper.error ?? model.snapshot.error ?? helper.status.message ?? model.exportError ?? event?.message
        // Ordinary requests use the reserved inline indicator. Only actionable
        // errors, safety notices and connection setup need the footer.
        footer.isHidden = message == nil && helper.connected
        footerDivider.isHidden = footer.isHidden
        progress.isHidden = footer.isHidden || !pending || (message != nil && !thermalRestoring)
        if !progress.isHidden { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        statusIcon.isHidden = message == nil
        statusIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Предупреждение")
        statusIcon.contentTintColor = .systemOrange
        dismissButton.isHidden = helper.error == nil && model.exportError == nil && event == nil
        helperButton.isHidden = helper.connected || helper.serviceStatus == .enabled || message != nil
        helperButton.title = helper.serviceStatus == .requiresApproval ? "Разрешить…" : "Включить…"
        let text: String
        if thermalRestoring { text = "Защита: возвращаем управление macOS…" }
        else if let message { text = message }
        else if !helper.connected { text = helper.serviceStatus == .enabled ? "Подключаем помощника…" : "Для управления нужен системный помощник." }
        else { text = model.modeTitle }
        NativeUI.text(status, text)
        status.toolTip = event?.detail ?? text
        refreshSettings()
        resizePanel()
    }
    @objc private func selectPage() {
        let selected = navigation.selectedSegment
        guard (0..<3).contains(selected), selected != page else { return }
        // Commit field editing before detaching its page; otherwise AppKit's
        // shared field editor can outlive the search field on the old page.
        view.window?.makeFirstResponder(nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageContainer.layer?.removeAnimation(forKey: "pageReveal")
        pages[page].removeFromSuperview()
        page = selected
        let incoming = pages[selected]
        incoming.frame = NSRect(x: 0, y: 0, width: pageContainer.bounds.width, height: selectedPageHeight)
        NativeUI.fill(incoming, in: pageContainer)
        resizePanel()
        view.layoutSubtreeIfNeeded()
        CATransaction.commit()

        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // One opaque page moves a few points. No alpha animation of native
            // controls, outgoing-page overlap, delayed work or animated layout.
            let reveal = CABasicAnimation(keyPath: "transform.translation.y")
            reveal.fromValue = 4
            reveal.toValue = 0
            reveal.duration = 0.14
            reveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
            reveal.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            pageContainer.layer?.add(reveal, forKey: "pageReveal")
        }
    }
    private var selectedPageHeight: CGFloat {
        switch page {
        case 0: return fans.contentHeight
        case 1: return curve.contentHeight
        default: return 310
        }
    }
    @objc private func selectGlassPage(_ sender: NSButton) {
        navigation.selectedSegment = sender.tag
        for button in glassTabs {
            button.state = button.tag == sender.tag ? .on : .off
            button.bezelColor = button.tag == sender.tag ? .controlAccentColor : nil
            LiquidGlass.selectTab(glassTabSurfaces[button.tag], selected: button.tag == sender.tag)
        }
        selectPage()
    }
    private func resizePanel() {
        guard rootStack != nil, contentHeight != nil else { return }
        contentHeight.constant = selectedPageHeight
        // Calculate from the new state, not the old constrained layout. This
        // also covers a footer appearing in the same turn as manual controls.
        let header: CGFloat = LiquidGlass.available ? 28 : 20
        let navigation: CGFloat = LiquidGlass.available ? 32 : 24
        let footerHeight: CGFloat = footer.isHidden ? 0 : 55
        let size = NSSize(width: Self.size.width, height: ceil(header + 42 + navigation + selectedPageHeight + 36 + 24 + footerHeight))
        if abs(lastContentSize.height - size.height) > 0.5 {
            lastContentSize = size
            // The popover owner changes both sizes with native resizing
            // disabled. Setting preferredContentSize here first would start
            // an automatic animated resize before the explicit callback.
            if let onPreferredSizeChange { onPreferredSizeChange(size) }
            else { preferredContentSize = size }
        }
    }
    private func configureSettings() {
        settings.bezelStyle = .texturedRounded
        settings.isBordered = false
        LiquidGlass.menu(settings)
        settings.controlSize = .small
        settings.setAccessibilityLabel("Настройки FanMacly")
        settings.toolTip = "Настройки FanMacly"
        NativeUI.size(settings, width: LiquidGlass.available ? 28 : 24, height: LiquidGlass.available ? 28 : 20)
        (settings.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Настройки")
        menu.addItem(title)
        loginItem = action("Открывать при входе", #selector(toggleLogin))
        menu.addItem(loginItem)
        menu.addItem(.separator())
        animationItem = action("Вращать значок вентилятора", #selector(toggleIconAnimation))
        temperatureItem = action("Показывать температуру CPU", #selector(toggleIconTemperature))
        menu.addItem(animationItem); menu.addItem(temperatureItem)
        let speed = NSMenuItem(title: "Скорость анимации", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu(); speedMenu.autoenablesItems = false
        for (index, value) in MenuBarSettings.AnimationSpeed.allCases.enumerated() {
            let item = action(value.title, #selector(selectAnimationSpeed(_:)))
            item.tag = index; speedMenu.addItem(item); speedItems.append(item)
        }
        speed.submenu = speedMenu; menu.addItem(speed)
        menu.addItem(.separator())
        menu.addItem(action("Как считается температура CPU…", #selector(explainCPU)))
        menu.addItem(action("Экспортировать датчики…", #selector(exportSensors)))
        menu.addItem(action("Разрешения macOS…", #selector(openApproval)))
        helperItem = action("Отключить помощника", #selector(toggleHelper))
        menu.addItem(helperItem)
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.5.0"
        let about = NSMenuItem(title: "FanMacly \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        let quit = action("Завершить FanMacly", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        settings.menu = menu
    }
    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }
    private func refreshSettings() {
        animationItem?.state = model.menuBarSettings.animated ? .on : .off
        temperatureItem?.state = model.menuBarSettings.showsTemperature ? .on : .off
        for item in speedItems {
            item.state = MenuBarSettings.AnimationSpeed.allCases[item.tag] == model.menuBarSettings.speed ? .on : .off
            item.isEnabled = model.menuBarSettings.animated
        }
        loginItem?.state = loginEnabled ? .on : .off
        loginItem?.isEnabled = !loginBusy
        helperItem?.title = helper.serviceStatus == .enabled || helper.serviceStatus == .requiresApproval ? "Отключить помощника" : "Включить управление…"
    }
    @objc private func toggleLogin() {
        guard !loginBusy else { return }
        loginBusy = true
        refreshSettings()
        Task { [weak self] in
            guard let self else { return }
            defer { self.loginBusy = false; self.refreshSettings() }
            do { self.loginEnabled = try await AppServices.shared.setLogin(!self.loginEnabled) }
            catch { self.model.exportError = error.localizedDescription }
        }
    }
    @objc private func exportSensors() { model.exportSnapshot() }
    @objc private func toggleIconAnimation() {
        model.menuBarSettings.animated.toggle(); model.saveMenuBarSettings()
    }
    @objc private func toggleIconTemperature() {
        model.menuBarSettings.showsTemperature.toggle(); model.saveMenuBarSettings()
    }
    @objc private func selectAnimationSpeed(_ sender: NSMenuItem) {
        guard MenuBarSettings.AnimationSpeed.allCases.indices.contains(sender.tag) else { return }
        model.menuBarSettings.speed = MenuBarSettings.AnimationSpeed.allCases[sender.tag]
        model.saveMenuBarSettings()
    }
    @objc private func explainCPU() {
        let alert = NSAlert()
        alert.messageText = "Температура CPU"
        alert.informativeText = model.cpuDiagnosticText
        alert.addButton(withTitle: "Понятно")
        alert.addButton(withTitle: "Справочник источника")
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "https://github.com/dkorunic/iSMC/blob/master/smc/sensors.go") { NSWorkspace.shared.open(url) }
    }
    @objc private func openApproval() { helper.openApproval() }
    @objc private func toggleHelper() {
        if helper.serviceStatus == .enabled || helper.serviceStatus == .requiresApproval { Task { await helper.unregister() } }
        else { helper.register() }
    }
    @objc private func enableHelper() {
        if helper.serviceStatus == .requiresApproval { helper.openApproval() } else { helper.register() }
    }
    @objc private func dismissMessage() {
        dismissedThermalEventID = helper.status.thermalEvent?.id
        helper.error = nil; model.exportError = nil
        render()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

@MainActor enum NativeUI {
    static func label(_ value: String, size: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular, secondary: Bool = false, numeric: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = numeric ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
    static func text(_ field: NSTextField, _ value: String) { if field.stringValue != value { field.stringValue = value } }
    static func stack(_ orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat, views: [NSView] = []) -> NSStackView {
        let stack = orientation == .vertical ? NativeColumn(views: views) : NSStackView(views: views)
        stack.orientation = orientation
        stack.alignment = orientation == .horizontal ? .centerY : .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        if orientation == .vertical {
            for view in views {
                view.translatesAutoresizingMaskIntoConstraints = false
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        return stack
    }
    static func append(_ view: NSView, to column: NSStackView) {
        column.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }
    static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        size(line, height: 1)
        return line
    }
    static func size(_ view: NSView, width: CGFloat? = nil, height: CGFloat? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        if let width { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }
    static func fill(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
}

@MainActor private final class NativeColumn: NSStackView {
    override var isFlipped: Bool { true }
}

/// Keep the top edge fixed while AppKit animates the popover height.
@MainActor private final class NativePanelSurface: NSView {
    override var isFlipped: Bool { true }
}
