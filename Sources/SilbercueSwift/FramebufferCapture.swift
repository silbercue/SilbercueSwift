import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit

/// 3-tier Simulator screenshot capture with automatic fallback:
///
/// 1. **BURST (CoreSimulator IOSurface):** Direct framebuffer read. ~5-15ms. TCC-free. Private API.
/// 2. **STREAM (ScreenCaptureKit SCStream):** Cached frame stream. ~15-30ms. Needs TCC.
/// 3. **SAFE (simctl):** Shell command. ~320ms. Always works. (in ScreenshotTools)
enum FramebufferCapture {

    enum CaptureError: Error, CustomStringConvertible {
        case noSimulatorWindow
        case permissionDenied
        case captureFailed(String)
        case encodingFailed

        var description: String {
            switch self {
            case .noSimulatorWindow: return "No booted Simulator window found on screen"
            case .permissionDenied:
                return "Screen Recording permission required. Grant it to Terminal/IDE in System Settings → Privacy → Screen Recording"
            case .captureFailed(let msg): return "Capture failed: \(msg)"
            case .encodingFailed: return "Image encoding failed"
            }
        }
    }

    @MainActor
    private static func ensureWindowServer() {
        _ = NSApplication.shared
    }

    // MARK: - Public API (3-tier fallback)

    /// Capture Simulator screenshot. Tries: BURST → STREAM → throws (caller does SAFE).
    @available(macOS 14.0, *)
    static func capture(
        simulator: String = "booted",
        format: String = "png",
        quality: Double = 0.8,
        outputPath: String
    ) async throws -> (path: String, fileSize: Int, width: Int, height: Int, method: String) {
        // Tier 3: BURST — CoreSimulator IOSurface (fastest, TCC-free)
        if CoreSimCapture.isAvailable {
            do {
                let r = try CoreSimCapture.capture(
                    simulator: simulator, format: format, quality: quality, outputPath: outputPath)
                return (r.path, r.fileSize, r.width, r.height, "burst")
            } catch {
                // Fall through to stream
            }
        }

        // Tier 2: STREAM — ScreenCaptureKit SCStream cache
        await ensureWindowServer()

        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw CaptureError.permissionDenied
        }

        do {
            try await SimulatorStream.shared.ensureRunning(simulator: simulator)
            let cgImage = try await SimulatorStream.shared.currentFrame()
            try saveImage(cgImage, format: format, quality: quality, path: outputPath)
            let fileSize =
                (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
            return (outputPath, fileSize, cgImage.width, cgImage.height, "stream")
        } catch {
            // Fallback: one-shot capture
            let r = try await captureOneShot(
                simulator: simulator, format: format, quality: quality, outputPath: outputPath)
            return (r.path, r.fileSize, r.width, r.height, "oneshot")
        }
    }

    // MARK: - One-Shot Fallback

    @available(macOS 14.0, *)
    private static func captureOneShot(
        simulator: String, format: String, quality: Double, outputPath: String
    ) async throws -> (path: String, fileSize: Int, width: Int, height: Int) {
        let window = try await findSimulatorWindow(simulator: simulator)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
        try saveImage(cgImage, format: format, quality: quality, path: outputPath)
        let fileSize =
            (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
        return (outputPath, fileSize, cgImage.width, cgImage.height)
    }

    // MARK: - Window Discovery

    @available(macOS 14.0, *)
    static func findSimulatorWindow(simulator: String = "booted") async throws -> SCWindow {
        let content = try await SCShareableContent.current
        let simWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator"
                && $0.frame.width > 100 && $0.frame.height > 100
        }

        guard !simWindows.isEmpty else {
            throw CaptureError.noSimulatorWindow
        }

        if simulator != "booted" {
            if let name = await resolveDeviceName(udid: simulator),
                let match = simWindows.first(where: { $0.title?.contains(name) == true })
            {
                return match
            }
        }

        return simWindows.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        })!
    }

    private static func resolveDeviceName(udid: String) async -> String? {
        guard
            let result = try? await Shell.xcrun(timeout: 5, "simctl", "list", "devices", "-j"),
            result.succeeded,
            let data = result.stdout.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let runtimes = json["devices"] as? [String: [[String: Any]]]
        else { return nil }

        for (_, devices) in runtimes {
            for device in devices {
                if let deviceUdid = device["udid"] as? String, deviceUdid == udid,
                    let name = device["name"] as? String
                {
                    return name
                }
            }
        }
        return nil
    }

    // MARK: - Image Encoding

    static func saveImage(
        _ image: CGImage, format: String, quality: Double, path: String
    ) throws {
        let url = URL(fileURLWithPath: path)
        let uti: CFString =
            (format == "jpeg" || format == "jpg")
            ? "public.jpeg" as CFString
            : "public.png" as CFString

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
            throw CaptureError.encodingFailed
        }

        var properties: [CFString: Any] = [:]
        if format.hasPrefix("jp") {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }

        CGImageDestinationAddImage(dest, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.encodingFailed
        }
    }
}

// MARK: - Persistent Simulator Stream

/// Actor managing a persistent SCStream that caches the latest Simulator frame.
/// First call starts the stream (~200ms). All subsequent screenshots read from cache (~0ms).
@available(macOS 14.0, *)
private actor SimulatorStream {
    static let shared = SimulatorStream()

    private var stream: SCStream?
    private var frameHandler: FrameHandler?
    private var targetSimulator: String?
    private nonisolated let ciContext = CIContext()

    /// Ensure the stream is running for the given simulator.
    func ensureRunning(simulator: String) async throws {
        if stream != nil && targetSimulator == simulator && (frameHandler?.hasFrame ?? false) {
            return
        }
        try await startStream(simulator: simulator)
    }

    /// Read the latest cached frame and convert to CGImage.
    func currentFrame() throws -> CGImage {
        guard let handler = frameHandler, let buffer = handler.latestBuffer else {
            throw FramebufferCapture.CaptureError.captureFailed("No cached frame")
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
            throw FramebufferCapture.CaptureError.captureFailed("No pixel buffer in sample")
        }

        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else {
            throw FramebufferCapture.CaptureError.captureFailed("CGImage conversion failed")
        }
        return cg
    }

    private func startStream(simulator: String) async throws {
        // Stop existing stream
        if let s = stream {
            try? await s.stopCapture()
            stream = nil
            frameHandler = nil
        }

        let window = try await FramebufferCapture.findSimulatorWindow(simulator: simulator)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let handler = FrameHandler()
        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        try s.addStreamOutput(
            handler, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await s.startCapture()

        // Wait for first frame (up to 500ms)
        for _ in 0..<50 {
            if handler.hasFrame { break }
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }

        guard handler.hasFrame else {
            try? await s.stopCapture()
            throw FramebufferCapture.CaptureError.captureFailed(
                "Stream started but no frame received within 500ms")
        }

        self.stream = s
        self.frameHandler = handler
        self.targetSimulator = simulator
    }
}

// MARK: - Frame Handler

/// Thread-safe handler that caches the latest CMSampleBuffer from SCStream.
/// The stream callback (~0ms) just swaps the pointer. Conversion happens on demand.
@available(macOS 14.0, *)
private final class FrameHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _buffer: CMSampleBuffer?

    var latestBuffer: CMSampleBuffer? {
        lock.withLock { _buffer }
    }

    var hasFrame: Bool {
        lock.withLock { _buffer != nil }
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        lock.withLock { _buffer = sampleBuffer }
    }
}
