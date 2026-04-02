import Foundation
import MCP

// MARK: - Version (single source of truth — update on each release)

public enum SilbercueSwiftVersion {
    public static let current = "3.6.0"
}

// MARK: - Debug Logging (stderr, safe for MCP stdio transport)

public enum Log {
    public static func warn(_ message: String) {
        fputs("[SilbercueSwift] \(message)\n", stderr)
    }
}

// MARK: - Convenience for CallTool.Result

public extension CallTool.Result {
    /// Quick success result with text content
    static func ok(_ text: String) -> Self {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)])
    }

    /// Quick error result with text content
    static func fail(_ text: String) -> Self {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: true)
    }

    /// Success result with text, optionally followed by an inline screenshot.
    /// Call with `screenshot: args?["screenshot"]?.boolValue ?? false`.
    static func okWithScreenshot(_ text: String, screenshot: Bool) async -> Self {
        var content: [Tool.Content] = [.text(text: text, annotations: nil, _meta: nil)]
        if screenshot {
            // Brief settle time for UI animations
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let img = await ActionScreenshot.capture() {
                content.append(img)
            }
        }
        return .init(content: content)
    }
}

// MARK: - Inline Screenshot after Action

public enum ActionScreenshot {
    /// Capture a compact screenshot and return as Tool.Content.image, or nil on failure.
    public static func capture() async -> Tool.Content? {
        // Resolve simulator: session default → auto-detect → first booted
        // MUST use resolveSimulator to expand short UDID prefixes (e.g. "51AC" → full UUID)
        let sim: String
        if let resolved = try? await SessionState.shared.resolveSimulator(nil) {
            sim = resolved
        } else if let first = await firstBootedSimulator() {
            sim = first
        } else {
            return nil
        }

        // Pro fast path
        if let proHandler = ProHooks.screenshotHandler,
           let result = await proHandler(sim, "jpeg") {
            if let compact = ImageUtils.downscale(base64: result.base64, scaleFactor: 3) {
                return .image(data: compact, mimeType: "image/jpeg", annotations: nil, _meta: nil)
            }
            return .image(data: result.base64, mimeType: "image/jpeg", annotations: nil, _meta: nil)
        }
        // Free fallback: simctl
        let path = "/tmp/ss-action-screenshot.jpeg"
        if let result = try? await Shell.xcrun(timeout: 10, "simctl", "io", sim, "screenshot", "--type=jpeg", path),
           result.succeeded,
           let data = FileManager.default.contents(atPath: path) {
            if let compact = ImageUtils.downscale(data: data, scaleFactor: 3) {
                return .image(data: compact.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil)
            }
            return .image(data: data.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil)
        }
        return nil
    }

    /// Quick fallback: first booted simulator UDID (no disambiguation error).
    /// Picks newest runtime, tiebreaks by UDID for determinism.
    private static func firstBootedSimulator() async -> String? {
        guard let result = try? await Shell.xcrun(timeout: 10, "simctl", "list", "devices", "booted", "-j"),
              result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return nil }
        var booted: [(udid: String, runtime: String)] = []
        for (runtime, deviceList) in devices {
            for device in deviceList {
                if let state = device["state"] as? String, state == "Booted",
                   let udid = device["udid"] as? String {
                    booted.append((udid, runtime))
                }
            }
        }
        return booted.sorted { a, b in
            let cmp = a.runtime.localizedStandardCompare(b.runtime)
            if cmp != .orderedSame { return cmp == .orderedDescending }
            return a.udid < b.udid
        }.first?.udid
    }
}

// MARK: - Image Utilities (CGImage resize, no AppKit)

import ImageIO
import CoreGraphics

public enum ImageUtils {
    /// Downscale base64-encoded image data by scaleFactor and re-encode as JPEG 80%.
    /// Returns new base64 string, or nil if processing fails.
    public static func downscale(base64: String, scaleFactor: Int) -> String? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return downscale(data: data, scaleFactor: scaleFactor)?.base64EncodedString()
    }

    /// Downscale image Data by scaleFactor and re-encode as JPEG 80%.
    public static func downscale(data: Data, scaleFactor: Int) -> Data? {
        guard scaleFactor > 1,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let targetWidth = original.width / scaleFactor
        let targetHeight = original.height / scaleFactor
        guard targetWidth > 0, targetHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: original.bitsPerComponent,
            bytesPerRow: 0,
            space: original.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: original.bitmapInfo.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let resized = context.makeImage() else { return nil }

        return jpegData(from: resized, quality: 0.8)
    }

    /// Encode CGImage as JPEG with quality (0.0-1.0). Pure ImageIO, no AppKit.
    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
