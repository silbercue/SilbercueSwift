import Foundation
import MCP

enum ScreenshotTools {
    static let tools: [Tool] = [
        Tool(
            name: "screenshot",
            description: "Take a screenshot of a booted simulator. Returns the file path. ~0.35s latency.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator UDID or 'booted'. Default: booted")]),
                    "output_path": .object(["type": .string("string"), "description": .string("Output file path. Default: /tmp/ss-screenshot.png")]),
                    "format": .object(["type": .string("string"), "description": .string("Image format: png or jpeg. Default: png")]),
                ]),
            ])
        ),
    ]

    static func screenshot(_ args: [String: Value]?) async -> CallTool.Result {
        let sim = args?["simulator"]?.stringValue ?? "booted"
        let format = args?["format"]?.stringValue ?? "png"
        let outputPath = args?["output_path"]?.stringValue ?? "/tmp/ss-screenshot.\(format)"

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let result = try await Shell.xcrun(
                timeout: 10,
                "simctl", "io", sim, "screenshot",
                "--type=\(format)",
                outputPath
            )
            let elapsed = String(format: "%.3f", CFAbsoluteTimeGetCurrent() - start)

            if result.succeeded {
                let fileSize: String
                if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath),
                   let size = attrs[.size] as? Int {
                    fileSize = "\(size / 1024)KB"
                } else {
                    fileSize = "?"
                }
                return .ok("Screenshot saved: \(outputPath)\nFormat: \(format) | Size: \(fileSize) | Time: \(elapsed)s")
            }
            return .fail("Screenshot failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }
}
