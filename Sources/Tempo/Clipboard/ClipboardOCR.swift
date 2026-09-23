import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads the text in copied images (Vision), so a screenshot of an error
/// message can be found by typing the message. One image at a time, on a
/// background queue: recognition is slow and memory-hungry, and nothing
/// waits on it.
enum ClipboardOCR {
    /// Longer sides are scaled down to this before reading: a 6K screenshot
    /// reads as well at this size, in a fraction of the time and memory.
    static let maxSide = 2500

    private static let queue = DispatchQueue(label: "com.ivy.tempo.clipboard.ocr", qos: .utility)

    /// Reads `file` on the OCR queue and calls `done` there with the text
    /// ("" when there's none), or nil when the image can't be read at all.
    static func recognize(_ file: URL, done: @escaping (String?) -> Void) {
        queue.async { done(recognize(file)) }
    }

    /// Reads the text in an image file, right here. "" when there's none,
    /// nil when the file isn't a readable image.
    static func recognize(_ file: URL) -> String? {
        autoreleasepool {
            guard let image = loadImage(file) else { return nil }
            // Vision rejects images this small, and there's no text in them.
            guard image.width >= 8, image.height >= 8 else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return ""
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return ClipboardLogic.ocrText(lines: lines)
        }
    }

    /// The image, scaled so its longer side is at most `maxSide`.
    private static func loadImage(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if max(width, height) <= maxSide, width > 0 {
            let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
