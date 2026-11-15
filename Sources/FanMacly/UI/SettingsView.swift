import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FanMaclyCore

struct SettingsView: View {
    let model: AppModel
    var body: some View {
        TabView {
            GeneralSettings(model: model).tabItem { Label("Основные", systemImage: "gearshape") }
            MenuBarSettingsView(model: model).tabItem { Label("Строка меню", systemImage: "menubar.rectangle") }
            AutomationSettingsView(model: model).tabItem { Label("Автоматизация", systemImage: "wand.and.stars") }
            HelperSettings(model: model).tabItem { Label("Компонент", systemImage: "lock.shield") }
            DiagnosticsSettings(model: model).tabItem { Label("Диагностика", systemImage: "stethoscope") }
        }
        .padding(20)
        .frame(width: 560, height: 470)
    }
}

@MainActor private func binding<T>(_ model: AppModel, _ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(get: { model.settings[keyPath: keyPath] }, set: { model.settings[keyPath: keyPath] = $0 })
}

private struct GeneralSettings: View {
    let model: AppModel
    @State private var login = false
    @State private var loginError: String?
    var body: some View {
        Form {
            Section {
                Toggle("Открывать FanMacly при входе в систему", isOn: Binding(get: { login }, set: { value in
                    Task {
                        do { login = try await AppServices.shared.setLogin(value); loginError = nil }
                        catch { loginError = error.localizedDescription }
                    }
                }))
                if let loginError { Text(loginError).foregroundStyle(.red).font(.caption) }
                Toggle("Восстанавливать последний режим при запуске", isOn: binding(model, \.restoreOnLaunch))
                Toggle("Возвращать управление macOS при выходе из FanMacly", isOn: binding(model, \.releaseOnQuit))
            }
            Section {
                Toggle("Возобновлять режим автоматически после защиты", isOn: Binding(get: { model.settings.autoResume }, set: {
                    model.settings.autoResume = $0
                    model.applyEffective()
                }))
                Text("Если FanMacly временно отдал управление macOS (перегрев, сбой датчиков, вмешательство другого приложения), режим вернётся сам через минуту стабильной работы — не чаще трёх раз за 30 минут.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Надёжность") }
            Section {
                Toggle("Когда режим приостановлен", isOn: binding(model, \.notifyOnSuspension))
                Toggle("Когда режим возобновлён", isOn: binding(model, \.notifyOnResume))
                Toggle("Когда найдено другое приложение управления вентиляторами", isOn: binding(model, \.notifyOnConflict))
            } header: { Text("Уведомления") }
        }
        .formStyle(.grouped)
        .task { login = await AppServices.shared.loginStatus() }
    }
}

private struct MenuBarSettingsView: View {
    let model: AppModel
    private func bind<T>(_ keyPath: WritableKeyPath<MenuBarSettings, T>) -> Binding<T> {
        Binding(get: { model.menuBarSettings[keyPath: keyPath] }, set: { model.menuBarSettings[keyPath: keyPath] = $0 })
    }
    var body: some View {
        Form {
            Picker("Показывать", selection: bind(\.display)) {
                ForEach(MenuBarSettings.Display.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Вращать значок вентилятора", isOn: bind(\.animated))
            Picker("Скорость вращения", selection: bind(\.speed)) {
                ForEach(MenuBarSettings.AnimationSpeed.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!model.menuBarSettings.animated)
            Toggle("Подсвечивать значок, когда управляет FanMacly", isOn: bind(\.tintsWhenActive))
            Text("Цвет значка: обычный — управляет macOS; акцентный — свой режим; оранжевый — буст, максимальное охлаждение или режим приостановлен.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct AutomationSettingsView: View {
    let model: AppModel
    private func bind(_ keyPath: WritableKeyPath<AutomationSettings, ModeSelection?>) -> Binding<String> {
        Binding(get: { model.automationSettings[keyPath: keyPath]?.key ?? "" },
                set: { model.automationSettings[keyPath: keyPath] = $0.isEmpty ? nil : ModeSelection(key: $0) })
    }
    var body: some View {
        Form {
            Toggle("Выбирать режим автоматически", isOn: Binding(get: { model.automationSettings.enabled }, set: { model.automationSettings.enabled = $0 }))
            Section {
                picker("От сети", bind(\.onPower))
                picker("От аккумулятора", bind(\.onBattery))
                picker("Режим энергосбережения", bind(\.lowPowerMode))
                Text("Сейчас: \(model.automation.powerDescription). Правило срабатывает при смене источника питания; выбранный вручную режим действует до следующей смены.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Питание") }
            .disabled(!model.automationSettings.enabled)
            Section {
                ForEach(model.automationSettings.appRules) { rule in
                    HStack {
                        Text(rule.name)
                        Spacer()
                        Picker("", selection: Binding(get: { rule.selection.key }, set: { key in
                            if let index = model.automationSettings.appRules.firstIndex(where: { $0.id == rule.id }), let value = ModeSelection(key: key) {
                                model.automationSettings.appRules[index].selection = value
                            }
                        })) {
                            ForEach(model.selectionOptions) { Text($0.title).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 180)
                        Button { model.automationSettings.appRules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Удалить правило")
                            .accessibilityLabel("Удалить правило")
                    }
                }
                Button("Добавить приложение…") { addApp() }
                Text("Пока любое из этих приложений запущено, FanMacly включает указанный режим. Например: Xcode, Final Cut Pro или игры → «Прохладный». Режим из Фокусирования важнее правил.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Приложения") }
            .disabled(!model.automationSettings.enabled)
            Section {
                Text("FanMacly можно включать из приложения «Команды» и в фильтрах Фокусирования (Системные настройки → Фокусирование → Фильтры фокусирования → FanMacly).")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Команды и Фокусирование") }
        }
        .formStyle(.grouped)
    }

    private func picker(_ title: String, _ selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Не менять").tag("")
            ForEach(model.selectionOptions) { Text($0.title).tag($0.id) }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !model.automationSettings.appRules.contains(where: { $0.bundleID == id }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            model.automationSettings.appRules.append(.init(bundleID: id, name: name, selection: .preset(.cool)))
        }
    }
}

private struct HelperSettings: View {
    let model: AppModel
    var body: some View {
        let helper = model.helper
        Form {
            Section {
                LabeledContent("Состояние", value: state)
                LabeledContent("Протокол", value: HelperIdentity.protocolVersion)
                if helper.connected, let intent = helper.status.intent {
                    LabeledContent("Сохранённый режим", value: intent.displayName)
                }
                HStack {
                    if helper.serviceStatus == .enabled {
                        Button("Переустановить") { helper.reinstall() }
                        Button("Отключить", role: .destructive) {
                            Task {
                                model.select(.automatic)
                                try? await Task.sleep(for: .milliseconds(600))
                                await helper.unregister()
                            }
                        }
                    } else if helper.serviceStatus == .requiresApproval {
                        Button("Открыть Объекты входа") { helper.openApproval() }
                    } else {
                        Button("Установить") { helper.register() }.disabled(!helper.signedForControl)
                    }
                }
                Text("Системный компонент работает от root, меняет режим вентиляторов и сам следит за температурой. Он сохраняет выбранный режим и продолжает его, даже если панель закрыта, Mac уходил в сон или FanMacly перезапустился.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Системный компонент") }
            Section {
                if model.conflicts.isEmpty {
                    Label("Других приложений управления вентиляторами не найдено", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    ForEach(model.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(conflict.name, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(conflict.detail).font(.caption).foregroundStyle(.secondary)
                            Text(conflict.process).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                        }
                    }
                }
            } header: { Text("Конфликты") }
        }
        .formStyle(.grouped)
    }
    private var state: String {
        let helper = model.helper
        if !helper.signedForControl { return "Сборка без подписи — только мониторинг" }
        if helper.needsUpdate { return "Нужно обновить" }
        switch helper.serviceStatus {
        case .enabled: return helper.connected ? "Работает" : "Установлен, подключение…"
        case .requiresApproval: return "Ждёт разрешения в Системных настройках"
        case .notFound: return "Не найден в приложении"
        default: return "Не установлен"
        }
    }
}

private struct DiagnosticsSettings: View {
    let model: AppModel
    @State private var copied = false
    var body: some View {
        Form {
            Section {
                Text(model.cpuDiagnosticText).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } header: { Text("Как считается температура CPU") }
            Section {
                HStack {
                    Button(copied ? "Скопировано" : "Скопировать отчёт") {
                        Task {
                            let report = await model.diagnosticReport()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                            copied = true
                        }
                    }
                    Button("Экспорт датчиков JSON…") { model.exportSnapshot() }
                }
                Text("Подробный журнал: Консоль → подсистема app.fanmacly.helper.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Отчёт") }
        }
        .formStyle(.grouped)
    }
}
