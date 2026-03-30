import CoreGraphics
import Foundation
import MCP

enum AccessibilityTools {

    // MARK: - Size Definitions

    /// Alias → Apple constant mapping. Ordered small → large.
    private static let sizeMap: [(alias: String, constant: String, label: String)] = [
        ("XS",      "UICTContentSizeCategoryXS",                      "Extra Small"),
        ("S",       "UICTContentSizeCategoryS",                       "Small"),
        ("M",       "UICTContentSizeCategoryM",                       "Medium"),
        ("default", "UICTContentSizeCategoryL",                       "Large (Default)"),
        ("L",       "UICTContentSizeCategoryL",                       "Large"),
        ("XL",      "UICTContentSizeCategoryXL",                      "Extra Large"),
        ("XXL",     "UICTContentSizeCategoryXXL",                     "XX-Large"),
        ("XXXL",    "UICTContentSizeCategoryXXXL",                    "XXX-Large"),
        ("AXM",     "UICTContentSizeCategoryAccessibilityM",          "Accessibility M"),
        ("AXL",     "UICTContentSizeCategoryAccessibilityL",          "Accessibility L"),
        ("AXXL",    "UICTContentSizeCategoryAccessibilityXL",         "Accessibility XL"),
        ("AX3",     "UICTContentSizeCategoryAccessibilityXXL",        "Accessibility XXL"),
        ("AX5",     "UICTContentSizeCategoryAccessibilityXXXL",       "Accessibility XXXL"),
    ]

    private static let defaultSizes = ["L", "XXXL", "AX3", "AX5"]

    private static let validAliases: Set<String> = Set(sizeMap.map(\.alias))

    // MARK: - Tool Definition

    static let tools: [Tool] = [
        Tool(
            name: "accessibility_check",
            description: """
                Check Dynamic Type rendering across multiple content size categories. \
                Sets each size on the simulator, relaunches the app, takes a screenshot, \
                and returns a structured report with inline images. \
                Claude Vision analyzes the screenshots for layout issues (truncation, overlap, clipping).
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "App bundle identifier. Optional — auto-detected from session if omitted"
                        ),
                    ]),
                    "simulator": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Simulator name or UDID. Optional — uses session default if omitted"
                        ),
                    ]),
                    "sizes": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Content size aliases to test. Valid: XS, S, M, default, L, XL, XXL, XXXL, AXM, AXL, AXXL, AX3, AX5. Default: [L, XXXL, AX3, AX5]"
                        ),
                    ]),
                    "settle_time": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Seconds to wait after app launch before screenshot. Default: 3"
                        ),
                    ]),
                ]),
            ])
        ),
    ]

    // MARK: - Entry Point

    static func accessibilityCheck(_ args: [String: Value]?) async -> CallTool.Result {
        let start = CFAbsoluteTimeGetCurrent()

        // Resolve simulator
        let simName: String
        do {
            simName = try await SessionState.shared.resolveSimulator(
                args?["simulator"]?.stringValue)
        } catch {
            return .fail("Cannot resolve simulator: \(error)")
        }
        let udid: String
        do {
            udid = try await SimTools.resolveSimulator(simName)
        } catch {
            return .fail("Simulator not found: \(simName)")
        }

        // Resolve bundle ID
        guard let bundleId = await SessionState.shared.resolveBundleId(
            args?["bundle_id"]?.stringValue) else {
            return .fail("Missing bundle_id — provide it or run build_run_sim first")
        }

        let settleTime = max(0.5, min(args?["settle_time"]?.numberValue ?? 3.0, 30.0))

        // Parse sizes
        let sizes: [String]
        if let sizesValue = args?["sizes"]?.arrayValue {
            let parsed = sizesValue.compactMap(\.stringValue).map { raw -> String in
                let upper = raw.uppercased()
                return upper == "DEFAULT" ? "default" : upper
            }
            for alias in parsed {
                if !validAliases.contains(alias) {
                    return .fail(
                        "Invalid size '\(alias)'. Valid: \(sizeMap.map(\.alias).joined(separator: ", "))"
                    )
                }
            }
            guard !parsed.isEmpty else {
                return .fail("sizes array must not be empty")
            }
            // Deduplicate by Apple constant (e.g. "default" and "L" both map to the same value)
            var seenConstants = Set<String>()
            var deduped: [String] = []
            for alias in parsed {
                if let entry = sizeMap.first(where: { $0.alias == alias }),
                   seenConstants.insert(entry.constant).inserted {
                    deduped.append(alias)
                }
            }
            sizes = deduped
        } else {
            sizes = defaultSizes
        }

        if sizes.count > 7 {
            return .fail(
                "Requested \(sizes.count) sizes — max 7 per run to avoid excessive runtime. Split into multiple calls.")
        }

        return await runCheck(
            udid: udid, simName: simName, bundleId: bundleId,
            sizes: sizes, settleTime: settleTime, start: start)
    }

    // MARK: - Core Logic

    private static func runCheck(
        udid: String, simName: String, bundleId: String,
        sizes: [String], settleTime: Double, start: CFAbsoluteTime
    ) async -> CallTool.Result {
        // Pre-check: simulator booted?
        if let r = try? await Shell.xcrun(timeout: 10, "simctl", "list", "devices", "-j"),
           r.succeeded, let data = r.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let groups = json["devices"] as? [String: [[String: Any]]] {
            let isBooted = groups.values.flatMap { $0 }.contains {
                ($0["udid"] as? String) == udid && ($0["state"] as? String) == "Booted"
            }
            if !isBooted {
                return .fail("Simulator \(simName) (\(udid)) is not booted. Run boot_sim first.")
            }
        }

        // Pre-check: app installed?
        if let r = try? await Shell.xcrun(timeout: 10, "simctl", "appinfo", udid, bundleId),
           !r.succeeded {
            return .fail("App \(bundleId) is not installed on \(simName). Run build_run_sim or install_app first.")
        }

        let runId = String(UUID().uuidString.prefix(8))

        // Resolve size aliases to (alias, constant, label) tuples
        let resolvedSizes = sizes.compactMap { alias in
            sizeMap.first { $0.alias == alias }
        }

        var results: [(alias: String, label: String, screenshotPath: String?, error: String?)] = []

        for size in resolvedSizes {
            // Set Dynamic Type via simctl spawn defaults write
            do {
                let r = try await Shell.xcrun(
                    timeout: 10, "simctl", "spawn", udid, "defaults", "write",
                    ".GlobalPreferences", "AppleContentSizeCategory", "-string", size.constant)
                guard r.succeeded else {
                    results.append((size.alias, size.label, nil, "defaults write failed: \(r.stderr)"))
                    continue
                }
            } catch {
                results.append((size.alias, size.label, nil, "defaults write error: \(error)"))
                continue
            }

            // Terminate app (ignore errors — may not be running)
            _ = try? await Shell.xcrun(timeout: 5, "simctl", "terminate", udid, bundleId)
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms for cleanup

            // Launch app
            let launchOk: Bool
            do {
                let r = try await Shell.xcrun(timeout: 15, "simctl", "launch", udid, bundleId)
                launchOk = r.succeeded
                if !launchOk {
                    results.append((size.alias, size.label, nil, "App launch failed: \(r.stderr)"))
                    continue
                }
            } catch {
                results.append((size.alias, size.label, nil, "App crash at launch: \(error)"))
                continue
            }

            // Settle — wait for UI to render
            try? await Task.sleep(nanoseconds: UInt64(settleTime * 1_000_000_000))

            // Screenshot via simctl (reliable, avoids CoreSimCapture MainActor issues)
            let path = "/tmp/ss-acc-\(runId)-\(size.alias).png"
            do {
                let r = try await Shell.xcrun(
                    timeout: 15, "simctl", "io", udid, "screenshot", "--type=png", path)
                if r.succeeded {
                    results.append((size.alias, size.label, path, nil))
                } else {
                    results.append((size.alias, size.label, nil, "Screenshot failed: \(r.stderr)"))
                }
            } catch {
                results.append((size.alias, size.label, nil, "Screenshot error: \(error)"))
            }
        }

        // Restore default Dynamic Type
        var restoreWarning: String?
        do {
            let r = try await Shell.xcrun(
                timeout: 10, "simctl", "spawn", udid, "defaults", "write",
                ".GlobalPreferences", "AppleContentSizeCategory", "-string",
                "UICTContentSizeCategoryL")
            if !r.succeeded {
                restoreWarning = "Failed to restore default Dynamic Type: \(r.stderr)"
            }
        } catch {
            restoreWarning = "Failed to restore default Dynamic Type: \(error)"
        }

        // Build report
        let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)
        let successCount = results.filter({ $0.screenshotPath != nil }).count
        let failCount = results.filter({ $0.error != nil }).count
        let status = failCount == 0 ? "PASS" : "WARN"

        var report: [String] = []
        report.append("[\(status)] Accessibility Matrix — Dynamic Type Check (\(elapsed)s)")
        report.append("Simulator: \(simName) (\(udid))")
        report.append("Bundle ID: \(bundleId)")
        report.append("Sizes tested: \(sizes.joined(separator: ", "))")
        report.append("Results: \(successCount) screenshots, \(failCount) errors")
        report.append("")
        report.append("IMPORTANT: Examine each screenshot for:")
        report.append("- Truncated or clipped text")
        report.append("- Overlapping UI elements")
        report.append("- Text overflowing containers")
        report.append("- Non-scrollable content that doesn't fit")
        report.append("- Buttons or labels that are unreadable")
        report.append("")

        for r in results {
            let icon = r.error != nil ? "[ERR]" : "[OK]"
            let detail = r.error ?? "Screenshot captured"
            report.append("  \(icon) \(r.alias) (\(r.label)): \(detail)")
        }

        if let warning = restoreWarning {
            report.append("")
            report.append("[WARN] \(warning)")
            report.append("Simulator may still have non-default Dynamic Type. Reset manually or reboot.")
        }

        // Build MCP content with inline images
        var content: [Tool.Content] = [
            .text(text: report.joined(separator: "\n"), annotations: nil, _meta: nil),
        ]

        // Attach screenshots as inline images
        for r in results {
            guard let path = r.screenshotPath,
                  let img = VisualTools.loadCGImage(path: path) else { continue }

            // Scale down for Claude Code (max 1900px per side)
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

        // Only set isError if ALL sizes failed (no screenshots at all).
        // Partial failures (some sizes crashed) are reported as WARN, not protocol-level errors.
        return .init(content: content, isError: successCount == 0 ? true : nil)
    }

    // MARK: - Image Scaling

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
