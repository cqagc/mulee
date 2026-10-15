import SwiftUI

enum TaskProgressStyle {
    case accent, waiting, success, completed

    var color: Color {
        switch self {
        case .accent: .accentColor
        case .waiting: Theme.wait
        case .success: Theme.success
        case .completed: Color.secondary.opacity(0.45)
        }
    }
}
