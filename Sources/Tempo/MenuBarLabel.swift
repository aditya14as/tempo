import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var ticker: Ticker

    var body: some View {
        let config = store.config
        if config.menuBarShows == .todayWeek {
            // Today + week side by side, each clearly labeled.
            let today = ProgressEngine.snapshot(.today, now: ticker.now, config: config)
            let week = ProgressEngine.snapshot(.week, now: ticker.now, config: config)
            switch config.menuBarStyle {
            case .text:
                Text("T \(ProgressEngine.percentText(today.fraction))  W \(ProgressEngine.percentText(week.fraction))")
                    .monospacedDigit()
            case .icon, .ring:
                // Ring = today, text = week.
                Image(nsImage: MenuBarRing.image(fraction: today.fraction ?? 0))
                Text("W \(ProgressEngine.percentText(week.fraction))")
                    .monospacedDigit()
            }
        } else {
            let metric = config.menuBarShows.metric ?? .week
            let snapshot = ProgressEngine.snapshot(metric, now: ticker.now, config: config)
            switch config.menuBarStyle {
            case .text:
                Text("\(metric.shortLetter) \(ProgressEngine.percentText(snapshot.fraction))")
                    .monospacedDigit()
            case .icon:
                Image(systemName: "circle.lefthalf.filled.inverse")
            case .ring:
                Image(nsImage: MenuBarRing.image(fraction: snapshot.fraction ?? 0, letter: metric.shortLetter))
            }
        }
    }
}

enum MenuBarRing {
    /// Template ring image so it adapts to light/dark menu bars automatically.
    /// Pass a letter to draw it in the ring's center (tells metrics apart).
    static func image(fraction: Double, letter: String? = nil) -> NSImage {
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

            if let letter {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                    .foregroundColor: NSColor.black.withAlphaComponent(0.9),
                ]
                let text = NSAttributedString(string: letter, attributes: attrs)
                let size = text.size()
                text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
