import Foundation
import MCP

/// Reusable, typed UI automation primitives.
/// Called by UITools (MCP handlers) and PlanExecutor (Pro batch execution).
/// Returns Swift types instead of MCP CallTool.Result strings.
///
/// All WDA calls route through WDAClientManager (per-UDID) via SessionState.
public enum UIActions {

    // MARK: - Types

    public struct ElementBinding: Sendable {
        public let elementId: String
        public let rect: WDAClient.ElementRect?
        public let swipes: Int
        public let label: String?

        public var centerX: Int? { rect?.centerX }
        public var centerY: Int? { rect?.centerY }

        public init(elementId: String, rect: WDAClient.ElementRect?, swipes: Int, label: String?) {
            self.elementId = elementId
            self.rect = rect
            self.swipes = swipes
            self.label = label
        }
    }

    public struct NavigateResult: Sendable {
        public let elementId: String
        public let swipes: Int
        public let screenshot: Tool.Content?
        public let steps: [String]
    }

    // MARK: - WDA Resolution

    /// Get the WDAClient for the session's current simulator.
    private static func wda() async throws -> WDAClient {
        try await SessionState.shared.wdaClient()
    }

    /// Get the UDID of the session's current simulator.
    private static func currentUDID() async throws -> String {
        try await SessionState.shared.resolveSimulator(nil)
    }

    // MARK: - Find

    /// Find a UI element and return its binding (id + rect + label).
    /// Pro cached path: AXP + tree cache (~0-5ms) when scroll=false + Pro hook set.
    /// Free AXP path: AXP direct bulk walk (~30ms) when scroll=false + AXP available.
    /// WDA fallback: HTTP (enriched → ~55ms, legacy → ~92ms).
    public static func find(
        using: String,
        value: String,
        scroll: Bool = false,
        direction: String = "auto",
        maxSwipes: Int = 10
    ) async throws -> ElementBinding {
        // Pro cached path: handler set by Pro → cached tree, 0-5ms
        if !scroll, let handler = ProHooks.findElementHandler {
            let udid = try await currentUDID()
            if let result = await handler(using, value, udid) {
                return result
            }
            // Pro hook returned nil (unsupported strategy or error) → fall through
        }

        // AXP direct path: Free tier, scroll=false, ~30ms
        if !scroll, AXPBridge.isAvailable {
            let udid = try await currentUDID()
            do {
                let result: AXPFindResult = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInteractive).async {
                        do {
                            let bridge = try AXPBridgeManager.bridge(for: udid)
                            let r = try bridge.findElement(using: using, value: value)
                            cont.resume(returning: r)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                let rect = WDAClient.ElementRect(
                    x: result.x, y: result.y, width: result.width, height: result.height
                )
                return ElementBinding(
                    elementId: result.syntheticId, rect: rect, swipes: 0, label: result.label
                )
            } catch {
                Log.warn("AXP find failed, falling back to WDA: \(error.localizedDescription)")
                // Fall through to WDA
            }
        }

        // WDA path (scroll=true, AXP unavailable, or AXP fallback)
        let client = try await wda()
        let (elementId, swipes, enrichedRect, enrichedLabel) = try await client.findElement(
            using: using, value: value, scroll: scroll,
            direction: direction, maxSwipes: maxSwipes
        )
        let rect: WDAClient.ElementRect?
        if let r = enrichedRect {
            rect = r
        } else {
            rect = try? await client.getElementRect(elementId: elementId)
        }
        let label: String?
        if let l = enrichedLabel {
            label = l
        } else {
            label = try? await client.getElementAttribute("label", elementId: elementId)
        }
        return ElementBinding(elementId: elementId, rect: rect, swipes: swipes, label: label)
    }

    // MARK: - Click / Tap

    /// Click a UI element by its ID.
    /// AXP-cached elements ("axp-" prefix): tap at cached center via IndigoHID (~32ms).
    /// WDA elements: fetch rect + IndigoHID tap (~72ms), or WDA click fallback (~293ms).
    public static func click(elementId: String) async throws {
        // AXP cache path: "axp-" prefix → cached coordinates → IndigoHID tap
        if elementId.hasPrefix("axp-") {
            if let handler = ProHooks.clickElementHandler, await handler(elementId) {
                return
            }
            // Free path: check AXPElementCache directly
            if let cached = AXPElementCache.lookup(elementId) {
                try await tap(x: Double(cached.centerX), y: Double(cached.centerY))
                return
            }
            throw UIActionError.axpElementExpired(elementId)
        }

        // WDA path (non-axp elements only)
        let udid = try await currentUDID()
        let client = await SessionState.shared.wdaClient(for: udid)
        if let native = await SessionState.shared.nativeInput(for: udid),
           let rect = try? await client.getElementRect(elementId: elementId) {
            do {
                try await native.tap(x: Double(rect.centerX), y: Double(rect.centerY))
                return
            } catch {
                await SessionState.shared.invalidateNativeInput(for: udid)
            }
        }
        try await client.click(elementId: elementId)
    }

    /// Tap at specific x,y coordinates.
    /// IndigoHID: ~32ms. WDA fallback: ~547ms.
    /// Falls back to WDA on HID failure (e.g. stale Mach port after app reinstall).
    public static func tap(x: Double, y: Double) async throws {
        let udid = try await currentUDID()
        if let native = await SessionState.shared.nativeInput(for: udid) {
            do {
                try await native.tap(x: x, y: y)
                return
            } catch {
                await SessionState.shared.invalidateNativeInput(for: udid)
            }
        }
        let client = await SessionState.shared.wdaClient(for: udid)
        try await client.tap(x: x, y: y)
    }

    /// Swipe from A to B.
    /// IndigoHID: ~330ms. WDA fallback: ~1152ms.
    /// Falls back to WDA on HID failure (e.g. stale Mach port after app reinstall).
    public static func swipe(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        durationMs: Int = 300
    ) async throws {
        let udid = try await currentUDID()
        if let native = await SessionState.shared.nativeInput(for: udid) {
            do {
                try await native.swipe(
                    fromX: fromX, fromY: fromY,
                    toX: toX, toY: toY,
                    durationMs: durationMs
                )
                return
            } catch {
                await SessionState.shared.invalidateNativeInput(for: udid)
            }
        }
        let client = await SessionState.shared.wdaClient(for: udid)
        try await client.swipe(
            startX: fromX, startY: fromY,
            endX: toX, endY: toY,
            durationMs: durationMs
        )
    }

    // MARK: - Double Tap

    /// Double-tap at specific x,y coordinates.
    /// IndigoHID first, WDA fallback.
    public static func doubleTap(x: Double, y: Double) async throws {
        let udid = try await currentUDID()
        if let native = await SessionState.shared.nativeInput(for: udid) {
            do {
                try await native.doubleTap(x: x, y: y)
                return
            } catch {
                await SessionState.shared.invalidateNativeInput(for: udid)
            }
        }
        let client = await SessionState.shared.wdaClient(for: udid)
        try await client.doubleTap(x: x, y: y)
    }

    // MARK: - Long Press

    /// Long-press at specific x,y coordinates.
    /// IndigoHID first, WDA fallback.
    public static func longPress(x: Double, y: Double, durationMs: Int = 1000) async throws {
        let udid = try await currentUDID()
        if let native = await SessionState.shared.nativeInput(for: udid) {
            do {
                try await native.longPress(x: x, y: y, durationMs: durationMs)
                return
            } catch {
                await SessionState.shared.invalidateNativeInput(for: udid)
            }
        }
        let client = await SessionState.shared.wdaClient(for: udid)
        try await client.longPress(x: x, y: y, durationMs: durationMs)
    }

    // MARK: - Drag and Drop

    /// Drag from source to target.
    /// IndigoHID first, WDA fallback.
    public static func dragAndDrop(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        pressDurationMs: Int = 1000,
        moveDurationMs: Int = 300
    ) async throws {
        let udid = try await currentUDID()
        if let native = await SessionState.shared.nativeInput(for: udid) {
            do {
                try await native.dragAndDrop(
                    fromX: fromX, fromY: fromY,
                    toX: toX, toY: toY,
                    pressDurationMs: pressDurationMs,
                    moveDurationMs: moveDurationMs
                )
                return
            } catch {
                await SessionState.shared.invalidateNativeInput(for: udid)
            }
        }
        let client = await SessionState.shared.wdaClient(for: udid)
        try await client.dragAndDrop(
            sourceElement: nil, targetElement: nil,
            fromX: fromX, fromY: fromY,
            toX: toX, toY: toY,
            pressDurationMs: pressDurationMs, holdDurationMs: 300
        )
    }

    // MARK: - Text

    /// Type text into an element. Auto-finds first text input if elementId is nil.
    public static func typeText(
        _ text: String,
        elementId: String? = nil,
        clearFirst: Bool = false
    ) async throws {
        let client = try await wda()
        if let eid = elementId {
            if clearFirst {
                try await client.clearElement(elementId: eid)
            }
            try await client.setValue(elementId: eid, text: text)
        } else {
            _ = try await client.ensureSession()
            let textInputTypes = [
                "XCUIElementTypeTextField",
                "XCUIElementTypeTextView",
                "XCUIElementTypeSearchField",
            ]
            var foundId: String?
            for typeName in textInputTypes {
                if let (eid, _, _, _) = try? await client.findElement(
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
                try await client.clearElement(elementId: eid)
            }
            try await client.setValue(elementId: eid, text: text)
        }
    }

    /// Get text content of a UI element.
    /// AXP-cached elements ("axp-" prefix): returns cached label/value (~0ms).
    /// WDA elements: HTTP request (~30ms).
    public static func getText(elementId: String) async throws -> String {
        // AXP cache path: "axp-" prefix → cached label/value
        if elementId.hasPrefix("axp-") {
            if let handler = ProHooks.getTextHandler,
               let text = await handler(elementId) {
                return text
            }
            // Free path: check AXPElementCache directly
            if let cached = AXPElementCache.lookup(elementId) {
                return cached.label ?? cached.value ?? ""
            }
            throw UIActionError.axpElementExpired(elementId)
        }

        // WDA path (non-axp elements only)
        let client = try await wda()
        return try await client.getText(elementId: elementId)
    }

    // MARK: - Navigate

    /// Navigate: find target, tap, wait, screenshot. Optionally go back first.
    /// Uses UIActions.find() for AXP-accelerated element lookup (0ms Pro / 30ms Free).
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
            try await tap(x: Double(center.x), y: Double(center.y))
            try await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)
            steps.append("back")
        }

        // Step 2: Find target (via AXP → WDA fallback)
        let escapedTarget = target.replacingOccurrences(of: "'", with: "\\'")
        let binding = try await find(
            using: "predicate string",
            value: "label == '\(escapedTarget)' OR identifier == '\(escapedTarget)'",
            scroll: scroll, direction: "auto", maxSwipes: scroll ? 10 : 0
        )

        // Step 3: Click
        try await click(elementId: binding.elementId)

        // Step 4: Settle
        try await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)

        // Step 5: Screenshot
        let screenshot = await ActionScreenshot.capture()

        return NavigateResult(
            elementId: binding.elementId,
            swipes: binding.swipes,
            screenshot: screenshot,
            steps: steps
        )
    }

    // MARK: - Source Tree

    /// Get pruned view hierarchy — flat array of interactive/labeled elements with frames.
    /// Pro cached path: AXP + tree cache (~0-5ms) when Pro hook set.
    /// Free AXP path: AXP direct bulk walk (~30ms) when AXP available.
    /// WDA fallback: HTTP (~1100ms).
    public static func getSourcePruned() async throws -> [[String: Any]] {
        // Pro cached path: handler set by Pro → cached tree, 0-5ms
        if let handler = ProHooks.getSourceHandler {
            let udid = try await currentUDID()
            if let result = await handler(udid) {
                return result
            }
            // Pro hook returned nil → fall through
        }

        // AXP direct path: Free tier, ~30ms
        if AXPBridge.isAvailable {
            do {
                let udid = try await currentUDID()
                let elements: [[String: Any]] = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInteractive).async {
                        do {
                            let bridge = try AXPBridgeManager.bridge(for: udid)
                            let result = try bridge.fetchTreePruned()
                            cont.resume(returning: result)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                return elements
            } catch {
                Log.warn("AXP get_source failed, falling back to WDA: \(error.localizedDescription)")
                // Fall through to WDA
            }
        }

        // WDA fallback (~1100ms)
        let client = try await wda()
        let source = try await client.getSource(format: "json")
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

    /// Find back button center via AXP (flat tree, ~30ms) or WDA fallback (~1100ms).
    /// Looks for first Button inside NavigationBar frame in AXP flat element list.
    public static func findBackButtonCenter() async -> (x: Int, y: Int)? {
        // AXP path: flat tree → find NavigationBar → first Button within its frame
        if AXPBridge.isAvailable {
            do {
                let udid = try await currentUDID()
                let result: (x: Int, y: Int)? = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInteractive).async {
                        do {
                            let bridge = try AXPBridgeManager.bridge(for: udid)
                            let (elements, rootFrame) = try bridge.fetchTree()

                            // Find NavigationBar frame
                            var navBarFrame: CGRect?
                            for elem in elements {
                                let role = elem.role ?? ""
                                if role == "AXNavigationBar" || role == "AXHeader" {
                                    navBarFrame = bridge.transformFrame(elem.frame, rootFrame: rootFrame)
                                    break
                                }
                            }

                            guard let navFrame = navBarFrame else {
                                cont.resume(returning: nil)
                                return
                            }

                            // Find first Button within NavigationBar frame
                            for elem in elements {
                                let role = elem.role ?? ""
                                guard role == "AXButton" else { continue }
                                let btnFrame = bridge.transformFrame(elem.frame, rootFrame: rootFrame)
                                // Button must be within NavigationBar bounds
                                if btnFrame.midY >= navFrame.minY && btnFrame.midY <= navFrame.maxY
                                    && btnFrame.midX >= navFrame.minX && btnFrame.midX <= navFrame.maxX {
                                    let cx = Int(btnFrame.midX.rounded())
                                    let cy = Int(btnFrame.midY.rounded())
                                    cont.resume(returning: (x: cx, y: cy))
                                    return
                                }
                            }

                            cont.resume(returning: nil)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                if let r = result { return r }
                // AXP found no back button → fall through to WDA
            } catch {
                Log.warn("AXP findBackButton failed, falling back to WDA: \(error.localizedDescription)")
            }
        }

        // WDA fallback
        guard let client = try? await wda(),
              let source = try? await client.getSource(format: "json"),
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
        case axpElementExpired(String)

        public var description: String {
            switch self {
            case .noTextInput:
                return "No text input found on screen (searched TextField, TextView, SearchField). Tap a text field first, or pass element_id."
            case .noBackButton:
                return "No back button found in NavigationBar"
            case .sourceParseError:
                return "Failed to parse JSON source"
            case .axpElementExpired(let id):
                return "Element \(String(id.prefix(12)))… expired from cache. Run find_element again to get a fresh reference."
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

        if type == "Button", let rect = (node["frame"] ?? node["rect"]) as? [String: Any] {
            func intVal(_ key: String) -> Int? {
                if let v = rect[key] as? Int { return v }
                if let v = rect[key] as? Double { return Int(v) }
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
