import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
        // Make the menu bar icon accept dropped files (→ Shelf).
        StatusItemDropper.installWhenReady()
        // Build the Shelf now and park it off-screen, so it already exists
        // (a legal drop target) before the first drag — a window shown only
        // after a drag starts can never receive that drag's drop.
        startFeaturesWhenReady()
        // Pop the Shelf up automatically whenever a file drag starts.
        DragWatcher.shared.start()
        // Nudge the menu bar dropdown under the icon (SwiftUI opens it offset).
        PanelAligner.shared.start()
    }

    /// The store is created by SwiftUI; keep checking until it exists, since
    /// the Shelf, Awake and the switcher all start from it.
    @MainActor
    private func startFeaturesWhenReady() {
        guard let store = ConfigStore.shared else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.startFeaturesWhenReady() }
            return
        }
        startFeatures(store)
    }

    @MainActor
    private func startFeatures(_ store: ConfigStore) {
        ShelfWindow.shared.prewarm(store: store)
        AwakeEngine.shared.start(store: store)
        SwitcherController.shared.start(store: store)
        ClipboardController.shared.start(store: store)
    }
}

@main
enum TempoMain {
    static func main() {
        if CommandLine.arguments.contains("--check") {
            exit(Int32(Checks.runAll()))
        }
        TempoApp.main()
    }
}

struct TempoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ConfigStore()
    // Every 10 s, so the menu bar's Awake countdown is never a minute off.
    @StateObject private var ticker = Ticker(interval: 10)

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store, ticker: ticker)
        }
        .menuBarExtraStyle(.window)
    }
}
