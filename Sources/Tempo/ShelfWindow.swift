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
    /// Quiet 0.2s ticks; after ~8s an opened card dims back to invisible.
    private var idleTicks = 0
    /// The card is ALWAYS on-screen, at 2% opacity and click-through when
    /// idle. Being a drop target is passive — a registered, visible window
    /// receives drags with no special permission and no timing games — so
    /// leaving it parked in place (invisible, letting clicks pass through)
    /// means it catches a drag the instant one crosses it. Full opacity is
    /// only for when there's something to look at.
    private static let idleAlpha: CGFloat = 0.02

    /// Build the card and leave it sitting under the icon, invisible.
    func prewarm(store: ConfigStore) {
        ensurePanel(store: store)
        goIdle()
    }

    /// The card's live drop area, so callers (idle timer) can reposition it
    /// if the icon shifts.
    func reposition() {
        guard let panel, !open else { return }
        position(panel)
    }

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

    /// Legacy name kept for callers: same as reveal.
    func revealForFileDrag(store: ConfigStore) {
        // A passing drag lights the card up via `dragHover`; nothing to do
        // here anymore, but keep the entry point so old call sites compile.
    }

    /// A drag is now hovering the card: make it fully visible so the drop
    /// target is obvious. It stays click-through (a drag isn't a click).
    func dragHover(_ entered: Bool) {
        guard let panel else { return }
        DropGlow.shared.targeted = entered
        if entered {
            panel.alphaValue = 1
            idleTicks = 0
        } else if !open {
            panel.alphaValue = Self.idleAlpha
        }
    }

    /// A drop landed: keep the card visible and interactive so you can see
    /// what you caught and drag it back out; the idle timer dims it later.
    func noteDrop() {
        open = true
        idleTicks = 0
        guard let panel else { return }
        panel.alphaValue = 1
        dropView?.passesClicksThrough = false
    }

    func fileDragEnded() {}
    func prime(store: ConfigStore) {}
    func unprimeIfIdle() {}

    /// Called ~5×/sec. An opened card dims back to invisible after ~8 quiet
    /// seconds; hovering it or a drag in flight resets the countdown.
    func tickIdle(dragActive: Bool) {
        reposition()
        guard let panel, open else {
            idleTicks = 0
            return
        }
        let busy = dragActive
            || DropGlow.shared.targeted
            || panel.frame.insetBy(dx: -20, dy: -20).contains(NSEvent.mouseLocation)
        if busy {
            idleTicks = 0
            return
        }
        idleTicks += 1
        if idleTicks >= 40 {
            idleTicks = 0
            goIdle()
        }
    }

    /// Invisible, click-through, still catching drags — the resting state.
    private func goIdle() {
        guard let panel else { return }
        open = false
        dropView?.passesClicksThrough = true
        position(panel)
        panel.alphaValue = Self.idleAlpha
        panel.orderFrontRegardless()
    }

    /// Opaque and interactive.
    private func showOpen(store: ConfigStore) {
        ensurePanel(store: store)
        guard let panel else { return }
        open = true
        idleTicks = 0
        dropView?.passesClicksThrough = false
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func ensurePanel(store: ConfigStore) {
        guard panel == nil else { return }
        let panel = NSPanel(
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
        let hosting = NSHostingView(rootView: ShelfView().environmentObject(store))
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
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
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

struct ShelfView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var glow = DropGlow.shared

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
                Text(glow.targeted ? "Drop it on this card." : "Drag items out anywhere.")
                    .font(.caption2)
                    .foregroundStyle(glow.targeted ? .secondary : .tertiary)
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
                    glow.targeted
                        ? AnyShapeStyle(store.config.theme.gradient)
                        : AnyShapeStyle(Color.primary.opacity(0.1)),
                    lineWidth: glow.targeted ? 2.5 : 1
                )
                .padding(0.5)
        )
        // Drops are handled by the FileDropView underneath this view —
        // it understands VS Code/Electron/browser drags SwiftUI can't.
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(glow.targeted ? AnyShapeStyle(store.config.theme.gradient) : AnyShapeStyle(.quaternary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: glow.targeted ? "arrow.down.circle.fill" : "tray.and.arrow.down")
                        .font(.system(size: glow.targeted ? 26 : 20))
                    Text(glow.targeted ? "Drop it here!" : "Drop files or links here")
                        .font(.system(.caption, design: .rounded).weight(glow.targeted ? .semibold : .regular))
                    Text(glow.targeted ? "(the menu bar can't take drops)" : "then drag them out anywhere")
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
    private func dragProvider(_ item: ShelfItem) -> NSItemProvider {
        if item.isFile, let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: item.link)) {
            return provider
        }
        if let url = item.url {
            return NSItemProvider(object: url as NSURL)
        }
        return NSItemProvider(object: item.link as NSString)
    }
}
