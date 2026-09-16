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

/// Chromium (Electron apps: Conductor, VS Code, browsers) bundles a web
/// page's custom drag data into one blob called a "Pickle". Layout, all
/// little-endian: uint32 payload size, uint32 entry count, then per entry
/// a key and a value — each a uint32 character count plus UTF-16 text,
/// padded so the next read starts on a 4-byte boundary.
enum ChromiumWebCustomData {
    static func entries(fromPickle data: Data) -> [String: String] {
        // Payload starts after the 4-byte size header; tolerate its absence.
        parse(data, from: 4) ?? parse(data, from: 0) ?? [:]
    }

    /// Pull anything path- or link-shaped out of the blob.
    static func urls(fromPickle data: Data) -> [URL] {
        let map = entries(fromPickle: data)
        for key in ["text/uri-list", "text/plain"] {
            if let value = map[key] {
                let urls = DroppedURLs.urls(fromText: value)
                if !urls.isEmpty { return urls }
            }
        }
        // Unknown keys? Any value that parses as paths/links still counts.
        return map.values.flatMap { DroppedURLs.urls(fromText: $0) }
    }

    private static func parse(_ raw: Data, from start: Int) -> [String: String]? {
        let data = Data(raw)  // rebase indices at 0
        var offset = start
        func readUInt32() -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            var value: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<(offset + 4)) }
            offset += 4
            return UInt32(littleEndian: value)
        }
        func readString() -> String? {
            guard let chars = readUInt32(), chars < 1_000_000 else { return nil }
            let bytes = Int(chars) * 2
            guard offset + bytes <= data.count else { return nil }
            let slice = data.subdata(in: offset..<(offset + bytes))
            offset += bytes
            offset = (offset + 3) & ~3
            return String(data: slice, encoding: .utf16LittleEndian)
        }
        guard let count = readUInt32(), count > 0, count < 1000 else { return nil }
        var map: [String: String] = [:]
        for _ in 0..<count {
            guard let key = readString(), let value = readString() else { return nil }
            map[key] = value
        }
        return map
    }
}

/// Every way apps put dragged files on a pasteboard, tried most-reliable
/// first. File promises are deliberately NOT here — they're async and some
/// apps (Chromium) promise files they never deliver, so they only run as a
/// last resort in FileDropView.
enum DropPayload {
    static let legacyPaths = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let webCustomData = NSPasteboard.PasteboardType("org.chromium.web-custom-data")

    static func urls(from pb: NSPasteboard) -> [URL] {
        // 1. Real URLs (Finder, Zed, modern apps).
        if let objects = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let urls = objects.filter {
                $0.isFileURL || $0.scheme == "http" || $0.scheme == "https"
            }
            if !urls.isEmpty { return urls }
        }
        // 2. Legacy path lists (older Electron file-tree drags).
        if let paths = pb.propertyList(forType: legacyPaths) as? [String], !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        // 3. Plain text that looks like a path or link (VS Code, Conductor).
        if let text = pb.string(forType: .string) {
            let urls = DroppedURLs.urls(fromText: text)
            if !urls.isEmpty { return urls }
        }
        // 4. Chromium's bundled custom drag data.
        if let blob = pb.data(forType: webCustomData) {
            let urls = ChromiumWebCustomData.urls(fromPickle: blob)
            if !urls.isEmpty { return urls }
        }
        return []
    }
}

/// Lights up the shelf border while a drag hovers over it (`targeted`) or
/// is in flight anywhere on screen (`dragInFlight`).
@MainActor
final class DropGlow: ObservableObject {
    static let shared = DropGlow()
    @Published var targeted = false
    @Published var dragInFlight = false
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

    /// Chromium/Electron drags (Conductor, VS Code, browsers) tag themselves
    /// with these — registering them lets those drags in even when no plain
    /// file type is present; the payload then usually sits in plain text.
    static let chromiumTypes: [NSPasteboard.PasteboardType] = [
        DropPayload.webCustomData,
        NSPasteboard.PasteboardType("org.chromium.chromium-initiated-drag"),
        NSPasteboard.PasteboardType("org.chromium.chromium-renderer-initiated-drag"),
        NSPasteboard.PasteboardType("org.chromium.drag-dummy-type"),
    ]

    /// Every live drop view — so a drag with brand-new types (each editor
    /// invents its own) can be registered everywhere the moment it starts.
    private static let registry = NSHashTable<FileDropView>.weakObjects()

    /// Called by DragWatcher when a drag begins: whatever types it carries,
    /// make sure every drop view accepts them, or draggingEntered never fires.
    static func acceptAlso(_ types: [NSPasteboard.PasteboardType]) {
        for view in registry.allObjects {
            let known = Set(view.registeredDraggedTypes)
            let fresh = types.filter { !known.contains($0) }
            guard !fresh.isEmpty else { continue }
            view.registerForDraggedTypes(view.registeredDraggedTypes + fresh)
        }
    }
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
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, DropPayload.legacyPaths, .string]
        types += Self.chromiumTypes
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
        Self.registry.add(self)
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
        Self.log("enter", pasteboard: sender.draggingPasteboard)
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
    static func log(_ note: String, pasteboard pb: NSPasteboard) {
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

        // Direct payloads first: URLs, path lists, plain text, Chromium
        // blobs. Promises used to run before the text check — and swallowed
        // Conductor's drops: Chromium promises a file it never delivers,
        // while the real path sits right there in the plain text.
        let urls = DropPayload.urls(from: pb)
        if !urls.isEmpty {
            Self.log("drop ok \(urls.count)", pasteboard: pb)
            onDrop?(urls)
            NSSound(named: "Pop")?.play()  // audible "got it!"
            return true
        }

        // Last resort: file promises (browsers, Mail) — a copy is written
        // into our Drops folder, then lands on the shelf.
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
            !receivers.isEmpty {
            Self.log("drop promise", pasteboard: pb)
            let dir = Self.dropsDirectory
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: Self.promiseQueue) { url, error in
                    guard error == nil else { return }
                    DispatchQueue.main.async { [weak self] in
                        self?.onDrop?([url])
                        NSSound(named: "Pop")?.play()
                    }
                }
            }
            return true
        }
        Self.log("drop unparsed", pasteboard: pb)
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
        Set([.fileURL, .URL, DropPayload.legacyPaths,
             NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
             NSPasteboard.PasteboardType("Apple files promise pasteboard type")]
            + FileDropView.chromiumTypes
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
        ShelfWindow.shared.tickIdle(dragActive: dragActive && mouseIsDown)
        if dragActive {
            if !mouseIsDown {
                dragActive = false
                DropGlow.shared.dragInFlight = false
                ShelfWindow.shared.fileDragEnded()
            }
            return
        }
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        // A fresh drag pasteboard + button held = a drag is in flight.
        guard mouseIsDown, let types = pb.types, !types.isEmpty else { return }
        // Whatever this app calls its drag data, accept it from now on.
        FileDropView.acceptAlso(types)
        FileDropView.log("dragstart", pasteboard: pb)
        guard hasFiles(pb), let store = ConfigStore.shared else { return }
        dragActive = true
        DropGlow.shared.dragInFlight = true
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
