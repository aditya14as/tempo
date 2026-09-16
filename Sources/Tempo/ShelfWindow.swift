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

    func toggle(store: ConfigStore) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        show(store: store)
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
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            panel.contentView = NSHostingView(rootView: ShelfView().environmentObject(store))
            // Park it near the top-right, under the menu bar item.
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - 284, y: f.maxY - 8))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
}

struct ShelfView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var dropTargeted = false

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
                    dropTargeted ? AnyShapeStyle(store.config.theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.1)),
                    lineWidth: dropTargeted ? 2 : 1
                )
                .padding(1)
        )
        .dropDestination(for: URL.self) { urls, _ in
            addDropped(urls)
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
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

    @discardableResult
    private func addDropped(_ urls: [URL]) -> Bool {
        let free = AppConfig.maxShelf - store.config.shelf.count
        guard free > 0, !urls.isEmpty else { return false }
        store.config.shelf.append(contentsOf: urls.prefix(free).map(ShelfItem.fromDroppedURL))
        return true
    }
}
