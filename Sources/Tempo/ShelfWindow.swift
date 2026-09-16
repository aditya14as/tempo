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

    func toggle(store: ConfigStore) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        autoShown = false
        show(store: store)
    }

    /// Brings the shelf up (or keeps it up) — used when a file lands on
    /// the menu bar icon so you can see where it went.
    func reveal(store: ConfigStore) {
        autoShown = false
        show(store: store)
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

    /// The drop landed here — an auto-shown shelf then stays open.
    func noteDrop() {
        caughtDrop = true
        autoShown = false
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
                contentRect: NSRect(x: 0, y: 0, width: 264, height: 320),
                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                backing: .buffered, defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            // Above the menu bar popover, so it never hides behind the panel.
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            // AppKit-level drop container: catches drags from VS Code,
            // Conductor, Zed, browsers — types SwiftUI's drop can't read.
            let drop = FileDropView(frame: NSRect(x: 0, y: 0, width: 264, height: 320))
            drop.onDrop = { [weak store] urls in store?.addToShelf(urls) }
            drop.onTargeted = { DropGlow.shared.targeted = $0 }
            drop.onAnyDrop = { ShelfWindow.shared.noteDrop() }
            let hosting = NSHostingView(rootView: ShelfView().environmentObject(store))
            hosting.frame = drop.bounds
            hosting.autoresizingMask = [.width, .height]
            drop.addSubview(hosting)
            panel.contentView = drop
            // Park it top-center, notch style — away from the menu bar panel.
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 132, y: f.maxY - 6))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
}

struct ShelfView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var glow = DropGlow.shared

    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Shelf")
                    .font(.system(.headline, design: .rounded))
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
                        }
                    }
                }
            }
            Text("Drop files or links here, then drag them anywhere.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 264, height: 320, alignment: .top)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    glow.targeted ? AnyShapeStyle(store.config.theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.1)),
                    lineWidth: glow.targeted ? 2 : 1
                )
                .padding(1)
        )
        // Drops are handled by the FileDropView underneath this view —
        // it understands VS Code/Electron/browser drags SwiftUI can't.
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(.quaternary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 22))
                    Text("Drop anything here")
                        .font(.system(.caption, design: .rounded))
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
