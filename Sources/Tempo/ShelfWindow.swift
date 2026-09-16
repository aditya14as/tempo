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
    /// True while the shelf is only up because a file drag brought it up.
    private var autoShown = false
    private var caughtDrop = false
    /// Quiet 0.2s ticks with no hover/drag; at 40 (~8s) the shelf hides.
    private var idleTicks = 0

    func toggle(store: ConfigStore) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        autoShown = false
        show(store: store)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Brings the shelf up (or keeps it up) — used when a file lands on
    /// the menu bar icon so you can see where it went.
    func reveal(store: ConfigStore) {
        autoShown = false
        show(store: store)
    }

    /// Called ~5×/sec by DragWatcher. Any visible shelf hides itself after
    /// ~8 quiet seconds; hovering it, a drag in flight, or a pressed mouse
    /// button resets the countdown.
    func tickIdle(dragActive: Bool) {
        guard let panel, panel.isVisible else {
            idleTicks = 0
            return
        }
        let busy = dragActive
            || DropGlow.shared.targeted
            || NSEvent.pressedMouseButtons != 0
            || panel.frame.insetBy(dx: -20, dy: -20).contains(NSEvent.mouseLocation)
        if busy {
            idleTicks = 0
            return
        }
        idleTicks += 1
        if idleTicks >= 40 {
            idleTicks = 0
            panel.orderOut(nil)
        }
    }

    /// A file drag just started somewhere on the Mac: pop the shelf up
    /// so there's a big target to drop on (dropping on the menu bar icon
    /// fights Mission Control's drag-to-top gesture).
    func revealForFileDrag(store: ConfigStore) {
        caughtDrop = false
        guard panel?.isVisible != true else { return }
        autoShown = true
        show(store: store)
    }

    /// The drop landed here — the idle countdown then tidies it away.
    func noteDrop() {
        caughtDrop = true
        autoShown = false
        idleTicks = 0
    }

    /// The drag ended. If we auto-appeared and caught nothing, slip away.
    /// (Small delay: the drop callback can land a beat after mouse-up.)
    func fileDragEnded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.autoShown, !self.caughtDrop else { return }
            self.autoShown = false
            self.panel?.orderOut(nil)
        }
    }

    private func show(store: ConfigStore) {
        if panel == nil {
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
            drop.onTargeted = { DropGlow.shared.targeted = $0 }
            drop.onAnyDrop = { ShelfWindow.shared.noteDrop() }
            let hosting = NSHostingView(rootView: ShelfView().environmentObject(store))
            hosting.frame = drop.bounds
            hosting.autoresizingMask = [.width, .height]
            drop.addSubview(hosting)
            panel.contentView = drop
            self.panel = panel
        }
        if let panel {
            position(panel)
            panel.orderFrontRegardless()
        }
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
                Text(glow.dragInFlight ? "Drop it on this card." : "Drag items out anywhere.")
                    .font(.caption2)
                    .foregroundStyle(glow.dragInFlight ? .secondary : .tertiary)
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
                    glow.targeted || glow.dragInFlight
                        ? AnyShapeStyle(store.config.theme.gradient)
                        : AnyShapeStyle(Color.primary.opacity(0.1)),
                    lineWidth: glow.targeted ? 2.5 : (glow.dragInFlight ? 2 : 1)
                )
                .padding(0.5)
        )
        // Drops are handled by the FileDropView underneath this view —
        // it understands VS Code/Electron/browser drags SwiftUI can't.
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(glow.dragInFlight ? AnyShapeStyle(store.config.theme.gradient) : AnyShapeStyle(.quaternary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: glow.dragInFlight ? "arrow.down.circle.fill" : "tray.and.arrow.down")
                        .font(.system(size: glow.dragInFlight ? 26 : 20))
                    Text(glow.dragInFlight ? "Drop it here!" : "Drop files or links here")
                        .font(.system(.caption, design: .rounded).weight(glow.dragInFlight ? .semibold : .regular))
                    Text(glow.dragInFlight ? "(the menu bar can't take drops)" : "then drag them out anywhere")
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
