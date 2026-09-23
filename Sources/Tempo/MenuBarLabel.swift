import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var ticker: Ticker
    @ObservedObject private var awake = AwakeEngine.shared

    var body: some View {
        let config = store.config
        if let state = awake.state, config.features.awake {
            // Awake: a bolt (plus optional time left) leads the usual item.
            // Without work-hours progress the bolt stands in for the icon.
            let progress = config.features.workHours
            Image(nsImage: MenuBarAwake.compose(
                awakeText: awakeText(state, config: config),
                base: progress ? baseImage(config) : nil,
                text: progress ? baseText(config) : nil
            ))
        } else if let image = baseImage(config) {
            Image(nsImage: image)
        } else {
            Text(baseText(config) ?? "")
                .monospacedDigit()
        }
    }

    private func awakeText(_ state: AwakeState, config: AppConfig) -> String? {
        guard config.awake.showTimeInMenuBar, let end = state.endsAt else { return nil }
        return AwakePlanner.menuBarRemaining(end.timeIntervalSince(ticker.now))
    }

    /// The item as an image, or nil for the plain-text style.
    private func baseImage(_ config: AppConfig) -> NSImage? {
        guard config.features.workHours else { return Self.appIcon }
        if config.menuBarShows == .todayWeek {
            // Today + week side by side: letter badge + percent + mini progress bar.
            let today = ProgressEngine.snapshot(.today, now: ticker.now, config: config)
            let week = ProgressEngine.snapshot(.week, now: ticker.now, config: config)
            return MenuBarBadges.image(segments: [
                ("T", today.fraction),
                ("W", week.fraction),
            ])
        }
        let metric = config.menuBarShows.metric ?? .week
        let snapshot = ProgressEngine.snapshot(metric, now: ticker.now, config: config)
        switch config.menuBarStyle {
        case .text:
            return nil
        case .icon:
            return Self.appIcon
        case .ring:
            return MenuBarRing.image(fraction: snapshot.fraction ?? 0, letter: metric.shortLetter)
        }
    }

    private static let appIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "circle.lefthalf.filled.inverse", accessibilityDescription: "Tempo")
        image?.isTemplate = true
        return image
    }()

    private func baseText(_ config: AppConfig) -> String? {
        guard config.features.workHours, config.menuBarShows != .todayWeek, config.menuBarStyle == .text else { return nil }
        let metric = config.menuBarShows.metric ?? .week
        let snapshot = ProgressEngine.snapshot(metric, now: ticker.now, config: config)
        return "\(metric.shortLetter) \(ProgressEngine.percentText(snapshot.fraction))"
    }
}

enum MenuBarAwake {
    /// Template image: bolt, optional time left, then the regular item
    /// (an image, or text for the Live % style).
    static func compose(awakeText: String?, base: NSImage?, text: String?) -> NSImage {
        let height: CGFloat = 18
        let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Keeping awake")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        let boltSize = bolt?.size ?? NSSize(width: 8, height: 12)
        let timeString = awakeText.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.black,
            ])
        }
        let baseString = text.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.black,
            ])
        }
        let gap: CGFloat = 3
        let sectionGap: CGFloat = 7
        var width = boltSize.width
        if let timeString { width += gap + timeString.size().width }
        if let base { width += sectionGap + base.size.width }
        if let baseString { width += sectionGap + baseString.size().width }

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            bolt?.draw(in: NSRect(x: x, y: (height - boltSize.height) / 2, width: boltSize.width, height: boltSize.height))
            x += boltSize.width
            if let timeString {
                x += gap
                let size = timeString.size()
                timeString.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
                x += size.width
            }
            if let base {
                x += sectionGap
                base.draw(in: NSRect(x: x, y: (height - base.size.height) / 2, width: base.size.width, height: base.size.height))
                x += base.size.width
            }
            if let baseString {
                x += sectionGap
                let size = baseString.size()
                baseString.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum MenuBarBadges {
    /// Template image: one segment per metric — a rounded "keycap" badge with
    /// the letter punched out, the percent beside it, and a slim progress bar
    /// underneath. Adapts to light/dark menu bars automatically.
    static func image(segments: [(letter: String, fraction: Double?)]) -> NSImage {
        let height: CGFloat = 18
        let badgeSide: CGFloat = 13
        let badgeGap: CGFloat = 5
        let segmentGap: CGFloat = 11
        let barHeight: CGFloat = 2.5
        let barGap: CGFloat = 2

        let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        let letterFont = NSFont.systemFont(ofSize: 8, weight: .heavy)

        let texts = segments.map { segment in
            NSAttributedString(string: ProgressEngine.percentText(segment.fraction), attributes: [
                .font: percentFont,
                .foregroundColor: NSColor.black.withAlphaComponent(0.95),
            ])
        }
        // Bar spans the percent text; keep a floor so tiny texts still read as a bar.
        let columnWidths = texts.map { max($0.size().width, 20) }
        let width = columnWidths.reduce(0, +)
            + CGFloat(segments.count) * (badgeSide + badgeGap)
            + CGFloat(max(segments.count - 1, 0)) * segmentGap

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, segment) in segments.enumerated() {
                let text = texts[index]
                let columnWidth = columnWidths[index]
                let textSize = text.size()

                // Badge: filled rounded square, letter knocked out of it.
                let badgeRect = NSRect(x: x, y: (height - badgeSide) / 2, width: badgeSide, height: badgeSide)
                NSColor.black.withAlphaComponent(0.88).setFill()
                NSBezierPath(roundedRect: badgeRect, xRadius: 3.5, yRadius: 3.5).fill()
                let letter = NSAttributedString(string: segment.letter, attributes: [
                    .font: letterFont,
                    .foregroundColor: NSColor.black,
                ])
                let letterSize = letter.size()
                NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
                letter.draw(at: NSPoint(
                    x: badgeRect.midX - letterSize.width / 2,
                    y: badgeRect.midY - letterSize.height / 2
                ))
                NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
                x += badgeSide + badgeGap

                // Percent above its mini progress bar, both vertically centered.
                let blockHeight = textSize.height + barGap + barHeight
                let blockBottom = (height - blockHeight) / 2
                text.draw(at: NSPoint(x: x, y: blockBottom + barHeight + barGap))

                let trackRect = NSRect(x: x, y: blockBottom, width: columnWidth, height: barHeight)
                NSColor.black.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: trackRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
                let clamped = min(max(segment.fraction ?? 0, 0), 1)
                if clamped > 0.001 {
                    let fillRect = NSRect(
                        x: x, y: blockBottom,
                        width: max(columnWidth * clamped, barHeight), height: barHeight
                    )
                    NSColor.black.withAlphaComponent(0.9).setFill()
                    NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
                }
                x += columnWidth + segmentGap
            }
            return true
        }
        image.isTemplate = true
        return image
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
