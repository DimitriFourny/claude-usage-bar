import AppKit

extension NSImage {
    /// Clawd, Claude Code's pixel mascot, decoded from its terminal art (`▐▛███▜▌` / `▝▜█████▛▘` / `▘▘ ▝▝`).
    /// Grid is 18×10: a quadrant-block character is 2 cells wide and 2 tall, each cell 1 wide × 2 tall
    /// to keep the terminal's character aspect ratio.
    static let clawd: NSImage = {
        let rects: [(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)] = [
            (3, 0, 12, 2),                                  // head
            (3, 2, 2, 2), (6, 2, 6, 2), (13, 2, 2, 2),      // eye row, with the two eye gaps
            (1, 4, 16, 2),                                  // arms
            (3, 6, 12, 2),                                  // body
            (4, 8, 1, 2), (6, 8, 1, 2), (11, 8, 1, 2), (13, 8, 1, 2), // legs
        ]
        // 1.5 pt per cell: whole device pixels on Retina, so edges stay crisp.
        let scale: CGFloat = 1.5
        let image = NSImage(size: NSSize(width: 18 * scale, height: 10 * scale), flipped: true) { _ in
            NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1).setFill()
            for rect in rects {
                NSRect(x: rect.x * scale, y: rect.y * scale, width: rect.width * scale, height: rect.height * scale).fill()
            }
            return true
        }
        image.isTemplate = false  // keep Claude orange instead of the menu bar's monochrome tint
        return image
    }()
}
