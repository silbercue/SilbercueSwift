import Foundation
import MCP

/// Reusable, typed UI automation primitives.
/// Called by UITools (MCP handlers) and PlanExecutor (Pro batch execution).
/// Returns Swift types instead of MCP CallTool.Result strings.
public enum UIActions {

    // MARK: - Types

    public struct ElementBinding: Sendable {
        public let elementId: String
        public let rect: WDAClient.ElementRect?
        public let swipes: Int
        public let label: String?

        public var centerX: Int? { rect?.centerX }
        public var centerY: Int? { rect?.centerY }
    }

    public struct NavigateResult: Sendable {
        public let elementId: String
        public let swipes: Int
        public let screenshot: Tool.Content?
        public let steps: [String]
    }

    // MARK: - Find

    /// Find a UI element and return its binding (id + rect + label).
    public static func find(
        using: String,
        value: String,
        scroll: Bool = false,
        direction: String = "auto",
        maxSwipes: Int = 10
    ) async throws -> ElementBinding {
        let (elementId, swipes) = try await WDAClient.shared.findElement(
            using: using, value: value, scroll: scroll,
            direction: direction, maxSwipes: maxSwipes
        )
        let rect = try? await WDAClient.shared.getElementRect(elementId: elementId)
        // Try to get label (best-effort)
        let label = try? await WDAClient.shared.getElementAttribute("label", elementId: elementId)
        return ElementBinding(elementId: elementId, rect: rect, swipes: swipes, label: label)
    }

    // MARK: - Click / Tap

    /// Click a UI element by its ID.
    public static func click(elementId: String) async throws {
        try await WDAClient.shared.click(elementId: elementId)
    }

    /// Tap at specific x,y coordinates.
    public static func tap(x: Double, y: Double) async throws {
        try await WDAClient.shared.tap(x: x, y: y)
    }

    // MARK: - Text

    /// Type text into an element. Auto-finds first text input if elementId is nil.
    public static func typeText(
        _ text: String,
        elementId: String? = nil,
        clearFirst: Bool = false
    ) async throws {
        if let eid = elementId {
            if clearFirst {
                try await WDAClient.shared.clearElement(elementId: eid)
            }
            try await WDAClient.shared.setValue(elementId: eid, text: text)
        } else {
            _ = try await WDAClient.shared.ensureSession()
            let textInputTypes = [
                "XCUIElementTypeTextField",
                "XCUIElementTypeTextView",
                "XCUIElementTypeSearchField",
            ]
            var foundId: String?
            for typeName in textInputTypes {
                if let (eid, _) = try? await WDAClient.shared.findElement(
                    using: "class name", value: typeName
                ) {
                    foundId = eid
                    break
                }
            }
            guard let eid = foundId else {
                throw UIActionError.noTextInput
            }
            if clearFirst {
                try await WDAClient.shared.clearElement(elementId: eid)
            }
            try await WDAClient.shared.setValue(elementId: eid, text: text)
        }
    }

    /// Get text content of a UI element.
    public static func getText(elementId: String) async throws -> String {
        try await WDAClient.shared.getText(elementId: elementId)
    }

    // MARK: - Navigate

    /// Navigate: find target, tap, wait, screenshot. Optionally go back first.
    public static func navigate(
        target: String,
        back: Bool = false,
        scroll: Bool = false,
        settleMs: Int = 300
    ) async throws -> NavigateResult {
        var steps: [String] = []

        // Step 1: Back navigation
        if back {
            guard let center = await findBackButtonCenter() else {
                throw UIActionError.noBackButton
            }
            try await WDAClient.shared.tap(x: Double(center.x), y: Double(center.y))
            try await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)
            steps.append("back")
        }

        // Step 2: Find target
        let escapedTarget = target.replacingOccurrences(of: "'", with: "\\'")
        let (elementId, swipes) = try await WDAClient.shared.findElement(
            using: "predicate string",
            value: "identifier == '\(escapedTarget)' OR label == '\(escapedTarget)'",
            scroll: scroll, direction: "auto", maxSwipes: scroll ? 10 : 0
        )

        // Step 3: Click
        try await WDAClient.shared.click(elementId: elementId)

        // Step 4: Settle
        try await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)

        // Step 5: Screenshot
        let screenshot = await ActionScreenshot.capture()

        return NavigateResult(
            elementId: elementId,
            swipes: swipes,
            screenshot: screenshot,
            steps: steps
        )
    }

    // MARK: - Source Tree

    /// Get pruned view hierarchy — flat array of interactive/labeled elements with frames.
    public static func getSourcePruned() async throws -> [[String: Any]] {
        let source = try await WDAClient.shared.getSource(format: "json")
        guard let data = source.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UIActionError.sourceParseError
        }
        // WDA wraps the tree as a JSON string inside "value"
        let tree: [String: Any]
        if let valueStr = json["value"] as? String,
           let valueData = valueStr.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: valueData) as? [String: Any] {
            tree = parsed
        } else if let valueDict = json["value"] as? [String: Any] {
            tree = valueDict
        } else {
            tree = json
        }
        var elements: [[String: Any]] = []
        pruneTree(tree, into: &elements)
        elements = deduplicateLabels(elements)
        elements.sort {
            let y0 = ($0["frame"] as? [String: Any])?["y"] as? Int ?? 0
            let y1 = ($1["frame"] as? [String: Any])?["y"] as? Int ?? 0
            return y0 < y1
        }
        return elements
    }

    /// Parse WDA source JSON into the tree root.
    public static func parseSourceTree(_ source: String) throws -> [String: Any] {
        guard let data = source.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UIActionError.sourceParseError
        }
        if let valueStr = json["value"] as? String,
           let valueData = valueStr.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: valueData) as? [String: Any] {
            return parsed
        } else if let valueDict = json["value"] as? [String: Any] {
            return valueDict
        }
        return json
    }

    // MARK: - Back Button

    /// Find back button center by walking WDA source tree.
    /// Uses get_source (0.1s) instead of findElement (avoids 6-18s WDA implicit wait).
    public static func findBackButtonCenter() async -> (x: Int, y: Int)? {
        guard let source = try? await WDAClient.shared.getSource(format: "json"),
              let data = source.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let tree: [String: Any]
        if let vs = json["value"] as? String,
           let vd = vs.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: vd) as? [String: Any] {
            tree = parsed
        } else {
            tree = json["value"] as? [String: Any] ?? json
        }
        return findFirstButtonInNavBar(tree)
    }

    // MARK: - Errors

    public enum UIActionError: Error, CustomStringConvertible {
        case noTextInput
        case noBackButton
        case sourceParseError

        public var description: String {
            switch self {
            case .noTextInput:
                return "No text input found on screen (searched TextField, TextView, SearchField). Tap a text field first, or pass element_id."
            case .noBackButton:
                return "No back button found in NavigationBar"
            case .sourceParseError:
                return "Failed to parse JSON source"
            }
        }
    }

    // MARK: - Private Helpers (Tree Walking)

    private static func findFirstButtonInNavBar(_ node: [String: Any]) -> (x: Int, y: Int)? {
        let rawType = node["type"] as? String ?? ""
        let type = rawType.hasPrefix("XCUIElementType") ? String(rawType.dropFirst("XCUIElementType".count)) : rawType

        if type == "NavigationBar" {
            if let btn = findFirstButton(in: node) {
                return btn
            }
        }
        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                if let result = findFirstButtonInNavBar(child) {
                    return result
                }
            }
        }
        return nil
    }

    private static func findFirstButton(in node: [String: Any]) -> (x: Int, y: Int)? {
        let rawType = node["type"] as? String ?? ""
        let type = rawType.hasPrefix("XCUIElementType") ? String(rawType.dropFirst("XCUIElementType".count)) : rawType

        if type == "Button", let frame = node["frame"] as? [String: Any] {
            func intVal(_ key: String) -> Int? {
                if let v = frame[key] as? Int { return v }
                if let v = frame[key] as? Double { return Int(v) }
                return nil
            }
            if let x = intVal("x"), let y = intVal("y"), let w = intVal("width"), let h = intVal("height") {
                return (x: x + w / 2, y: y + h / 2)
            }
        }
        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                if let result = findFirstButton(in: child) {
                    return result
                }
            }
        }
        return nil
    }

    // MARK: - Private Helpers (Pruned Source)

    private static let interactableTypes: Set<String> = [
        "Button", "TextField", "SecureTextField", "TextView", "StaticText",
        "Switch", "Slider", "Cell", "NavigationBar", "Alert", "Sheet",
        "SearchField", "Picker", "TabBar", "Link",
    ]

    static func pruneTree(_ node: [String: Any], into result: inout [[String: Any]]) {
        let rawType = node["type"] as? String ?? ""
        let type = rawType.hasPrefix("XCUIElementType")
            ? String(rawType.dropFirst("XCUIElementType".count))
            : rawType

        let label = (node["label"] as? String) ?? ""
        let identifier = (node["identifier"] as? String) ?? ""
        let rawValue = node["value"]
        let valueStr: String? = {
            if rawValue is NSNull || rawValue == nil { return nil }
            if let s = rawValue as? String, !s.isEmpty { return s }
            if let n = rawValue as? NSNumber { return n.stringValue }
            return nil
        }()

        let isInteractable = interactableTypes.contains(type)
        let hasInfo = !label.isEmpty || !identifier.isEmpty || valueStr != nil

        let isTopLevelContainer = type == "Application" || type == "Window"
        let isDecorativeImage = type == "Image" && label.isEmpty
            && (identifier == "chevron.forward" || identifier == "chevron.right"
                || identifier == "chevron.backward" || identifier == "checkmark"
                || identifier.isEmpty)

        if (isInteractable || hasInfo) && !isDecorativeImage && !isTopLevelContainer {
            var element: [String: Any] = ["type": type]
            if !label.isEmpty { element["label"] = label }
            if !identifier.isEmpty { element["id"] = identifier }
            if let v = valueStr { element["value"] = v }
            if let frame = node["frame"] as? [String: Any] {
                var f: [String: Int] = [:]
                func intVal(_ key: String) -> Int? {
                    if let v = frame[key] as? Int { return v }
                    if let v = frame[key] as? Double { return Int(v) }
                    return nil
                }
                if let x = intVal("x") { f["x"] = x }
                if let y = intVal("y") { f["y"] = y }
                if let w = intVal("width") { f["w"] = w }
                if let h = intVal("height") { f["h"] = h }
                if !f.isEmpty { element["frame"] = f }
            }
            result.append(element)
        }

        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                pruneTree(child, into: &result)
            }
        }
    }

    static func deduplicateLabels(_ elements: [[String: Any]]) -> [[String: Any]] {
        struct Rect { let x, y, w, h: Int }
        var parentRects: [String: [Rect]] = [:]
        var buttonFrameKeys = Set<String>()
        for elem in elements {
            let type = elem["type"] as? String ?? ""
            if let label = elem["label"] as? String, !label.isEmpty,
               type == "Button" || type == "Cell" || type == "NavigationBar",
               let f = elem["frame"] as? [String: Int],
               let x = f["x"], let y = f["y"], let w = f["w"], let h = f["h"] {
                parentRects[label, default: []].append(Rect(x: x, y: y, w: w, h: h))
            }
            if type == "Button", let f = elem["frame"] as? [String: Int] {
                buttonFrameKeys.insert("\(f["x"] ?? 0),\(f["y"] ?? 0),\(f["w"] ?? 0),\(f["h"] ?? 0)")
            }
        }
        var seenKeys = Set<String>()
        return elements.filter { elem in
            let type = elem["type"] as? String ?? ""
            let label = elem["label"] as? String ?? ""
            if type == "StaticText" && !label.isEmpty,
               let rects = parentRects[label],
               let f = elem["frame"] as? [String: Int],
               let sx = f["x"], let sy = f["y"], let sw = f["w"], let sh = f["h"] {
                let contained = rects.contains { r in
                    sx >= r.x && sy >= r.y
                        && sx + sw <= r.x + r.w && sy + sh <= r.y + r.h
                }
                if contained { return false }
            }
            if type == "Cell" && label.isEmpty {
                if let f = elem["frame"] as? [String: Int] {
                    let key = "\(f["x"] ?? 0),\(f["y"] ?? 0),\(f["w"] ?? 0),\(f["h"] ?? 0)"
                    if buttonFrameKeys.contains(key) { return false }
                }
            }
            let value = elem["value"] as? String ?? ""
            if !label.isEmpty && !value.isEmpty {
                let key = "\(type):\(label):\(value)"
                if seenKeys.contains(key) { return false }
                seenKeys.insert(key)
            }
            return true
        }
    }
}
