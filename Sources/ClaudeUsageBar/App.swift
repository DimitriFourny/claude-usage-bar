import AppKit
import Observation
import SwiftUI

@main
@MainActor
enum ClaudeUsageBarApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = StatusItemController()
        withExtendedLifetime(controller) { app.run() }
    }
}

/// AppKit status item instead of SwiftUI's `MenuBarExtra`: its label is rendered as a template image,
/// which drops colors, while an `NSStatusBarButton` attributed title keeps them.
@MainActor
final class StatusItemController: NSObject {
    private let model = UsageModel()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    override init() {
        super.init()
        let hosting = NSHostingController(rootView: UsagePopover(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.image = .clawd
        item.button?.imagePosition = .imageLeading
        updateTitle()
    }

    /// Re-renders whenever any model property read by `title()` changes.
    private func updateTitle() {
        let title = withObservationTracking { self.title() } onChange: { [weak self] in
            Task { @MainActor in self?.updateTitle() }
        }
        item.button?.attributedTitle = title
    }

    private func title() -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let result = NSMutableAttributedString()
        func append(_ text: String, color: NSColor? = nil) {
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color ?? .labelColor]))
        }

        guard model.hasSession else {
            append("Claude: sign in")
            return result
        }
        guard let fiveHour = model.fiveHour, let weekly = model.weekly else {
            append(model.error == nil ? "Claude …" : "Claude ⚠︎")
            return result
        }
        append("5h ")
        append(UsageModel.percent(fiveHour.remaining), color: UsageLevel(remaining: fiveHour.remaining).menuBarColor)
        append(" · 7d ")
        append(UsageModel.percent(weekly.remaining), color: UsageLevel(remaining: weekly.remaining).menuBarColor)
        if model.error != nil { append(" ⚠︎") }
        return result
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refreshIfStale()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
