import WidgetKit
import SwiftUI

@main
struct FanMaclyControlsBundle: WidgetBundle {
    var body: some Widget {
        AutomaticCoolingControl()
        ProfileCoolingControl()
        MaximumCoolingControl()
        FanStatusWidget()
    }
}

struct AutomaticCoolingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.fanmacly.controls.automatic") {
            ControlWidgetButton(action: FanModeControlIntent(.automatic)) {
                Label("Авто", image: "FanAutomatic")
            }
        }
        .displayName("Авто")
        .description("Вернуть управление вентиляторами macOS.")
    }
}
struct ProfileCoolingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.fanmacly.controls.profile") {
            ControlWidgetButton(action: FanModeControlIntent(.profile)) {
                Label("Профиль", image: "FanProfile")
            }
        }
        .displayName("Профиль")
        .description("Включить текущий температурный профиль FanMacly.")
    }
}
struct MaximumCoolingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.fanmacly.controls.maximum") {
            ControlWidgetButton(action: FanModeControlIntent(.maximum)) {
                Label("Максимум", image: "FanMaximum")
            }
        }
        .displayName("Максимум")
        .description("Установить максимальные обороты всех вентиляторов.")
    }
}
