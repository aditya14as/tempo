import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A small always-on-top panel. Unlike the menu bar popover, it stays open
/// while you click around Finder or VS Code — so drag & drop actually works.
/// Drop files/links in; drag them out again into Mail, Slack, Finder, anywhere.
@MainActor
final class ShelfWindow {
    static let shared = ShelfWindow()
    private var panel: NSPanel?
    private weak var dropView: FileDropView?
    /// True while the card is opaque because the user opened it or it just
    /// caught a drop (versus merely lit up under a passing drag).
    private var open = false
    /// True while the card is up purely because a drag is in flight; if the
    /// drag ends without a drop landing, it tucks itself away again.
    private var revealedByDrag = false
    /// Where an opened card belongs: under the icon (clicked open) or at the
    /// safe centered spot (popped for a drag, and where a caught drop stays).
    private enum Anchor { case icon, safe }
    private var anchor: Anchor = .icon
    /// Quiet ticks; after ~8s an opened card dims back to invisible.
    private var idleTicks = 0
    /// When idle the card is parked here — ordered-in (so it stays in the
    /// window list and can catch the very next drag) but off-screen, at 2%
    /// opacity and click-through. A visible-but-2%-alpha window sits BELOW
    /// macOS's drag-target threshold and silently receives no drops, so the
    /// card is only a real target once a drag pops it to full opacity.
    private static let idleAlpha: CGFloat = 0.02
    private static let offscreen = NSPoint(x: -20000, y: -20000)

    /// Build the card and tuck it away, ready for the first drag.
    func prewarm(store: ConfigStore) {
        ensurePanel(store: store)
        goIdle()
    }

    /// Keep an opened card pinned under the icon if the menu bar shifts. A
    /// card placed by a drag stays exactly where the drag put it.
    func reposition() {
        guard let panel, open, !revealedByDrag, anchor == .icon else { return }
        position(panel)
    }

    /// Whether a given window is the Shelf card — lets the panel aligner
    /// tell the Shelf apart from the menu bar dropdown.
    func isShelf(_ window: NSWindow) -> Bool { window === panel }

    func toggle(store: ConfigStore) {
        if open {
            goIdle()
        } else {
            showOpen(store: store)
        }
    }

    func hide() {
        goIdle()
    }

    /// Show the card opaque and interactive — used when the user opens it or
    /// a file just landed on the menu bar icon.
    func reveal(store: ConfigStore) {
        showOpen(store: store)
    }

    /// A file drag just began somewhere: pop the card up full-opacity and
    /// interactive so the drop actually lands. The card already exists and is
    /// ordered-in, so it's in the drag's target set; raising its opacity is
    /// what makes it catch. Where it goes depends on the pointer (see
    /// `ShelfPlacement`): a centred spot just below the menu bar for a drag
    /// picked up inside a window (Finder, VS Code), or — when the pointer is
    /// already up in the menu bar (a Zed drag only reaches macOS once it
    /// leaves Zed's window, and up is the natural exit) — right under the
    /// pointer, over the bar, where `followDrag` then keeps it and where
    /// `.stationary` keeps it visible even as Mission Control opens.
    func revealForDrag(store: ConfigStore) {
        ensurePanel(store: store)
        guard let panel else { return }
        // Already open: it's a drop target where it is. Moving it (or tucking
        // it away when the drag ends elsewhere) would lose the user's card.
        if open {
            DropGlow.shared.dragInFlight = true
            idleTicks = 0
            return
        }
        revealedByDrag = true
        open = false
        idleTicks = 0
        anchor = .safe
        DropGlow.shared.dragInFlight = true
        dropView?.passesClicksThrough = false
        place(panel, forDragAt: NSEvent.mouseLocation)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Legacy name kept for old call sites: same as revealForDrag.
    func revealForFileDrag(store: ConfigStore) { revealForDrag(store: store) }

    /// Called every drag tick. Once the pointer is up in the menu bar strip,
    /// keep the card directly under it (sliding along as the pointer moves), so
    /// wherever you let go in the bar the card is there to catch it — Mission
    /// Control may flash open, but the stationary card stays put beneath the
    /// cursor. Outside the bar the card is left where it first popped, so a
    /// drag meant for another app isn't hijacked.
    func followDrag() {
        guard let panel, revealedByDrag, let screen = Self.screen(containing: NSEvent.mouseLocation)
        else { return }
        let cursor = NSEvent.mouseLocation
        let inBar = ShelfPlacement.isInMenuBar(cursor: cursor, screen: screen.frame, visible: screen.visibleFrame)
        if DropGlow.shared.pointerInMenuBar != inBar { DropGlow.shared.pointerInMenuBar = inBar }
        guard inBar else { return }
        place(panel, forDragAt: cursor)
    }

    /// A drag is now hovering the card: keep it fully visible.
    func dragHover(_ entered: Bool) {
        guard let panel else { return }
        DropGlow.shared.targeted = entered
        if entered {
            panel.alphaValue = 1
            idleTicks = 0
        } else if !open && !revealedByDrag {
            panel.alphaValue = Self.idleAlpha
        }
    }

    /// A drop landed: keep the card up and interactive where it is, so you
    /// can see what you caught and drag it back out; it dims later when idle.
    func noteDrop() {
        open = true
        revealedByDrag = false
        idleTicks = 0
        DropGlow.shared.dragInFlight = false
        DropGlow.shared.pointerInMenuBar = false
        guard let panel else { return }
        panel.alphaValue = 1
        dropView?.passesClicksThrough = false
        // If the card caught the drop while sitting over the menu bar, slide it
        // down flush under the bar so the bar is usable again — it stays open.
        let cardScreen = Self.screen(containing: NSPoint(x: panel.frame.midX, y: panel.frame.maxY)) ?? NSScreen.main
        guard let visible = cardScreen?.visibleFrame else { return }
        let top = ShelfPlacement.settledTop(currentTop: panel.frame.maxY, visible: visible)
        if top != panel.frame.maxY {
            var frame = panel.frame
            frame.origin.y = top - frame.height
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    /// The in-flight drag ended. If nothing landed (the card was up only as a
    /// drop target), tuck it away again shortly; a drop sets `open`, keeping
    /// it up. The short delay lets a just-released drop finish delivering.
    func fileDragEnded() {
        DropGlow.shared.dragInFlight = false
        DropGlow.shared.targeted = false
        DropGlow.shared.pointerInMenuBar = false
        guard revealedByDrag, !open else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if self.revealedByDrag && !self.open { self.goIdle() }
        }
    }

    func prime(store: ConfigStore) {}
    func unprimeIfIdle() {}

    /// Called ~25×/sec. An opened card dims back to invisible after ~8 quiet
    /// seconds; hovering it or a drag in flight resets the countdown.
    func tickIdle(dragActive: Bool) {
        guard let panel, open else {
            idleTicks = 0
            return
        }
        reposition()
        let busy = dragActive
            || DropGlow.shared.targeted
            || panel.frame.insetBy(dx: -20, dy: -20).contains(NSEvent.mouseLocation)
        if busy {
            idleTicks = 0
            return
        }
        idleTicks += 1
        if idleTicks >= 200 {  // ~8s at 40ms/tick
            idleTicks = 0
            goIdle()
        }
    }

    /// The resting state: ordered-in (so it can catch the next drag) but
    /// parked off-screen, invisible and click-through.
    private func goIdle() {
        guard let panel else { return }
        open = false
        revealedByDrag = false
        idleTicks = 0
        anchor = .icon
        DropGlow.shared.dragInFlight = false
        DropGlow.shared.targeted = false
        DropGlow.shared.pointerInMenuBar = false
        dropView?.passesClicksThrough = true
        panel.alphaValue = Self.idleAlpha
        panel.setFrameOrigin(Self.offscreen)
        panel.orderFrontRegardless()
    }

    /// Opaque and interactive, under the menu bar icon — used when the user
    /// clicks the tray button to open the shelf (no drag, no top-edge risk).
    private func showOpen(store: ConfigStore) {
        ensurePanel(store: store)
        guard let panel else { return }
        open = true
        revealedByDrag = false
        idleTicks = 0
        anchor = .icon
        DropGlow.shared.dragInFlight = false
        dropView?.passesClicksThrough = false
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func ensurePanel(store: ConfigStore) {
        guard panel == nil else { return }
        let panel = ShelfPanel(
            contentRect: NSRect(x: 0, y: 0, width: 264, height: 236),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // No traffic-light dots — it's a floating card, not a document.
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        // Above the menu bar popover, so it never hides behind the panel.
        panel.level = .statusBar
        // .stationary is the crux of a reliable menu-bar drop: a drag lingering
        // at the top edge makes macOS open Mission Control, and a stationary
        // window stays put and visible THROUGH Mission Control — so the card is
        // still right there under the pointer to drop on, instead of vanishing
        // into the windows overview.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        // AppKit-level drop container: catches drags from VS Code,
        // Conductor, Zed, browsers — types SwiftUI's drop can't read.
        let drop = FileDropView(frame: NSRect(x: 0, y: 0, width: 264, height: 236))
        drop.name = "shelf"
        drop.onDrop = { [weak store] urls in store?.addToShelf(urls) }
        drop.onTargeted = { ShelfWindow.shared.dragHover($0) }
        drop.onAnyDrop = { ShelfWindow.shared.noteDrop() }
        let hosting = ShelfHostingView(rootView: ShelfView().environmentObject(store))
        hosting.frame = drop.bounds
        hosting.autoresizingMask = [.width, .height]
        drop.addSubview(hosting)
        panel.contentView = drop
        self.dropView = drop
        self.panel = panel
    }

    /// Sits right under the Tempo menu bar icon. If the menu bar panel is
    /// open there too, slides left of it so the two never overlap.
    private func position(_ panel: NSPanel) {
        let width = panel.frame.width
        let icon = StatusItemDropper.iconScreenFrame()
        let screen = NSScreen.screens.first { $0.frame.intersects(icon ?? .zero) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var x = (icon?.midX ?? visible.midX) - width / 2
        let top = min((icon?.minY ?? visible.maxY) - 4, visible.maxY - 2)
        if let open = menuBarPanelWindow() {
            x = min(x, open.frame.minX - width - 10)
        }
        x = max(visible.minX + 8, min(x, visible.maxX - width - 8))
        // Runs ~25×/sec while open; only touch the window when it would move.
        let point = NSPoint(x: x, y: top)
        if NSPoint(x: panel.frame.minX, y: panel.frame.maxY) != point { panel.setFrameTopLeftPoint(point) }
    }

    /// Places the card for a drag whose pointer is at `cursor`: centred below
    /// the menu bar for an ordinary drag, or under the pointer and over the bar
    /// once the pointer is up there (`ShelfPlacement.topLeft`).
    private func place(_ panel: NSPanel, forDragAt cursor: NSPoint) {
        let icon = StatusItemDropper.iconScreenFrame()
        let screen = Self.screen(containing: cursor)
            ?? NSScreen.screens.first { $0.frame.intersects(icon ?? .zero) }
            ?? NSScreen.main
        guard let screen else { return }
        let placed = ShelfPlacement.topLeft(
            cardSize: panel.frame.size, cursor: cursor,
            screen: screen.frame, visible: screen.visibleFrame
        )
        let current = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        if current != placed.point { panel.setFrameTopLeftPoint(placed.point) }
    }

    /// The display the pointer is on (inclusive of its edges), or nil off any.
    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first {
            let f = $0.frame
            return point.x >= f.minX && point.x <= f.maxX && point.y >= f.minY && point.y <= f.maxY
        }
    }

    /// The MenuBarExtra popover, if it's currently on screen: a visible app
    /// window hugging the menu bar that isn't the shelf or the status item.
    private func menuBarPanelWindow() -> NSWindow? {
        guard let top = NSScreen.main?.visibleFrame.maxY else { return nil }
        return NSApp.windows.first { window in
            window !== panel
                && window.isVisible
                && !window.className.contains("StatusBarWindow")
                && window.frame.height > 100
                && window.frame.maxY > top - 40
        }
    }
}

/// The card's window. AppKit refuses by default to place a titled window over
/// the menu bar (`constrainFrameRect` pulls it back under the bar) — but over
/// the bar, under the pointer, is exactly where a menu-bar drop needs the card
/// to be. Overriding the constraint lets the card go where it's told.
final class ShelfPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    /// Never take focus: the menu bar panel closes when it loses key, and a
    /// click that only makes the card key never reaches its buttons.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Acts on the first click, even though the card is never key.
private final class ShelfHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where the Shelf card pops for an in-flight drag. Pure geometry in Cocoa
/// coordinates (origin bottom-left; `visible` is the screen minus the menu bar
/// and Dock, `screen` the whole display), so `--check` pins it down with no
/// windows involved.
///
/// Two spots:
/// - `.belowBar`: horizontally centred, `topGap` points below the menu bar —
///   the target for a drag picked up inside a window (Finder, VS Code), which
///   reaches macOS immediately, so the card is up before the pointer moves.
/// - `.overBar`: the pointer is up in the menu bar, so the card goes right
///   under it and over the bar, the cursor already on it. A Zed drag only
///   reaches macOS once it leaves Zed's window, and up into the bar is the
///   natural exit; a drag lingering there opens Mission Control, so the card
///   is `.stationary` (stays visible through it) and `followDrag` keeps it
///   under the moving pointer. After a drop it slides below the bar
///   (`settledTop`).
enum ShelfPlacement {
    enum Spot: Equatable { case belowBar, overBar }
    static let inset: CGFloat = 8
    static let topGap: CGFloat = 44
    /// A maximized window stops a point short of the bar, so a pointer that has
    /// just left it may be in that sliver; count it as already in the bar.
    static let barSlack: CGFloat = 2

    /// True when the pointer is in `screen`'s menu bar strip.
    static func isInMenuBar(cursor: NSPoint, screen: NSRect, visible: NSRect) -> Bool {
        cursor.x >= screen.minX && cursor.x <= screen.maxX
            && cursor.y >= visible.maxY - barSlack && cursor.y <= screen.maxY
    }

    /// The card's top-left corner (minX, maxY) and which spot it is.
    static func topLeft(
        cardSize: NSSize, cursor: NSPoint, screen: NSRect, visible: NSRect
    ) -> (point: NSPoint, spot: Spot) {
        let w = cardSize.width
        if isInMenuBar(cursor: cursor, screen: screen, visible: visible) {
            let x = max(visible.minX + inset, min(cursor.x - w / 2, visible.maxX - w - inset))
            return (NSPoint(x: x, y: screen.maxY), .overBar)
        }
        let x = max(visible.minX + inset, min(visible.midX - w / 2, visible.maxX - w - inset))
        return (NSPoint(x: x, y: visible.maxY - topGap), .belowBar)
    }

    /// Where a card that caught a drop settles: never over the menu bar.
    static func settledTop(currentTop: CGFloat, visible: NSRect) -> CGFloat {
        min(currentTop, visible.maxY)
    }
}

struct ShelfView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var glow = DropGlow.shared

    /// True when a drag is in flight (card popped) or hovering the card — the
    /// moment to show the "drop it here" invitation.
    private var inviting: Bool { glow.targeted || glow.dragInFlight }
    /// The pointer is up in the menu bar with the card under it: reassure that
    /// letting go here works even though Mission Control may flash open.
    private var inMenuBar: Bool { inviting && glow.pointerInMenuBar }

    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // Close sits top-left, where every Mac window keeps it.
                Button { ShelfWindow.shared.hide() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close the shelf")
                Text("Shelf")
                    .font(.system(.headline, design: .rounded))
                if !store.config.shelf.isEmpty {
                    Text("\(store.config.shelf.count)")
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer()
                if !store.config.shelf.isEmpty {
                    Button("Clear") { store.config.shelf.removeAll() }
                        .buttonStyle(.plain)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            if store.config.shelf.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(store.config.shelf) { item in
                            tile(item)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                Text(inMenuBar ? "Let go here — the card stays put."
                    : inviting ? "Drop it on this card." : "Drag items out anywhere.")
                    .font(.caption2)
                    .foregroundStyle(inviting ? .secondary : .tertiary)
            }
        }
        .padding(14)
        .frame(width: 264, height: 236, alignment: .top)
        .animation(.spring(duration: 0.3), value: store.config.shelf)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            // Colored border while any file drag is in flight — the card,
            // not the menu bar icon, is where drops land (macOS grabs
            // top-of-screen drags for Mission Control, we can't stop it).
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    inviting
                        ? AnyShapeStyle(store.config.theme.gradient)
                        : AnyShapeStyle(Color.primary.opacity(0.1)),
                    lineWidth: inviting ? 2.5 : 1
                )
                .padding(0.5)
        )
        // Drops are handled by the FileDropView underneath this view —
        // it understands VS Code/Electron/browser drags SwiftUI can't.
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(inviting ? AnyShapeStyle(store.config.theme.gradient) : AnyShapeStyle(.quaternary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: inviting ? "arrow.down.circle.fill" : "tray.and.arrow.down")
                        .font(.system(size: inviting ? 26 : 20))
                    Text(inMenuBar ? "Let go here" : inviting ? "Drop it here!" : "Drop files or links here")
                        .font(.system(.caption, design: .rounded).weight(inviting ? .semibold : .regular))
                    Text(inMenuBar ? "stays put even if Mission Control opens"
                        : inviting ? "let go anywhere on this card" : "then drag them out anywhere")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            )
    }

    private func tile(_ item: ShelfItem) -> some View {
        VStack(spacing: 4) {
            icon(item)
                .frame(width: 34, height: 34)
            Text(item.name)
                .font(.system(size: 9, design: .rounded))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(alignment: .topTrailing) {
            Button { store.config.shelf.removeAll { $0.id == item.id } } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
            .buttonStyle(.plain)
            .padding(3)
        }
        .onTapGesture {
            if let url = item.url { NSWorkspace.shared.open(url) }
        }
        .onDrag { dragProvider(item) }
        .help(item.link)
    }

    @ViewBuilder
    private func icon(_ item: ShelfItem) -> some View {
        if item.isFile {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.link))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "link.circle.fill")
                .resizable()
                .foregroundStyle(store.config.theme.gradient)
        }
    }

    /// Hands the real file (not just its name) to whatever you drop it on.
    /// Also tags the drag with the item's own link: the file itself can
    /// arrive as a copy at another path, and dropping it back on the Shelf
    /// (or the menu bar icon) must find the item already there, not add a twin.
    private func dragProvider(_ item: ShelfItem) -> NSItemProvider {
        let provider: NSItemProvider
        if item.isFile, let file = NSItemProvider(contentsOf: URL(fileURLWithPath: item.link)) {
            provider = file
        } else if let url = item.url {
            provider = NSItemProvider(object: url as NSURL)
        } else {
            provider = NSItemProvider(object: item.link as NSString)
        }
        let link = item.link
        provider.registerDataRepresentation(forTypeIdentifier: DropPayload.shelfLink.rawValue, visibility: .all) { done in
            done(Data(link.utf8), nil)
            return nil
        }
        return provider
    }
}
