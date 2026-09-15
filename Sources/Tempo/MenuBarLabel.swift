import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var ticker: Ticker

    var body: some View {
        let config = store.config
        let snapshot = ProgressEngine.snapshot(config.menuBarMetric, now: ticker.now, config: config)
        switch config.menuBarStyle {
        case .text:
            Text("\(config.menuBarMetric.shortLetter) \(ProgressEngine.percentText(snapshot.fraction))")
                .monospacedDigit()
        case .icon:
            Image(systemName: "circle.lefthalf.filled.inverse")
        case .ring:
            Image(nsImage: MenuBarRing.image(fraction: snapshot.fraction ?? 0))
        }
    }
}

enum MenuBarRing {
    /// Template ring image so it adapts to light/dark menu bars automatically.
    static func image(fraction: Double) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let lineWidth: CGFloat = 2.6
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2 - lineWidth / 2 - 1

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.black.withAlphaComponent(0.25).setStroke()
            track.stroke()

            let clamped = min(max(fraction, 0), 1)
            if clamped > 0.001 {
                let progress = NSBezierPath()
                progress.appendArc(
                    withCenter: center, radius: radius,
                    startAngle: 90, endAngle: 90 - 360 * clamped, clockwise: true
                )
                progress.lineWidth = lineWidth
                progress.lineCapStyle = .round
                NSColor.black.setStroke()
                progress.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
