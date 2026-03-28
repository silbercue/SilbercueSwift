import CoreGraphics
import Foundation
import MCP

enum MultiDeviceTools {
    /// Debug log to file — stderr would corrupt MCP protocol on stdout.
    private static func log(_ msg: String) {
        let ts = String(format: "%.1f", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 10000))
        let line = "[\(ts)] \(msg)\n"
        let path = "/tmp/ss-mdc-debug.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }
    static let tools: [Tool] = [
        Tool(
            name: "multi_device_check",
            description:
                "Install and launch an app on multiple simulators in parallel, take screenshots, and compare them. Supports Dark Mode, Landscape, and iPad. Returns inline screenshots, pixel-diff for same-resolution pairs, and a Layout Score.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_path": .object([
                        "type": .string("string"),
                        "description": .string("Path to .app bundle to install"),
                    ]),
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "App bundle identifier. Optional — auto-detected from Info.plist if omitted"
                        ),
                    ]),
                    "simulators": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Comma-separated simulator names/UDIDs. Example: 'iPhone SE (3rd generation), iPhone 16 Pro Max, iPad Pro 13-inch (M4)'"
                        ),
                    ]),
                    "dark_mode": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Also test in Dark Mode? Takes screenshots in both Light and Dark. Default: false"
                        ),
                    ]),
                    "landscape": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Also test in Landscape? Rotates each device and takes additional screenshots. Default: false"
                        ),
                    ]),
                    "settle_time": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Seconds to wait after launch before screenshot. Default: 3"),
                    ]),
                    "threshold": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Max allowed diff % between same-resolution pairs. Default: 1.0"),
                    ]),
                ]),
                "required": .array([
                    .string("app_path"), .string("simulators"),
                ]),
            ])
        ),
    ]

    // MARK: - Internal Types

    private struct DeviceState {
        let name: String
        let udid: String
        var wasAlreadyBooted: Bool
        var bootOk = false
        var launchOk = false
        var error: String?
    }

    private struct TaskResult: Sendable {
        let udid: String
        let success: Bool
        let message: String
    }

    private struct Mode {
        let appearance: String  // "light" or "dark"
        let orientation: String  // "portrait" or "landscape"
        var label: String { "\(orientation)-\(appearance)" }
    }

    private struct DeviceScreenshot {
        let name: String
        let udid: String
        let mode: Mode
        var image: CGImage?
        var path: String?
        var error: String?
    }

    private struct PairResult {
        let nameA: String
        let nameB: String
        let mode: Mode
        let sameResolution: Bool
        let diffPercent: Double
        let diffPath: String?
        let passed: Bool
    }

    // MARK: - Entry Point

    static func multiDeviceCheck(_ args: [String: Value]?) async -> CallTool.Result {
        guard let appPath = args?["app_path"]?.stringValue, !appPath.isEmpty else {
            return .fail("Missing required: app_path")
        }
        guard let simsStr = args?["simulators"]?.stringValue, !simsStr.isEmpty else {
            return .fail("Missing required: simulators")
        }
        guard FileManager.default.fileExists(atPath: appPath) else {
            return .fail("App not found: \(appPath)")
        }

        // Auto-detect bundle ID
        let bundleId: String
        if let bid = args?["bundle_id"]?.stringValue, !bid.isEmpty {
            bundleId = bid
        } else {
            let plistPath = appPath.hasSuffix("/")
                ? "\(appPath)Info.plist" : "\(appPath)/Info.plist"
            if let data = FileManager.default.contents(atPath: plistPath),
                let plist = try? PropertyListSerialization.propertyList(
                    from: data, format: nil) as? [String: Any],
                let detected = plist["CFBundleIdentifier"] as? String
            {
                bundleId = detected
            } else {
                return .fail("Cannot auto-detect bundle_id from \(plistPath). Provide bundle_id.")
            }
        }

        let settleTime = args?["settle_time"]?.numberValue ?? 3.0
        let threshold = args?["threshold"]?.numberValue ?? 1.0
        let testDarkMode = args?["dark_mode"]?.boolValue ?? false
        let testLandscape = args?["landscape"]?.boolValue ?? false

        let simNames = simsStr.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard simNames.count >= 2 else {
            return .fail("Need at least 2 simulators. Got: \(simNames.count)")
        }

        let start = CFAbsoluteTimeGetCurrent()
        let runId = String(UUID().uuidString.prefix(8))
        log("=== START multi_device_check run=\(runId) devices=\(simNames.count) dark=\(testDarkMode) landscape=\(testLandscape) ===")

        // Build test modes
        var modes = [Mode(appearance: "light", orientation: "portrait")]
        if testDarkMode {
            modes.append(Mode(appearance: "dark", orientation: "portrait"))
        }
        if testLandscape {
            modes.append(Mode(appearance: "light", orientation: "landscape"))
            if testDarkMode {
                modes.append(Mode(appearance: "dark", orientation: "landscape"))
            }
        }

        // ===== Phase 1: Resolve simulators =====
        log("Phase 1: resolving \(simNames.count) simulators...")
        let deviceList: [String: [[String: Any]]]
        do {
            let r = try await Shell.xcrun(timeout: 15, "simctl", "list", "devices", "-j")
            guard r.succeeded,
                  let data = r.stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let groups = json["devices"] as? [String: [[String: Any]]]
            else {
                return .fail("Failed to list simulators: \(r.stderr)")
            }
            deviceList = groups
        } catch {
            return .fail("simctl list failed: \(error)")
        }

        // Build lookup tables from the single fetch
        var bootedUDIDs = Set<String>()
        var nameToUDID: [String: String] = [:]  // lowercased name → UDID
        var udidToName: [String: String] = [:]  // UDID → display name (for window matching)
        for (_, devs) in deviceList {
            for dev in devs {
                guard let name = dev["name"] as? String,
                      let udid = dev["udid"] as? String else { continue }
                nameToUDID[name.lowercased()] = udid
                udidToName[udid] = name
                if let state = dev["state"] as? String, state == "Booted" {
                    bootedUDIDs.insert(udid)
                }
            }
        }

        // Resolve each simulator name without additional simctl calls
        var devices: [DeviceState] = []
        let uuidRegex = try! NSRegularExpression(
            pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$",
            options: .caseInsensitive)
        for name in simNames {
            let udid: String
            let displayName: String
            if uuidRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
                udid = name
                displayName = udidToName[name] ?? name  // Resolve UDID → device name
            } else if let found = nameToUDID[name.lowercased()] {
                udid = found
                displayName = name
            } else if let found = nameToUDID.first(where: { $0.key.hasPrefix(name.lowercased()) }) {
                udid = found.value
                displayName = udidToName[found.value] ?? name
            } else {
                return .fail("Simulator '\(name)' not found")
            }
            devices.append(DeviceState(
                name: displayName, udid: udid,
                wasAlreadyBooted: bootedUDIDs.contains(udid)))
        }

        log("Phase 1 done: resolved \(devices.count) devices")

        // ===== Phase 2: Boot in parallel =====
        let needsBoot = devices.filter { !$0.wasAlreadyBooted }
        if !needsBoot.isEmpty {
            let bootResults = await withTaskGroup(of: TaskResult.self) { group in
                for device in needsBoot {
                    let udid = device.udid
                    group.addTask {
                        do {
                            let r = try await Shell.xcrun(timeout: 60, "simctl", "boot", udid)
                            let ok = r.succeeded || r.stderr.contains("current state: Booted")
                            return TaskResult(udid: udid, success: ok, message: ok ? "OK" : r.stderr)
                        } catch {
                            return TaskResult(udid: udid, success: false, message: "\(error)")
                        }
                    }
                }
                var results: [TaskResult] = []
                for await r in group { results.append(r) }
                return results
            }
            for r in bootResults {
                if let idx = devices.firstIndex(where: { $0.udid == r.udid }) {
                    devices[idx].bootOk = r.success
                    if !r.success { devices[idx].error = "Boot: \(r.message)" }
                }
            }
            _ = try? await Shell.run("/usr/bin/open", arguments: ["-a", "Simulator"], timeout: 5)
            await waitForAllBooted(udids: needsBoot.map(\.udid), timeout: 30)
        }
        for i in devices.indices where devices[i].wasAlreadyBooted {
            devices[i].bootOk = true
        }

        let bootedDevices = devices.filter(\.bootOk)
        guard bootedDevices.count >= 2 else {
            let errs = devices.filter { !$0.bootOk }.map { "\($0.name): \($0.error ?? "?")" }
            return .fail("Only \(bootedDevices.count) booted. Need 2+.\n\(errs.joined(separator: "\n"))")
        }

        log("Phase 2 done: \(devices.filter(\.bootOk).count)/\(devices.count) booted")

        // ===== Phase 3: Install parallel, then launch sequentially =====
        log("Phase 3: install + launch...")
        // Install in parallel (safe — simctl install is idempotent)
        let installResults = await withTaskGroup(of: TaskResult.self) { group in
            for device in bootedDevices {
                let udid = device.udid
                group.addTask {
                    do {
                        let r = try await Shell.xcrun(timeout: 60, "simctl", "install", udid, appPath)
                        return TaskResult(udid: udid, success: r.succeeded,
                            message: r.succeeded ? "OK" : "Install: \(r.stderr)")
                    } catch {
                        return TaskResult(udid: udid, success: false, message: "\(error)")
                    }
                }
            }
            var results: [TaskResult] = []
            for await r in group { results.append(r) }
            return results
        }
        for r in installResults {
            if let idx = devices.firstIndex(where: { $0.udid == r.udid }) {
                if !r.success { devices[idx].error = r.message }
            }
        }

        // Launch with 500ms stagger — SpringBoard (SBMainWorkspace) processes
        // foreground requests serially. Parallel launches return exit 0 but
        // silently fail to foreground. 500ms gap lets SpringBoard finish each request.
        for i in devices.indices where devices[i].bootOk {
            let udid = devices[i].udid
            _ = try? await Shell.run("/usr/bin/xcrun",
                arguments: ["simctl", "terminate", udid, bundleId], timeout: 5)

            var launched = false
            for attempt in 1...2 {
                do {
                    let r = try await Shell.run("/usr/bin/xcrun",
                        arguments: ["simctl", "launch", udid, bundleId], timeout: 15)
                    if r.succeeded {
                        launched = true
                        break
                    }
                    if attempt == 2 {
                        devices[i].error = "Launch: \(r.stderr)"
                    }
                } catch {
                    if attempt == 2 { devices[i].error = "Launch: \(error)" }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms before retry
            }
            devices[i].launchOk = launched

            // 500ms stagger between devices for SpringBoard
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let readyDevices = devices.filter(\.launchOk)
        guard readyDevices.count >= 2 else {
            let errs = devices.filter { !$0.launchOk }.map { "\($0.name): \($0.error ?? "?")" }
            return .fail("Only \(readyDevices.count) launched. Need 2+.\n\(errs.joined(separator: "\n"))")
        }

        log("Phase 3 done: \(readyDevices.count)/\(devices.count) launched")

        // Initial settle
        try? await Task.sleep(nanoseconds: UInt64(settleTime * 1_000_000_000))

        log("Phase 4: screenshot \(modes.count) mode(s)...")
        // ===== Phase 4: Screenshot each mode =====
        var allScreenshots: [DeviceScreenshot] = []
        var allPairs: [PairResult] = []

        // Resolve window IDs once — stable integers, no name matching ambiguity
        var windowIDs: [String: Int] = [:]
        if testLandscape {
            windowIDs = await resolveWindowIDs(deviceNames: readyDevices.map(\.name))
            log("  Window IDs: \(windowIDs)")
        }

        for mode in modes {
            log("  Mode \(mode.label): setting appearance...")
            for d in readyDevices {
                _ = try? await Shell.xcrun(timeout: 5, "simctl", "ui", d.udid, "appearance", mode.appearance)
            }

            // Set orientation
            if mode.orientation == "landscape" {
                for d in readyDevices {
                    if let wid = windowIDs[d.name] {
                        await rotateDevice(windowID: wid, name: d.name, toPortrait: false)
                    } else {
                        log("    WARN: No window ID for \(d.name) — skipping rotation")
                    }
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            } else if modes.contains(where: { $0.orientation == "landscape" }) {
                // Ensure portrait if we've been in landscape before
            }

            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s for appearance transition

            // Screenshot each device via simctl (reliable, has timeout).
            // CoreSimCapture is avoided here — its synchronous ObjC calls can
            // block the Swift concurrency runtime when multiple sims are active.
            log("  Mode \(mode.label): taking \(readyDevices.count) screenshots...")
            var modeScreenshots: [DeviceScreenshot] = []
            for d in readyDevices {
                log("    Screenshot \(d.name)...")
                let safeName = VisualTools.sanitize(d.name)
                let path = "/tmp/ss-mdc-\(runId)-\(mode.label)-\(safeName).png"
                var ss = DeviceScreenshot(name: d.name, udid: d.udid, mode: mode)

                do {
                    let r = try await Shell.xcrun(timeout: 15, "simctl", "io", d.udid,
                        "screenshot", "--type=png", path)
                    if r.succeeded, let img = VisualTools.loadCGImage(path: path) {
                        ss.image = img
                        ss.path = path
                    } else { ss.error = r.stderr }
                } catch { ss.error = "\(error)" }
                log("    Screenshot \(d.name): \(ss.image != nil ? "OK" : "FAIL \(ss.error ?? "")")")
                modeScreenshots.append(ss)
            }

            log("  Mode \(mode.label): comparing pairs...")
            // Pairwise comparison within this mode
            let captured = modeScreenshots.filter { $0.image != nil }
            for i in 0..<captured.count {
                for j in (i + 1)..<captured.count {
                    let a = captured[i], b = captured[j]
                    guard let imgA = a.image, let imgB = b.image else { continue }
                    let sameRes = imgA.width == imgB.width && imgA.height == imgB.height

                    if sameRes {
                        let cmp = VisualTools.pixelCompare(baseline: imgA, current: imgB)
                        var diffPath: String?
                        if let diffImg = cmp.diffImage {
                            let p = "/tmp/ss-mdc-diff-\(runId)-\(mode.label)-\(VisualTools.sanitize(a.name))-vs-\(VisualTools.sanitize(b.name)).png"
                            VisualTools.savePNG(image: diffImg, path: p)
                            diffPath = p
                        }
                        allPairs.append(PairResult(
                            nameA: a.name, nameB: b.name, mode: mode,
                            sameResolution: true, diffPercent: cmp.diffPercent,
                            diffPath: diffPath, passed: cmp.diffPercent <= threshold))
                    } else {
                        allPairs.append(PairResult(
                            nameA: a.name, nameB: b.name, mode: mode,
                            sameResolution: false, diffPercent: -1,
                            diffPath: nil, passed: true))
                    }
                }
            }

            allScreenshots.append(contentsOf: modeScreenshots)
        }

        // ===== Phase 5: Restore state =====
        // Restore portrait if we rotated
        if testLandscape {
            for d in readyDevices {
                if let wid = windowIDs[d.name] {
                    await rotateDevice(windowID: wid, name: d.name, toPortrait: true)
                }
            }
        }
        // Restore light mode if we changed
        if testDarkMode {
            for d in readyDevices {
                _ = try? await Shell.xcrun(timeout: 5, "simctl", "ui", d.udid, "appearance", "light")
            }
        }

        // ===== Phase 6: Layout Score + Report =====
        let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)
        let score = computeLayoutScore(
            devices: devices, screenshots: allScreenshots,
            pairs: allPairs, threshold: threshold)
        let sameResFailed = allPairs.filter { $0.sameResolution && !$0.passed }
        let allPassed = sameResFailed.isEmpty
        let status = allPassed ? "PASS" : "FAIL"

        var report: [String] = []
        report.append("[\(status)] Multi-Device Consistency Check (\(elapsed)s)")
        report.append("Layout Score: \(score)/100")
        report.append("Modes tested: \(modes.map(\.label).joined(separator: ", "))")
        report.append("Bundle ID: \(bundleId)")
        report.append("")

        // Per-device summary
        report.append("Devices:")
        for d in devices {
            let icon = d.launchOk ? "[OK]" : "[ERR]"
            let err = d.error.map { " — \($0)" } ?? ""
            report.append("  \(icon) \(d.name)\(err)")
        }

        // Per-mode results
        for mode in modes {
            report.append("")
            report.append("--- \(mode.label) ---")
            let modeShots = allScreenshots.filter { $0.mode.label == mode.label }
            for ss in modeShots {
                let icon = ss.image != nil ? "[OK]" : "[ERR]"
                let dims = ss.image.map { "\($0.width)x\($0.height)" } ?? "n/a"
                report.append("  \(icon) \(ss.name) (\(dims))")
            }

            let modePairs = allPairs.filter { $0.mode.label == mode.label }
            if !modePairs.isEmpty {
                for p in modePairs {
                    if p.sameResolution {
                        let icon = p.passed ? "[OK]" : "[DIFF]"
                        report.append("  \(icon) \(p.nameA) vs \(p.nameB): \(String(format: "%.2f", p.diffPercent))%")
                        if let dp = p.diffPath, !p.passed {
                            report.append("       Diff: \(dp)")
                        }
                    } else {
                        report.append("  [SKIP] \(p.nameA) vs \(p.nameB): different resolution")
                    }
                }
            }
        }

        // Build MCP content with inline images
        var content: [Tool.Content] = [
            .text(text: report.joined(separator: "\n"), annotations: nil, _meta: nil)
        ]

        // Inline screenshots (primary mode only to keep response size manageable)
        let primaryMode = modes[0]
        let primaryShots = allScreenshots.filter { $0.mode.label == primaryMode.label && $0.image != nil }
        for ss in primaryShots {
            guard let img = ss.image else { continue }
            if let data = try? FramebufferCapture.encodeImage(scaleDown(img), format: "jpeg", quality: 0.6) {
                content.append(.image(data: data.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil))
                content.append(.text(text: "\(ss.name) [\(primaryMode.label)] \(img.width)x\(img.height)", annotations: nil, _meta: nil))
            }
        }

        // If dark mode tested, include dark screenshots too
        if testDarkMode {
            let darkShots = allScreenshots.filter { $0.mode.appearance == "dark" && $0.mode.orientation == "portrait" && $0.image != nil }
            for ss in darkShots {
                guard let img = ss.image else { continue }
                if let data = try? FramebufferCapture.encodeImage(scaleDown(img), format: "jpeg", quality: 0.6) {
                    content.append(.image(data: data.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil))
                    content.append(.text(text: "\(ss.name) [portrait-dark] \(img.width)x\(img.height)", annotations: nil, _meta: nil))
                }
            }
        }

        // Diff images for failures
        for p in allPairs where !p.passed && p.sameResolution {
            if let path = p.diffPath, let img = VisualTools.loadCGImage(path: path),
                let data = try? FramebufferCapture.encodeImage(scaleDown(img), format: "jpeg", quality: 0.8)
            {
                content.append(.image(data: data.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil))
                content.append(.text(text: "DIFF [\(p.mode.label)]: \(p.nameA) vs \(p.nameB)", annotations: nil, _meta: nil))
            }
        }

        log("=== DONE run=\(runId) score=\(score) elapsed=\(elapsed)s ===")
        return .init(content: content, isError: allPassed ? nil : true)
    }

    // MARK: - Appearance & Rotation

    /// Resolve CGWindowIDs for all open Simulator windows.
    /// Returns a mapping of device name → window ID (unique integer).
    /// Window IDs are stable for the lifetime of the window — no name matching needed.
    private static func resolveWindowIDs(deviceNames: [String]) async -> [String: Int] {
        let script = """
        set output to ""
        tell application "System Events"
            tell process "Simulator"
                repeat with w in windows
                    set output to output & (id of w) & "|||" & (name of w) & linefeed
                end repeat
            end tell
        end tell
        return output
        """
        guard let result = try? await Shell.run("/usr/bin/osascript", arguments: ["-e", script], timeout: 10),
              result.succeeded else { return [:] }

        var mapping: [String: Int] = [:]
        // Sort names longest-first so "iPhone 16 Pro Max" matches before "iPhone 16 Pro"
        let sortedNames = deviceNames.sorted { $0.count > $1.count }
        var claimedWindows = Set<Int>()

        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "|||", maxSplits: 1)
            guard parts.count == 2, let wid = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let windowTitle = String(parts[1])
            for name in sortedNames {
                if windowTitle.contains(name) && mapping[name] == nil && !claimedWindows.contains(wid) {
                    mapping[name] = wid
                    claimedWindows.insert(wid)
                    break  // This window is claimed, don't match shorter names
                }
            }
        }
        return mapping
    }

    /// Rotate a simulator via AppleScript menu click using CGWindowID.
    /// No name matching — the integer window ID is unique and stable.
    private static func rotateDevice(windowID: Int, name: String, toPortrait: Bool) async {
        let menuItem = toPortrait ? "Rotate Right" : "Rotate Left"
        let script = """
        tell application "Simulator" to activate
        delay 0.2
        tell application "System Events"
            tell process "Simulator"
                perform action "AXRaise" of (first window whose id is \(windowID))
                delay 0.3
                click menu item "\(menuItem)" of menu "Device" of menu bar 1
            end tell
        end tell
        """
        log("    Rotate \(name) (wid=\(windowID)) → \(toPortrait ? "portrait" : "landscape")")
        let result = try? await Shell.run("/usr/bin/osascript", arguments: ["-e", script], timeout: 10)
        let ok = result?.succeeded ?? false
        log("    Rotate result: \(ok ? "OK" : result?.stderr ?? "failed")")
    }

    // MARK: - Image Scaling

    /// Scale a CGImage down so neither dimension exceeds maxPx.
    /// Claude Code limits inline images to 2000px per side in multi-image responses.
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

    // MARK: - Layout Score

    /// Compute a 0-100 layout score based on test results.
    private static func computeLayoutScore(
        devices: [DeviceState], screenshots: [DeviceScreenshot],
        pairs: [PairResult], threshold: Double
    ) -> Int {
        let totalDevices = devices.count
        let bootedCount = devices.filter(\.bootOk).count
        let launchedCount = devices.filter(\.launchOk).count
        let screenshotCount = screenshots.filter({ $0.image != nil }).count
        let expectedScreenshots = screenshots.count

        // Device readiness: 30 points
        let deviceScore: Double
        if totalDevices > 0 {
            let bootRate = Double(bootedCount) / Double(totalDevices)
            let launchRate = Double(launchedCount) / Double(totalDevices)
            deviceScore = (bootRate + launchRate) / 2.0 * 30.0
        } else { deviceScore = 0 }

        // Screenshot success: 30 points
        let screenshotScore: Double
        if expectedScreenshots > 0 {
            screenshotScore = Double(screenshotCount) / Double(expectedScreenshots) * 30.0
        } else { screenshotScore = 0 }

        // Consistency: 40 points (based on same-resolution pair diffs)
        let sameResPairs = pairs.filter(\.sameResolution)
        let consistencyScore: Double
        if sameResPairs.isEmpty {
            consistencyScore = 40.0  // No same-res pairs = assume OK
        } else {
            let passRate = Double(sameResPairs.filter(\.passed).count) / Double(sameResPairs.count)
            let avgDiff = sameResPairs.map(\.diffPercent).reduce(0, +) / Double(sameResPairs.count)
            let diffPenalty = min(avgDiff / threshold, 1.0)
            consistencyScore = (passRate * 0.7 + (1.0 - diffPenalty) * 0.3) * 40.0
        }

        return min(100, max(0, Int(deviceScore + screenshotScore + consistencyScore)))
    }

    // MARK: - Simulator Helpers

    private static func currentlyBootedUDIDs() async -> Set<String> {
        guard let result = try? await Shell.xcrun(timeout: 10, "simctl", "list", "devices", "-j"),
            let data = result.stdout.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let groups = json["devices"] as? [String: [[String: Any]]]
        else { return [] }

        var booted = Set<String>()
        for (_, devs) in groups {
            for dev in devs {
                if let state = dev["state"] as? String, state == "Booted",
                    let udid = dev["udid"] as? String
                { booted.insert(udid) }
            }
        }
        return booted
    }

    private static func waitForAllBooted(udids: [String], timeout: TimeInterval) async {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        let target = Set(udids)
        while CFAbsoluteTimeGetCurrent() < deadline {
            let booted = await currentlyBootedUDIDs()
            if target.isSubset(of: booted) { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
