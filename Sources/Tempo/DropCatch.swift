import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Turning dropped text into URLs (pure, covered by --check)

enum DroppedURLs {
    /// Accepts absolute paths, ~ paths, file:// and http(s) links. Rejects the rest.
    static func url(fromString raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("file://") { return URL(string: s) }
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        if s.hasPrefix("~") { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        if let url = URL(string: s), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https" {
            return url
        }
        return nil
    }

    /// One URL per line — the "uri-list" shape editors put on the pasteboard.
    static func urls(fromText text: String) -> [URL] {
        text.split(whereSeparator: \.isNewline).compactMap { url(fromString: String($0)) }
    }
}

/// Lights up the shelf border while a drag hovers over it.
@MainActor
final class DropGlow: ObservableObject {
    static let shared = DropGlow()
    @Published var targeted = false
}

// MARK: - An AppKit drop target that accepts far more than SwiftUI's does

/// SwiftUI's `.dropDestination` only understands modern file-URL drags.
/// VS Code, Conductor, Zed and browsers use older pasteboard types (path
/// lists, plain text, file promises) — this view reads them all.
final class FileDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onTargeted: ((Bool) -> Void)?
    /// Fires the instant anything is dropped, before parsing — lets the
    /// auto-shown shelf know it caught something and should stay open.
    var onAnyDrop: (() -> Void)?
    /// When set, plain clicks fall through to the status bar button below.
    weak var forwardClicksTo: NSStatusBarButton?

    private static let legacyPaths = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    /// Chromium/Electron apps put their drag payload under this type.
    static let chromiumData = NSPasteboard.PasteboardType("org.chromium.web-custom-data")
    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()

    /// Promised files (drags from browsers, Mail, some editors) get copied here.
    static var dropsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Tempo/Drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, Self.legacyPaths, .string, Self.chromiumData]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // Clicks pass straight through to the menu bar button (so the panel
    // still opens normally); only drags are handled here.
    override func mouseDown(with event: NSEvent) {
        if let button = forwardClicksTo { button.mouseDown(with: event) } else { super.mouseDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let button = forwardClicksTo { button.rightMouseDown(with: event) } else { super.rightMouseDown(with: event) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onTargeted?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargeted?(false)
    }

    /// Every drop attempt gets one line in /tmp/tempo-drop.log — reading it
    /// shows exactly which pasteboard types an app hands us (debug aid).
    private func logDrop(_ pb: NSPasteboard, note: String) {
        let types = (pb.types ?? []).map(\.rawValue).joined(separator: ", ")
        let text = (pb.string(forType: .string) ?? "").prefix(300)
        let line = "\(Date()) [\(note)] types=[\(types)] text=\(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/tempo-drop.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        onAnyDrop?()
        let pb = sender.draggingPasteboard
        logDrop(pb, note: "drop")

        // 1. Real URLs (Finder, Zed, modern apps).
        if let objects = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let urls = objects.filter {
                $0.isFileURL || $0.scheme == "http" || $0.scheme == "https"
            }
            if !urls.isEmpty {
                onDrop?(urls)
                return true
            }
        }

        // 2. Legacy path lists (Electron apps: VS Code, Conductor, …).
        if let paths = pb.propertyList(forType: Self.legacyPaths) as? [String], !paths.isEmpty {
            onDrop?(paths.map { URL(fileURLWithPath: $0) })
            return true
        }

        // 3. File promises (browsers, Mail): the file gets copied in first.
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
            !receivers.isEmpty {
            let dir = Self.dropsDirectory
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: Self.promiseQueue) { url, error in
                    guard error == nil else { return }
                    DispatchQueue.main.async { [weak self] in self?.onDrop?([url]) }
                }
            }
            return true
        }

        // 4. Plain text that looks like a path or link.
        if let text = pb.string(forType: .string) {
            let urls = DroppedURLs.urls(fromText: text)
            if !urls.isEmpty {
                onDrop?(urls)
                return true
            }
        }
        logDrop(pb, note: "unparsed")
        return false
    }
}

// MARK: - Auto-show the Shelf when a file drag starts anywhere

/// Watches the system drag pasteboard (cheap poll, ~5×/sec). When you start
/// dragging a file in any app, the Shelf pops up top-center so you can drop
/// there — dropping on the tiny menu bar icon fights Mission Control, this
/// doesn't. If the drag ends elsewhere, the auto-shown shelf slips away again.
@MainActor
final class DragWatcher {
    static let shared = DragWatcher()
    private var timer: Timer?
    private var lastChange = NSPasteboard(name: .drag).changeCount
    private var dragActive = false

    private static let fileTypes: Set<NSPasteboard.PasteboardType> =
        Set([.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType"), FileDropView.chromiumData]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { DragWatcher.shared.tick() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let pb = NSPasteboard(name: .drag)
        let mouseIsDown = NSEvent.pressedMouseButtons & 1 == 1
        if dragActive {
            if !mouseIsDown {
                dragActive = false
                ShelfWindow.shared.fileDragEnded()
            }
            return
        }
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        // A fresh drag pasteboard + button held = a drag is in flight.
        guard mouseIsDown, hasFiles(pb), let store = ConfigStore.shared else { return }
        dragActive = true
        ShelfWindow.shared.revealForFileDrag(store: store)
    }

    private func hasFiles(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types else { return false }
        return types.contains { Self.fileTypes.contains($0) }
    }
}

// MARK: - Make the menu bar icon itself a drop target

/// Finds the app's status bar button after launch and lays a FileDropView
/// over it, so files dropped on the Tempo icon land straight on the Shelf.
/// (SwiftUI's MenuBarExtra gives no direct handle on the button, so we
/// look for it among the app's windows — the standard workaround.)
@MainActor
enum StatusItemDropper {
    /// The status item can appear a beat after launch; retry until found.
    static func installWhenReady(attempts: Int = 40) {
        guard attempts > 0 else { return }
        if install() { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            installWhenReady(attempts: attempts - 1)
        }
    }

    /// Safe to call repeatedly — cheap no-op once the overlay is in place.
    @discardableResult
    static func install() -> Bool {
        guard let button = statusButton() else { return false }
        if let existing = button.subviews.compactMap({ $0 as? FileDropView }).first {
            existing.frame = button.bounds
            return true
        }
        let drop = FileDropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.forwardClicksTo = button
        drop.onDrop = { urls in
            guard let store = ConfigStore.shared else { return }
            store.addToShelf(urls)
            ShelfWindow.shared.reveal(store: store)
        }
        button.addSubview(drop)
        return true
    }

    /// Where the Tempo icon sits on screen — lets the Shelf open right there.
    static func iconScreenFrame() -> NSRect? {
        statusButton()?.window?.frame
    }

    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows where window.className.contains("StatusBarWindow") {
            if let button = findButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let button = findButton(in: sub) { return button }
        }
        return nil
    }
}
