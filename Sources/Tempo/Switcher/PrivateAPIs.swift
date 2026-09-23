import AppKit
import ApplicationServices
import Darwin

/// Private window-server / Accessibility symbols the switcher uses, resolved
/// at runtime with `dlsym` so a missing or renamed symbol degrades a feature
/// instead of failing to link (or crashing at launch). Every entry is optional;
/// callers fall back to public API when one is nil.
enum PrivateAPIs {
    typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    typealias MainConnectionFn = @convention(c) () -> Int32
    typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias SetSymbolicHotKeyEnabledFn = @convention(c) (Int32, Bool) -> Int32
    typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let skyLight: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let processDefault = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        var pointer: UnsafeMutableRawPointer?
        if let skyLight { pointer = dlsym(skyLight, name) }
        if pointer == nil { pointer = dlsym(processDefault, name) }
        guard let pointer else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    static let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", as: SetFrontProcessFn.self)
    static let postEventRecord = symbol("SLPSPostEventRecordTo", as: PostEventRecordFn.self)
    static let mainConnection = symbol("CGSMainConnectionID", as: MainConnectionFn.self)
    static let copySpacesForWindows = symbol("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
    static let copyManagedDisplaySpaces = symbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
    static let setSymbolicHotKeyEnabled = symbol("CGSSetSymbolicHotKeyEnabled", as: SetSymbolicHotKeyEnabledFn.self)
    static let axGetWindow = symbol("_AXUIElementGetWindow", as: AXGetWindowFn.self)
    static let getProcessForPID = symbol("GetProcessForPID", as: GetProcessForPIDFn.self)
    static let createWithRemoteToken = symbol("_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteTokenFn.self)

    /// Name → resolved?, for the `--check` info lines.
    static var resolution: [(String, Bool)] {
        [
            ("_SLPSSetFrontProcessWithOptions", setFrontProcess != nil),
            ("SLPSPostEventRecordTo", postEventRecord != nil),
            ("CGSMainConnectionID", mainConnection != nil),
            ("CGSCopySpacesForWindows", copySpacesForWindows != nil),
            ("CGSCopyManagedDisplaySpaces", copyManagedDisplaySpaces != nil),
            ("CGSSetSymbolicHotKeyEnabled", setSymbolicHotKeyEnabled != nil),
            ("_AXUIElementGetWindow", axGetWindow != nil),
            ("GetProcessForPID", getProcessForPID != nil),
            ("_AXUIElementCreateWithRemoteToken", createWithRemoteToken != nil),
        ]
    }

    // MARK: - Helpers

    /// The window server id behind an AX window element (0 if unknown).
    static func windowID(of element: AXUIElement) -> CGWindowID {
        guard let axGetWindow else { return 0 }
        var wid: CGWindowID = 0
        return axGetWindow(element, &wid) == .success ? wid : 0
    }

    /// The AX element of a window Accessibility doesn't list — one on another
    /// Space, such as a fullscreen window. Apps number their AX elements from
    /// zero, so this walks the ids (AltTab's trick) until one is that window.
    /// About 50 ms for a big app, stopping at the first match.
    static func windowElement(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
        guard wid != 0, let createWithRemoteToken, let axGetWindow else { return nil }
        // pid (4 bytes), 0 (4), "coco" (4), element id (8).
        var token = Data(count: 20)
        withUnsafeBytes(of: pid) { token.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: Int32(0x636f636f)) { token.replaceSubrange(8..<12, with: $0) }
        for id: UInt64 in 0..<1000 {
            withUnsafeBytes(of: id) { token.replaceSubrange(12..<20, with: $0) }
            guard let element = createWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.25)
            var found: CGWindowID = 0
            // Buttons and tabs report their window's id too; only the window itself will do.
            guard axGetWindow(element, &found) == .success, found == wid,
                WindowScanner.copy(element, kAXRoleAttribute) as? String == kAXWindowRole
            else { continue }
            return element
        }
        return nil
    }

    static func processSerialNumber(for pid: pid_t) -> ProcessSerialNumber? {
        guard let getProcessForPID else { return nil }
        var psn = ProcessSerialNumber()
        return getProcessForPID(pid, &psn) == noErr ? psn : nil
    }

    /// Brings exactly `wid` of `pid` to the front and makes it key — AltTab's
    /// recipe (which is yabai's): set the front process for that window, then
    /// post a synthetic "make key" event record (down + up) to the process.
    /// Returns false when the private calls aren't available.
    @discardableResult
    static func makeFrontAndKey(pid: pid_t, wid: CGWindowID) -> Bool {
        guard wid != 0, let setFrontProcess, var psn = processSerialNumber(for: pid) else { return false }
        let userGenerated: UInt32 = 0x200
        guard setFrontProcess(&psn, wid, userGenerated) == 0 else { return false }
        if let postEventRecord {
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x3a] = 0x10
            var windowID = wid.littleEndian
            withUnsafeBytes(of: &windowID) { raw in
                for (offset, byte) in raw.enumerated() { bytes[0x3c + offset] = byte }
            }
            // A point far outside any content, so the synthetic "click" can't hit a control.
            var point = CGPoint(x: 300_000, y: 300_000)
            withUnsafeBytes(of: &point) { raw in
                for (offset, byte) in raw.enumerated() { bytes[0x20 + offset] = byte }
            }
            bytes[0x08] = 0x01
            _ = bytes.withUnsafeMutableBufferPointer { postEventRecord(&psn, $0.baseAddress!) }
            bytes[0x08] = 0x02
            _ = bytes.withUnsafeMutableBufferPointer { postEventRecord(&psn, $0.baseAddress!) }
        }
        return true
    }

    // MARK: - Spaces

    /// Which Spaces exist right now, which are visible, and their 1-based
    /// numbers (Mission Control order, across displays).
    struct SpaceSnapshot {
        var current: Set<UInt64>
        var number: [UInt64: Int]
    }

    static func spaceSnapshot() -> SpaceSnapshot? {
        guard let mainConnection, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        var snapshot = SpaceSnapshot(current: [], number: [:])
        var counter = 0
        for display in displays {
            if let current = display["Current Space"] as? [String: Any], let id = spaceID(current) {
                snapshot.current.insert(id)
            }
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = spaceID(space) else { continue }
                counter += 1
                snapshot.number[id] = counter
            }
        }
        return snapshot.current.isEmpty ? nil : snapshot
    }

    private static func spaceID(_ dict: [String: Any]) -> UInt64? {
        if let n = dict["ManagedSpaceID"] as? NSNumber { return n.uint64Value }
        if let n = dict["id64"] as? NSNumber { return n.uint64Value }
        return nil
    }

    /// The Spaces a window lives on (empty for minimized windows or when the
    /// private call is unavailable).
    static func spaces(of wid: CGWindowID) -> [UInt64] {
        guard wid != 0, let mainConnection, let copySpacesForWindows else { return [] }
        let windows = [NSNumber(value: wid)] as CFArray
        guard let result = copySpacesForWindows(mainConnection(), 0x7, windows)?.takeRetainedValue() as? [NSNumber]
        else { return [] }
        return result.map(\.uint64Value)
    }

    // MARK: - System ⌘⇥ / ⌘`

    /// Symbolic hot key ids: 1 = ⌘⇥, 2 = ⌘⇧⇥, 27 = ⌘` (move focus to next window).
    @discardableResult
    static func setSymbolicHotKey(_ id: Int32, enabled: Bool) -> Bool {
        guard let setSymbolicHotKeyEnabled else { return false }
        return setSymbolicHotKeyEnabled(id, enabled) == 0
    }
}
