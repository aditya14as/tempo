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
    /// The reading happens in a short-lived `Tempo --ocr` child process:
    /// Vision's models and buffers (tens of MB at peak) then leave with it
    /// instead of staying in the menu bar app for good.
    static func recognize(_ file: URL, done: @escaping (String?) -> Void) {
        queue.async { done(recognizeInHelper(file) ?? recognize(file)) }
    }

    /// Entry point for `Tempo --ocr <file>`: prints the text and exits 0, or
    /// exits 2 when the file isn't a readable image.
    static func runHelper(_ path: String) -> Int32 {
        guard let text = recognize(URL(fileURLWithPath: path)) else { return 2 }
        FileHandle.standardOutput.write(Data(text.utf8))
        return 0
    }

    /// The helper's answer, or `.none` when the helper couldn't be started
    /// (the caller then reads in-process).
    private static func recognizeInHelper(_ file: URL) -> String?? {
        guard let executable = Bundle.main.executableURL else { return .none }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--ocr", file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .none }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // A helper that crashed on this image counts as "nothing found", so
        // the image is never retried (and can't take the app down with it).
        guard process.terminationReason == .exit else { return .some("") }
        switch process.terminationStatus {
        case 0: return .some(String(decoding: data, as: UTF8.self))
        case 2: return .some(nil)
        default: return .some("")
        }
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
