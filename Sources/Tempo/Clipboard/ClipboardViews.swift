import AppKit
import SwiftUI

// MARK: - Popup

/// The ⇧⌘C popup, laid out like Maccy: search and the history on the left
/// with a small menu under it, the selected entry in full on the right.
/// Keys are handled by `ClipboardController`; this view only draws and
/// handles the mouse.
struct ClipboardPopupView: View {
    @ObservedObject var controller: ClipboardController
    @EnvironmentObject var store: ConfigStore

    private var theme: Theme { store.config.theme }
    private var config: ClipboardConfig { store.config.clipboard }

    var body: some View {
        let size = controller.panelSize
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchBar
                Divider().opacity(0.5)
                list
                Divider().opacity(0.5)
                ClipFooter(controller: controller, theme: theme, config: config)
            }
            .frame(width: controller.listWidth)
            if controller.previewPaneShown {
                Divider().opacity(0.5)
                VStack(spacing: 0) {
                    ClipPreviewToolbar(controller: controller, item: controller.selected)
                    Divider().opacity(0.5)
                    if let item = controller.selected {
                        ClipPreviewPane(controller: controller, item: item)
                    } else {
                        Text("Nothing selected")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.025))
            }
        }
        .frame(width: size.width, height: size.height)
        .background(
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: ClipboardMetrics.cornerRadius, style: .continuous))
        )
        .clipShape(RoundedRectangle(cornerRadius: ClipboardMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ClipboardMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.gradient)
            ClipSearchField(controller: controller)
                .frame(height: 22)
            if config.paused {
                Text("Paused")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
            }
            Text("\(controller.results.count)")
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            ClipIconButton(symbol: "sidebar.right",
                           help: controller.previewPaneShown ? "Hide the preview" : "Show the preview",
                           tint: controller.previewPaneShown ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(.secondary)) {
                controller.togglePreviewPane()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: ClipboardMetrics.topBarHeight)
    }

    @ViewBuilder
    private var list: some View {
        if controller.results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: controller.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text(controller.query.isEmpty ? "Copy something and it shows up here." : "No matches")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                if !controller.query.isEmpty {
                    Text("↩ copies “\(controller.query)”")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 30)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 1) {
                        ForEach(controller.results) { item in
                            ClipRow(controller: controller, item: item, theme: theme,
                                    selected: item.id == controller.selectedID,
                                    hint: controller.hints[item.id])
                                .id(item.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: controller.selectedID) { _, id in
                    guard controller.selectedByKeyboard, let id else { return }
                    proxy.scrollTo(id)
                }
                .onChange(of: controller.isShown) { _, shown in
                    if shown, let id = controller.selectedID { proxy.scrollTo(id, anchor: .top) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// A key cap plus what it does, like the switcher's hints.
struct ClipHint: View {
    var key: String
    var label: String

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
            Text(label)
        }
        .font(.system(size: 10, design: .rounded))
        .foregroundStyle(.tertiary)
        .fixedSize()
    }
}

/// A small borderless toolbar button with a hover highlight.
private struct ClipIconButton: View {
    var symbol: String
    var help: String
    var tint: AnyShapeStyle = AnyShapeStyle(.secondary)
    var action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Footer

/// Maccy's menu under the list: clear, pause, settings, then the key hints.
private struct ClipFooter: View {
    @ObservedObject var controller: ClipboardController
    var theme: Theme
    var config: ClipboardConfig

    var body: some View {
        VStack(spacing: 0) {
            if controller.confirmingClear {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .frame(width: 16)
                    Text("Clear \(controller.unpinnedCount) item\(controller.unpinnedCount == 1 ? "" : "s")? Pinned ones stay.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    ClipHint(key: "↩", label: "clear")
                    ClipHint(key: "⎋", label: "cancel")
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.red.opacity(0.1)))
            } else {
                ClipMenuRow(symbol: "trash", title: "Clear all", shortcut: "⌥⌘⌫",
                            enabled: controller.unpinnedCount > 0) {
                    controller.confirmingClear = true
                }
            }
            ClipMenuRow(symbol: config.paused ? "play.circle" : "pause.circle",
                        title: config.paused ? "Resume recording" : "Pause recording",
                        shortcut: nil,
                        tint: config.paused ? .orange : nil) {
                controller.togglePaused()
            }
            ClipMenuRow(symbol: "gearshape", title: "Settings…", shortcut: "⌘,") {
                controller.openSettings()
            }
            HStack(spacing: 10) {
                let pastes = config.pasteOnSelect
                ClipHint(key: "↩", label: pastes ? "paste" : "copy")
                ClipHint(key: "⌥↩", label: pastes ? "copy" : "paste")
                ClipHint(key: "⇧↩", label: config.plainTextPaste ? "formatted" : "plain")
                ClipHint(key: "⌥P", label: "pin")
                ClipHint(key: "⌥⌫", label: "delete")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }
}

/// One menu-like row in the footer: icon, title, shortcut on the right.
private struct ClipMenuRow: View {
    var symbol: String
    var title: String
    var shortcut: String?
    var enabled = true
    var tint: Color?
    var action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                Text(title)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                Spacer(minLength: 6)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering && enabled ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

// MARK: - Rows

/// One history entry. Not observing the controller: a row redraws only
/// when its own inputs change, which keeps arrow keys cheap on long lists.
private struct ClipRow: View {
    let controller: ClipboardController
    var item: ClipItem
    var theme: Theme
    var selected: Bool
    var hint: String?

    var body: some View {
        HStack(spacing: 9) {
            if item.kind == .image {
                ClipThumbnail(item: item, maxHeight: ClipboardMetrics.thumbnailHeight,
                              maxWidth: ClipboardMetrics.thumbnailWidth, maxPixel: 300)
                Spacer(minLength: 6)
            } else {
                ClipKindIcon(item: item, size: 20)
                Text(ClipText.oneLine(item.title))
                    .font(.system(size: 13, weight: selected ? .medium : .regular, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
            }
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.gradient)
            }
            if let icon = controller.appIcon(item.appBundleID) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 14, height: 14)
            }
            Text(hint ?? "")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 26, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, item.kind == .image ? 5 : 0)
        .frame(minHeight: ClipboardMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? AnyShapeStyle(theme.gradient.opacity(0.28)) : AnyShapeStyle(Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.clear), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { controller.hoverSelect(item.id) }
        }
        .onTapGesture { controller.click(item) }
        .contextMenu {
            Button("Paste") { controller.paste(item, plain: false) }
            Button("Paste as plain text") { controller.paste(item, plain: true) }
            Button("Copy") { controller.copy(item, plain: false) }
            if ClipboardController.imageText(item) != nil {
                Button("Copy text in image") { controller.copyImageText(item) }
            }
            Divider()
            Button(item.isPinned ? "Unpin" : "Pin") { ClipboardHistory.shared.togglePin(item.id) }
            Button("Delete") { ClipboardHistory.shared.delete(item.id) }
        }
    }
}

/// An image entry's picture at its own aspect ratio, sized from the
/// dimensions in its title so the row never changes height while it loads.
struct ClipThumbnail: View {
    var item: ClipItem
    var maxHeight: CGFloat
    var maxWidth: CGFloat
    var maxPixel: CGFloat
    @ViewState private var loaded: (id: UUID, image: NSImage)?

    var body: some View {
        let mine = loaded?.id == item.id ? loaded?.image : nil
        let image = mine ?? ClipboardHistory.shared.cachedThumbnail(item, maxPixel: maxPixel)
        let size = ClipText.fittedSize(ClipText.pixelSize(item) ?? image?.size, maxWidth: maxWidth, maxHeight: maxHeight)
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                shape.fill(Color.primary.opacity(0.06))
                    .overlay(Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(.tertiary))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .task(id: item.id) {
            if let image = await ClipboardHistory.shared.thumbnail(item, maxPixel: maxPixel) { loaded = (item.id, image) }
        }
    }
}

/// The small picture at the start of a text row: a colour swatch or an SF
/// Symbol for the kind. (Image rows show a `ClipThumbnail` instead.)
struct ClipKindIcon: View {
    var item: ClipItem
    var size: CGFloat

    var body: some View {
        Group {
            switch item.kind {
            case .color:
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ClipText.color(fromHex: item.title) ?? .gray)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    .frame(width: size * 0.8, height: size * 0.8)
            case .image: symbol("photo")
            case .text: symbol("doc.text")
            case .richText: symbol("doc.richtext")
            case .files: symbol("doc")
            case .link: symbol("link")
            }
        }
        .frame(width: size, height: size)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.6))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Preview pane

/// Over the preview: what the selected entry is, and buttons for it.
private struct ClipPreviewToolbar: View {
    @ObservedObject var controller: ClipboardController
    var item: ClipItem?

    var body: some View {
        HStack(spacing: 2) {
            if let item {
                Text(ClipText.kindName(item.kind))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                Spacer(minLength: 4)
                if ClipboardController.imageText(item) != nil {
                    ClipIconButton(symbol: "text.viewfinder", help: "Copy the text in this image  ⌥T") {
                        controller.copyImageText(item)
                    }
                }
                ClipIconButton(symbol: item.isPinned ? "pin.slash" : "pin",
                               help: item.isPinned ? "Unpin  ⌥P" : "Pin  ⌥P") {
                    controller.togglePinSelected()
                }
                ClipIconButton(symbol: "trash", help: "Delete  ⌥⌫") {
                    controller.deleteSelected()
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: ClipboardMetrics.topBarHeight)
    }
}

/// The selected entry in full, with what's known about it underneath.
private struct ClipPreviewPane: View {
    let controller: ClipboardController
    var item: ClipItem

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            ClipMetadata(controller: controller, item: item)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            ClipLargeImage(item: item)
                .padding(14)
        case .files:
            ClipFileList(urls: controller.fileURLs(item))
        case .color:
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ClipText.color(fromHex: item.title) ?? .gray)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .frame(maxWidth: 220, maxHeight: 160)
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(20)
        default:
            ClipTextPreview(text: controller.previewText(item))
        }
    }
}

/// An image entry fitted to the pane; shows the list's smaller thumbnail
/// while the big one decodes, so moving the selection never flashes.
private struct ClipLargeImage: View {
    var item: ClipItem
    @ViewState private var loaded: (id: UUID, image: NSImage)?

    var body: some View {
        let history = ClipboardHistory.shared
        let big = loaded?.id == item.id ? loaded?.image : nil
        content(big ?? history.cachedThumbnail(item, maxPixel: 1200) ?? history.cachedThumbnail(item, maxPixel: 300))
            .task(id: item.id) {
                if let image = await history.thumbnail(item, maxPixel: 1200) { loaded = (item.id, image) }
            }
    }

    @ViewBuilder
    private func content(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Image(systemName: "photo")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ClipFileList: View {
    var urls: [URL]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(url.deletingLastPathComponent().path)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Maccy's info block: where it came from, how big, when, how often.
private struct ClipMetadata: View {
    let controller: ClipboardController
    var item: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                if let name = item.appName ?? item.appBundleID {
                    GridRow {
                        label("Application:")
                        HStack(spacing: 4) {
                            if let icon = controller.appIcon(item.appBundleID) {
                                Image(nsImage: icon).resizable().interpolation(.high)
                                    .frame(width: 14, height: 14)
                                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                            }
                            Text(name).lineLimit(1)
                        }
                    }
                }
                switch item.kind {
                case .image:
                    if let size = ClipText.pixelSize(item) {
                        row("Dimensions:", "\(ClipText.number(Int(size.width)))×\(ClipText.number(Int(size.height)))")
                    }
                case .files:
                    row("Files:", ClipText.number(controller.fileURLs(item).count))
                case .color:
                    EmptyView()
                default:
                    let count = controller.previewText(item).count
                    row("Characters:", ClipText.number(count) + (count >= 20_000 ? "+" : ""))
                }
                if item.bytes > 0 {
                    row("Size:", ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
                }
                row("First copy time:", ClipText.dateTime(item.firstCopied))
                row("Last copy time:", ClipText.dateTime(item.lastCopied))
                row("Number of copies:", ClipText.number(item.copies))
                if let pin = item.pin {
                    row("Pinned:", "⌘" + pin.uppercased())
                }
            }
            if let text = ClipboardController.imageText(item) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Text in image", systemImage: "text.viewfinder")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
        }
        .font(.system(size: 11, design: .rounded))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            label(title)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// The preview's text: AppKit, so 20,000 characters scroll smoothly and can
/// be selected (⌘C copies the selection; typing goes back to the search).
private struct ClipTextPreview: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 10, height: 12)
            view.textContainer?.lineFragmentPadding = 4
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.scroll(.zero)
    }
}

// MARK: - Text helpers

enum ClipText {
    /// Titles are shown on one line: collapse newlines and runs of spaces.
    static func oneLine(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ⏎ ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// "#RGB", "#RRGGBB" or "#RRGGBBAA" → a colour.
    static func color(fromHex text: String) -> Color? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 6 ? (value << 8) | 0xFF : value
        return Color(.sRGB,
                     red: Double((rgba >> 24) & 0xFF) / 255,
                     green: Double((rgba >> 16) & 0xFF) / 255,
                     blue: Double((rgba >> 8) & 0xFF) / 255,
                     opacity: Double(rgba & 0xFF) / 255)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func ago(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 30 ? "just now" : relative.localizedString(for: date, relativeTo: Date())
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    static func dateTime(_ date: Date) -> String { dateFormatter.string(from: date) }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter
    }()

    /// 3004 → "3,004".
    static func number(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func kindName(_ kind: ClipKind) -> String {
        switch kind {
        case .text: return "Text"
        case .richText: return "Formatted text"
        case .image: return "Image"
        case .files: return "Files"
        case .color: return "Colour"
        case .link: return "Link"
        }
    }

    /// An image entry's size in pixels, from its title ("Image 1200×800").
    static func pixelSize(_ item: ClipItem) -> CGSize? {
        guard item.kind == .image, let last = item.title.split(separator: " ").last else { return nil }
        let parts = last.split(separator: "×")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// A thumbnail frame at the image's aspect ratio inside the bounds;
    /// small images aren't blown up past their size. Unknown → a square.
    static func fittedSize(_ pixels: CGSize?, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard let pixels, pixels.width > 0, pixels.height > 0 else { return CGSize(width: maxHeight, height: maxHeight) }
        let aspect = pixels.width / pixels.height
        var height = min(maxHeight, max(pixels.height, 16))
        var width = height * aspect
        if width > maxWidth {
            width = maxWidth
            height = max(width / aspect, 8)
        }
        return CGSize(width: max(width, 16).rounded(), height: height.rounded())
    }
}

// MARK: - Search field

/// An AppKit text field, so the controller can make it first responder the
/// moment the panel opens (SwiftUI focus can't be set from outside a view).
struct ClipSearchField: NSViewRepresentable {
    @ObservedObject var controller: ClipboardController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        let base = NSFont.systemFont(ofSize: 15)
        field.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 15) } ?? base
        field.placeholderString = "Type to search…"
        field.delegate = context.coordinator
        controller.searchField = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let query = controller.query
        guard field.stringValue != query else { return }
        if let editor = field.currentEditor() as? NSTextView {
            if !editor.hasMarkedText() { editor.string = query }
        } else {
            field.stringValue = query
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            ClipboardController.shared.query = field.stringValue
        }
    }
}

// MARK: - Menu bar tab

/// The Clips tab in the menu bar panel: the latest few entries, search,
/// and a way into the full popup.
struct ClipboardTab: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var history = ClipboardHistory.shared
    @ViewState private var query = ""
    @ViewState private var copiedID: UUID?
    @ViewState private var confirmClear = false

    private var theme: Theme { store.config.theme }
    private var config: ClipboardConfig { store.config.clipboard }

    var body: some View {
        let items = Array(history.visible(query: query).prefix(8))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(.subheadline, design: .rounded))
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                Button {
                    // Let the menu bar panel close first so the popup takes key cleanly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        MainActor.assumeIsolated { ClipboardController.shared.show() }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.and.text.magnifyingglass")
                        Text(config.shortcut?.label ?? "Open")
                    }
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(theme.gradient))
                    .foregroundStyle(.white)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Open the clipboard popup")
            }

            VStack(spacing: 2) {
                if items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                        Text(query.isEmpty ? "Copy something and it shows up here." : "No matches")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    ForEach(items) { item in
                        TabRow(item: item, theme: theme, copied: copiedID == item.id) { plain in
                            copy(item, plain: plain)
                        }
                    }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))

            HStack(spacing: 10) {
                Toggle(isOn: $store.config.clipboard.paused) {
                    Text(config.paused ? "Paused" : "Pause recording")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(config.paused ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                if history.ignoringNext {
                    Text("Skipping next copy")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.tertiary)
                } else {
                    Button("Skip next copy") { history.ignoreNextCopy() }
                        .buttonStyle(.plain)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                        .help("Don't record the next thing you copy")
                }
                Spacer(minLength: 4)
                if confirmClear {
                    Button("Cancel") { confirmClear = false }
                        .buttonStyle(.plain)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                    Button("Clear") {
                        history.clear(keepPinned: true)
                        confirmClear = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.red)
                } else {
                    Button {
                        confirmClear = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .font(.system(.caption, design: .rounded))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(history.items.allSatisfy(\.isPinned))
                    .help("Clear the history (pinned entries stay)")
                }
            }
        }
    }

    private func copy(_ item: ClipItem, plain: Bool) {
        history.copy(item, plain: plain)
        copiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated { if copiedID == item.id { copiedID = nil } }
        }
    }

    private struct TabRow: View {
        var item: ClipItem
        var theme: Theme
        var copied: Bool
        var copy: (Bool) -> Void
        @ViewState private var hovering = false

        var body: some View {
            Button {
                copy(false)
            } label: {
                HStack(spacing: 8) {
                    // Every row keeps one height: a big picture here spilled
                    // over its neighbours. The popup has room for large ones.
                    if item.kind == .image {
                        ClipThumbnail(item: item, maxHeight: 20, maxWidth: 28, maxPixel: 64)
                            .frame(width: 28, height: 20)
                    } else {
                        ClipKindIcon(item: item, size: 18)
                            .frame(width: 28, height: 20)
                    }
                    Text(ClipText.oneLine(item.title))
                        .font(.system(.subheadline, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if copied {
                        Text("Copied")
                            .font(.system(.caption2, design: .rounded).weight(.semibold))
                            .foregroundStyle(theme.gradient)
                    } else if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.gradient)
                    } else {
                        Text(ClipText.ago(item.lastCopied))
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(item.title.count > 60 ? String(item.title.prefix(400)) : "")
            .contextMenu {
                Button("Copy") { copy(false) }
                Button("Copy as plain text") { copy(true) }
                Divider()
                Button(item.isPinned ? "Unpin" : "Pin") { ClipboardHistory.shared.togglePin(item.id) }
                Button("Delete") { ClipboardHistory.shared.delete(item.id) }
            }
        }
    }
}
