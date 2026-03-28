import Foundation
import MCP

enum ScreenshotTools {
    static let tools: [Tool] = [
        Tool(
            name: "screenshot",
            description: "Take a screenshot of a booted simulator. Returns the image inline. 3-tier: burst (~10ms, native) → stream (~20ms, ScreenCaptureKit) → safe (~320ms, simctl).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object([
                        "type": .string("string"),
                        "description": .string("Simulator UDID or 'booted'. Default: booted"),
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "description": .string("Image format: png or jpeg. Default: jpeg"),
                    ]),
                ]),
            ])
        ),
    ]

    static func screenshot(_ args: [String: Value]?) async -> CallTool.Result {
        let sim = args?["simulator"]?.stringValue ?? "booted"
        let format = args?["format"]?.stringValue ?? "jpeg"

        let start = CFAbsoluteTimeGetCurrent()

        // Fast path: inline capture (macOS 14+)
        if #available(macOS 14.0, *) {
            do {
                let result = try await FramebufferCapture.captureInline(
                    simulator: sim, format: format
                )
                let elapsed = String(
                    format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
                let mimeType = format.hasPrefix("jp") ? "image/jpeg" : "image/png"
                return .init(content: [
                    .image(
                        data: result.base64, mimeType: mimeType, annotations: nil, _meta: nil),
                    .text(
                        text: "\(result.width)x\(result.height) | \(result.dataSize / 1024)KB | \(elapsed)ms (\(result.method))",
                        annotations: nil, _meta: nil),
                ])
            } catch {
                // Fall through to simctl
                return await simctlScreenshot(sim: sim, format: format, start: start)
            }
        }

        return await simctlScreenshot(sim: sim, format: format, start: start)
    }

    // MARK: - simctl Fallback (writes to file, returns path)

    private static func simctlScreenshot(
        sim: String, format: String, start: CFAbsoluteTime
    ) async -> CallTool.Result {
        let outputPath = "/tmp/ss-screenshot.\(format)"
        do {
            let result = try await Shell.xcrun(
                "simctl", "io", sim, "screenshot",
                "--type=\(format)",
                outputPath
            )
            let elapsed = String(
                format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)

            if result.succeeded {
                // Read file and return inline
                if let data = FileManager.default.contents(atPath: outputPath) {
                    let mimeType = format.hasPrefix("jp") ? "image/jpeg" : "image/png"
                    return .init(content: [
                        .image(
                            data: data.base64EncodedString(), mimeType: mimeType,
                            annotations: nil, _meta: nil),
                        .text(
                            text: "\(data.count / 1024)KB | \(elapsed)ms (simctl)",
                            annotations: nil, _meta: nil),
                    ])
                }
                return .ok("Screenshot saved: \(outputPath) | \(elapsed)ms (simctl)")
            }
            return .fail("Screenshot failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }
}
