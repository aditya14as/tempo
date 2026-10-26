import AppKit
import QuickLookUI

/// Coordinates macOS Quick Look preview for items parked on the Shelf.
@MainActor
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ShelfQuickLook()

    private(set) var currentURL: URL?

    var isOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    /// Toggles or updates the Quick Look preview panel for the given URL.
    /// If the panel is already showing this URL, it closes.
    /// If showing a different URL, it updates to the new URL.
    /// If closed, it opens the panel.
    func preview(url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if isOpen && currentURL == url {
            dismiss()
            return
        }
        currentURL = url
        if isOpen {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Dismisses the Quick Look panel if it is currently previewing `url`.
    func dismissIfShowing(url: URL) {
        if currentURL == url {
            dismiss()
        }
    }

    /// Closes the Quick Look panel and clears the current URL.
    func dismiss() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else {
            currentURL = nil
            return
        }
        panel.orderOut(nil)
        currentURL = nil
    }

    /// Called by the active responder's `endPreviewPanelControl` when the panel closes.
    func handlePanelDidClose() {
        currentURL = nil
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            currentURL != nil ? 1 : 0
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            currentURL as NSURL?
        }
    }
}
