import Foundation
import MCP

enum UITools {
    static let tools: [Tool] = [
        Tool(
            name: "wda_status",
            description: "Check if WebDriverAgent is running and reachable.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        Tool(
            name: "handle_alert",
            description: "Handle iOS system alerts AND in-app dialogs. Searches Springboard, active app, and ContactsUI (iOS 18+). Actions: accept, dismiss, get_text, accept_all, dismiss_all. One call replaces screenshot→find→click.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object(["type": .string("string"), "description": .string("Action: 'accept', 'dismiss', 'get_text', 'accept_all' (batch), or 'dismiss_all' (batch)")]),
                    "button_label": .object(["type": .string("string"), "description": .string("Optional: specific button to tap (e.g. 'Allow While Using App'). If omitted, uses smart defaults.")]),
                ]),
                "required": .array([.string("action")]),
            ])
        ),
        Tool(
            name: "wda_create_session",
            description: "Create a new WDA session, optionally for a specific app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundle_id": .object(["type": .string("string"), "description": .string("Optional bundle ID to activate")]),
                    "wda_url": .object(["type": .string("string"), "description": .string("WDA base URL. Default: http://localhost:8100")]),
                ]),
            ])
        ),
        Tool(
            name: "find_element",
            description: "Find a UI element. With scroll: true, auto-scrolls the nearest ScrollView/List until the element appears (one call, no manual swipe loop needed).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "using": .object(["type": .string("string"), "description": .string("Strategy: 'accessibility id', 'class name', 'predicate string', 'class chain'")]),
                    "value": .object(["type": .string("string"), "description": .string("Search value")]),
                    "scroll": .object(["type": .string("boolean"), "description": .string("Auto-scroll to find off-screen elements. Default: false")]),
                    "direction": .object(["type": .string("string"), "description": .string("Scroll direction: 'auto' (smart — detects boundaries, reverses automatically), 'down', 'up', 'left', 'right'. Default: 'auto'")]),
                    "max_swipes": .object(["type": .string("number"), "description": .string("Max scroll attempts. Default: 10")]),
                ]),
                "required": .array([.string("using"), .string("value")]),
            ])
        ),
        Tool(
            name: "find_elements",
            description: "Find multiple UI elements matching a query.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "using": .object(["type": .string("string"), "description": .string("Strategy: 'accessibility id', 'class name', 'xpath', 'predicate string', 'class chain'")]),
                    "value": .object(["type": .string("string"), "description": .string("Search value")]),
                ]),
                "required": .array([.string("using"), .string("value")]),
            ])
        ),
        Tool(
            name: "click_element",
            description: "Click/tap a UI element by its ID. Set screenshot: true to get an inline screenshot after the tap (saves a separate screenshot call).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "element_id": .object(["type": .string("string"), "description": .string("Element ID from find_element")]),
                    "screenshot": .object(["type": .string("boolean"), "description": .string("Take inline screenshot after action. Default: false")]),
                ]),
                "required": .array([.string("element_id")]),
            ])
        ),
        Tool(
            name: "tap_coordinates",
            description: "Tap at specific x,y coordinates on screen. Set screenshot: true to get an inline screenshot after the tap.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                    "screenshot": .object(["type": .string("boolean"), "description": .string("Take inline screenshot after action. Default: false")]),
                ]),
                "required": .array([.string("x"), .string("y")]),
            ])
        ),
        Tool(
            name: "type_text",
            description: "Type text into a specified element, or auto-find the first text input (TextField, TextView, or SearchField) on screen.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string"), "description": .string("Text to type")]),
                    "element_id": .object(["type": .string("string"), "description": .string("Optional element ID to type into")]),
                    "clear_first": .object(["type": .string("boolean"), "description": .string("Clear existing text first. Default: false")]),
                    "screenshot": .object(["type": .string("boolean"), "description": .string("Take inline screenshot after action. Default: false")]),
                ]),
                "required": .array([.string("text")]),
            ])
        ),
        Tool(
            name: "get_text",
            description: "Get text content of a UI element.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "element_id": .object(["type": .string("string"), "description": .string("Element ID from find_element")]),
                ]),
                "required": .array([.string("element_id")]),
            ])
        ),
        Tool(
            name: "get_source",
            description: "Get the view hierarchy of the current screen. Use format 'pruned' for a flat list of interactive elements with frames (~80-90% smaller, ideal for LLM).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "format": .object(["type": .string("string"), "description": .string("Format: json, xml, description, or pruned. 'pruned' = flat JSON array of labeled/interactive elements with compact frames. Default: json")]),
                ]),
            ])
        ),
        Tool(
            name: "navigate",
            description: "Navigate to a screen in one call: finds element by label, taps it, waits for animation, takes compact screenshot. Replaces 3 separate calls (find + click + screenshot). Use back: true to go back first.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "target": .object(["type": .string("string"), "description": .string("Label or accessibility ID of the element to tap (e.g. 'Button & Tap Tests')")]),
                    "back": .object(["type": .string("boolean"), "description": .string("Tap the back button first before navigating to target. Default: false")]),
                    "scroll": .object(["type": .string("boolean"), "description": .string("Use SmartScroll if target not visible. Default: false")]),
                    "settle_ms": .object(["type": .string("number"), "description": .string("Wait time in ms after tap for animations. Default: 300")]),
                ]),
                "required": .array([.string("target")]),
            ])
        ),
    ]

    // MARK: - Registration (Free tools only)

    static let registrations: [ToolRegistration] = tools.compactMap { tool in
        let handler: (@Sendable ([String: Value]?) async -> CallTool.Result)? = switch tool.name {
        case "wda_status": wdaStatus
        case "handle_alert": handleAlert
        case "wda_create_session": wdaCreateSession
        case "find_element": findElement
        case "find_elements": findElements
        case "click_element": clickElement
        case "tap_coordinates": tapCoordinates
        case "type_text": typeText
        case "get_text": getText
        case "get_source": getSource
        case "navigate": navigate
        default: nil
        }
        guard let h = handler else { return nil }
        return ToolRegistration(tool: tool, handler: h)
    }

    // MARK: - Implementations

    static func handleAlert(_ args: [String: Value]?) async -> CallTool.Result {
        guard let action = args?["action"]?.stringValue else {
            return .fail("Missing required: action ('accept', 'dismiss', 'get_text', 'accept_all', 'dismiss_all')")
        }
        let buttonLabel = args?["button_label"]?.stringValue

        switch action {
        case "get_text":
            guard let info = await WDAClient.shared.getAlertText() else {
                Task { guard let udid = await SimStateCache.currentUDID() else { return }
                    await SimStateCache.shared.recordAlert(udid: udid, state: "none") }
                return .ok("No alert visible.")
            }
            Task { guard let udid = await SimStateCache.currentUDID() else { return }
                await SimStateCache.shared.recordAlert(udid: udid, state: "visible: \(info.text)") }
            return .ok("Alert text: \(info.text)\nButtons: \(info.buttons.joined(separator: ", "))")

        case "accept":
            do {
                let info = try await WDAClient.shared.acceptAlert(buttonLabel: buttonLabel)
                Task { guard let udid = await SimStateCache.currentUDID() else { return }
                    await SimStateCache.shared.recordAlert(udid: udid, state: "none") }
                var msg = "Alert accepted."
                if let info {
                    msg += "\nAlert was: \(info.text)\nButtons were: \(info.buttons.joined(separator: ", "))"
                }
                return .ok(msg)
            } catch {
                return .fail("Accept alert failed: \(error)")
            }

        case "dismiss":
            do {
                let info = try await WDAClient.shared.dismissAlert(buttonLabel: buttonLabel)
                Task { guard let udid = await SimStateCache.currentUDID() else { return }
                    await SimStateCache.shared.recordAlert(udid: udid, state: "none") }
                var msg = "Alert dismissed."
                if let info {
                    msg += "\nAlert was: \(info.text)\nButtons were: \(info.buttons.joined(separator: ", "))"
                }
                return .ok(msg)
            } catch {
                return .fail("Dismiss alert failed: \(error)")
            }

        case "accept_all":
            // Pro gate: batch alert handling
            if !(await LicenseManager.shared.isPro) {
                return .fail(
                    "\"accept_all\" is a [PRO] feature.\n"
                    + "Clears all permission dialogs in one sweep — no more screenshot-find-click loops.\n"
                    + "Free: action='accept' handles them one by one.\n\n"
                    + "Level up here → \(LicenseManager.upgradeURL)\n"
                    + "Then: silbercueswift activate <YOUR-KEY>")
            }
            do {
                let result = try await WDAClient.shared.handleAllAlerts(accept: true)
                if result.count == 0 {
                    return .ok("No alerts visible.")
                }
                var msg = "\(result.count) alert(s) accepted."
                for (i, alert) in result.alerts.enumerated() {
                    msg += "\n  [\(i + 1)] \(alert.text) → buttons: \(alert.buttons.joined(separator: ", ")) (source: \(alert.source))"
                }
                return .ok(msg)
            } catch {
                return .fail("Accept all alerts failed: \(error)")
            }

        case "dismiss_all":
            // Pro gate: batch alert handling
            if !(await LicenseManager.shared.isPro) {
                return .fail(
                    "\"dismiss_all\" is a [PRO] feature.\n"
                    + "Clears all permission dialogs in one sweep — no more screenshot-find-click loops.\n"
                    + "Free: action='dismiss' handles them one by one.\n\n"
                    + "Level up here → \(LicenseManager.upgradeURL)\n"
                    + "Then: silbercueswift activate <YOUR-KEY>")
            }
            do {
                let result = try await WDAClient.shared.handleAllAlerts(accept: false)
                if result.count == 0 {
                    return .ok("No alerts visible.")
                }
                var msg = "\(result.count) alert(s) dismissed."
                for (i, alert) in result.alerts.enumerated() {
                    msg += "\n  [\(i + 1)] \(alert.text) → buttons: \(alert.buttons.joined(separator: ", ")) (source: \(alert.source))"
                }
                return .ok(msg)
            } catch {
                return .fail("Dismiss all alerts failed: \(error)")
            }

        default:
            return .fail("Unknown action: '\(action)'. Use 'accept', 'dismiss', 'get_text', 'accept_all', or 'dismiss_all'.")
        }
    }

    static func wdaStatus(_ args: [String: Value]?) async -> CallTool.Result {
        let healthy = await WDAClient.shared.isHealthy()
        let backendName = await WDAClient.shared.backend.displayName
        let fallback = await WDAClient.shared.fallbackInfo
        Task { guard let udid = await SimStateCache.currentUDID() else { return }
            await SimStateCache.shared.recordWDAStatus(udid: udid, status: healthy ? "healthy (\(backendName))" : "not responding") }

        if healthy {
            do {
                let status = try await WDAClient.shared.status()
                let sessionInfo = "Sessions tracked: \(await WDAClient.shared.sessionCount)"
                var msg = "WDA Status: \(status.ready ? "READY" : "NOT READY")\nBackend: \(backendName)\nBundle: \(status.bundleId)\n\(sessionInfo)"
                if let info = fallback {
                    msg += "\nInfo: \(info)"
                }
                return .ok(msg)
            } catch {
                return .ok("WDA reachable but status parse failed: \(error)")
            }
        } else {
            return .fail("WDA not responding (health check timeout 2s). Backend: \(backendName). Try restarting WDA or the simulator.")
        }
    }

    static func wdaCreateSession(_ args: [String: Value]?) async -> CallTool.Result {
        let customURL = args?["wda_url"]?.stringValue
        let bundleId = args?["bundle_id"]?.stringValue

        if let url = customURL {
            // Per-call override: try custom URL directly, NO deploy attempt.
            let previousURL = await WDAClient.shared.getBaseURL()
            let healthBefore = await WDAClient.shared.isHealthy()
            Log.warn("wdaCreateSession: custom URL=\(url), previous=\(previousURL), healthBefore=\(healthBefore)")
            await WDAClient.shared.setBaseURL(url)

            do {
                // Skip ensureWDARunning — never deploy to a custom URL
                let sid = try await WDAClient.shared.createSession(bundleId: bundleId)
                var msg = "Session created: \(sid) (custom WDA: \(url))"
                if let warning = await WDAClient.shared.sessionWarning {
                    msg += "\n\(warning)"
                }
                return .ok(msg)
            } catch {
                await WDAClient.shared.setBaseURL(previousURL)
                let healthAfter = await WDAClient.shared.isHealthy()
                Log.warn("wdaCreateSession: custom URL failed: \(error). healthAfter=\(healthAfter), restored to \(previousURL)")
                return .fail("Connection to \(url) failed: \(error). Default URL (\(previousURL)) restored.")
            }
        }

        // Default path: ensureWDARunning + createSession
        do {
            try await WDAClient.shared.ensureWDARunning()

            let sid = try await WDAClient.shared.createSession(bundleId: bundleId)
            var msg = "Session created: \(sid)"

            if let warning = await WDAClient.shared.sessionWarning {
                msg += "\n\(warning)"
            }
            return .ok(msg)
        } catch {
            return .fail("Session creation failed: \(error)")
        }
    }

    static func findElement(_ args: [String: Value]?) async -> CallTool.Result {
        guard let using = args?["using"]?.stringValue,
              let value = args?["value"]?.stringValue else {
            return .fail("Missing required: using, value")
        }
        let scroll = args?["scroll"]?.boolValue ?? false
        let direction = args?["direction"]?.stringValue ?? "auto"
        let maxSwipes = args?["max_swipes"]?.intValue ?? 10

        // Pro gate: scroll:true requires Pro
        if scroll, !(await LicenseManager.shared.isPro) {
            return .fail(
                "\"scroll: true\" is a [PRO] feature.\n"
                + "SmartScroll finds off-screen elements automatically — no manual swipe loops.\n"
                + "Free: scroll manually, then find_element without scroll.\n\n"
                + "Level up here → \(LicenseManager.upgradeURL)\n"
                + "Then: silbercueswift activate <YOUR-KEY>")
        }

        do {
            let start = CFAbsoluteTimeGetCurrent()
            let binding = try await UIActions.find(
                using: using, value: value, scroll: scroll,
                direction: direction, maxSwipes: maxSwipes
            )
            let rectStr: String
            if let rect = binding.rect {
                rectStr = " — frame: \(rect.description), center: (\(rect.centerX), \(rect.centerY))"
            } else {
                rectStr = ""
            }
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            var msg = "Element found: \(binding.elementId) (\(elapsed)ms)\(rectStr)"
            if binding.swipes > 0 {
                msg += " — scrolled \(binding.swipes) time(s) \(direction)"
            }
            return .ok(msg)
        } catch {
            return .fail("Element not found: \(error)")
        }
    }

    static func findElements(_ args: [String: Value]?) async -> CallTool.Result {
        guard let using = args?["using"]?.stringValue,
              let value = args?["value"]?.stringValue else {
            return .fail("Missing required: using, value")
        }
        do {
            let start = CFAbsoluteTimeGetCurrent()
            let elements = try await WDAClient.shared.findElements(using: using, value: value)
            // Fetch rects in parallel (best-effort)
            let rects = await withTaskGroup(of: (Int, WDAClient.ElementRect?).self) { group in
                for (i, eid) in elements.enumerated() {
                    group.addTask {
                        (i, try? await WDAClient.shared.getElementRect(elementId: eid))
                    }
                }
                var result = [Int: WDAClient.ElementRect?]()
                for await (i, rect) in group { result[i] = rect }
                return result
            }
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            let lines = elements.enumerated().map { i, eid in
                if let rect = rects[i] ?? nil {
                    return "  [\(i)] \(eid) — frame: \(rect.description), center: (\(rect.centerX), \(rect.centerY))"
                }
                return "  [\(i)] \(eid)"
            }
            return .ok("Found \(elements.count) elements (\(elapsed)ms):\n" + lines.joined(separator: "\n"))
        } catch {
            return .fail("Find elements failed: \(error)")
        }
    }

    static func clickElement(_ args: [String: Value]?) async -> CallTool.Result {
        guard let elementId = args?["element_id"]?.stringValue else {
            return .fail("Missing required: element_id")
        }
        do {
            let start = CFAbsoluteTimeGetCurrent()
            try await UIActions.click(elementId: elementId)
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            return await .okWithScreenshot("Clicked element \(elementId) (\(elapsed)ms)", screenshot: args?["screenshot"]?.boolValue ?? false)
        } catch {
            return .fail("Click failed: \(error)")
        }
    }

    static func tapCoordinates(_ args: [String: Value]?) async -> CallTool.Result {
        guard let x = args?["x"]?.numberValue,
              let y = args?["y"]?.numberValue else {
            return .fail("Missing required: x, y")
        }
        do {
            let start = CFAbsoluteTimeGetCurrent()
            try await UIActions.tap(x: x, y: y)
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            return await .okWithScreenshot("Tapped at (\(Int(x)), \(Int(y))) (\(elapsed)ms)", screenshot: args?["screenshot"]?.boolValue ?? false)
        } catch {
            return .fail("Tap failed: \(error)")
        }
    }

    static func typeText(_ args: [String: Value]?) async -> CallTool.Result {
        guard let text = args?["text"]?.stringValue else {
            return .fail("Missing required: text")
        }
        let elementId = args?["element_id"]?.stringValue
        let clearFirst = args?["clear_first"]?.boolValue ?? false

        do {
            try await UIActions.typeText(text, elementId: elementId, clearFirst: clearFirst)
            return await .okWithScreenshot("Typed '\(text)'", screenshot: args?["screenshot"]?.boolValue ?? false)
        } catch {
            return .fail("Type failed: \(error)")
        }
    }

    static func getText(_ args: [String: Value]?) async -> CallTool.Result {
        guard let elementId = args?["element_id"]?.stringValue else {
            return .fail("Missing required: element_id")
        }
        do {
            let text = try await UIActions.getText(elementId: elementId)
            return .ok("Text: \(text)")
        } catch {
            return .fail("Get text failed: \(error)")
        }
    }

    static func navigate(_ args: [String: Value]?) async -> CallTool.Result {
        guard let target = args?["target"]?.stringValue else {
            return .fail("Missing required: target")
        }
        let back = args?["back"]?.boolValue ?? false
        let scroll = args?["scroll"]?.boolValue ?? false
        let settleMs = args?["settle_ms"]?.intValue ?? 300

        // Pro gate: scroll requires Pro (same as find_element)
        if scroll, !(await LicenseManager.shared.isPro) {
            return .fail(
                "navigate with scroll requires [PRO].\n"
                + "Free: navigate without scroll.\n\n"
                + "Level up → \(LicenseManager.upgradeURL)")
        }

        let start = CFAbsoluteTimeGetCurrent()

        do {
            let result = try await UIActions.navigate(
                target: target, back: back, scroll: scroll, settleMs: settleMs
            )

            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            var scrollNote = ""
            if result.swipes > 0 { scrollNote = ", scrolled \(result.swipes)x" }
            let stepsStr = result.steps.isEmpty ? "" : result.steps.joined(separator: " → ") + " → "
            let text = "Navigated to '\(target)' (\(result.elementId), \(elapsed)ms\(scrollNote)). [\(stepsStr)tap → settle \(settleMs)ms]"

            var content: [Tool.Content] = [.text(text: text, annotations: nil, _meta: nil)]
            if let img = result.screenshot {
                content.append(img)
            }
            return .init(content: content)
        } catch {
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            let errStr = "\(error)"
            let cleanErr = errStr.contains("not found")
                ? "Element '\(target)' not found on current screen"
                : errStr
            if back {
                return .fail("Navigate failed after [back] (\(elapsed)ms): \(cleanErr)")
            }
            return .fail("Navigate failed (\(elapsed)ms): \(cleanErr)")
        }
    }

    static func getSource(_ args: [String: Value]?) async -> CallTool.Result {
        let format = args?["format"]?.stringValue ?? "json"
        do {
            let start = CFAbsoluteTimeGetCurrent()

            if format == "pruned" {
                let elements = try await UIActions.getSourcePruned()
                let elementCount = elements.count
                let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)
                // Cache screen info
                Task { guard let udid = await SimStateCache.currentUDID() else { return }
                    await SimStateCache.shared.recordScreenInfo(udid: udid, elementCount: max(elementCount, 1), summary: format) }
                // One element per line for LLM readability
                let lines = elements.compactMap { elem -> String? in
                    guard let d = try? JSONSerialization.data(withJSONObject: elem, options: [.sortedKeys]),
                          let line = String(data: d, encoding: .utf8) else { return nil }
                    return "  " + line
                }
                let output = "[\n" + lines.joined(separator: ",\n") + "\n]"
                return .ok("Pruned hierarchy (\(elapsed)s, \(elements.count) elements, \(output.count) chars):\n\(output)")
            }

            // Full mode: existing behavior
            let source = try await WDAClient.shared.getSource(format: format)
            let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)
            let elementCount = source.components(separatedBy: "\"type\"").count - 1
            Task { guard let udid = await SimStateCache.currentUDID() else { return }
                await SimStateCache.shared.recordScreenInfo(udid: udid, elementCount: max(elementCount, 1), summary: format) }
            let truncated = source.count > 50000 ? String(source.prefix(50000)) + "\n... [truncated]" : source
            return .ok("View hierarchy (\(elapsed)s, \(source.count) chars):\n\(truncated)")
        } catch {
            return .fail("Get source failed: \(error)")
        }
    }

}

