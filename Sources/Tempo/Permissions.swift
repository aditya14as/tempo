import AppKit
import ApplicationServices

/// The two system permissions the switcher touches. Accessibility is required
/// (the global ⌥⇥ tap and raising windows both need it); Screen Recording is
/// optional and only unlocks live window previews.
///
/// Tempo is ad-hoc signed, so every rebuild gets a new code hash. macOS keeps
/// the OLD hash in Privacy & Security and quietly stops trusting the new
/// binary — the toggle looks on, but `AXIsProcessTrusted()` says no. The
/// installer resets both grants before copying the new build; if someone
/// rebuilds by hand, `staleGrantHint` tells them the one-line fix.
enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system "Tempo would like to control this computer" dialog
    /// (once per grant state; macOS rate-limits it after that).
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts for Screen Recording; returns true if already granted.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static let bundleID = "com.ivy.tempo"

    /// Shown next to a grant that looks on but isn't working.
    static var staleGrantHint: String {
        "Rebuilt Tempo? Remove it from the list and add it again, or run "
            + "`tccutil reset Accessibility \(bundleID)` and relaunch."
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
