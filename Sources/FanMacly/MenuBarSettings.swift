import Foundation

struct MenuBarSettings: Codable, Equatable {
    enum AnimationSpeed: String, Codable, CaseIterable {
        case calm, normal, fast
        var title: String {
            switch self { case .calm: return "Спокойная"; case .normal: return "Обычная"; case .fast: return "Быстрая" }
        }
        var multiplier: Double {
            switch self { case .calm: return 0.6; case .normal: return 1; case .fast: return 1.5 }
        }
    }
    var animated = true
    var showsTemperature = false
    var speed: AnimationSpeed = .normal
}
