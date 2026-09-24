import AppKit
import Combine
import ImageIO
import os

/// The clipboard history's engine: watches the pasteboard, keeps what was
/// copied, and puts an entry back when it's picked.
///
/// Recording works like Maccy. macOS has no "pasteboard changed" event, so
/// the change count is polled twice a second while recording is on. Each new
/// copy is read in full (every pasteboard item, merged into one entry),
/// filtered by the user's settings, and deduplicated against the history.
///
/// Storage: `~/Library/Application Support/Tempo/Clipboard/` holds
/// `history.json` (the entries) and `blobs/<id>/<n>`, the raw data for type
/// `types[n]` of that entry. Copies can hold passwords and private text, so
/// the folder is owner-only. The data is read back only when an entry is
/// copied, pasted or previewed.
@MainActor
final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()

    /// Tempo's own marker type, written on every copy Tempo makes.
    nonisolated static let markerType = NSPasteboard.PasteboardType("com.ivy.tempo.clip")

    /// All entries, newest first as recorded (use `visible(query:)` to list).
    @Published private(set) var items: [ClipItem] = []
    /// The next copy won't be recorded (the popup's "ignore next copy").
    @Published private(set) var ignoringNext = false
    /// An import from Maccy is running.
    @Published private(set) var importing = false
    /// How the last Maccy import went (entries added, or why it failed).
    @Published private(set) var lastMaccyImport: Result<Int, ClipboardImportError>?
    /// Maccy is open, and may take ⇧⌘C before Tempo sees it.
    @Published private(set) var maccyRunning = false

    /// Anything bigger isn't kept: a 200 MB screenshot or video copy would
    /// bloat the history and stall the save.
    nonisolated static let maxEntryBytes = 50 * 1024 * 1024
    private static let pollInterval: TimeInterval = 0.5
    private static let saveDelay: TimeInterval = 0.5
    private static let previewLimit = 20_000

    private weak var store: ConfigStore?
    private var config = ClipboardConfig()
    private var configObservation: AnyCancellable?
    private var pollTimer: Timer?
    private var lastChangeCount = 0
    /// Content hash per entry, for spotting repeats (kept in `index.json`).
    private var fingerprints: [UUID: String] = [:]
    private var saveWork: DispatchWorkItem?
    private var directory: URL?
    /// Disk work runs here, in order, so a read always sees earlier writes.
    private let io = DispatchQueue(label: "com.ivy.tempo.clipboard.io", qos: .utility)
    private let thumbnails = NSCache<NSString, NSImage>()
    private var thumbnailWaiters: [String: [CheckedContinuation<NSImage?, Never>]] = [:]
    private var thumbnailFailures: Set<String> = []
    /// Decoding has its own queue so a big image never holds up saving.
    private let thumbnailQueue = DispatchQueue(label: "com.ivy.tempo.clipboard.thumbnails", qos: .userInitiated)
    /// Image entries waiting for their text to be read, next first.
    private var ocrPending: [UUID] = []
    private var ocrRunning = false
    private let log = Logger(subsystem: "com.ivy.tempo", category: "clipboard")

    private init() {
        thumbnails.countLimit = 300
        // Big previews are up to 1200 px; bound the bytes, not just the count.
        thumbnails.totalCostLimit = 48 << 20
    }

    // MARK: - Lifecycle

    func start(store: ConfigStore) {
        guard self.store == nil else { return }
        // `--check` has no store of its own and must never touch real history.
        guard !CommandLine.arguments.contains("--check") else { return }
        self.store = store
        directory = Self.makeDirectory()
        load()
        configObservation = store.$config
            .map(\.clipboard)
            .removeDuplicates()
            .sink { config in
                DispatchQueue.main.async { MainActor.assumeIsolated { ClipboardHistory.shared.apply(config) } }
            }
        apply(store.config.clipboard)
        // A limit lowered since last run (or the old 200 default becoming
        // 150) applies right away, not only at the next copy.
        trim()
        watchMaccy()
        // Images saved before text was read out of them: newest first, one
        // at a time, after launch has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                let history = ClipboardHistory.shared
                history.queueOCR(ClipboardLogic.needingOCR(history.items))
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { ClipboardHistory.shared.willTerminate() } }
    }

    private func apply(_ new: ClipboardConfig) {
        let old = config
        config = new
        let recording = new.enabled && !new.paused
        if recording, pollTimer == nil {
            // Whatever was copied while off or paused stays unrecorded.
            lastChangeCount = NSPasteboard.general.changeCount
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
                MainActor.assumeIsolated { ClipboardHistory.shared.poll() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
            log.notice("recording on")
        } else if !recording, let timer = pollTimer {
            timer.invalidate()
            pollTimer = nil
            log.notice("recording off (enabled=\(new.enabled, privacy: .public) paused=\(new.paused, privacy: .public))")
        }
        if new.historySize != old.historySize { trim() }
    }

    private func willTerminate() {
        if config.clearOnQuit { clear(keepPinned: true) }
        flush()
    }

    // MARK: - Listing

    /// The entries to show for what's typed: in the configured order (pins
    /// on top if set), narrowed by the configured search mode. Matches the
    /// title or the text read out of an image.
    func visible(query: String) -> [ClipItem] {
        let sorted = ClipboardLogic.sorted(items, by: config.sort, pinsOnTop: config.pinsOnTop)
        return ClipboardLogic.filter(sorted, query: query, mode: config.searchMode, pinsOnTop: config.pinsOnTop)
    }

    /// A small picture of an image entry, if it's already decoded. Never
    /// starts work, so a view can call it while drawing.
    func cachedThumbnail(_ item: ClipItem, maxPixel: CGFloat) -> NSImage? {
        thumbnails.object(forKey: Self.thumbnailKey(item, maxPixel) as NSString)
    }

    /// Decodes a small picture of an image entry in the background (once per
    /// size) and hands it back; nil for anything that isn't a readable image.
    /// Only the asking view redraws when it arrives: republishing the whole
    /// history here made every clipboard view redraw, which asked for more
    /// thumbnails, and the list flickered in a loop.
    func thumbnail(_ item: ClipItem, maxPixel: CGFloat) async -> NSImage? {
        guard item.kind == .image, let index = item.types.firstIndex(where: ClipboardLogic.isImageType),
            let file = blobURL(item.id, index)
        else { return nil }
        let key = Self.thumbnailKey(item, maxPixel)
        if let cached = thumbnails.object(forKey: key as NSString) { return cached }
        // A file that didn't decode won't next time either.
        if thumbnailFailures.contains(key) { return nil }
        return await withCheckedContinuation { waiter in
            if thumbnailWaiters[key] != nil {
                thumbnailWaiters[key]?.append(waiter)
                return
            }
            thumbnailWaiters[key] = [waiter]
            let pixel = max(Int(maxPixel), 16)
            thumbnailQueue.async {
                let image = Self.decodeThumbnail(file, maxPixel: pixel)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let history = ClipboardHistory.shared
                        if let image {
                            let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
                            history.thumbnails.setObject(image, forKey: key as NSString, cost: pixels * 4)
                        } else {
                            history.thumbnailFailures.insert(key)
                        }
                        for waiter in history.thumbnailWaiters.removeValue(forKey: key) ?? [] {
                            waiter.resume(returning: image)
                        }
                    }
                }
            }
        }
    }

    private static func thumbnailKey(_ item: ClipItem, _ maxPixel: CGFloat) -> String {
        "\(item.id.uuidString)-\(Int(maxPixel))"
    }

    private nonisolated static func decodeThumbnail(_ file: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// The full text for the preview: the plain text (or the text inside the
    /// formatting), else the file paths one per line, else the title.
    func previewText(_ item: ClipItem) -> String {
        if item.kind == .files {
            let paths = fileURLs(item).map(\.path).joined(separator: "\n")
            if !paths.isEmpty { return paths }
        }
        // Only the text types are read: an image entry's blob can be 50 MB.
        let pairs = loadPairs(item) { ClipboardLogic.isPlainTextType($0) || ClipboardLogic.isRichTextType($0) }
        let text = Self.plainText(in: pairs) ?? item.title
        return text.count > Self.previewLimit ? String(text.prefix(Self.previewLimit)) : text
    }

    func fileURLs(_ item: ClipItem) -> [URL] {
        guard item.types.contains(ClipboardLogic.fileURLType) else { return [] }
        return loadPairs(item) { $0 == ClipboardLogic.fileURLType }.compactMap { Self.fileURL(from: $0.data) }
    }

    // MARK: - Actions

    /// Puts an entry back on the pasteboard (plain = text only) and moves it
    /// to the top of the history. False when its data is gone (it's dropped).
    @discardableResult
    func copy(_ item: ClipItem, plain: Bool) -> Bool {
        let pairs = loadPairs(item)
        guard !pairs.isEmpty else {
            log.error("copy: no stored data for an entry, dropping it")
            delete(item.id)
            return false
        }
        write(pairs, plain: plain)
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return true }
        var entry = items.remove(at: index)
        entry.lastCopied = Date()
        entry.copies += 1
        items.insert(entry, at: 0)
        scheduleSave()
        return true
    }

    /// Copies the entry, then pastes it into the front app with a ⌘V ~60 ms
    /// later (once the popup is gone and that app is key again). Without
    /// Accessibility it's only copied; if nothing could be copied, nothing
    /// is pasted either (⌘V would paste whatever was there before).
    func paste(_ item: ClipItem, plain: Bool) {
        guard copy(item, plain: plain) else { return }
        guard Permissions.accessibilityGranted else {
            log.notice("paste: no Accessibility, copied only")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            MainActor.assumeIsolated { ClipboardPaster.pasteIntoFrontApp() }
        }
    }

    /// ↩ with nothing matching: copy what was typed (and remember it).
    func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        let pairs = [(type: ClipboardLogic.plainTextType, data: Data(text.utf8))]
        write(pairs, plain: false)
        guard config.enabled, !config.paused else { return }
        if let entry = makeEntry(pairs: pairs, bundleID: nil, appName: nil) { add(entry, pairs: pairs) }
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        fingerprints[id] = nil
        removeBlobs([id])
        scheduleSave()
    }

    /// Pins with the first free letter, or unpins. With every letter taken
    /// it stays unpinned.
    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].isPinned {
            // Not trimmed now: an old entry shouldn't vanish the moment it's
            // unpinned. The next copy applies the limit.
            items[index].pin = nil
        } else if let letter = ClipboardLogic.nextPin(used: Set(items.compactMap(\.pin))) {
            items[index].pin = letter
        } else {
            log.notice("pin: all letters taken")
            return
        }
        scheduleSave()
    }

    func clear(keepPinned: Bool) {
        let gone = items.filter { !keepPinned || !$0.isPinned }.map(\.id)
        guard !gone.isEmpty else { return }
        let goneSet = Set(gone)
        items.removeAll { goneSet.contains($0.id) }
        for id in gone { fingerprints[id] = nil }
        removeBlobs(gone)
        scheduleSave()
        log.notice("cleared \(gone.count, privacy: .public) entries")
    }

    func ignoreNextCopy() {
        ignoringNext = true
    }

    // MARK: - Recording

    typealias Pairs = [(type: String, data: Data)]

    /// What one look at the pasteboard found.
    enum ReadOutcome {
        /// A copy worth recording: every pasteboard item merged into one list.
        case copy(Pairs)
        /// Not kept; the reason is for the log (nil = say nothing, Tempo's own copy).
        case skipped(String?)
        /// The pasteboard changed again while it was being read. The data may
        /// mix two copies, so it's dropped; the next poll reads the newer one.
        case changed
    }

    private func poll() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard config.enabled, !config.paused else { return }
        if ignoringNext {
            ignoringNext = false
            log.notice("skipped: ignore next copy")
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        if let bundleID = app?.bundleIdentifier, config.ignoredApps.contains(where: { $0.bundleID == bundleID }) {
            log.notice("skipped: ignored app \(bundleID, privacy: .public)")
            return
        }
        switch Self.read(pb, changeCount: count, config: config) {
        case .copy(let pairs):
            guard let entry = makeEntry(pairs: pairs, bundleID: app?.bundleIdentifier, appName: app?.localizedName)
            else { return }
            add(entry, pairs: pairs)
        case .skipped(let reason):
            if let reason { log.notice("skipped: \(reason, privacy: .public)") }
        case .changed:
            log.notice("pasteboard changed while reading, rereading next poll")
        }
    }

    /// Reads the copy on `pb` (made at `changeCount`), filtered by the
    /// settings. Merges every pasteboard item into one list (BBEdit and Edge
    /// write two); file URLs are kept one per file.
    nonisolated static func read(_ pb: NSPasteboard, changeCount: Int, config: ClipboardConfig) -> ReadOutcome {
        let pbItems = pb.pasteboardItems ?? []
        var allTypes: [String] = []
        for item in pbItems {
            for type in item.types where !allTypes.contains(type.rawValue) { allTypes.append(type.rawValue) }
        }
        guard !allTypes.isEmpty else { return .skipped("empty pasteboard") }
        if allTypes.contains(markerType.rawValue) { return .skipped(nil) }  // Tempo's own copy
        if ClipboardLogic.shouldIgnore(types: allTypes, ignoredTypes: config.ignoredTypes) {
            return .skipped("ignored type")
        }

        var pairs: Pairs = []
        var total = 0
        // TIFF is the uncompressed twin of a PNG that often comes with it; a
        // 5K screenshot's TIFF alone is ~60 MB. It's only kept if it fits.
        var spareTIFFs: [NSPasteboardItem] = []
        for item in pbItems {
            let types = ClipboardLogic.storableTypes(item.types.map(\.rawValue))
            for type in types {
                if !config.saveRichText, ClipboardLogic.isRichTextType(type) { continue }
                if !config.saveImages, ClipboardLogic.isImageType(type) { continue }
                if type == tiffType, types.contains(where: { $0 != tiffType && ClipboardLogic.isImageType($0) }) {
                    spareTIFFs.append(item)
                    continue
                }
                let isFile = type == ClipboardLogic.fileURLType
                if !isFile, pairs.contains(where: { $0.type == type }) { continue }
                guard let data = item.data(forType: NSPasteboard.PasteboardType(type)) else { continue }
                if isFile, pairs.contains(where: { $0.type == type && $0.data == data }) { continue }
                total += data.count
                if total > maxEntryBytes { return .skipped("copy over \(maxEntryBytes / 1_048_576) MB") }
                pairs.append((type, data))
            }
        }
        for item in spareTIFFs where !pairs.contains(where: { $0.type == tiffType }) {
            guard let data = item.data(forType: NSPasteboard.PasteboardType(tiffType)),
                total + data.count <= maxEntryBytes
            else { continue }
            total += data.count
            pairs.append((tiffType, data))
        }
        // Items read after a newer copy can come back empty or from that copy.
        guard pb.changeCount == changeCount else { return .changed }
        return .copy(pairs)
    }

    private nonisolated static let tiffType = "public.tiff"

    /// Builds the entry for a copy, or nil (with the reason logged) when the
    /// settings say it isn't kept.
    private func makeEntry(pairs: Pairs, bundleID: String?, appName: String?) -> ClipItem? {
        guard !pairs.isEmpty else {
            log.notice("skipped: nothing storable")
            return nil
        }
        var entry = ClipItem()
        entry.types = pairs.map(\.type)
        entry.bytes = pairs.reduce(0) { $0 + $1.data.count }
        entry.appBundleID = bundleID
        entry.appName = appName

        let files = pairs.filter { $0.type == ClipboardLogic.fileURLType }.compactMap { Self.fileURL(from: $0.data) }
        let text = Self.plainText(in: pairs)
        let hasRich = pairs.contains { ClipboardLogic.isRichTextType($0.type) }
        let image = pairs.first { ClipboardLogic.isImageType($0.type) }

        if let text, ClipboardLogic.matchesIgnoredPattern(text, patterns: config.ignoredPatterns) {
            log.notice("skipped: matches an ignored pattern")
            return nil
        }
        if !files.isEmpty {
            guard config.saveFiles else {
                log.notice("skipped: files not saved")
                return nil
            }
            entry.kind = .files
            entry.title = ClipboardLogic.title(forText: files.map(\.lastPathComponent).joined(separator: ", "))
        } else if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let kind = ClipboardLogic.kind(forText: text)
            entry.kind = kind == .text && hasRich ? .richText : kind
            entry.title = ClipboardLogic.title(forText: text)
        } else if let image {
            entry.kind = .image
            entry.title = Self.imageTitle(image.data)
        } else {
            log.notice("skipped: no text, files or image (types \(pairs.map(\.type).joined(separator: ","), privacy: .public))")
            return nil
        }
        return entry
    }

    /// Adds a recorded copy, or — when the same content is already in the
    /// history — bumps that entry instead (keeping its pin and first date).
    private func add(_ entry: ClipItem, pairs: Pairs) {
        let fingerprint = ClipboardLogic.fingerprint(pairs)
        if let index = items.firstIndex(where: { fingerprints[$0.id] == fingerprint }) {
            var existing = items.remove(at: index)
            existing.lastCopied = Date()
            existing.copies += 1
            // Same main content, but the formatting (or the icon, the source
            // page…) may differ this time: keep the newest copy's data, so
            // pasting gives back what was copied last.
            existing.types = entry.types
            existing.bytes = entry.bytes
            existing.kind = entry.kind
            existing.title = entry.title
            // Same image bytes (that's the fingerprint), so its text stands;
            // an image that replaces text needs reading.
            if existing.kind != .image { existing.ocrText = nil }
            writeBlobs(existing.id, pairs)
            if entry.appBundleID != nil {
                existing.appBundleID = entry.appBundleID
                existing.appName = entry.appName
            }
            items.insert(existing, at: 0)
            if existing.kind == .image, existing.ocrText == nil { queueOCR([existing.id], first: true) }
            log.notice("repeat copy bumped (kind \(existing.kind.rawValue, privacy: .public))")
        } else {
            items.insert(entry, at: 0)
            fingerprints[entry.id] = fingerprint
            writeBlobs(entry.id, pairs)
            if entry.kind == .image { queueOCR([entry.id], first: true) }
            log.notice("recorded \(entry.kind.rawValue, privacy: .public) from \(entry.appBundleID ?? "?", privacy: .public), types \(entry.types.joined(separator: ","), privacy: .public)")
        }
        trim()
        scheduleSave()
    }

    private func trim() {
        let (kept, dropped) = ClipboardLogic.trimmed(items, limit: config.historySize)
        guard !dropped.isEmpty else { return }
        items = kept
        for item in dropped { fingerprints[item.id] = nil }
        removeBlobs(dropped.map(\.id))
        scheduleSave()
    }

    // MARK: - Text in images

    /// Queues image entries to have their text read (see `ClipboardOCR`).
    /// `first` puts them ahead of the backlog: a fresh copy is the one
    /// someone is about to search for.
    private func queueOCR(_ ids: [UUID], first: Bool = false) {
        let new = ids.filter { !ocrPending.contains($0) }
        guard !new.isEmpty else { return }
        ocrPending = first ? new + ocrPending : ocrPending + new
        runNextOCR()
    }

    private func runNextOCR() {
        guard !ocrRunning else { return }
        while !ocrPending.isEmpty {
            let id = ocrPending.removeFirst()
            guard let item = items.first(where: { $0.id == id }), item.kind == .image, item.ocrText == nil,
                let index = item.types.firstIndex(where: ClipboardLogic.isImageType),
                let file = blobURL(id, index)
            else { continue }
            ocrRunning = true
            // Through the disk queue first, so a copy's data is written before
            // it's read back.
            io.async {
                ClipboardOCR.recognize(file) { text in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { ClipboardHistory.shared.finishOCR(id, text: text) }
                    }
                }
            }
            return
        }
    }

    private func finishOCR(_ id: UUID, text: String?) {
        ocrRunning = false
        if let index = items.firstIndex(where: { $0.id == id }), items[index].ocrText == nil {
            // "" = read, nothing found (or unreadable): never tried again.
            items[index].ocrText = text ?? ""
            scheduleSave()
        }
        // A breather between images keeps a backlog from pinning a core.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated { ClipboardHistory.shared.runNextOCR() }
        }
    }

    // MARK: - Importing from Maccy

    /// Where Maccy keeps its history (inside its sandbox container).
    nonisolated static var maccyHistoryURL: URL { MaccyImport.historyURL }
    /// Whether Maccy has been used on this Mac (its container exists).
    nonisolated static var maccyInstalled: Bool { MaccyImport.installed }

    private func watchMaccy() {
        updateMaccyRunning()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == MaccyImport.bundleID else { return }
                MainActor.assumeIsolated { ClipboardHistory.shared.updateMaccyRunning() }
            }
        }
    }

    private func updateMaccyRunning() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: MaccyImport.bundleID)
            .contains { !$0.isTerminated }
        if running != maccyRunning { maccyRunning = running }
    }

    /// Quits Maccy so ⇧⌘C reaches Tempo. Only ever on the user's click.
    func quitMaccy() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: MaccyImport.bundleID) {
            app.terminate()
        }
    }

    /// Imports Maccy's history: each entry goes through the same steps as a
    /// copy Tempo records (settings, types, kind, title), keeps its dates,
    /// copy count and pin (letter permitting), and folds into an entry
    /// Tempo already has for the same content. The history size applies
    /// (pins aside). Returns how many new entries were added. Running it
    /// twice adds nothing the second time.
    func importMaccy() async -> Result<Int, ClipboardImportError> {
        guard directory != nil else { return .failure(.failed("the clipboard history isn't running.")) }
        guard !importing else { return .failure(.busy) }
        importing = true
        lastMaccyImport = nil
        let result = await runMaccyImport()
        lastMaccyImport = result
        importing = false
        return result
    }

    private func runMaccyImport() async -> Result<Int, ClipboardImportError> {
        let loaded = await Task.detached(priority: .userInitiated) { MaccyImport.load() }.value
        switch loaded {
        case .failure(let error):
            log.error("maccy import failed: \(error.message, privacy: .public)")
            return .failure(error)
        case .success(let records):
            let count = merge(records)
            log.notice("maccy import: \(records.count, privacy: .public) read, \(count, privacy: .public) added")
            return .success(count)
        }
    }

    private func merge(_ records: [MaccyRecord]) -> Int {
        var used = Set(items.compactMap(\.pin))
        var budget = max(config.historySize, 0)
        var added: [UUID] = []
        var names: [String: String?] = [:]
        for record in records.sorted(by: { $0.lastCopied > $1.lastCopied }) {
            guard let pairs = MaccyImport.pairs(for: record, config: config) else { continue }
            let fingerprint = ClipboardLogic.fingerprint(pairs)
            if let index = items.firstIndex(where: { fingerprints[$0.id] == fingerprint }) {
                // Already here (copied in both, or imported before): keep the
                // widest dates and the larger count, so a second import is a no-op.
                items[index].firstCopied = min(items[index].firstCopied, record.firstCopied)
                items[index].lastCopied = max(items[index].lastCopied, record.lastCopied)
                items[index].copies = max(items[index].copies, record.copies)
                if !items[index].isPinned, let letter = MaccyImport.pin(for: record.pin, used: used) {
                    items[index].pin = letter
                    used.insert(letter)
                }
                continue
            }
            let letter = MaccyImport.pin(for: record.pin, used: used)
            guard letter != nil || budget > 0 else { continue }
            let name: String?
            if let bundleID = record.application {
                if let cached = names[bundleID] {
                    name = cached
                } else {
                    name = Self.appName(bundleID)
                    names[bundleID] = name
                }
            } else {
                name = nil
            }
            guard var entry = makeEntry(pairs: pairs, bundleID: record.application, appName: name) else { continue }
            entry.firstCopied = record.firstCopied
            entry.lastCopied = record.lastCopied
            entry.copies = max(record.copies, 1)
            entry.pin = letter
            if let letter { used.insert(letter) } else { budget -= 1 }
            items.append(entry)
            fingerprints[entry.id] = fingerprint
            writeBlobs(entry.id, pairs)
            added.append(entry.id)
        }
        // Keep the history newest first, as if it had been recorded here.
        items = items.enumerated().sorted { a, b in
            if a.element.lastCopied != b.element.lastCopied { return a.element.lastCopied > b.element.lastCopied }
            return a.offset < b.offset
        }.map(\.element)
        trim()
        scheduleSave()
        let kept = Set(items.map(\.id))
        let survivors = added.filter { kept.contains($0) }
        queueOCR(ClipboardLogic.needingOCR(items.filter { survivors.contains($0.id) }))
        return survivors.count
    }

    private static func appName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    // MARK: - Writing to the pasteboard

    /// Writes stored data to the general pasteboard. A copy made elsewhere
    /// since the last poll is recorded first, or it would never be seen.
    private func write(_ pairs: Pairs, plain: Bool) {
        let pb = NSPasteboard.general
        if pb.changeCount != lastChangeCount { poll() }
        Self.fill(pb, with: pairs, plain: plain)
        lastChangeCount = pb.changeCount
    }

    /// Replaces what's on `pb` with stored data. File URLs each get their own
    /// pasteboard item (that's how Finder expects several files); everything
    /// else rides on the first. Plain keeps just the text — and the files, so
    /// a file copy still pastes as files. The marker keeps Tempo from
    /// recording its own copy, and `org.nspasteboard.source` names Tempo as
    /// the app that wrote it.
    nonisolated static func fill(_ pb: NSPasteboard, with pairs: Pairs, plain: Bool) {
        let first = NSPasteboardItem()
        var extra: [NSPasteboardItem] = []
        let text = plainText(in: pairs)
        let plainOnly = plain && text != nil
        if plainOnly, let text { first.setString(text, forType: .string) }
        var usedFirstFile = false
        for pair in pairs {
            let type = NSPasteboard.PasteboardType(pair.type)
            if pair.type == ClipboardLogic.fileURLType {
                if usedFirstFile {
                    let item = NSPasteboardItem()
                    item.setData(pair.data, forType: type)
                    extra.append(item)
                } else {
                    usedFirstFile = true
                    first.setData(pair.data, forType: type)
                }
                continue
            }
            if plainOnly || pair.type == ClipboardLogic.sourceType { continue }
            first.setData(pair.data, forType: type)
        }
        if first.types.isEmpty, let text { first.setString(text, forType: .string) }
        first.setData(Data(), forType: markerType)
        first.setString(Permissions.bundleID, forType: NSPasteboard.PasteboardType(ClipboardLogic.sourceType))
        pb.clearContents()
        pb.writeObjects([first] + extra)
    }

    // MARK: - Reading stored data

    private nonisolated static func plainText(in pairs: Pairs) -> String? {
        if let data = pairs.first(where: { ClipboardLogic.isPlainTextType($0.type) })?.data,
            let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        for pair in pairs where ClipboardLogic.isRichTextType(pair.type) {
            let type: NSAttributedString.DocumentType
            switch pair.type {
            case "public.rtf", "NeXT Rich Text Format v1.0 pasteboard type": type = .rtf
            case "public.rtfd", "com.apple.flat-rtfd", "NeXT RTFD pasteboard type": type = .rtfd
            case "public.html", "Apple HTML pasteboard type": type = .html
            default: continue
            }
            // HTML goes through WebKit, which must not run for huge blobs.
            if type == .html, pair.data.count > 2_000_000 { continue }
            if let attributed = try? NSAttributedString(data: pair.data, options: [.documentType: type],
                                                        documentAttributes: nil)
            {
                return attributed.string
            }
        }
        return nil
    }

    private nonisolated static func fileURL(from data: Data) -> URL? {
        if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL { return url.standardizedFileURL }
        if let string = String(data: data, encoding: .utf8), let url = URL(string: string), url.isFileURL {
            return url.standardizedFileURL
        }
        return nil
    }

    private static func imageTitle(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return "Image" }
        return "Image \(width)×\(height)"
    }

    // MARK: - Disk

    private static func makeDirectory() -> URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Tempo/Clipboard", isDirectory: true)
        let blobs = dir.appendingPathComponent("blobs", isDirectory: true)
        do {
            try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blobs.path)
        } catch {
            Logger(subsystem: "com.ivy.tempo", category: "clipboard")
                .error("can't create history folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return dir
    }

    private var historyFile: URL? { directory?.appendingPathComponent("history.json") }
    private var indexFile: URL? { directory?.appendingPathComponent("index.json") }

    private func blobDirectory(_ id: UUID) -> URL? {
        directory?.appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func blobURL(_ id: UUID, _ index: Int) -> URL? {
        blobDirectory(id)?.appendingPathComponent(String(index))
    }

    private func load() {
        guard let historyFile, let data = try? Data(contentsOf: historyFile) else { return }
        guard let loaded = try? JSONDecoder().decode([ClipItem].self, from: data) else {
            log.error("history.json unreadable, starting empty")
            return
        }
        let fm = FileManager.default
        // An entry whose data is gone can't be pasted; drop it.
        items = loaded.filter { item in blobDirectory(item.id).map { fm.fileExists(atPath: $0.path) } ?? false }
        if let indexFile, let indexData = try? Data(contentsOf: indexFile),
            let index = try? JSONDecoder().decode([UUID: String].self, from: indexData)
        {
            fingerprints = index.filter { id, _ in items.contains { $0.id == id } }
        }
        // Entries saved before their fingerprint was: work it out once.
        for item in items where fingerprints[item.id] == nil {
            fingerprints[item.id] = ClipboardLogic.fingerprint(loadPairs(item))
        }
        removeOrphanBlobs()
        log.notice("loaded \(self.items.count, privacy: .public) entries")
    }

    /// The stored (type, data) pairs of an entry: file n is `types[n]`.
    private func loadPairs(_ item: ClipItem, only wanted: (String) -> Bool = { _ in true }) -> [(type: String, data: Data)] {
        let urls = item.types.indices.map { wanted(item.types[$0]) ? blobURL(item.id, $0) : nil }
        return io.sync {
            var pairs: Pairs = []
            for (index, url) in urls.enumerated() {
                guard let url, let data = try? Data(contentsOf: url) else { continue }
                pairs.append((item.types[index], data))
            }
            return pairs
        }
    }

    private func writeBlobs(_ id: UUID, _ pairs: Pairs) {
        guard let dir = blobDirectory(id) else { return }
        let datas = pairs.map(\.data)
        io.async {
            let fm = FileManager.default
            try? fm.removeItem(at: dir)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                for (index, data) in datas.enumerated() {
                    let file = dir.appendingPathComponent(String(index))
                    try data.write(to: file, options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
            } catch {
                Logger(subsystem: "com.ivy.tempo", category: "clipboard")
                    .error("can't store copy: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func removeBlobs(_ ids: [UUID]) {
        // Stale thumbnails are harmless: ids never come back, and NSCache evicts.
        let dirs = ids.compactMap { blobDirectory($0) }
        guard !dirs.isEmpty else { return }
        io.async {
            for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        }
    }

    /// Blob folders left behind by a crash between saving data and history.
    private func removeOrphanBlobs() {
        guard let blobs = directory?.appendingPathComponent("blobs", isDirectory: true) else { return }
        let known = Set(items.map(\.id.uuidString))
        io.async {
            let fm = FileManager.default
            let names = (try? fm.contentsOfDirectory(atPath: blobs.path)) ?? []
            for name in names where !known.contains(name) {
                try? fm.removeItem(at: blobs.appendingPathComponent(name))
            }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { ClipboardHistory.shared.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    private func saveNow() {
        saveWork = nil
        guard let historyFile, let indexFile else { return }
        let snapshot = items
        let index = fingerprints
        io.async {
            do {
                let encoder = JSONEncoder()
                try encoder.encode(snapshot).write(to: historyFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyFile.path)
                try encoder.encode(index).write(to: indexFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexFile.path)
            } catch {
                Logger(subsystem: "com.ivy.tempo", category: "clipboard")
                    .error("can't save history: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Saves now and waits for every pending write (quitting).
    private func flush() {
        if saveWork != nil {
            saveWork?.cancel()
            saveNow()
        }
        io.sync {}
    }
}
