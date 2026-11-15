# FanMacly

Утилита в строке меню для мониторинга температур и управления вентиляторами Mac с **Apple Silicon**. Работает на macOS 14 и новее; Intel не поддерживается. Нет сетевых запросов, аккаунтов, аналитики и сторонних зависимостей.

## Возможности

- **Режимы в один клик**: Авто (macOS), Тихо, Баланс, Холод, Макс, а также свои профили и ручной режим.
- **Буст** на 5–60 минут: максимум оборотов, затем возврат к прежнему режиму.
- **Надёжное управление.** Выбранный режим хранит системный компонент. Режим переживает закрытие панели, сон, перезапуск приложения и короткие сбои датчиков. Если macOS забирает вентилятор, компонент возвращает его. Защитные возвраты временные: режим восстанавливается сам. Подробности — в [docs/control-policy.md](docs/control-policy.md).
- **Понятный статус**: цветная иконка в строке меню, баннеры с причиной и кнопкой «Вернуть», уведомления и журнал событий.
- **Редактор профилей**: точки кривой перетаскиваются на графике, шкала до 100 °C, рядом с процентами видны обороты, отмечена текущая рабочая точка.
- **Монитор**: история температур, оборотов и мощности GPU/CPU за час, понятный список датчиков, журнал событий.
- **Автоматизация**: режим по питанию (сеть, аккумулятор, энергосбережение) и по запущенным приложениям. Режимом можно управлять из «Команд», Siri, фильтров Фокусирования и Пункта управления. Есть виджет рабочего стола.
- **Конфликты**: FanMacly предупреждает, если вентиляторами управляет другое приложение (например, Macs Fan Control).

## Сборка и установка

Нужны Xcode 27 / Command Line Tools с macOS SDK 27 и Swift 6.4. XcodeGen нужен только при изменении `Controls.project.yml`.

```sh
bash scripts/build.sh                      # ad-hoc: только мониторинг
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' bash scripts/build.sh
```

1. Скопируйте `build/FanMacly.app` в `/Applications` и откройте приложение.
2. Нажмите **Установить** в панели. macOS попросит разрешение в **Системные настройки → Основные → Объекты входа и расширения**.
3. После обновления с 0.x FanMacly сам заменит системный компонент: сменился протокол, теперь 1.0.5. Если не получится, в панели появится кнопка **Обновить**.

У подписанной сборки виджет рабочего стола получает данные через App Group `TEAMID.app.fanmacly`. Ad-hoc сборка не может управлять root-компонентом.

## Разработка

```sh
bash scripts/check.sh                       # сборка + все тесты
bash scripts/preview.sh --panel-window      # изолированная копия UI (свой bundle ID, без компонента)
bash scripts/preview.sh --open-window=profiles|monitor|settings
bash scripts/soak-test.sh 30                # 30 минут наблюдения за регистрами SMC (только чтение)
.build/debug/fanmacly-probe --watch=60      # построчный журнал FnMd/Ftst/целей/температур
.build/debug/fanmacly-probe --power         # мощность через IOReport
```

| Модуль | Назначение |
|---|---|
| `SMCBridge` | C-мост к IOKit/AppleSMC |
| `FanMaclyCore` | модели, `ControlPolicy`, `ThermalGuard`, `ControlEngine`, `FanModeController`, `PowerSampler` |
| `FanMaclyHelper` | root-компонент: XPC, сохранённое намерение, журнал восстановления |
| `FanMacly` | приложение: `AppModel`, SwiftUI-панель и окна, App Intents, автоматизация |
| `FanMaclyControls` | WidgetKit: кнопки Пункта управления и виджет рабочего стола (Xcode-проект из `Controls.project.yml`) |
| `FanMaclyProbe` | диагностика только на чтение |

## Документация

- [docs/control-policy.md](docs/control-policy.md) — пороги, состояния, захват `Ftst`, автовозобновление.
- [docs/improvement-plan.md](docs/improvement-plan.md) — анализ 0.9 и план 1.0.
- [CHANGELOG.md](CHANGELOG.md) — изменения.
- [docs/verification/](docs/verification/) — протоколы аппаратных проверок 0.x.

## Ограничения

Интерфейс AppleSMC не документирован Apple; ключи зависят от модели и прошивки. Неподдерживаемая запись завершается ошибкой, а не мнимым успехом. Счётчики мощности CPU (IOReport) на некоторых системах «замирают»; тогда FanMacly показывает пик температуры ядра вместо ватт.

## Источники

- Агрегаты CPU: [iSMC](https://github.com/dkorunic/iSMC/blob/master/smc/sensors.go), [OSHI #3535](https://github.com/oshi/oshi/pull/3535).
- Каналы датчиков: [Stats](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift), [VirtualSMC](https://github.com/acidanthera/VirtualSMC/blob/master/Docs/SMCSensorKeys.txt).
- Передача управления на Apple Silicon: [исследование Ftst](https://github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md), [MacGauge FanControl](https://github.com/StevenACZ/MacGauge/blob/main/Sources/MacFanCore/FanControl.swift), [sak0a/MacFanControl](https://github.com/sak0a/MacFanControl).
- Мощность: [macmon](https://github.com/vladkens/macmon).
- Apple: [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [ProcessInfo.ThermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum), [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos).
