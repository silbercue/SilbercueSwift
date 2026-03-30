import CoreGraphics
import Foundation
import MCP

enum LocalizationTools {

    // MARK: - Locale Definitions

    /// Language code -> (AppleLanguages value, AppleLocale value, display label, RTL flag).
    private static let localeMap: [(code: String, language: String, locale: String, label: String, isRTL: Bool)] = [
        ("en", "en", "en_US", "English", false),
        ("de", "de", "de_DE", "German", false),
        ("fr", "fr", "fr_FR", "French", false),
        ("es", "es", "es_ES", "Spanish", false),
        ("it", "it", "it_IT", "Italian", false),
        ("pt", "pt-BR", "pt_BR", "Portuguese (Brazil)", false),
        ("zh", "zh-Hans", "zh_CN", "Chinese (Simplified)", false),
        ("ja", "ja", "ja_JP", "Japanese", false),
        ("ko", "ko", "ko_KR", "Korean", false),
        ("ru", "ru", "ru_RU", "Russian", false),
        ("ar", "ar", "ar_SA", "Arabic", true),
        ("he", "he", "he_IL", "Hebrew", true),
        ("th", "th", "th_TH", "Thai", false),
        ("hi", "hi", "hi_IN", "Hindi", false),
        ("tr", "tr", "tr_TR", "Turkish", false),
    ]

    private static let defaultLocales = ["en", "de", "ar", "ja", "ru"]

    private static let validCodes: String = {
        localeMap.map { "\($0.code) (\($0.label))" }.joined(separator: ", ")
    }()

    // MARK: - Tool Definition

    static let tools: [Tool] = [
        Tool(
            name: "localization_check",
            description:
                "Check app rendering across different languages/locales. Sets each locale, relaunches the app, and takes a screenshot. Returns inline screenshots and a summary report for Claude Vision analysis. RTL languages (Arabic, Hebrew) are explicitly flagged. Resets locale to English after the run.",
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
                    "locales": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Comma-separated locale codes to test. Default: 'en,de,ar,ja,ru'. Valid: \(validCodes)"
                        ),
                    ]),
                    "settle_time": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Seconds to wait after relaunch before screenshot. Default: 3.0"),
                    ]),
                ]),
                "required": .array([]),
            ])
        ),
    ]

    // MARK: - Entry Point

    static func localizationCheck(_ args: [String: Value]?) async -> CallTool.Result {
        let start = CFAbsoluteTimeGetCurrent()
        let runId = String(UUID().uuidString.prefix(8))

        // --- Resolve simulator ---
        let udid: String
        let explicitSim = args?["simulator"]?.stringValue
        do {
            let resolved = try await SessionState.shared.resolveSimulator(explicitSim)
            if let normalized = await resolveSimulatorUDID(resolved) {
                udid = normalized
            } else {
                udid = resolved
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

        // --- Parse locales ---
        let rawCodes: [String]
        if let localesStr = args?["locales"]?.stringValue, !localesStr.isEmpty {
            rawCodes = localesStr.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        } else {
            rawCodes = defaultLocales
        }

        // Resolve and deduplicate — unknown codes pass through as-is
        let rtlCodes: Set<String> = ["ar", "he", "fa", "ur"]
        var resolvedLocales: [(code: String, language: String, locale: String, label: String, isRTL: Bool)] = []
        var seenCodes = Set<String>()
        for raw in rawCodes {
            let code = raw.lowercased()
            let entry: (code: String, language: String, locale: String, label: String, isRTL: Bool)
            if let known = localeMap.first(where: { $0.code == code }) {
                entry = known
            } else {
                entry = (code: code, language: raw, locale: raw, label: raw, isRTL: rtlCodes.contains(code))
            }
            guard seenCodes.insert(entry.code).inserted else { continue }
            resolvedLocales.append(entry)
        }

        let settleTime = min(max(args?["settle_time"]?.numberValue ?? 3.0, 0.5), 30.0)

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

        // --- Cycle through locales ---
        struct LocaleResult {
            let code: String
            let label: String
            let isRTL: Bool
            var image: CGImage?
            var path: String?
            var crashed: Bool = false
            var error: String?
        }

        var results: [LocaleResult] = []

        for entry in resolvedLocales {
            var result = LocaleResult(code: entry.code, label: entry.label, isRTL: entry.isRTL)

            // 1. Set language + locale
            let langResult = try? await Shell.xcrun(
                timeout: 10, "simctl", "spawn", udid,
                "defaults", "write", "-g", "AppleLanguages",
                "-array", entry.language)
            if langResult?.succeeded != true {
                result.error = "Failed to set language: \(langResult?.stderr ?? "unknown")"
                results.append(result)
                continue
            }

            let localeResult = try? await Shell.xcrun(
                timeout: 10, "simctl", "spawn", udid,
                "defaults", "write", "-g", "AppleLocale",
                "-string", entry.locale)
            if localeResult?.succeeded != true {
                result.error = "Failed to set locale: \(localeResult?.stderr ?? "unknown")"
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
                result.error = "App crashed or failed to launch at \(entry.code): \(launchResult?.stderr ?? "unknown")"
                results.append(result)
                continue
            }

            // 3. Settle (locale changes need slightly more time)
            try? await Task.sleep(nanoseconds: UInt64(settleTime * 1_000_000_000))

            // 4. Screenshot
            let safeName = VisualTools.sanitize(entry.code)
            let path = "/tmp/ss-loc-\(runId)-\(safeName).png"
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

        // --- Reset locale to English ---
        let resetLang = try? await Shell.xcrun(
            timeout: 10, "simctl", "spawn", udid,
            "defaults", "write", "-g", "AppleLanguages",
            "-array", "en")
        let resetLocale = try? await Shell.xcrun(
            timeout: 10, "simctl", "spawn", udid,
            "defaults", "write", "-g", "AppleLocale",
            "-string", "en_US")
        let resetFailed = resetLang?.succeeded != true || resetLocale?.succeeded != true

        // Terminate app so it doesn't keep running in the last tested locale
        _ = try? await Shell.xcrun(timeout: 5, "simctl", "terminate", udid, bundleId)

        // --- Build report ---
        let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)
        let successCount = results.filter({ $0.image != nil }).count
        let crashCount = results.filter(\.crashed).count
        let failCount = results.filter({ $0.image == nil && !$0.crashed }).count
        let rtlCount = resolvedLocales.filter(\.isRTL).count

        let allFailed = successCount == 0 && !results.isEmpty
        let status = allFailed ? "FAIL" : (crashCount > 0 ? "WARNING" : (failCount > 0 ? "PARTIAL" : "PASS"))

        var report: [String] = []
        report.append("[\(status)] Localization Layout Check (\(elapsed)s)")
        report.append("Simulator: \(udid)")
        report.append("Bundle ID: \(bundleId)")
        report.append("Locales tested: \(resolvedLocales.count)")
        report.append("Screenshots: \(successCount)/\(resolvedLocales.count)")
        if rtlCount > 0 { report.append("RTL locales: \(rtlCount)") }
        if crashCount > 0 { report.append("Crashes: \(crashCount)") }
        report.append("")

        report.append("Results:")
        for r in results {
            let icon: String
            if r.crashed { icon = "[CRASH]" }
            else if r.image != nil { icon = "[OK]" }
            else { icon = "[ERR]" }

            let rtlTag = r.isRTL ? " [RTL]" : ""
            let dims = r.image.map { "\($0.width)x\($0.height)" } ?? ""
            let detail = r.error ?? dims
            report.append("  \(icon) \(r.code) (\(r.label))\(rtlTag) — \(detail)")
        }

        report.append("")
        report.append("Summary: \(successCount) von \(resolvedLocales.count) Sprachen erfolgreich, \(crashCount) Crashes, \(failCount) Fehler")
        if resetFailed {
            report.append("WARNING: Locale reset failed — simulator may have crashed. Manually reset with: xcrun simctl spawn \(udid) defaults write -g AppleLanguages -array en")
        } else {
            report.append("Locale reset to English (en_US). App terminated.")
        }
        report.append("")
        report.append("Analyze the screenshots below for: truncated strings, overlapping elements, incorrect RTL layout (for Arabic/Hebrew), font rendering issues (CJK characters), and text that overflows its container.")

        // --- Build MCP content with inline images ---
        var content: [Tool.Content] = [
            .text(text: report.joined(separator: "\n"), annotations: nil, _meta: nil),
        ]

        for r in results where r.image != nil {
            guard let img = r.image else { continue }
            let scaled = scaleDown(img)
            if let data = try? FramebufferCapture.encodeImage(scaled, format: "jpeg", quality: 0.6) {
                let rtlTag = r.isRTL ? " [RTL]" : ""
                content.append(.image(
                    data: data.base64EncodedString(), mimeType: "image/jpeg",
                    annotations: nil, _meta: nil))
                content.append(.text(
                    text: "\(r.code) (\(r.label))\(rtlTag) — \(img.width)x\(img.height)",
                    annotations: nil, _meta: nil))
            }
        }

        let hasErrors = crashCount > 0 || allFailed
        return .init(content: content, isError: hasErrors ? true : nil)
    }

    // MARK: - Helpers

    private static func resolveSimulatorUDID(_ name: String) async -> String? {
        let uuidRegex = try! NSRegularExpression(
            pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$",
            options: .caseInsensitive)
        if uuidRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
            return name
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
        for (_, devs) in groups {
            for dev in devs {
                guard let devName = dev["name"] as? String,
                      let devUDID = dev["udid"] as? String else { continue }
                if devName.lowercased().hasPrefix(lower) { return devUDID }
            }
        }
        return nil
    }

    private static func detectBundleId(appPath: String) -> String? {
        let plistPath = appPath.hasSuffix("/") ? "\(appPath)Info.plist" : "\(appPath)/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bid = plist["CFBundleIdentifier"] as? String
        else { return nil }
        return bid
    }

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
