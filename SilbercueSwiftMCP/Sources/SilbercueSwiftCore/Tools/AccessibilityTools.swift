import CoreGraphics
import Foundation
import MCP

enum AccessibilityTools {

    // MARK: - Size Definitions

    /// Friendly alias → Apple constant mapping.
    private static let sizeMap: [(alias: String, constant: String, label: String)] = [
        ("XS",      "UICTContentSizeCategoryXS",                      "Extra Small"),
        ("S",       "UICTContentSizeCategoryS",                       "Small"),
        ("M",       "UICTContentSizeCategoryM",                       "Medium"),
        ("default", "UICTContentSizeCategoryL",                       "Default (Large)"),
        ("L",       "UICTContentSizeCategoryL",                       "Large"),
        ("XL",      "UICTContentSizeCategoryXL",                      "Extra Large"),
        ("XXL",     "UICTContentSizeCategoryXXL",                     "XX-Large"),
        ("XXXL",    "UICTContentSizeCategoryXXXL",                    "XXX-Large"),
        ("AX1",     "UICTContentSizeCategoryAccessibilityM",          "Accessibility M"),
        ("AX2",     "UICTContentSizeCategoryAccessibilityL",          "Accessibility L"),
        ("AX3",     "UICTContentSizeCategoryAccessibilityXL",         "Accessibility XL"),
        ("AX4",     "UICTContentSizeCategoryAccessibilityXXL",        "Accessibility XXL"),
        ("AX5",     "UICTContentSizeCategoryAccessibilityXXXL",       "Accessibility XXXL"),
    ]

    private static let defaultSizes = ["L", "XXXL", "AX3", "AX5"]

    private static let validAliases: String = {
        sizeMap.map { "\($0.alias) (\($0.label))" }.joined(separator: ", ")
    }()

    // MARK: - Tool Definition

    static let tools: [Tool] = [
        Tool(
            name: "accessibility_check",
            description:
                "Check app rendering across Dynamic Type sizes. Sets each size, relaunches the app, and takes a screenshot. Returns inline screenshots and a summary report for Claude Vision analysis. Resets Dynamic Type to default after the run.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Simulator name or UDID. Optional — auto-resolved from session defaults if omitted"
                        ),
                    ]),
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "App bundle identifier. Optional — auto-detected from session defaults or most recent install"
                        ),
                    ]),
                    "app_path": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Path to .app bundle. Optional — only needed if app is not yet installed"
                        ),
                    ]),
                    "sizes": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Comma-separated size aliases to test. Default: 'L,XXXL,AX3,AX5'. Valid: XS, S, M, default, L, XL, XXL, XXXL, AX1-AX5"
                        ),
                    ]),
                    "settle_time": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Seconds to wait after relaunch before screenshot. Default: 2.0"),
                    ]),
                ]),
                "required": .array([]),
            ])
        ),
    ]

    // MARK: - Entry Point

    static func accessibilityCheck(_ args: [String: Value]?) async -> CallTool.Result {
        let start = CFAbsoluteTimeGetCurrent()
        let runId = String(UUID().uuidString.prefix(8))

        // --- Resolve simulator ---
        let udid: String
        let explicitSim = args?["simulator"]?.stringValue
        do {
            let resolved = try await SessionState.shared.resolveSimulator(explicitSim)
            // resolveSimulator returns a name or UDID — normalize to UDID
            if let normalized = await resolveSimulatorUDID(resolved) {
                udid = normalized
            } else {
                udid = resolved // Assume it's already a UDID
            }
        } catch {
            return .fail("Simulator resolution failed: \(error.localizedDescription)")
        }

        // --- Resolve bundle ID ---
        let bundleId: String
        let explicitBid = args?["bundle_id"]?.stringValue
        if let bid = await SessionState.shared.resolveBundleId(explicitBid), !bid.isEmpty {
            bundleId = bid
        } else if let appPath = args?["app_path"]?.stringValue, !appPath.isEmpty,
                  let detected = detectBundleId(appPath: appPath) {
            bundleId = detected
        } else {
            return .fail("No bundle_id — provide 'bundle_id' or 'app_path', or run build_sim first.")
        }

        // --- Parse sizes ---
        let sizeAliases: [String]
        if let sizesStr = args?["sizes"]?.stringValue, !sizesStr.isEmpty {
            sizeAliases = sizesStr.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        } else {
            sizeAliases = defaultSizes
        }

        // Validate all sizes and deduplicate by constant
        var resolvedSizes: [(alias: String, constant: String, label: String)] = []
        var seenConstants = Set<String>()
        for alias in sizeAliases {
            guard let entry = sizeMap.first(where: { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }) else {
                return .fail("Invalid size '\(alias)'. Valid sizes: \(validAliases)")
            }
            guard seenConstants.insert(entry.constant).inserted else { continue }
            resolvedSizes.append(entry)
        }

        let settleTime = min(max(args?["settle_time"]?.numberValue ?? 2.0, 0.5), 30.0)

        // --- Install if app_path provided ---
        if let appPath = args?["app_path"]?.stringValue, !appPath.isEmpty {
            guard FileManager.default.fileExists(atPath: appPath) else {
                return .fail("App not found: \(appPath)")
            }
            let r = try? await Shell.xcrun(timeout: 60, "simctl", "install", udid, appPath)
            if r?.succeeded != true {
                return .fail("Install failed: \(r?.stderr ?? "unknown")")
            }
        }

        // --- Cycle through sizes ---
        struct SizeResult {
            let alias: String
            let label: String
            let constant: String
            var image: CGImage?
            var path: String?
            var crashed: Bool = false
            var error: String?
        }

        var results: [SizeResult] = []

        for entry in resolvedSizes {
            var result = SizeResult(alias: entry.alias, label: entry.label, constant: entry.constant)

            // 1. Set Dynamic Type
            let setResult = try? await Shell.xcrun(
                timeout: 10, "simctl", "spawn", udid,
                "defaults", "write", "-g", "AppleContentSizeCategory",
                "-string", entry.constant)
            if setResult?.succeeded != true {
                result.error = "Failed to set Dynamic Type: \(setResult?.stderr ?? "unknown")"
                results.append(result)
                continue
            }

            // 2. Terminate + relaunch
            _ = try? await Shell.xcrun(timeout: 5, "simctl", "terminate", udid, bundleId)
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms for cleanup

            let launchResult = try? await Shell.run(
                "/usr/bin/xcrun",
                arguments: ["simctl", "launch", udid, bundleId],
                timeout: 15)

            if launchResult?.succeeded != true {
                result.crashed = true
                result.error = "App crashed or failed to launch at \(entry.alias): \(launchResult?.stderr ?? "unknown")"
                results.append(result)
                continue
            }

            // 3. Settle
            try? await Task.sleep(nanoseconds: UInt64(settleTime * 1_000_000_000))

            // 4. Screenshot
            let safeName = VisualTools.sanitize(entry.alias)
            let path = "/tmp/ss-dt-\(runId)-\(safeName).png"
            let ssResult = try? await Shell.xcrun(
                timeout: 15, "simctl", "io", udid, "screenshot", "--type=png", path)

            if ssResult?.succeeded == true, let img = VisualTools.loadCGImage(path: path) {
                result.image = img
                result.path = path
            } else {
                result.error = "Screenshot failed: \(ssResult?.stderr ?? "unknown")"
            }

            results.append(result)
        }

        // --- Reset Dynamic Type to default ---
        _ = try? await Shell.xcrun(
            timeout: 10, "simctl", "spawn", udid,
            "defaults", "write", "-g", "AppleContentSizeCategory",
            "-string", "UICTContentSizeCategoryL")

        // --- Build report ---
        let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)
        let successCount = results.filter({ $0.image != nil }).count
        let crashCount = results.filter(\.crashed).count
        let failCount = results.filter({ $0.image == nil && !$0.crashed }).count

        let allFailed = successCount == 0 && !results.isEmpty
        let status = allFailed ? "FAIL" : (crashCount > 0 ? "WARNING" : (failCount > 0 ? "PARTIAL" : "PASS"))

        var report: [String] = []
        report.append("[\(status)] Accessibility Matrix — Dynamic Type Check (\(elapsed)s)")
        report.append("Simulator: \(udid)")
        report.append("Bundle ID: \(bundleId)")
        report.append("Sizes tested: \(resolvedSizes.count)")
        report.append("Screenshots: \(successCount)/\(resolvedSizes.count)")
        if crashCount > 0 { report.append("Crashes: \(crashCount)") }
        report.append("")

        report.append("Results:")
        for r in results {
            let icon: String
            if r.crashed { icon = "[CRASH]" }
            else if r.image != nil { icon = "[OK]" }
            else { icon = "[ERR]" }

            let dims = r.image.map { "\($0.width)x\($0.height)" } ?? ""
            let detail = r.error ?? dims
            report.append("  \(icon) \(r.alias) (\(r.label)) — \(detail)")
        }

        report.append("")
        report.append("Summary: \(successCount) von \(resolvedSizes.count) Stufen erfolgreich, \(crashCount) Crashes, \(failCount) Fehler")
        report.append("Dynamic Type reset to Default (Large).")
        report.append("")
        report.append("Analyze the screenshots below for: truncated text, overlapping elements, unscrollable containers, and illegible content at large sizes.")

        // --- Build MCP content with inline images ---
        var content: [Tool.Content] = [
            .text(text: report.joined(separator: "\n"), annotations: nil, _meta: nil),
        ]

        for r in results where r.image != nil {
            guard let img = r.image else { continue }
            let scaled = scaleDown(img)
            if let data = try? FramebufferCapture.encodeImage(scaled, format: "jpeg", quality: 0.6) {
                content.append(.image(
                    data: data.base64EncodedString(), mimeType: "image/jpeg",
                    annotations: nil, _meta: nil))
                content.append(.text(
                    text: "\(r.alias) (\(r.label)) — \(img.width)x\(img.height)",
                    annotations: nil, _meta: nil))
            }
        }

        let hasErrors = crashCount > 0 || allFailed
        return .init(content: content, isError: hasErrors ? true : nil)
    }

    // MARK: - Helpers

    /// Resolve simulator name to UDID.
    private static func resolveSimulatorUDID(_ name: String) async -> String? {
        let uuidRegex = try! NSRegularExpression(
            pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$",
            options: .caseInsensitive)
        if uuidRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
            return name // Already a UDID
        }

        guard let r = try? await Shell.xcrun(timeout: 15, "simctl", "list", "devices", "-j"),
              r.succeeded,
              let data = r.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["devices"] as? [String: [[String: Any]]]
        else { return nil }

        let lower = name.lowercased()
        for (_, devs) in groups {
            for dev in devs {
                guard let devName = dev["name"] as? String,
                      let devUDID = dev["udid"] as? String else { continue }
                if devName.lowercased() == lower { return devUDID }
            }
        }
        // Prefix match
        for (_, devs) in groups {
            for dev in devs {
                guard let devName = dev["name"] as? String,
                      let devUDID = dev["udid"] as? String else { continue }
                if devName.lowercased().hasPrefix(lower) { return devUDID }
            }
        }
        return nil
    }

    /// Detect bundle ID from .app Info.plist.
    private static func detectBundleId(appPath: String) -> String? {
        let plistPath = appPath.hasSuffix("/") ? "\(appPath)Info.plist" : "\(appPath)/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bid = plist["CFBundleIdentifier"] as? String
        else { return nil }
        return bid
    }

    /// Scale image down for inline MCP response (max 1900px per side).
    private static func scaleDown(_ image: CGImage, maxPx: Int = 1900) -> CGImage {
        let w = image.width, h = image.height
        guard w > maxPx || h > maxPx else { return image }

        let scale = Double(maxPx) / Double(max(w, h))
        let newW = Int(Double(w) * scale)
        let newH = Int(Double(h) * scale)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }
}
