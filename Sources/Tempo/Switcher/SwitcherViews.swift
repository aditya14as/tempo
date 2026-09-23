import AppKit
import SwiftUI

/// Card and grid dimensions — shared by the views and the controller's
/// layout math so both agree on where every card is.
enum SwitcherMetrics {
    static let padding: CGFloat = 18
    static let spacing: CGFloat = 10
    static let cornerRadius: CGFloat = 26
    static let hintsHeight: CGFloat = 26

    static func cardWidth(_ size: SwitcherSize) -> CGFloat {
        switch size {
        case .small: return 180
        case .medium: return 232
        case .large: return 300
        }
    }
    static func previewHeight(_ size: SwitcherSize) -> CGFloat { (cardWidth(size) - 12) * 0.625 }
    static func cardHeight(_ size: SwitcherSize) -> CGFloat { previewHeight(size) + 12 + 6 + 16 }

    static let iconCell: CGFloat = 92
    static let iconTitleHeight: CGFloat = 30
    static let listWidth: CGFloat = 520
    static let listRow: CGFloat = 40
}

/// Everything the switcher view renders. The controller mutates it; one
/// hosting view is reused across shows so opening stays instant.
@MainActor
final class SwitcherModel: ObservableObject {
    @Published var items: [SwitchItem] = []
    @Published var selected = 0
    /// The last selection came from the pointer: don't scroll the grid under it.
    var selectedByPointer = false
    @Published var hovered: Int?
    @Published var images: [CGWindowID: NSImage] = [:]
    @Published var style: SwitcherStyle = .thumbnails
    @Published var size: SwitcherSize = .medium
    @Published var columns = 1
    /// Height of the scrolling area when everything doesn't fit; nil = no scroll.
    @Published var scrollHeight: CGFloat?
    @Published var theme: Theme = .aurora
    @Published var showHints = true
    @Published var showSpaceBadges = true
    @Published var previewsOn = true
    /// Card frames in the hosting view's top-left coordinates, for mouse hit-tests.
    var cardFrames: [Int: CGRect] = [:]
    /// The visible part of the scrolling grid; cards scrolled out of it can't be hit.
    var viewport: CGRect?
    private var icons: [pid_t: NSImage] = [:]

    var selectedItem: SwitchItem? { items.indices.contains(selected) ? items[selected] : nil }

    func icon(for item: SwitchItem) -> NSImage {
        if let cached = icons[item.pid] { return cached }
        let icon = NSRunningApplication(processIdentifier: item.pid)?.icon
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        icons[item.pid] = icon
        return icon
    }

    func resetIcons() { icons.removeAll() }

    func index(at point: CGPoint) -> Int? {
        if let viewport = scrollHeight != nil ? viewport : nil, !viewport.contains(point) { return nil }
        // Frames arrive a beat after the list changes; never return a stale index.
        return cardFrames.first { items.indices.contains($0.key) && $0.value.contains(point) }?.key
    }
}

private struct ViewportKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

private struct CardFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        VStack(spacing: 12) {
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No windows")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 260, height: 120)
            } else {
                scrolling
                if model.style == .icons, let item = model.selectedItem {
                    Text(item.displayTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 520)
                        .frame(height: SwitcherMetrics.iconTitleHeight - 12)
                }
            }
            if model.showHints {
                hints
            }
        }
        .padding(SwitcherMetrics.padding)
        .background(
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: SwitcherMetrics.cornerRadius, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SwitcherMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .coordinateSpace(name: "switcher")
        .onPreferenceChange(CardFramesKey.self) { frames in
            MainActor.assumeIsolated { model.cardFrames = frames }
        }
        .onPreferenceChange(ViewportKey.self) { frame in
            MainActor.assumeIsolated { model.viewport = frame }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var scrolling: some View {
        if let height = model.scrollHeight {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    content
                }
                .frame(height: height)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ViewportKey.self, value: geo.frame(in: .named("switcher")))
                })
                .onChange(of: model.selected) { _, index in
                    guard !model.selectedByPointer else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(index, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(model.selected, anchor: .center) }
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.style {
        case .thumbnails:
            grid(width: SwitcherMetrics.cardWidth(model.size)) { index, item in PreviewCard(model: model, index: index, item: item) }
        case .icons:
            grid(width: SwitcherMetrics.iconCell) { index, item in IconCard(model: model, index: index, item: item) }
        case .titles:
            VStack(spacing: 2) {
                // By position, like the grid: the row drawn at i is always items[i].
                ForEach(model.items.indices, id: \.self) { index in
                    ListRow(model: model, index: index, item: model.items[index])
                        .id(index)
                        .background(frameReporter(index))
                }
            }
            .frame(width: SwitcherMetrics.listWidth)
        }
    }

    /// A plain (not lazy) grid: LazyVGrid reuses cells by position and, when
    /// the list changes while the panel is hidden, can keep drawing the old
    /// cards — so the highlight and the pointer land on the wrong window.
    private func grid<Card: View>(width: CGFloat, @ViewBuilder card: @escaping (Int, SwitchItem) -> Card) -> some View {
        let columns = max(1, model.columns)
        let rows = stride(from: 0, to: model.items.count, by: columns).map { start in
            Array(start..<min(start + columns, model.items.count))
        }
        return VStack(alignment: .leading, spacing: SwitcherMetrics.spacing) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: SwitcherMetrics.spacing) {
                    ForEach(row, id: \.self) { index in
                        card(index, model.items[index])
                            .frame(width: width)
                            .id(index)
                            .background(frameReporter(index))
                    }
                }
            }
        }
    }

    private func frameReporter(_ index: Int) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: CardFramesKey.self, value: [index: geo.frame(in: .named("switcher"))])
        }
    }

    private var hints: some View {
        HStack(spacing: 12) {
            hint("⇥", "next")
            hint("⇧⇥", "back")
            hint("↩", "open")
            hint("W", "close")
            hint("M", "minimize")
            hint("H", "hide")
            hint("Q", "quit")
            hint("⎋", "cancel")
        }
        .font(.system(size: 10, design: .rounded))
        .foregroundStyle(.tertiary)
        .frame(height: SwitcherMetrics.hintsHeight - 12)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
            Text(label)
        }
    }
}

/// Selected / hovered styling shared by every card style.
private struct CardChrome: ViewModifier {
    var selected: Bool
    var hovered: Bool
    var theme: Theme
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.1 : hovered ? 0.05 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.clear), lineWidth: 2.5)
            )
            .animation(.easeOut(duration: 0.08), value: selected)
    }
}

private struct Badges: View {
    var item: SwitchItem
    var showSpace: Bool

    var body: some View {
        HStack(spacing: 3) {
            if showSpace, let number = item.spaceNumber { chip(text: "\(number)", icon: "square.stack.3d.up.fill") }
            if item.isMinimized { chip(text: nil, icon: "minus.circle.fill") }
            if item.isHidden { chip(text: nil, icon: "eye.slash.fill") }
            if item.isWindowless { chip(text: nil, icon: "moon.zzz.fill") }
        }
    }

    private func chip(text: String?, icon: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            if let text { Text(text).font(.system(size: 9, weight: .bold, design: .rounded)) }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(.regularMaterial))
        .foregroundStyle(.secondary)
    }
}

private struct PreviewCard: View {
    @ObservedObject var model: SwitcherModel
    var index: Int
    var item: SwitchItem

    var body: some View {
        let width = SwitcherMetrics.cardWidth(model.size) - 12
        let height = SwitcherMetrics.previewHeight(model.size)
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if model.previewsOn, let image = model.images[item.wid] {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
                        .padding(6)
                } else {
                    Image(nsImage: model.icon(for: item))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: height * 0.5, height: height * 0.5)
                        .opacity(item.isMinimized || item.isWindowless ? 0.6 : 1)
                }
            }
            .frame(width: width, height: height)
            .overlay(alignment: .topTrailing) {
                Badges(item: item, showSpace: model.showSpaceBadges).padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if model.previewsOn && model.images[item.wid] != nil {
                    Image(nsImage: model.icon(for: item))
                        .resizable()
                        .frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: -4, y: 6)
                }
            }
            HStack(spacing: 5) {
                if !(model.previewsOn && model.images[item.wid] != nil) {
                    Image(nsImage: model.icon(for: item)).resizable().frame(width: 14, height: 14)
                }
                Text(item.displayTitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: width - 8, height: 16)
            .foregroundStyle(index == model.selected ? .primary : .secondary)
        }
        .padding(6)
        .modifier(CardChrome(selected: index == model.selected, hovered: index == model.hovered,
                             theme: model.theme, radius: 14))
        .help(item.displayTitle)
    }
}

private struct IconCard: View {
    @ObservedObject var model: SwitcherModel
    var index: Int
    var item: SwitchItem

    var body: some View {
        Image(nsImage: model.icon(for: item))
            .resizable()
            .interpolation(.high)
            .frame(width: 64, height: 64)
            .opacity(item.isMinimized || item.isWindowless ? 0.6 : 1)
            .frame(width: SwitcherMetrics.iconCell, height: SwitcherMetrics.iconCell)
            .overlay(alignment: .topTrailing) { Badges(item: item, showSpace: model.showSpaceBadges).padding(4) }
            .modifier(CardChrome(selected: index == model.selected, hovered: index == model.hovered,
                                 theme: model.theme, radius: 18))
    }
}

private struct ListRow: View {
    @ObservedObject var model: SwitcherModel
    var index: Int
    var item: SwitchItem

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: model.icon(for: item)).resizable().frame(width: 22, height: 22)
            Text(item.displayTitle)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Badges(item: item, showSpace: model.showSpaceBadges)
            Text(item.appName)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: SwitcherMetrics.listRow)
        .modifier(CardChrome(selected: index == model.selected, hovered: index == model.hovered,
                             theme: model.theme, radius: 10))
    }
}

/// Behind-window blur that stays vibrant even though the panel never becomes key.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        let tint = TintView()
        tint.autoresizingMask = [.width, .height]
        tint.frame = view.bounds
        view.addSubview(tint)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        for case let tint as TintView in nsView.subviews { tint.needsDisplay = true }
    }

    /// Settings → Appearance → Background: a layer of the window colour over
    /// the glass, so text stays readable over busy windows behind.
    private final class TintView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let opacity = MainActor.assumeIsolated { ConfigStore.shared?.config.backgroundOpacity ?? 0 }
            NSColor.windowBackgroundColor.withAlphaComponent(opacity).setFill()
            dirtyRect.fill()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The switcher's window: borderless, never activates Tempo, floats above
/// everything on every Space (including full-screen ones).
final class SwitcherPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
