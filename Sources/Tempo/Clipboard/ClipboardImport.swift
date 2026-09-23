import Foundation
import SQLite3

/// Why importing another clipboard manager's history didn't work.
enum ClipboardImportError: Error, Equatable, Sendable {
    /// There's no history file where Maccy keeps it.
    case notFound
    /// macOS refused access (App Data protection, or Full Disk Access).
    case accessDenied
    /// The file is there but isn't laid out the way Maccy stores history.
    case unsupported
    /// An import is already running, or the history isn't set up.
    case busy
    case failed(String)

    var message: String {
        switch self {
        case .notFound:
            return "Couldn't find Maccy's history."
        case .accessDenied:
            return "macOS didn't let Tempo read Maccy's data. Allow it when asked, or turn Tempo on in "
                + "System Settings → Privacy & Security → App Management / Full Disk Access, then try again."
        case .unsupported:
            return "This version of Maccy stores its history in a way Tempo can't read."
        case .busy:
            return "An import is already running."
        case .failed(let reason):
            return "Import failed: \(reason)"
        }
    }
}

/// One pasteboard type of a Maccy entry.
struct MaccyContent: Equatable, Sendable {
    var type: String
    var data: Data
}

/// One entry of Maccy's history, as read from its database.
struct MaccyRecord: Equatable, Sendable {
    var title: String
    /// Bundle identifier of the app it was copied in.
    var application: String?
    var firstCopied: Date
    var lastCopied: Date
    var copies: Int
    var pin: String?
    /// In the order Maccy stored them (the order they were copied).
    var contents: [MaccyContent]
}

/// Reads Maccy's history (https://github.com/p0deje/Maccy).
///
/// Maccy 2 keeps it in SwiftData, Maccy 0.x/1.x in Core Data; both write the
/// same SQLite layout (entities `HistoryItem` and `HistoryItemContent`):
///
///     ZHISTORYITEM        Z_PK, ZAPPLICATION, ZFIRSTCOPIEDAT, ZLASTCOPIEDAT,
///                         ZNUMBEROFCOPIES, ZPIN, ZTITLE
///     ZHISTORYITEMCONTENT Z_PK, ZITEM (→ ZHISTORYITEM.Z_PK), ZTYPE, ZVALUE
///
/// Dates are Core Data timestamps (seconds since 2001). Reading is split in
/// two: `records(database:)` is a pure read of a database file (checked
/// with a synthetic one), and `ClipboardHistory.importMaccy()` turns the
/// records into history entries.
enum MaccyImport {
    static let bundleID = "org.p0deje.Maccy"

    static var containerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)", isDirectory: true)
    }

    /// Where the sandboxed Maccy (every current build) keeps its history.
    static var historyURL: URL {
        containerURL.appendingPathComponent("Data/Library/Application Support/Maccy/Storage.sqlite")
    }

    /// A build without the sandbox would keep it here instead.
    static var unsandboxedHistoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Maccy/Storage.sqlite")
    }

    /// Whether Maccy has been used on this Mac. Only the container folder is
    /// looked at: anything inside it would set off macOS's App Data prompt.
    static var installed: Bool {
        FileManager.default.fileExists(atPath: containerURL.path)
            || FileManager.default.fileExists(atPath: unsandboxedHistoryURL.path)
    }

    /// Pasteboard types Maccy adds for itself, never worth keeping.
    static let droppedTypes: Set<String> = [
        "org.p0deje.Maccy", "x.nspasteboard.ModifiedType", "com.apple.linkpresentation.metadata",
        "org.chromium.internal.source-rfh-token",
    ]

    // MARK: - Loading

    /// Copies Maccy's database (with its -wal and -shm, so recent copies are
    /// in it) to a private temporary folder, reads the copy, and deletes it.
    /// Maccy's own file is only ever read. Slow: call off the main thread.
    static func load() -> Result<[MaccyRecord], ClipboardImportError> {
        var denied = false
        for source in [historyURL, unsandboxedHistoryURL] {
            switch load(from: source) {
            case .success(let records): return .success(records)
            case .failure(.notFound): continue
            case .failure(.accessDenied): denied = true
            case .failure(let error): return .failure(error)
            }
        }
        return .failure(denied ? .accessDenied : .notFound)
    }

    static func load(from source: URL) -> Result<[MaccyRecord], ClipboardImportError> {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("tempo-maccy-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        let copy = temp.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.copyItem(at: source, to: copy)
        } catch {
            return .failure(classify(error))
        }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: source.path + suffix)
            try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
        }
        // Blobs Core Data moved out of the database stay where they are; they're
        // read in place, one by one.
        return records(database: copy, externalData: externalDataDirectory(for: source))
    }

    /// Core Data's folder for blobs kept outside the database:
    /// `.<store name>_SUPPORT/_EXTERNAL_DATA` next to it.
    static func externalDataDirectory(for database: URL) -> URL {
        let name = database.deletingPathExtension().lastPathComponent
        return database.deletingLastPathComponent()
            .appendingPathComponent(".\(name)_SUPPORT/_EXTERNAL_DATA", isDirectory: true)
    }

    private static func classify(_ error: Error) -> ClipboardImportError {
        let ns = error as NSError
        var chain: [NSError] = [ns]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { chain.append(underlying) }
        for e in chain {
            if e.domain == NSCocoaErrorDomain, e.code == NSFileReadNoSuchFileError || e.code == NSFileNoSuchFileError {
                return .notFound
            }
            if e.domain == NSCocoaErrorDomain, e.code == NSFileReadNoPermissionError { return .accessDenied }
            if e.domain == NSPOSIXErrorDomain {
                if e.code == Int(ENOENT) { return .notFound }
                if e.code == Int(EPERM) || e.code == Int(EACCES) { return .accessDenied }
            }
        }
        return .failed(ns.localizedDescription)
    }

    // MARK: - Reading the database

    /// Every entry in a Maccy database, oldest first. Pure: reads `database`
    /// (read-only) and, for blobs Core Data stored outside it, files in
    /// `externalData`. Entries with no readable content are left out.
    static func records(database: URL, externalData: URL? = nil) -> Result<[MaccyRecord], ClipboardImportError> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
            let db
        else {
            let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open the database"
            sqlite3_close(db)
            return .failure(.failed(reason))
        }
        defer { sqlite3_close(db) }

        let itemColumns = columns(db, "ZHISTORYITEM")
        let contentColumns = columns(db, "ZHISTORYITEMCONTENT")
        guard itemColumns.contains("Z_PK"),
            contentColumns.isSuperset(of: ["Z_PK", "ZITEM", "ZTYPE", "ZVALUE"])
        else {
            // No tables at all may just mean the file couldn't be read.
            if itemColumns.isEmpty, let error = check(db) { return .failure(error) }
            return .failure(.unsupported)
        }
        func column(_ name: String) -> String { itemColumns.contains(name) ? name : "NULL" }

        // Contents first, grouped by the entry they belong to.
        var contents: [Int64: [MaccyContent]] = [:]
        let external = externalData.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let contentSQL = "SELECT ZITEM, ZTYPE, ZVALUE FROM ZHISTORYITEMCONTENT WHERE ZITEM IS NOT NULL ORDER BY ZITEM, Z_PK"
        let contentResult = query(db, contentSQL) { row in
            guard let type = text(row, 1), !type.isEmpty, let raw = blob(row, 2),
                let data = decodeValue(raw, externalData: external)
            else { return }
            contents[sqlite3_column_int64(row, 0), default: []].append(MaccyContent(type: type, data: data))
        }
        if let error = contentResult { return .failure(error) }

        var records: [MaccyRecord] = []
        let itemSQL = """
            SELECT Z_PK, \(column("ZTITLE")), \(column("ZAPPLICATION")), \(column("ZFIRSTCOPIEDAT")),
                   \(column("ZLASTCOPIEDAT")), \(column("ZNUMBEROFCOPIES")), \(column("ZPIN"))
            FROM ZHISTORYITEM ORDER BY Z_PK
            """
        let itemResult = query(db, itemSQL) { row in
            guard let parts = contents[sqlite3_column_int64(row, 0)], !parts.isEmpty else { return }
            let last = date(row, 4) ?? date(row, 3) ?? Date()
            let first = date(row, 3) ?? last
            let application = text(row, 2).flatMap { $0.isEmpty ? nil : $0 }
            let pin = text(row, 6).flatMap { $0.isEmpty ? nil : $0 }
            let copies = sqlite3_column_type(row, 5) == SQLITE_NULL ? 1 : Int(sqlite3_column_int64(row, 5))
            records.append(MaccyRecord(title: text(row, 1) ?? "", application: application, firstCopied: min(first, last),
                                       lastCopied: last, copies: max(copies, 1), pin: pin, contents: parts))
        }
        if let error = itemResult { return .failure(error) }
        return .success(records)
    }

    /// A stored value as its real bytes. With external storage on, Core Data
    /// prefixes each value: 0x01 = the bytes follow inline, 0x02 = the rest
    /// is the name of a file in `_EXTERNAL_DATA`. Without it (Maccy's own
    /// models), the value is the bytes as they are.
    static func decodeValue(_ raw: Data, externalData: URL?) -> Data? {
        guard let marker = raw.first else { return raw }
        if marker == 0x02, let name = externalName(raw.dropFirst()) {
            guard let externalData else { return nil }
            return try? Data(contentsOf: externalData.appendingPathComponent(name))
        }
        if marker == 0x01, externalData != nil { return Data(raw.dropFirst()) }
        return raw
    }

    /// The file name in an external-data reference: a UUID in ASCII, maybe
    /// NUL-terminated. Nil when it isn't one (then the value is just data
    /// that happens to start with 0x02).
    private static func externalName(_ bytes: Data) -> String? {
        var trimmed = bytes
        while trimmed.last == 0 { trimmed.removeLast() }
        guard trimmed.count >= 32, trimmed.count <= 64,
            let name = String(data: trimmed, encoding: .ascii),
            name.allSatisfy({ $0.isHexDigit || $0 == "-" })
        else { return nil }
        return name
    }

    // MARK: - SQLite helpers

    private static func columns(_ db: OpaquePointer, _ table: String) -> Set<String> {
        var names: Set<String> = []
        _ = query(db, "PRAGMA table_info(\(table))") { row in
            if let name = text(row, 1) { names.insert(name) }
        }
        return names
    }

    /// Whether the database can be read at all (an unreadable file shows up
    /// as "no tables").
    private static func check(_ db: OpaquePointer) -> ClipboardImportError? {
        query(db, "SELECT count(*) FROM sqlite_master") { _ in }
    }

    /// Runs `sql`, calling `row` for each result row; nil on success.
    private static func query(_ db: OpaquePointer, _ sql: String, row: (OpaquePointer) -> Void) -> ClipboardImportError? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return error(db)
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                row(statement)
            } else if step == SQLITE_DONE {
                return nil
            } else {
                return error(db)
            }
        }
    }

    private static func error(_ db: OpaquePointer) -> ClipboardImportError {
        let code = sqlite3_errcode(db) & 0xff
        if code == SQLITE_AUTH || code == SQLITE_PERM || code == SQLITE_CANTOPEN { return .accessDenied }
        if code == SQLITE_NOTADB || code == SQLITE_CORRUPT { return .unsupported }
        return .failed(String(cString: sqlite3_errmsg(db)))
    }

    private static func text(_ row: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(row, index) != SQLITE_NULL, let cString = sqlite3_column_text(row, index) else { return nil }
        return String(cString: cString)
    }

    private static func blob(_ row: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(row, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(row, index))
        guard count > 0, let bytes = sqlite3_column_blob(row, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    /// A Core Data timestamp: seconds since 1 January 2001.
    private static func date(_ row: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(row, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, index))
    }

    // MARK: - Turning records into entries

    /// The (type, data) pairs Tempo would have stored had it recorded this
    /// copy itself, under the same settings: nil when it wouldn't be kept.
    /// Mirrors `ClipboardHistory.poll`/`read` (copies from "never record"
    /// apps skipped, noise types dropped, "don't record" markers honoured,
    /// formatting/images off, the TIFF twin of another image kept only if
    /// it fits, the size cap).
    static func pairs(for record: MaccyRecord, config: ClipboardConfig,
                      maxBytes: Int = ClipboardHistory.maxEntryBytes) -> [(type: String, data: Data)]? {
        if let app = record.application, config.ignoredApps.contains(where: { $0.bundleID == app }) { return nil }
        let allTypes = record.contents.map(\.type)
        if ClipboardLogic.shouldIgnore(types: allTypes, ignoredTypes: config.ignoredTypes) { return nil }
        let storable = Set(ClipboardLogic.storableTypes(allTypes)).subtracting(droppedTypes)
        let kept = record.contents.filter { content in
            guard storable.contains(content.type) else { return false }
            if !config.saveRichText, ClipboardLogic.isRichTextType(content.type) { return false }
            if !config.saveImages, ClipboardLogic.isImageType(content.type) { return false }
            return true
        }
        let tiff = "public.tiff"
        let hasOtherImage = kept.contains { $0.type != tiff && ClipboardLogic.isImageType($0.type) }
        var pairs: [(type: String, data: Data)] = []
        var spareTIFF: Data?
        var total = 0
        for content in kept {
            if content.type == tiff, hasOtherImage {
                if spareTIFF == nil { spareTIFF = content.data }
                continue
            }
            let isFile = content.type == ClipboardLogic.fileURLType
            if !isFile, pairs.contains(where: { $0.type == content.type }) { continue }
            if isFile, pairs.contains(where: { $0.type == content.type && $0.data == content.data }) { continue }
            total += content.data.count
            if total > maxBytes { return nil }
            pairs.append((content.type, content.data))
        }
        if let spareTIFF, total + spareTIFF.count <= maxBytes { pairs.append((tiff, spareTIFF)) }
        return pairs.isEmpty ? nil : pairs
    }

    /// The pin letter an imported entry gets: Maccy's own letter when Tempo
    /// hands it out too and it's free, else the next free one, else none.
    static func pin(for maccyPin: String?, used: Set<String>) -> String? {
        guard let maccyPin, !maccyPin.isEmpty else { return nil }
        let letter = maccyPin.lowercased()
        if ClipboardLogic.pinLetters.contains(letter), !used.contains(letter) { return letter }
        return ClipboardLogic.nextPin(used: used)
    }
}
