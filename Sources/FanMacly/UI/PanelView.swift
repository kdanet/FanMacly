import SwiftUI
import FanMaclyCore

/// The menu bar panel: state, temperatures, one-click modes, boost and fans.
struct PanelView: View {
    let model: AppModel
    var openWindow: (AppWindow) -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(model: model, openWindow: openWindow, quit: quit)
            PanelBanners(model: model, openWindow: openWindow)
            TemperatureRow(model: model)
            ModePicker(model: model, openWindow: openWindow)
            BoostRow(model: model)
            FansSection(model: model)
            Divider().opacity(0.5)
            HStack(spacing: 4) {
                FooterButton(title: "Профили", symbol: "chart.xyaxis.line") { openWindow(.profiles) }
                FooterButton(title: "Монитор", symbol: "waveform.path.ecg") { openWindow(.monitor) }
                FooterButton(title: "Настройки", symbol: "gearshape") { openWindow(.settings) }
            }
        }
        .padding(14)
        .frame(width: 340)
        .animation(.easeOut(duration: 0.18), value: model.controlState)
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
    }
}

// MARK: - Header

private struct PanelHeader: View {
    let model: AppModel
    var openWindow: (AppWindow) -> Void
    var quit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle().fill(stateColor.opacity(0.16))
                FanGlyph(rpm: model.averageRPM, color: stateColor, size: 21)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title(for: model.displayedSelection))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                // No live numbers here, so the wrapping never jumps.
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let speed = model.averageRPM {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(rpmNumber(speed))
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.default, value: Int(speed / 10))
                    Text("об/мин").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Средние обороты: \(rpm(speed))")
            }
            Menu {
                Button("Профили…") { openWindow(.profiles) }
                Button("Монитор…") { openWindow(.monitor) }
                Button("Настройки…") { openWindow(.settings) }
                Divider()
                Button("Завершить FanMacly", action: quit)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusEffectDisabled()
            .accessibilityLabel("Меню FanMacly")
        }
    }

    private var stateColor: Color {
        switch model.controlState {
        case .active: return model.helper.status.coolingBoost ? .orange : .accentColor
        case .suspended, .reacquiring: return .orange
        case .applying: return .accentColor
        case .macOS, .connecting, .setupNeeded: return .secondary
        }
    }

    private var subtitle: String {
        switch model.controlState {
        case .setupNeeded: return "Только мониторинг"
        case .connecting: return "Подключение к системному компоненту…"
        case .macOS:
            if let until = model.boostUntil { return "Буст до \(until.formatted(date: .omitted, time: .shortened))" }
            return "Управляет macOS"
        case .applying: return "Применяем…"
        case .reacquiring: return "macOS забрала вентилятор — возвращаем управление"
        case .suspended(let suspension):
            if let date = suspension.resumeDate, date > Date() {
                return "Временно у macOS · повтор в \(date.formatted(date: .omitted, time: .shortened))"
            }
            return "Временно у macOS"
        case .active:
            if let reason = model.helper.status.boostReason, model.helper.status.coolingBoost {
                return "Максимальное охлаждение · \(reason)"
            }
            var text = "Управляет FanMacly"
            if let rule = model.overrideReason { text += " · \(rule)" }
            return text
        }
    }
}

// MARK: - Banners

private struct PanelBanners: View {
    let model: AppModel
    var openWindow: (AppWindow) -> Void

    var body: some View {
        VStack(spacing: 8) {
            if case .setupNeeded = model.controlState { setupBanner }
            if case .suspended(let suspension) = model.controlState {
                Banner(style: .warning,
                       title: suspension.message,
                       message: suspension.resumeDate.map { date in
                           date > Date() ? "Режим вернётся сам около \(date.formatted(date: .omitted, time: .shortened)), если условия будут стабильны."
                                        : "Ждём стабильных показаний, чтобы вернуть режим." } ?? "Нажмите «Вернуть», чтобы попробовать снова.",
                       actions: [("Вернуть «\(model.title(for: model.activeSelection))»", { model.resume() }),
                                 ("Журнал", { openWindow(.monitor) })])
            }
            ForEach(model.visibleConflicts) { conflict in
                Banner(style: .warning, title: "Обнаружено: \(conflict.name)", message: conflict.detail,
                       onDismiss: { model.dismissConflict(conflict) })
            }
            if let error = model.transientError {
                Banner(style: .error, title: error, onDismiss: { model.transientError = nil })
            } else if model.helper.connected, let message = model.helper.status.message {
                // The helper's own state: it goes away when the helper clears it.
                Banner(style: .error, title: message)
            }
        }
    }

    /// A registration failure worth showing instead of the generic hint.
    private var setupError: String? {
        guard let error = model.helper.error, error != "Нужно обновить системный компонент FanMacly." else { return nil }
        return error
    }

    @ViewBuilder private var setupBanner: some View {
        let helper = model.helper
        if !helper.signedForControl {
            Banner(style: .info, title: "Это сборка без подписи",
                   message: "Мониторинг работает. Для управления вентиляторами нужна сборка с подписью Apple Development или Developer ID.")
        } else if helper.needsUpdate {
            Banner(style: .info, title: "Обновите системный компонент",
                   message: setupError ?? "Компонент управления устарел после обновления FanMacly.",
                   actions: [("Обновить", { helper.reinstall() })])
        } else if helper.serviceStatus == .requiresApproval {
            Banner(style: .info, title: "Разрешите FanMacly в Системных настройках",
                   message: "Основные → Объекты входа и расширения → разрешить FanMacly.",
                   actions: [("Открыть настройки", { helper.openApproval() })])
        } else {
            Banner(style: .info, title: "Управление вентиляторами выключено",
                   message: setupError ?? "Установите системный компонент: он меняет обороты и следит за безопасностью, даже когда панель закрыта.",
                   actions: [("Установить", { helper.register() })])
        }
    }
}

// MARK: - Temperatures

private struct TemperatureRow: View {
    let model: AppModel
    private var peakDetail: String {
        let peak = model.helper.connected ? model.helper.status.peakCPUReading : model.snapshot.cpuPeakReading
        return peak.map { "ядро до \(Int($0.celsius.rounded()))°" } ?? " "
    }
    var body: some View {
        HStack(spacing: 8) {
            MetricView(title: "CPU", value: temperature(model.cpuTemperature), level: .cpu(model.cpuTemperature),
                       detail: model.power?.cpuWatts.map(watts) ?? peakDetail)
                .help(model.cpuDiagnosticText)
            MetricView(title: "GPU", value: temperature(model.snapshot.temperature(.gpu)), level: .gpu(model.snapshot.temperature(.gpu)),
                       detail: model.power?.gpuWatts.map(watts) ?? " ")
            MetricView(title: "Аккумулятор", value: temperature(model.snapshot.temperature(.battery)), level: .battery(model.snapshot.temperature(.battery)),
                       detail: AutomationController.onBattery ? "от аккумулятора" : "от сети")
        }
    }
}

// MARK: - Modes

private struct ModePicker: View {
    let model: AppModel
    var openWindow: (AppWindow) -> Void

    var body: some View {
        let displayed = model.displayedSelection
        let pending = model.pendingSelection
        let disabled = !model.canControl
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Режим")
            HStack(spacing: 6) {
                ModeTile(title: "Авто", symbol: "a.circle", selected: displayed == .automatic, pending: pending == .automatic) {
                    model.select(.automatic)
                }
                ForEach(CoolingPreset.allCases) { preset in
                    ModeTile(title: preset.shortTitle, symbol: preset.symbol, selected: displayed == .preset(preset),
                             pending: pending == .preset(preset), disabled: disabled) { model.select(.preset(preset)) }
                }
                ModeTile(title: "Макс", symbol: "wind", selected: displayed == .maximum, pending: pending == .maximum, disabled: disabled) {
                    model.select(.maximum)
                }
                customTile(displayed: displayed, disabled: disabled)
            }
        }
    }

    private func customTile(displayed: ModeSelection, disabled: Bool) -> some View {
        let custom: Bool = {
            switch displayed { case .profile, .manual: return true; default: return false }
        }()
        return Menu {
            if !model.profileLibrary.profiles.isEmpty {
                Section("Мои профили") {
                    ForEach(model.profileLibrary.profiles) { profile in
                        Button {
                            model.select(.profile(profile.id))
                        } label: {
                            if displayed == .profile(profile.id) { Label(profile.name, systemImage: "checkmark") } else { Text(profile.name) }
                        }
                    }
                }
            }
            Button {
                model.select(.manual)
            } label: {
                if displayed == .manual { Label("Вручную", systemImage: "checkmark") } else { Text("Вручную") }
            }
            Divider()
            Button("Создать или изменить профиль…") { openWindow(.profiles) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: custom ? model.symbol(for: displayed) : "ellipsis").font(.system(size: 15, weight: .medium)).frame(height: 18)
                Text(custom ? shortName(displayed) : "Свой").font(.system(size: 10.5, weight: custom ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(custom ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(custom ? Color.accentColor : Color.primary.opacity(0.055)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel("Свои профили и ручной режим")
    }

    private func shortName(_ selection: ModeSelection) -> String {
        if case .manual = selection { return "Ручной" }
        return model.title(for: selection)
    }
}

// MARK: - Boost

private struct BoostRow: View {
    let model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill").foregroundStyle(model.boostUntil == nil ? Color.secondary : Color.orange)
            if let until = model.boostUntil {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Буст: максимум оборотов").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 3) {
                        Text("ещё")
                        Text(timerInterval: Date()...until, countsDown: true).monospacedDigit()
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Остановить") { model.cancelBoost() }.controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Буст").font(.system(size: 12, weight: .medium))
                    Text("Максимум на 5–60 минут").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu("Включить") {
                    ForEach([5, 10, 30, 60], id: \.self) { minutes in
                        Button(minutes < 60 ? "На \(minutes) мин" : "На 1 час") { model.startBoost(minutes: minutes) }
                    }
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .fixedSize()
                .disabled(!model.canControl)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .card(cornerRadius: 10, tint: model.boostUntil == nil ? nil : .orange)
    }
}

// MARK: - Fans

private struct FansSection: View {
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Вентиляторы", trailing: manual ? AnyView(linkToggle) : nil)
            if model.snapshot.fans.isEmpty {
                Text(model.loading ? "Читаем датчики…" : model.snapshot.fanCount == 0 ? "В этом Mac нет вентиляторов." : "Вентиляторы недоступны.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.snapshot.fans.enumerated()), id: \.element.id) { index, fan in
                        if index > 0 { Divider().padding(.leading, 30) }
                        FanRow(model: model, fan: fan, manual: manual)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .card(cornerRadius: 10)
            }
        }
    }
    private var manual: Bool { model.displayedSelection == .manual && model.boostUntil == nil }
    private var linkToggle: some View {
        Toggle("Синхронно", isOn: Binding(get: { model.manualLinked }, set: { model.manualLinked = $0 }))
            .toggleStyle(.checkbox).controlSize(.mini).font(.system(size: 10.5))
    }
}

private struct FanRow: View {
    let model: AppModel
    let fan: FanReading
    let manual: Bool
    @State private var position: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                FanGlyph(rpm: fan.current)
                Text(fan.name).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 6)
                Sparkline(values: model.history.fanSeries(fan.id, duration: 600))
                    .frame(width: 64, height: 16)
                Text(rpmNumber(fan.current))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 44, alignment: .trailing)
                    .contentTransition(.numericText())
                Text("об/мин").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(caption).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary).padding(.leading, 26)
            if manual { manualControls.padding(.leading, 26) }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var caption: String {
        let range = "\(rpmNumber(fan.safeMinimum))–\(rpmNumber(fan.maximum))"
        if model.helper.connected, model.helper.status.mode != .system, let target = model.helper.status.targets[fan.id] {
            return "Цель \(rpmNumber(target)) · диапазон \(range)"
        }
        return "Диапазон \(range) об/мин"
    }

    private var manualControls: some View {
        let scale = ManualFanSpeedScale(fan: fan)
        let desired = model.manualTargets[fan.id] ?? fan.current ?? fan.safeMinimum
        return HStack(spacing: 6) {
            Slider(value: Binding(get: { position ?? scale.position(for: desired) }, set: { value in
                position = value
                model.setManualTarget(scale.rpm(at: value), fan: fan.id, commit: false)
            }), in: 0...100) { editing in
                if !editing, let position {
                    model.setManualTarget(scale.rpm(at: position), fan: fan.id, commit: true)
                    self.position = nil
                }
            }
            .controlSize(.small)
            .disabled(!model.canControl)
            .accessibilityLabel("Обороты: \(fan.name)")
            .accessibilityValue(rpm(model.manualTargets[fan.id]))
            Text(desired == 0 ? "Стоп" : rpmNumber(desired))
                .font(.system(size: 10.5).monospacedDigit()).frame(width: 40, alignment: .trailing)
            Menu {
                Button("Остановить (0 об/мин)") { model.setManualTarget(0, fan: fan.id, commit: true) }
                Button("Минимум") { model.setManualTarget(fan.safeMinimum, fan: fan.id, commit: true) }
                Button("Максимум") { model.setManualTarget(fan.maximum ?? fan.safeMinimum, fan: fan.id, commit: true) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Быстрые значения")
        }
    }
}
