import AppKit
import PollyKit
import SwiftUI

/// Draws the menu bar icon of the design: Polly's head, plus a count when there is something to read.
/// Critical is a red pill with Polly on its back; the other states are template images, so macOS colors
/// them for a light or dark menu bar.
enum MenuBarIcon {
    private static let height: CGFloat = 22
    private static let glyphSize: CGFloat = 17
    private static let gap: CGFloat = 4

    @MainActor
    static func image(mood: MonitorSummary.Mood, badge: String?) -> NSImage {
        let critical = mood == .critical
        let padding: CGFloat = critical ? 7 : 2
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let ink = critical ? NSColor.white : NSColor.black
        let label = badge.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: ink]) }
        let triangleSize: CGFloat = mood == .warning ? 12 : 0

        var width = padding + glyphSize + padding
        if triangleSize > 0 { width += gap + triangleSize }
        if let label { width += gap + ceil(label.size().width) }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            if critical {
                context.setFillColor(NSColor(srgbRed: 0xDC / 255, green: 0x3B / 255, blue: 0x42 / 255, alpha: 1).cgColor)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                context.fillPath()
            }

            var x = padding
            context.saveGState()
            context.translateBy(x: x, y: (height - glyphSize) / 2)
            context.scaleBy(x: glyphSize / 18, y: glyphSize / 18)
            if critical {
                // On its back: mirrored over the horizontal axis of its 18 pt box.
                context.translateBy(x: 0, y: 18)
                context.scaleBy(x: 1, y: -1)
            }
            context.setAlpha(mood == .unreachable ? 0.45 : 1)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setFillColor(ink.cgColor)
            for path in ["M5.6 5.4 Q4.6 2 7 0.9 Q8.2 3.2 7.7 5.2 Z",
                         "M12.6 7.2 Q17.2 7 17.4 11.4 Q17.2 13.4 15.6 13.8 Q15.4 11 13 10.9 Z"] {
                context.addPath(Path(svg: path).cgPath)
            }
            context.addEllipse(in: CGRect(x: 2.1, y: 4.6, width: 11.8, height: 11.8))
            context.fillPath()
            // The eye shows what is behind the icon: the menu bar, or the red of the pill.
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(x: 8.05, y: 7.65, width: 3.3, height: 3.3))
            context.endTransparencyLayer()
            context.restoreGState()
            x += glyphSize

            if triangleSize > 0 {
                x += gap
                context.saveGState()
                context.translateBy(x: x, y: (height - triangleSize) / 2)
                context.scaleBy(x: triangleSize / 20, y: triangleSize / 20)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                let triangle = Path(svg: "M10 2.6 L18 16.6 H2 Z").cgPath
                context.setFillColor(ink.cgColor)
                context.setStrokeColor(ink.cgColor)
                context.setLineWidth(2.4)
                context.setLineJoin(.round)
                context.addPath(triangle)
                context.drawPath(using: .fillStroke)
                context.setBlendMode(.clear)
                context.setLineCap(.round)
                context.addPath(Path(svg: "M10 7.6 V11.4").cgPath)
                context.strokePath()
                context.fillEllipse(in: CGRect(x: 8.7, y: 12.9, width: 2.6, height: 2.6))
                context.endTransparencyLayer()
                context.restoreGState()
                x += triangleSize
            }

            if let label {
                x += gap
                label.draw(at: NSPoint(x: x, y: (height - label.size().height) / 2))
            }
            return true
        }
        // A template image can't carry the red pill or the yellow of the design's warning triangle.
        image.isTemplate = !critical
        return image
    }
}
