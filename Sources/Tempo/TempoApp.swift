import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
        // Make the menu bar icon accept dropped files (→ Shelf).
        StatusItemDropper.installWhenReady()
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
    @StateObject private var ticker = Ticker()

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
