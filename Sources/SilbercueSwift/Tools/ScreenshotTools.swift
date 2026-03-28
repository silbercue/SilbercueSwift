import Foundation
import MCP

enum ScreenshotTools {
    static let tools: [Tool] = [
        Tool(
            name: "screenshot",
            description: "Take a screenshot of a booted simulator. 3-tier: burst (~10ms, native) → stream (~20ms, ScreenCaptureKit) → safe (~320ms, simctl). Returns file path.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object([
                        "type": .string("string"),
                        "description": .string("Simulator UDID or 'booted'. Default: booted"),
                    ]),
                    "output_path": .object([
                        "type": .string("string"),
                        "description": .string("Output file path. Default: /tmp/ss-screenshot.png"),
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "description": .string("Image format: png or jpeg. Default: png"),
                    ]),
                ]),
            ])
        ),
    ]

    static func screenshot(_ args: [String: Value]?) async -> CallTool.Result {
        let sim = args?["simulator"]?.stringValue ?? "booted"
        let format = args?["format"]?.stringValue ?? "png"
        let outputPath = args?["output_path"]?.stringValue ?? "/tmp/ss-screenshot.\(format)"

        let start = CFAbsoluteTimeGetCurrent()

        // Fast path: ScreenCaptureKit (macOS 14+)
        if #available(macOS 14.0, *) {
            do {
                let result = try await FramebufferCapture.capture(
                    simulator: sim,
                    format: format,
                    outputPath: outputPath
                )
                let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
                return .ok(
                    "Screenshot saved: \(result.path)\nFormat: \(format) | \(result.width)x\(result.height) | \(result.fileSize / 1024)KB | \(elapsed)ms (\(result.method))"
                )
            } catch {
                // Fall through to simctl
                let fallbackNote = "ScreenCaptureKit failed (\(error)), using simctl fallback"
                return await simctlScreenshot(
                    sim: sim, format: format, outputPath: outputPath,
                    start: start, note: fallbackNote
                )
            }
        }

        // Slow path: simctl (macOS <14 or fallback)
        return await simctlScreenshot(
            sim: sim, format: format, outputPath: outputPath, start: start
        )
    }

    // MARK: - simctl Fallback

    private static func simctlScreenshot(
        sim: String, format: String, outputPath: String,
        start: CFAbsoluteTime, note: String? = nil
    ) async -> CallTool.Result {
        do {
            let result = try await Shell.xcrun(
                "simctl", "io", sim, "screenshot",
                "--type=\(format)",
                outputPath
            )
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)

            if result.succeeded {
                let fileSize: String
                if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath),
                    let size = attrs[.size] as? Int
                {
                    fileSize = "\(size / 1024)KB"
                } else {
                    fileSize = "?"
                }
                var msg = "Screenshot saved: \(outputPath)\nFormat: \(format) | Size: \(fileSize) | \(elapsed)ms (simctl)"
                if let note { msg += "\nNote: \(note)" }
                return .ok(msg)
            }
            return .fail("Screenshot failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }
}
