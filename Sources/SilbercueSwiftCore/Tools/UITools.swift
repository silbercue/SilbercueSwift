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
            description: "Click/tap a UI element by its ID.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "element_id": .object(["type": .string("string"), "description": .string("Element ID from find_element")]),
                ]),
                "required": .array([.string("element_id")]),
            ])
        ),
        Tool(
            name: "tap_coordinates",
            description: "Tap at specific x,y coordinates on screen.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                ]),
                "required": .array([.string("x"), .string("y")]),
            ])
        ),
        Tool(
            name: "double_tap",
            description: "Double-tap at specific coordinates.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                ]),
                "required": .array([.string("x"), .string("y")]),
            ])
        ),
        Tool(
            name: "long_press",
            description: "Long-press at specific coordinates.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                    "duration_ms": .object(["type": .string("number"), "description": .string("Duration in milliseconds. Default: 1000")]),
                ]),
                "required": .array([.string("x"), .string("y")]),
            ])
        ),
        Tool(
            name: "swipe",
            description: "Swipe from one point to another.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "start_x": .object(["type": .string("number"), "description": .string("Start X")]),
                    "start_y": .object(["type": .string("number"), "description": .string("Start Y")]),
                    "end_x": .object(["type": .string("number"), "description": .string("End X")]),
                    "end_y": .object(["type": .string("number"), "description": .string("End Y")]),
                    "duration_ms": .object(["type": .string("number"), "description": .string("Swipe duration in ms. Default: 300")]),
                ]),
                "required": .array([.string("start_x"), .string("start_y"), .string("end_x"), .string("end_y")]),
            ])
        ),
        Tool(
            name: "pinch",
            description: "Pinch/zoom at a center point. scale > 1 = zoom in, scale < 1 = zoom out.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "center_x": .object(["type": .string("number"), "description": .string("Center X coordinate")]),
                    "center_y": .object(["type": .string("number"), "description": .string("Center Y coordinate")]),
                    "scale": .object(["type": .string("number"), "description": .string("Scale factor. >1 = zoom in, <1 = zoom out")]),
                    "duration_ms": .object(["type": .string("number"), "description": .string("Duration in ms. Default: 500")]),
                ]),
                "required": .array([.string("center_x"), .string("center_y"), .string("scale")]),
            ])
        ),
        Tool(
            name: "drag_and_drop",
            description: "Drag from source to target. Works with element IDs, coordinates, or mixed. Smart defaults activate drag mode automatically — works for reorderable lists, Kanban boards, sliders, canvas dragging.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "source_element": .object(["type": .string("string"), "description": .string("Source element ID from find_element")]),
                    "target_element": .object(["type": .string("string"), "description": .string("Target element ID from find_element")]),
                    "from_x": .object(["type": .string("number"), "description": .string("Source X coordinate (alternative to source_element)")]),
                    "from_y": .object(["type": .string("number"), "description": .string("Source Y coordinate")]),
                    "to_x": .object(["type": .string("number"), "description": .string("Target X coordinate (alternative to target_element)")]),
                    "to_y": .object(["type": .string("number"), "description": .string("Target Y coordinate")]),
                    "press_duration_ms": .object(["type": .string("number"), "description": .string("Long-press duration to activate drag mode (ms). Default: 1000")]),
                    "hold_duration_ms": .object(["type": .string("number"), "description": .string("Hold at target before drop (ms). Default: 300")]),
                ]),
            ])
        ),
        Tool(
            name: "type_text",
            description: "Type text into the currently focused element or a specified element.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string"), "description": .string("Text to type")]),
                    "element_id": .object(["type": .string("string"), "description": .string("Optional element ID to type into")]),
                    "clear_first": .object(["type": .string("boolean"), "description": .string("Clear existing text first. Default: false")]),
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
            description: "Get the full view hierarchy (source tree) of the current screen.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "format": .object(["type": .string("string"), "description": .string("Format: json, xml, or description. Default: json")]),
                ]),
            ])
        ),
    ]

    // MARK: - Implementations

    static func handleAlert(_ args: [String: Value]?) async -> CallTool.Result {
        guard let action = args?["action"]?.stringValue else {
            return .fail("Missing required: action ('accept', 'dismiss', 'get_text', 'accept_all', 'dismiss_all')")
        }
        let buttonLabel = args?["button_label"]?.stringValue

        switch action {
        case "get_text":
            guard let info = await WDAClient.shared.getAlertText() else {
                return .ok("No alert visible.")
            }
            return .ok("Alert text: \(info.text)\nButtons: \(info.buttons.joined(separator: ", "))")

        case "accept":
            do {
                let info = try await WDAClient.shared.acceptAlert(buttonLabel: buttonLabel)
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
                var msg = "Alert dismissed."
                if let info {
                    msg += "\nAlert was: \(info.text)\nButtons were: \(info.buttons.joined(separator: ", "))"
                }
                return .ok(msg)
            } catch {
                return .fail("Dismiss alert failed: \(error)")
            }

        case "accept_all":
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
        if let url = args?["wda_url"]?.stringValue {
            await WDAClient.shared.setBaseURL(url)
        }

        let bundleId = args?["bundle_id"]?.stringValue

        do {
            // Health-check with auto-restart before creating session
            try await WDAClient.shared.ensureWDARunning()

            let sid = try await WDAClient.shared.createSession(bundleId: bundleId)
            var msg = "Session created: \(sid)"

            // Warn if too many sessions are tracked
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
        do {
            let start = CFAbsoluteTimeGetCurrent()
            let (elementId, swipes) = try await WDAClient.shared.findElement(
                using: using, value: value, scroll: scroll, direction: direction, maxSwipes: maxSwipes
            )
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            var msg = "Element found: \(elementId) (\(elapsed)ms)"
            if swipes > 0 {
                msg += " — scrolled \(swipes) time(s) \(direction)"
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
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            return .ok("Found \(elements.count) elements (\(elapsed)ms):\n" + elements.enumerated().map { "  [\($0.offset)] \($0.element)" }.joined(separator: "\n"))
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
            try await WDAClient.shared.click(elementId: elementId)
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            return .ok("Clicked element \(elementId) (\(elapsed)ms)")
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
            try await WDAClient.shared.tap(x: x, y: y)
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            return .ok("Tapped at (\(Int(x)), \(Int(y))) (\(elapsed)ms)")
        } catch {
            return .fail("Tap failed: \(error)")
        }
    }

    static func doubleTap(_ args: [String: Value]?) async -> CallTool.Result {
        guard let x = args?["x"]?.numberValue,
              let y = args?["y"]?.numberValue else {
            return .fail("Missing required: x, y")
        }
        do {
            try await WDAClient.shared.doubleTap(x: x, y: y)
            return .ok("Double-tapped at (\(Int(x)), \(Int(y)))")
        } catch {
            return .fail("Double-tap failed: \(error)")
        }
    }

    static func longPress(_ args: [String: Value]?) async -> CallTool.Result {
        guard let x = args?["x"]?.numberValue,
              let y = args?["y"]?.numberValue else {
            return .fail("Missing required: x, y")
        }
        let durationMs = args?["duration_ms"]?.intValue ?? 1000
        do {
            try await WDAClient.shared.longPress(x: x, y: y, durationMs: durationMs)
            return .ok("Long-pressed at (\(Int(x)), \(Int(y))) for \(durationMs)ms")
        } catch {
            return .fail("Long-press failed: \(error)")
        }
    }

    static func swipeAction(_ args: [String: Value]?) async -> CallTool.Result {
        guard let sx = args?["start_x"]?.numberValue,
              let sy = args?["start_y"]?.numberValue,
              let ex = args?["end_x"]?.numberValue,
              let ey = args?["end_y"]?.numberValue else {
            return .fail("Missing required: start_x, start_y, end_x, end_y")
        }
        let durationMs = args?["duration_ms"]?.intValue ?? 300
        do {
            try await WDAClient.shared.swipe(startX: sx, startY: sy, endX: ex, endY: ey, durationMs: durationMs)
            return .ok("Swiped from (\(Int(sx)),\(Int(sy))) to (\(Int(ex)),\(Int(ey)))")
        } catch {
            return .fail("Swipe failed: \(error)")
        }
    }

    static func pinchAction(_ args: [String: Value]?) async -> CallTool.Result {
        guard let cx = args?["center_x"]?.numberValue,
              let cy = args?["center_y"]?.numberValue,
              let scale = args?["scale"]?.numberValue else {
            return .fail("Missing required: center_x, center_y, scale")
        }
        let durationMs = args?["duration_ms"]?.intValue ?? 500
        do {
            try await WDAClient.shared.pinch(centerX: cx, centerY: cy, scale: scale, durationMs: durationMs)
            return .ok("Pinch at (\(Int(cx)),\(Int(cy))) scale=\(scale)")
        } catch {
            return .fail("Pinch failed: \(error)")
        }
    }

    static func dragAndDrop(_ args: [String: Value]?) async -> CallTool.Result {
        let sourceElement = args?["source_element"]?.stringValue
        let targetElement = args?["target_element"]?.stringValue
        let fromX = args?["from_x"]?.numberValue
        let fromY = args?["from_y"]?.numberValue
        let toX = args?["to_x"]?.numberValue
        let toY = args?["to_y"]?.numberValue
        let pressDurationMs = args?["press_duration_ms"]?.intValue ?? 1000
        let holdDurationMs = args?["hold_duration_ms"]?.intValue ?? 300

        let hasSource = sourceElement != nil || (fromX != nil && fromY != nil)
        let hasTarget = targetElement != nil || (toX != nil && toY != nil)
        guard hasSource, hasTarget else {
            return .fail("Need source (source_element OR from_x+from_y) and target (target_element OR to_x+to_y)")
        }

        do {
            let start = CFAbsoluteTimeGetCurrent()
            try await WDAClient.shared.dragAndDrop(
                sourceElement: sourceElement, targetElement: targetElement,
                fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                pressDurationMs: pressDurationMs, holdDurationMs: holdDurationMs
            )
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            let srcDesc = sourceElement ?? "(\(Int(fromX!)),\(Int(fromY!)))"
            let tgtDesc = targetElement ?? "(\(Int(toX!)),\(Int(toY!)))"
            return .ok("Dragged \(srcDesc) → \(tgtDesc) (\(elapsed)ms)")
        } catch {
            return .fail("Drag failed: \(error)")
        }
    }

    static func typeText(_ args: [String: Value]?) async -> CallTool.Result {
        guard let text = args?["text"]?.stringValue else {
            return .fail("Missing required: text")
        }
        let elementId = args?["element_id"]?.stringValue
        let clearFirst = args?["clear_first"]?.boolValue ?? false

        do {
            if let eid = elementId {
                if clearFirst {
                    try await WDAClient.shared.clearElement(elementId: eid)
                }
                try await WDAClient.shared.setValue(elementId: eid, text: text)
            } else {
                // Find first text field and type into it
                _ = try await WDAClient.shared.ensureSession()
                let (eid, _) = try await WDAClient.shared.findElement(using: "class name", value: "XCUIElementTypeTextField")
                if clearFirst {
                    try await WDAClient.shared.clearElement(elementId: eid)
                }
                try await WDAClient.shared.setValue(elementId: eid, text: text)
            }
            return .ok("Typed '\(text)'")
        } catch {
            return .fail("Type failed: \(error)")
        }
    }

    static func getText(_ args: [String: Value]?) async -> CallTool.Result {
        guard let elementId = args?["element_id"]?.stringValue else {
            return .fail("Missing required: element_id")
        }
        do {
            let text = try await WDAClient.shared.getText(elementId: elementId)
            return .ok("Text: \(text)")
        } catch {
            return .fail("Get text failed: \(error)")
        }
    }

    static func getSource(_ args: [String: Value]?) async -> CallTool.Result {
        let format = args?["format"]?.stringValue ?? "json"
        do {
            let start = CFAbsoluteTimeGetCurrent()
            let source = try await WDAClient.shared.getSource(format: format)
            let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)
            // Truncate if too large
            let truncated = source.count > 50000 ? String(source.prefix(50000)) + "\n... [truncated]" : source
            return .ok("View hierarchy (\(elapsed)s, \(source.count) chars):\n\(truncated)")
        } catch {
            return .fail("Get source failed: \(error)")
        }
    }
}

// MARK: - Value helpers

extension Value {
    var numberValue: Double? {
        switch self {
        case .double(let n): return n
        case .int(let n): return Double(n)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var intValue: Int? {
        numberValue.map(Int.init)
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true" || s == "1"
        default: return nil
        }
    }
}
