import AppKit
import Foundation
import SQLite3

/// Self-checks for the clipboard history's pure logic and its settings.
/// Never touches the real pasteboard or the history on disk: pasteboard
/// checks use a private, throwaway pasteboard.
enum ClipboardChecks {
    private static func clip(_ title: String, last: TimeInterval = 0, first: TimeInterval = 0,
                             copies: Int = 1, pin: String? = nil) -> ClipItem {
        var item = ClipItem()
        item.title = title
        item.lastCopied = Date(timeIntervalSinceReferenceDate: last)
        item.firstCopied = Date(timeIntervalSinceReferenceDate: first)
        item.copies = copies
        item.pin = pin
        return item
    }

    static func run() {
        search()
        order()
        pins()
        text()
        filtering()
        identity()
        settings()
        pasteboard()
        imageText()
        ocr()
        maccy()
    }

    // MARK: - Search

    private static func search() {
        Checks.expect(ClipboardLogic.matches("Hello World", query: "o w", mode: .exact)
            && ClipboardLogic.matches("Café au lait", query: "CAFE", mode: .exact)
            && !ClipboardLogic.matches("Hello", query: "hx", mode: .exact),
            "exact search ignores case and accents")
        Checks.expect(ClipboardLogic.matches("anything", query: "", mode: .regex), "an empty query matches everything")
        Checks.expect(ClipboardLogic.matches("git checkout main", query: "gcm", mode: .fuzzy)
            && !ClipboardLogic.matches("git checkout main", query: "mcg", mode: .fuzzy),
            "fuzzy search matches letters in order")
        Checks.expect(ClipboardLogic.matches("Order #1234", query: "#\\d{4}", mode: .regex)
            && ClipboardLogic.matches("ABC", query: "^abc$", mode: .regex)
            && !ClipboardLogic.matches("Order", query: "\\d", mode: .regex),
            "regex search is case-insensitive")
        Checks.expect(ClipboardLogic.matches("a (b", query: "(b", mode: .regex)
            && !ClipboardLogic.matches("ab", query: "(b", mode: .regex),
            "an invalid regex searches as plain text")
        let long = String(repeating: "x", count: 6000) + "needle"
        Checks.expect(!ClipboardLogic.matches(long, query: "needle", mode: .exact)
            && ClipboardLogic.matches(String(repeating: "x", count: 100) + "needle", query: "needle", mode: .exact),
            "search stops after the first 5000 characters")

        let items = [clip("logic"), clip("git checkout"), clip("pinned gc thing", pin: "b"), clip("nothing here")]
        let fuzzy = ClipboardLogic.filter(items, query: "gc", mode: .fuzzy).map(\.title)
        Checks.expect(fuzzy == ["pinned gc thing", "git checkout", "logic"],
            "fuzzy results rank closer matches first, pins still lead (got \(fuzzy))")
        let noPinsFirst = ClipboardLogic.filter(items, query: "gc", mode: .fuzzy, pinsOnTop: false).map(\.title)
        Checks.expect(noPinsFirst.first == "git checkout" || noPinsFirst.first == "pinned gc thing",
            "fuzzy without pins on top ranks purely by score")
        Checks.expect((ClipboardLogic.fuzzyScore("abc", query: "abc") ?? 0) > (ClipboardLogic.fuzzyScore("a-x-b-x-c", query: "abc") ?? 0),
            "consecutive letters score higher")
        let exact = ClipboardLogic.filter(items, query: "git", mode: .exact).map(\.title)
        Checks.expect(exact == ["git checkout"], "exact filter keeps only matches, in order")
        Checks.expect(ClipboardLogic.filter(items, query: "", mode: .exact).count == items.count,
            "an empty query keeps the whole list")
        Checks.expect(ClipboardLogic.filter(items, query: "[", mode: .regex).isEmpty
            && ClipboardLogic.filter([clip("a[b")], query: "[", mode: .regex).count == 1,
            "filter falls back to plain text for an invalid regex")
    }

    // MARK: - Order and trimming

    private static func order() {
        let a = clip("a", last: 30, first: 1, copies: 1)
        let b = clip("b", last: 20, first: 3, copies: 5)
        let c = clip("c", last: 10, first: 2, copies: 5, pin: "b")
        let items = [a, b, c]
        Checks.expect(ClipboardLogic.sorted(items, by: .lastCopied, pinsOnTop: true).map(\.title) == ["c", "a", "b"],
            "pins lead, then newest copy first")
        Checks.expect(ClipboardLogic.sorted(items, by: .lastCopied, pinsOnTop: false).map(\.title) == ["a", "b", "c"],
            "without pins on top, pins sort like the rest")
        Checks.expect(ClipboardLogic.sorted(items, by: .firstCopied, pinsOnTop: false).map(\.title) == ["b", "c", "a"],
            "first-copied order is newest first")
        Checks.expect(ClipboardLogic.sorted(items, by: .copyCount, pinsOnTop: false).map(\.title) == ["b", "c", "a"],
            "most copied first, ties go to the more recent")

        let many = (0..<6).map { clip("u\($0)", last: TimeInterval($0)) } + [clip("p", last: -100, pin: "c")]
        let (kept, dropped) = ClipboardLogic.trimmed(many, limit: 3)
        Checks.expect(Set(kept.map(\.title)) == ["u3", "u4", "u5", "p"] && Set(dropped.map(\.title)) == ["u0", "u1", "u2"],
            "trimming drops the oldest unpinned and keeps pins")
        Checks.expect(kept.map(\.title) == ["u3", "u4", "u5", "p"], "trimming keeps the input order")
        Checks.expect(ClipboardLogic.trimmed(many, limit: 10).dropped.isEmpty, "under the limit nothing is dropped")
        Checks.expect(ClipboardLogic.trimmed(many, limit: 0).kept.map(\.title) == ["p"], "a zero limit keeps only pins")
    }

    // MARK: - Pins

    private static func pins() {
        Checks.expect(ClipboardLogic.nextPin(used: []) == "b", "the first pin is b")
        Checks.expect(ClipboardLogic.nextPin(used: ["b"]) == "e", "c and d stay free for copy and delete")
        var used: Set<String> = []
        var handed: [String] = []
        while let next = ClipboardLogic.nextPin(used: used) {
            handed.append(next)
            used.insert(next)
        }
        Checks.expect(handed == ["b", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "r", "s", "t", "u", "y"],
            "pins run b…y skipping a, c, d, p, q, v, w, x, z")
        Checks.expect(ClipboardLogic.nextPin(used: used) == nil, "no pin once every letter is taken")
        Checks.expect(ClipboardLogic.nextPin(used: used.subtracting(["k"])) == "k", "a freed letter is reused")
    }

    // MARK: - Titles and kinds

    private static func text() {
        Checks.expect(ClipboardLogic.title(forText: "  hello\n\n\tworld  \r\n") == "hello world",
            "titles collapse whitespace and trim")
        Checks.expect(ClipboardLogic.title(forText: "a\u{0007}b\u{0000}c") == "abc", "titles drop control characters")
        Checks.expect(ClipboardLogic.title(forText: "👨‍👩‍👧 family") == "👨‍👩‍👧 family", "emoji joiners survive")
        Checks.expect(ClipboardLogic.title(forText: String(repeating: "ab ", count: 1000)).count == 1000,
            "titles are capped at 1000 characters")
        Checks.expect(ClipboardLogic.title(forText: " \n\t ").isEmpty, "whitespace-only text has an empty title")

        Checks.expect(ClipboardLogic.kind(forText: "#fff") == .color
            && ClipboardLogic.kind(forText: " #1A2b3C \n") == .color
            && ClipboardLogic.kind(forText: "#11223344") == .color,
            "hex colours are recognised")
        Checks.expect(ClipboardLogic.kind(forText: "#ffff") == .text
            && ClipboardLogic.kind(forText: "#ggg") == .text
            && ClipboardLogic.kind(forText: "fff") == .text,
            "almost-colours stay text")
        Checks.expect(ClipboardLogic.kind(forText: "https://example.com/a?b=1") == .link
            && ClipboardLogic.kind(forText: "http://localhost:8080") == .link,
            "a single web address is a link")
        Checks.expect(ClipboardLogic.kind(forText: "see https://example.com") == .text
            && ClipboardLogic.kind(forText: "ftp://example.com") == .text
            && ClipboardLogic.kind(forText: "https://a.com https://b.com") == .text
            && ClipboardLogic.kind(forText: "https://") == .text,
            "text around a link, other schemes and bare schemes are text")
    }

    // MARK: - What's kept

    private static func filtering() {
        Checks.expect(ClipboardLogic.shouldIgnore(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], ignoredTypes: [])
            && ClipboardLogic.shouldIgnore(types: ["com.agilebits.onepassword"], ignoredTypes: [])
            && ClipboardLogic.shouldIgnore(types: ["Pasteboard generator type"], ignoredTypes: []),
            "password-manager and transient copies are ignored")
        Checks.expect(ClipboardLogic.shouldIgnore(types: ["com.example.secret"], ignoredTypes: [" com.example.secret "])
            && !ClipboardLogic.shouldIgnore(types: ["public.utf8-plain-text"], ignoredTypes: ["com.example.secret", ""]),
            "user-listed types are ignored, others kept")

        let stored = ClipboardLogic.storableTypes([
            "public.utf8-plain-text", "dyn.ah62d4rv4gu8y", "com.microsoft.ole.source.foo",
            "com.microsoft.Link-Source", "com.apple.webkit.bookmark", "com.ivy.tempo.clip", "public.rtf", "public.png",
        ])
        Checks.expect(stored == ["public.utf8-plain-text", "public.rtf", "public.png"],
            "noise types are dropped, order kept (got \(stored))")

        Checks.expect(ClipboardLogic.matchesIgnoredPattern("card 4111 1111 1111 1111", patterns: ["\\d{4} \\d{4}"])
            && !ClipboardLogic.matchesIgnoredPattern("hello", patterns: ["\\d+"])
            && !ClipboardLogic.matchesIgnoredPattern("a(b", patterns: ["(", ""])
            && ClipboardLogic.matchesIgnoredPattern("a(b", patterns: ["(", "a\\("]),
            "ignored patterns match, invalid ones are skipped")

        Checks.expect(ClipboardLogic.isImageType("public.png") && ClipboardLogic.isImageType("public.tiff")
            && !ClipboardLogic.isImageType("public.utf8-plain-text"), "image types are recognised")
    }

    // MARK: - Identity

    private static func identity() {
        let hello = Data("hello".utf8)
        let a = ClipboardLogic.fingerprint([("public.utf8-plain-text", hello), ("public.rtf", Data("{\\rtf1 hello}".utf8))])
        let b = ClipboardLogic.fingerprint([("public.utf8-plain-text", hello), (ClipboardLogic.sourceType, Data("x".utf8))])
        let c = ClipboardLogic.fingerprint([("public.utf8-plain-text", Data("hello!".utf8))])
        Checks.expect(a == b, "the same text is one entry, whatever formats come with it")
        Checks.expect(a != c, "different text is a different entry")
        let files1 = ClipboardLogic.fingerprint([("public.file-url", Data("file:///a".utf8)), ("public.file-url", Data("file:///b".utf8))])
        let files2 = ClipboardLogic.fingerprint([("public.file-url", Data("file:///a".utf8))])
        let files3 = ClipboardLogic.fingerprint([("public.file-url", Data("file:///a".utf8)), ("public.file-url", Data("file:///b".utf8)),
                                                 ("com.ivy.tempo.clip", Data())])
        Checks.expect(files1 != files2 && files1 == files3, "file lists compare in full; the marker doesn't count")
        let png = ClipboardLogic.fingerprint([("public.png", Data([1, 2, 3]))])
        Checks.expect(png != ClipboardLogic.fingerprint([("public.png", Data([1, 2, 4]))])
            && png == ClipboardLogic.fingerprint([("public.png", Data([1, 2, 3])), ("org.chromium.source-url", Data("u".utf8))]),
            "images compare by their bytes")
        Checks.expect(ClipboardLogic.fingerprint([("public.utf8-plain-text", Data([1, 2, 3]))]) != png,
            "text and an image with the same bytes differ")
        let name = Data("report.pdf".utf8)
        Checks.expect(ClipboardLogic.fingerprint([("public.file-url", Data("file:///a/report.pdf".utf8)), ("public.utf8-plain-text", name)])
            != ClipboardLogic.fingerprint([("public.file-url", Data("file:///b/report.pdf".utf8)), ("public.utf8-plain-text", name)]),
            "two files with the same name are different copies")
    }

    // MARK: - Settings

    private static func settings() {
        let old = Data(#"{"theme":"aurora","launchAtLogin":false}"#.utf8)
        let decoded = try? JSONDecoder().decode(AppConfig.self, from: old)
        Checks.expect(decoded?.clipboard == ClipboardConfig(), "a config saved before the clipboard gets its defaults")
        Checks.expect(decoded?.clipboard.shortcut == KeyCombo(keyCode: 8, modifiers: [.command, .shift]),
            "the default shortcut is ⇧⌘C")

        let partial = Data(#"{"clipboard":{"historySize":50}}"#.utf8)
        let partialConfig = try? JSONDecoder().decode(AppConfig.self, from: partial)
        Checks.expect(partialConfig?.clipboard.historySize == 50 && partialConfig?.clipboard.shortcut != nil
            && partialConfig?.clipboard.searchMode == .exact,
            "missing clipboard keys fall back to defaults")

        func size(_ json: String) -> Int? {
            (try? JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)))?.clipboard.historySize
        }
        Checks.expect(ClipboardConfig().historySize == 150, "the history keeps 150 entries by default")
        Checks.expect(size(#"{"clipboard":{"historySize":200}}"#) == 150,
            "the old 200 default moves to 150")
        Checks.expect(size(#"{"clipboard":{"historySize":200,"historySizeV2":true}}"#) == 200,
            "200 chosen after the change stays 200")
        Checks.expect(size(#"{"clipboard":{"historySize":1}}"#) == 10
            && size(#"{"clipboard":{"historySize":99999}}"#) == 2000,
            "the history size stays within 10…2000")
        var roundTrip = ClipboardConfig()
        roundTrip.historySize = 200
        let reloaded = (try? JSONEncoder().encode(roundTrip)).flatMap { try? JSONDecoder().decode(ClipboardConfig.self, from: $0) }
        Checks.expect(reloaded?.historySize == 200, "a chosen size survives save and load")

        var pinnedA = ClipItem(); pinnedA.pin = "b"
        var pinnedB = ClipItem(); pinnedB.pin = "e"
        let loose = ClipItem()
        Checks.expect(ClipText.lastPinnedBeforeRest([pinnedA, pinnedB, loose]) == pinnedB.id,
            "the divider goes after the last pinned entry")
        Checks.expect(ClipText.lastPinnedBeforeRest([loose, pinnedA]) == nil
            && ClipText.lastPinnedBeforeRest([pinnedA, pinnedB]) == nil,
            "no divider without pins on top, or with nothing under them")

        var cleared = ClipboardConfig()
        cleared.shortcut = nil
        cleared.searchMode = .fuzzy
        cleared.sort = .copyCount
        cleared.ignoredPatterns = ["\\d{16}"]
        cleared.ignoredTypes = ["com.example.secret"]
        cleared.paused = true
        let data = try? JSONEncoder().encode(cleared)
        let back = data.flatMap { try? JSONDecoder().decode(ClipboardConfig.self, from: $0) }
        Checks.expect(back == cleared, "clipboard settings survive save and load")
        Checks.expect(back != nil && back?.shortcut == nil, "a cleared shortcut stays cleared")
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Checks.expect(json.contains(#""shortcut":null"#), "a cleared shortcut is saved as null")

        var item = ClipItem()
        item.title = "x"
        item.pin = "b"
        item.types = ["public.file-url", "public.file-url"]
        let itemBack = (try? JSONEncoder().encode([item])).flatMap { try? JSONDecoder().decode([ClipItem].self, from: $0) }
        Checks.expect(itemBack == [item], "history entries survive save and load")
    }

    // MARK: - Text in images

    private static func imageText() {
        var shot = clip("Image 1200×800", last: 10)
        shot.kind = .image
        shot.ocrText = "Build failed: missing semicolon"
        var blank = clip("Image 10×10", last: 20)
        blank.kind = .image
        blank.ocrText = ""
        let note = clip("semicolon rules", last: 5)
        let items = [shot, blank, note]
        let exact = ClipboardLogic.filter(items, query: "build FAILED", mode: .exact).map(\.title)
        Checks.expect(exact == ["Image 1200×800"], "exact search finds text read out of an image (got \(exact))")
        Checks.expect(ClipboardLogic.filter(items, query: "semicolon", mode: .exact).map(\.title) == ["Image 1200×800", "semicolon rules"],
            "search matches the title or the image text, in history order")
        Checks.expect(ClipboardLogic.filter(items, query: "missing\\s+semi", mode: .regex).map(\.title) == ["Image 1200×800"]
            && ClipboardLogic.filter(items, query: "(semi", mode: .regex).isEmpty,
            "regex search looks at image text too")
        Checks.expect(ClipboardLogic.filter(items, query: "1200", mode: .exact).map(\.title) == ["Image 1200×800"],
            "an image is still found by its title")
        let fuzzy = ClipboardLogic.filter(items, query: "semicolon", mode: .fuzzy).map(\.title)
        Checks.expect(fuzzy == ["semicolon rules", "Image 1200×800"],
            "fuzzy scores the better of title and image text (got \(fuzzy))")
        Checks.expect(ClipboardLogic.filter(items, query: "bfms", mode: .fuzzy).map(\.title) == ["Image 1200×800"],
            "fuzzy search reaches into image text")
        Checks.expect(ClipboardLogic.searchTexts(blank) == ["Image 10×10"], "an image with no text searches its title only")

        Checks.expect(ClipboardLogic.ocrText(lines: ["  Hello ", "", "  ", "World"]) == "Hello\nWorld",
            "recognised lines are trimmed, blanks dropped, one per line")
        Checks.expect(ClipboardLogic.ocrText(lines: []) == "", "an image with no text reads as empty, not nil")
        Checks.expect(ClipboardLogic.ocrText(lines: [String(repeating: "x", count: 6000)]).count == ClipboardLogic.ocrLimit,
            "image text is capped at 5000 characters")

        var old = clip("Image 1×1", last: 1)
        old.kind = .image
        var new = clip("Image 2×2", last: 50)
        new.kind = .image
        var done = clip("Image 3×3", last: 60)
        done.kind = .image
        done.ocrText = ""
        let queue = ClipboardLogic.needingOCR([old, note, done, new])
        Checks.expect(queue == [new.id, old.id], "unread images are read newest first; text and read images are skipped")

        let legacy = Data(#"[{"id":"\#(UUID().uuidString)","kind":"image","title":"Image 1×1","types":["public.png"],"firstCopied":0,"lastCopied":0,"copies":1,"bytes":1}]"#.utf8)
        let decoded = try? JSONDecoder().decode([ClipItem].self, from: legacy)
        Checks.expect(decoded?.count == 1 && decoded?.first?.ocrText == nil, "entries saved before OCR load with no image text")
        var withText = ClipItem()
        withText.ocrText = ""
        let back = (try? JSONEncoder().encode(withText)).flatMap { try? JSONDecoder().decode(ClipItem.self, from: $0) }
        Checks.expect(back?.ocrText == "", "\"no text found\" survives save and load, so it isn't read again")
    }

    /// Vision on real pixels: text drawn into a large image (so it's scaled
    /// down first), and a blank one.
    private static func ocr() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tempo-ocr-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func png(width: Int, height: Int, text: String?) -> URL? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: rep)
            else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            if let text {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 220, weight: .semibold), .foregroundColor: NSColor.black,
                ]
                (text as NSString).draw(at: NSPoint(x: 200, y: height / 2 - 120), withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
            let url = dir.appendingPathComponent(UUID().uuidString + ".png")
            return (try? data.write(to: url)) != nil ? url : nil
        }
        let big = png(width: 5000, height: 1000, text: "Invoice 4821 overdue")
        let text = big.flatMap { ClipboardOCR.recognize($0) } ?? "<unread>"
        Checks.expect(text.localizedCaseInsensitiveContains("invoice") && text.contains("4821"),
            "text is read out of a large image (got \(text.debugDescription))")
        let blank = png(width: 400, height: 300, text: nil)
        let none = blank.flatMap { ClipboardOCR.recognize($0) }
        Checks.expect(none == "", "a blank image reads as no text (got \(none.debugDescription))")
        let junk = dir.appendingPathComponent("junk.png")
        try? Data("not an image".utf8).write(to: junk)
        Checks.expect(ClipboardOCR.recognize(junk) == nil, "a file that isn't an image can't be read")
    }

    // MARK: - Maccy import

    private static func maccy() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tempo-maccy-check-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("Storage.sqlite")

        let externalName = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        let external = MaccyImport.externalDataDirectory(for: dbURL)
        Checks.expect(external.path.hasSuffix("/.Storage_SUPPORT/_EXTERNAL_DATA"), "external blobs live in .Storage_SUPPORT")
        try? fm.createDirectory(at: external, withIntermediateDirectories: true)
        try? Data("kept outside the database".utf8).write(to: external.appendingPathComponent(externalName))

        func hex(_ data: Data) -> String { "X'" + data.map { String(format: "%02X", $0) }.joined() + "'" }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let reference = Data([0x02]) + Data(externalName.utf8) + Data([0])
        let rtf = Data(#"{\rtf1 hello}"#.utf8)
        // Maccy 2's SwiftData layout: Z_ENT/Z_OPT bookkeeping, Core Data dates.
        let sql = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE ZHISTORYITEM (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZNUMBEROFCOPIES INTEGER,
                ZFIRSTCOPIEDAT TIMESTAMP, ZLASTCOPIEDAT TIMESTAMP, ZAPPLICATION VARCHAR, ZPIN VARCHAR, ZTITLE VARCHAR);
            CREATE TABLE ZHISTORYITEMCONTENT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZITEM INTEGER,
                ZTYPE VARCHAR, ZVALUE BLOB);
            CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR(255), Z_PLIST BLOB);
            INSERT INTO ZHISTORYITEM VALUES (1, 1, 1, 3, 1000.5, 2000.25, 'com.apple.Safari', NULL, 'hello maccy');
            INSERT INTO ZHISTORYITEM VALUES (2, 1, 1, 1, 3000, 3000, NULL, 'c', 'pinned thing');
            INSERT INTO ZHISTORYITEM VALUES (3, 1, 1, 2, 4000, 5000, 'com.apple.Preview', '', '');
            INSERT INTO ZHISTORYITEM VALUES (4, 1, 1, NULL, NULL, 6000, NULL, NULL, 'outside');
            INSERT INTO ZHISTORYITEM VALUES (5, 1, 1, 1, 7000, 7000, NULL, NULL, 'no contents');
            INSERT INTO ZHISTORYITEMCONTENT VALUES (10, 2, 1, 1, 'public.utf8-plain-text', \(hex(Data("hello maccy".utf8))));
            INSERT INTO ZHISTORYITEMCONTENT VALUES (11, 2, 1, 1, 'public.rtf', \(hex(rtf)));
            INSERT INTO ZHISTORYITEMCONTENT VALUES (12, 2, 1, 1, 'org.p0deje.Maccy', X'');
            INSERT INTO ZHISTORYITEMCONTENT VALUES (13, 2, 1, 2, 'public.utf8-plain-text', \(hex(Data("pinned thing".utf8))));
            INSERT INTO ZHISTORYITEMCONTENT VALUES (14, 2, 1, 3, 'public.png', \(hex(png)));
            INSERT INTO ZHISTORYITEMCONTENT VALUES (15, 2, 1, 3, 'public.tiff', NULL);
            INSERT INTO ZHISTORYITEMCONTENT VALUES (16, 2, 1, 4, 'public.utf8-plain-text', \(hex(reference)));
            INSERT INTO ZHISTORYITEMCONTENT VALUES (17, 2, 1, NULL, 'public.utf8-plain-text', X'6F727068616E');
            """
        var db: OpaquePointer?
        let made = sqlite3_open(dbURL.path, &db) == SQLITE_OK && sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        Checks.expect(made, "a synthetic Maccy database is built")
        // Left open: the rows are still only in the -wal file, which the
        // import must copy along with the database.
        let walBytes = (try? fm.attributesOfItem(atPath: dbURL.path + "-wal")[.size] as? Int) ?? 0
        let loaded = MaccyImport.load(from: dbURL)
        sqlite3_close(db)
        let records = (try? loaded.get()) ?? []
        Checks.expect(records.count == 4, "entries with contents are read, empty ones skipped (got \(records.count), \(loaded))")
        guard records.count == 4 else { return }
        let text = records[0], pinned = records[1], image = records[2], outside = records[3]
        Checks.expect(text.title == "hello maccy" && text.application == "com.apple.Safari" && text.copies == 3
            && text.firstCopied == Date(timeIntervalSinceReferenceDate: 1000.5)
            && text.lastCopied == Date(timeIntervalSinceReferenceDate: 2000.25),
            "title, app, copy count and Core Data dates are read")
        Checks.expect(text.contents.map(\.type) == ["public.utf8-plain-text", "public.rtf", "org.p0deje.Maccy"]
            && text.contents[1].data == rtf, "every stored type is read in order")
        Checks.expect(pinned.pin == "c" && text.pin == nil && image.pin == nil, "pins are read; an empty pin is none")
        Checks.expect(image.application == "com.apple.Preview" && image.contents.map(\.type) == ["public.png"]
            && image.contents.first?.data == png, "image bytes are read; a NULL value is skipped")
        Checks.expect(outside.contents.first.map { String(decoding: $0.data, as: UTF8.self) } == "kept outside the database",
            "a blob stored outside the database is read from _EXTERNAL_DATA")
        Checks.expect(outside.copies == 1 && outside.firstCopied == outside.lastCopied
            && outside.lastCopied == Date(timeIntervalSinceReferenceDate: 6000),
            "missing counts and dates fall back sensibly")
        Checks.expect(walBytes > 0, "rows still only in the -wal file are read (the -wal is copied too)")

        // Read straight from the file (no copy): the same parse.
        if case .success(let direct) = MaccyImport.records(database: dbURL, externalData: external) {
            Checks.expect(direct == records, "reading the database in place gives the same records")
        } else {
            Checks.expect(false, "reading the database in place gives the same records")
        }

        Checks.expect(MaccyImport.load(from: dir.appendingPathComponent("missing.sqlite")) == .failure(.notFound),
            "a missing history is reported as not found")
        let other = dir.appendingPathComponent("Other.sqlite")
        var otherDB: OpaquePointer?
        _ = sqlite3_open(other.path, &otherDB)
        _ = sqlite3_exec(otherDB, "CREATE TABLE ZSOMETHING (Z_PK INTEGER PRIMARY KEY)", nil, nil, nil)
        sqlite3_close(otherDB)
        Checks.expect(MaccyImport.records(database: other) == .failure(.unsupported), "an unknown layout is unsupported")
        let junk = dir.appendingPathComponent("Junk.sqlite")
        try? Data(repeating: 0x41, count: 4096).write(to: junk)
        if case .failure = MaccyImport.records(database: junk) { Checks.expect(true, "a file that isn't a database fails") } else {
            Checks.expect(false, "a file that isn't a database fails")
        }

        // Blob prefixes.
        Checks.expect(MaccyImport.decodeValue(Data([0x01, 0x41]), externalData: external) == Data([0x41])
            && MaccyImport.decodeValue(Data([0x01, 0x41]), externalData: nil) == Data([0x01, 0x41])
            && MaccyImport.decodeValue(Data([0x02, 0x41]), externalData: external) == Data([0x02, 0x41])
            && MaccyImport.decodeValue(Data(), externalData: external) == Data(),
            "inline-data prefixes are stripped only with external storage; other bytes are kept")

        // Into Tempo's shape, under Tempo's settings.
        let config = ClipboardConfig()
        let textPairs = MaccyImport.pairs(for: text, config: config)
        Checks.expect(textPairs?.map(\.type) == ["public.utf8-plain-text", "public.rtf"], "Maccy's own marker type is dropped")
        var noRich = ClipboardConfig()
        noRich.saveRichText = false
        Checks.expect(MaccyImport.pairs(for: text, config: noRich)?.map(\.type) == ["public.utf8-plain-text"],
            "with formatting off, an import keeps only the text")
        var noImages = ClipboardConfig()
        noImages.saveImages = false
        Checks.expect(MaccyImport.pairs(for: image, config: noImages) == nil, "with images off, image entries aren't imported")
        var secret = text
        secret.contents.append(MaccyContent(type: "org.nspasteboard.ConcealedType", data: Data()))
        Checks.expect(MaccyImport.pairs(for: secret, config: config) == nil, "concealed copies aren't imported")
        var fromPasswords = text
        fromPasswords.application = "com.apple.Passwords"
        Checks.expect(MaccyImport.pairs(for: fromPasswords, config: config) == nil,
            "copies from a never-record app aren't imported")
        var twin = image
        twin.contents.append(MaccyContent(type: "public.tiff", data: Data(count: 100)))
        Checks.expect(MaccyImport.pairs(for: twin, config: config, maxBytes: 50)?.map(\.type) == ["public.png"]
            && MaccyImport.pairs(for: twin, config: config)?.map(\.type) == ["public.png", "public.tiff"],
            "a TIFF twin comes along only if it fits")
        Checks.expect(MaccyImport.pairs(for: text, config: config, maxBytes: 5) == nil, "an entry over the size cap is skipped")
        Checks.expect(textPairs.map { ClipboardLogic.fingerprint($0) }
            == ClipboardLogic.fingerprint([(ClipboardLogic.plainTextType, Data("hello maccy".utf8))]),
            "an imported copy matches the same text copied in Tempo")

        Checks.expect(MaccyImport.pin(for: "e", used: []) == "e" && MaccyImport.pin(for: "E", used: []) == "e",
            "a Maccy pin keeps its letter when Tempo uses it")
        Checks.expect(MaccyImport.pin(for: "c", used: []) == "b" && MaccyImport.pin(for: "e", used: ["e"]) == "b",
            "a letter Tempo reserves or has taken gets the next free one")
        Checks.expect(MaccyImport.pin(for: nil, used: []) == nil && MaccyImport.pin(for: "", used: []) == nil
            && MaccyImport.pin(for: "b", used: Set(ClipboardLogic.pinLetters)) == nil,
            "no pin, or no letter left, imports unpinned")
    }

    // MARK: - Pasteboard reading and writing

    private static func pasteboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("tempo.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let config = ClipboardConfig()
        func put(_ items: [[String: Data]]) {
            pb.clearContents()
            pb.writeObjects(items.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types.sorted(by: { $0.key < $1.key }) {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                return item
            })
        }
        func read(_ config: ClipboardConfig = ClipboardConfig()) -> ClipboardHistory.Pairs? {
            if case .copy(let pairs) = ClipboardHistory.read(pb, changeCount: pb.changeCount, config: config) { return pairs }
            return nil
        }
        func types(_ item: NSPasteboardItem?) -> Set<String> { Set(item?.types.map(\.rawValue) ?? []) }

        let rtf = Data(#"{\rtf1\ansi {\b bold} words}"#.utf8)
        put([["public.utf8-plain-text": Data("bold words".utf8), "public.rtf": rtf]])
        let text = read()
        // The pasteboard adds translated types (UTF-16 text); only ours are checked.
        Checks.expect(Set(text?.map(\.type) ?? []).isSuperset(of: ["public.rtf", "public.utf8-plain-text"]),
            "a text copy keeps its text and formatting")

        var noRich = ClipboardConfig()
        noRich.saveRichText = false
        put([["public.rtf": rtf]])
        let derived = read(noRich)
        let derivedText = derived?.first { $0.type == ClipboardLogic.plainTextType }.flatMap { String(data: $0.data, encoding: .utf8) }
        Checks.expect(derived?.contains { ClipboardLogic.isRichTextType($0.type) } == false && derivedText == "bold words",
            "with rich text off, formatting is dropped and formatted-only text keeps its words")

        put([["public.utf8-plain-text": Data("secret".utf8), "org.nspasteboard.ConcealedType": Data()]])
        if case .skipped = ClipboardHistory.read(pb, changeCount: pb.changeCount, config: config) {
            Checks.expect(true, "a concealed copy is skipped")
        } else {
            Checks.expect(false, "a concealed copy is skipped")
        }

        put([["public.utf8-plain-text": Data("x".utf8)]])
        let stale = ClipboardHistory.read(pb, changeCount: pb.changeCount - 1, config: config)
        if case .changed = stale { Checks.expect(true, "a copy that changed mid-read is reread") } else {
            Checks.expect(false, "a copy that changed mid-read is reread")
        }

        let big = Data(count: ClipboardHistory.maxEntryBytes + 1)
        put([["public.png": Data([0x89, 0x50]), "public.tiff": big]])
        let screenshot = read()
        Checks.expect(screenshot?.map(\.type) == ["public.png"], "a huge TIFF twin of a PNG is dropped, the PNG kept")
        put([["public.png": Data([0x89, 0x50]), "public.tiff": Data([0x49, 0x49])]])
        Checks.expect(read()?.map(\.type) == ["public.png", "public.tiff"], "a small TIFF twin is kept")
        put([["public.tiff": big]])
        Checks.expect(read() == nil, "a lone copy over the cap is skipped")

        let fileA = Data("file:///tmp/a.txt".utf8), fileB = Data("file:///tmp/b.txt".utf8)
        put([["public.file-url": fileA, "public.utf8-plain-text": Data("a.txt".utf8)],
             ["public.file-url": fileB, "public.utf8-plain-text": Data("b.txt".utf8)]])
        let files = read()
        Checks.expect(files?.filter { $0.type == "public.file-url" }.map(\.data) == [fileA, fileB],
            "every copied file is kept")

        // Writing back: Tempo's marker and source, formats kept, files one per item.
        ClipboardHistory.fill(pb, with: text ?? [], plain: false)
        let first = pb.pasteboardItems?.first
        Checks.expect(types(first).isSuperset(of: ["public.rtf", "public.utf8-plain-text", "com.ivy.tempo.clip"])
            && first?.string(forType: NSPasteboard.PasteboardType(ClipboardLogic.sourceType)) == Permissions.bundleID,
            "a copy back keeps its formatting, Tempo's marker and names Tempo as the source")
        if case .skipped(nil) = ClipboardHistory.read(pb, changeCount: pb.changeCount, config: config) {
            Checks.expect(true, "Tempo's own copy isn't recorded")
        } else {
            Checks.expect(false, "Tempo's own copy isn't recorded")
        }
        ClipboardHistory.fill(pb, with: text ?? [], plain: true)
        Checks.expect(types(pb.pasteboardItems?.first) == ["public.utf8-plain-text", "com.ivy.tempo.clip", ClipboardLogic.sourceType]
            && pb.string(forType: .string) == "bold words",
            "a plain copy back is text only")
        ClipboardHistory.fill(pb, with: files ?? [], plain: true)
        let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL]
        Checks.expect(pb.pasteboardItems?.count == 2 && urls?.map(\.path) == ["/tmp/a.txt", "/tmp/b.txt"],
            "a plain copy back of files still pastes the files, one per item")
    }
}
