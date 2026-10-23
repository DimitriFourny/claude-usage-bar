import AppKit
import SwiftUI

/// How much of a window is left: below 25% is low (light orange), below 10% critical (light red).
enum UsageLevel {
    case normal, low, critical

    init(remaining: Double) {
        // Classify what the user sees: 24.6 is displayed as "25%" and must not be orange.
        switch remaining.rounded() {
        case ..<10: self = .critical
        case ..<25: self = .low
        default: self = .normal
        }
    }

    /// Menu bar tint; `nil` keeps the system menu bar text color.
    var menuBarColor: NSColor? {
        switch self {
        case .normal: nil
        case .low: .usageLightOrange
        case .critical: .usageLightRed
        }
    }

    var popoverColor: Color {
        switch self {
        case .normal: .green
        case .low: Color(nsColor: .usageLightOrange)
        case .critical: Color(nsColor: .usageLightRed)
        }
    }
}

extension NSColor {
    /// Pastel on dark backgrounds; deeper on light ones, where pastels would be unreadable.
    static let usageLightOrange = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 1.00, green: 0.72, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.88, green: 0.48, blue: 0.05, alpha: 1)
    }

    static let usageLightRed = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 1.00, green: 0.50, blue: 0.48, alpha: 1)
            : NSColor(srgbRed: 0.86, green: 0.18, blue: 0.16, alpha: 1)
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
