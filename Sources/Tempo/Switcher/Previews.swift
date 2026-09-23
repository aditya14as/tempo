import AppKit
@preconcurrency import ScreenCaptureKit

/// Window thumbnails via ScreenCaptureKit. Only used when Screen Recording is
/// allowed; otherwise cards show the app icon, which is designed to look
/// intentional rather than broken. Images are cached per window so a reopened
/// switcher paints instantly while fresh captures stream in.
@MainActor
final class PreviewStore {
    static let shared = PreviewStore()
    private(set) var cache: [CGWindowID: NSImage] = [:]
    private var content: SCShareableContent?
    private var contentAt = Date.distantPast
    private var generation = 0

    var available: Bool { Permissions.screenRecordingGranted }

    /// Captures `wids` at about `pixelWidth` wide, calling `update` on the main
    /// actor as each image lands. A newer request cancels delivery of older ones.
    func capture(_ wids: [CGWindowID], pixelWidth: CGFloat, update: @escaping @MainActor (CGWindowID, NSImage) -> Void) {
        guard available, !wids.isEmpty else { return }
        generation += 1
        let token = generation
        Task { @MainActor in
            guard let content = await self.shareableContent() else { return }
            let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for wid in wids {
                    guard let window = windows[wid] else { continue }
                    let config = SCStreamConfiguration()
                    let scale = pixelWidth / max(window.frame.width, 1)
                    config.width = max(1, Int(window.frame.width * min(scale, 2)))
                    config.height = max(1, Int(window.frame.height * min(scale, 2)))
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    group.addTask {
                        let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        return (wid, image)
                    }
                }
                for await (wid, image) in group {
                    guard let image else { continue }
                    let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    self.cache[wid] = nsImage
                    if token == self.generation { update(wid, nsImage) }
                }
            }
        }
    }

    func forget(except keep: Set<CGWindowID>) {
        cache = cache.filter { keep.contains($0.key) }
    }

    private func shareableContent() async -> SCShareableContent? {
        if let content, Date().timeIntervalSince(contentAt) < 2 { return content }
        let fresh = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        if let fresh {
            content = fresh
            contentAt = Date()
        }
        return fresh ?? content
    }
}
