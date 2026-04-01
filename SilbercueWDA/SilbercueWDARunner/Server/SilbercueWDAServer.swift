import FlyingFox
import Foundation
import XCTest

/// Lightweight async HTTP server wrapping XCUITest via FlyingFox.
/// Runs inside an XCTest bundle on the iOS Simulator.
/// @unchecked Sendable: Server is accessed from a single test thread,
/// FlyingFox handles concurrency internally via Swift Concurrency.
final class SilbercueWDAServer: @unchecked Sendable {
    static let shared = SilbercueWDAServer()

    private var httpServer: HTTPServer?
    @MainActor private let bridge = XCUIBridge()
    private let sessionManager = SessionManager()
    private let startTime = Date()
    private let version = "0.2.0"

    // Cached device info (set once at start, never changes during runtime)
    private var cachedIOSVersion = "unknown"
    private var cachedSimulatorName = "unknown"
    private var cachedDeviceModel = "unknown"

    // Health state (Story 4.1-4.3)
    private let healthLock = NSLock()
    private var _healthy = true
    private var _lastHeartbeat: Date?
    private var _consecutiveHeartbeatFailures = 0
    private var _activeCommandCount = 0
    private var _lastCommandStart: Date?
    private var heartbeatTimer: DispatchSourceTimer?
    private static let maxHeartbeatFailures = 3
    private static let stuckCommandTimeout: TimeInterval = 60

    private static let testedXcodeVersions = ["16.0", "16.1", "16.2", "16.3", "17.0", "17.1", "17.2", "17.3"]

    var isHealthy: Bool {
        healthLock.lock()
        defer { healthLock.unlock() }
        return _healthy
    }

    private init() {}

    func start(port: UInt16 = 8100) async throws {
        // Cache device info once — these never change during runtime.
        // Avoids @MainActor contention when /status is called under load.
        cachedIOSVersion = await UIDevice.current.systemVersion
        cachedSimulatorName = await UIDevice.current.name
        cachedDeviceModel = await UIDevice.current.model

        let server = HTTPServer(
            address: .loopback(port: port),
            timeout: 10,
            logger: .disabled,
            handler: Router(wda: self)
        )
        self.httpServer = server
        startHeartbeat()
        print("[SilbercueWDA] Server started on http://localhost:\(port)")
        try await server.run()
    }

    // MARK: - Active Command Tracking

    func beginCommand() {
        healthLock.lock()
        _activeCommandCount += 1
        if _lastCommandStart == nil {
            _lastCommandStart = Date()
        }
        healthLock.unlock()
    }

    func endCommand() {
        healthLock.lock()
        _activeCommandCount = max(0, _activeCommandCount - 1)
        if _activeCommandCount == 0 {
            _lastCommandStart = nil
        }
        healthLock.unlock()
    }

    // MARK: - Heartbeat (Story 4.1)

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.performHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func performHeartbeat() {
        // Check for stuck commands first (commands active for too long)
        healthLock.lock()
        let commandActive = _activeCommandCount > 0
        let commandStart = _lastCommandStart
        healthLock.unlock()

        if commandActive, let start = commandStart,
           Date().timeIntervalSince(start) > Self.stuckCommandTimeout {
            healthLock.lock()
            _healthy = false
            let count = _activeCommandCount
            let elapsed = Int(Date().timeIntervalSince(start))
            healthLock.unlock()
            print("[SilbercueWDA] UNHEALTHY: \(count) commands stuck for \(elapsed)s — MainActor likely deadlocked, triggering exit(1)")
            exit(1)
        }

        let semaphore = DispatchSemaphore(value: 0)

        Task { @MainActor in
            let _ = XCUIApplication(bundleIdentifier: "com.apple.springboard").state
            semaphore.signal()
        }

        let timeout = semaphore.wait(timeout: .now() + 10)
        if timeout == .timedOut {
            if commandActive {
                // MainActor is busy with our own command — not a real failure
                print("[SilbercueWDA] Heartbeat skipped (command active, MainActor busy)")
                return
            }
            healthLock.lock()
            _consecutiveHeartbeatFailures += 1
            let failures = _consecutiveHeartbeatFailures
            if failures >= Self.maxHeartbeatFailures {
                _healthy = false
                healthLock.unlock()
                print("[SilbercueWDA] UNHEALTHY: \(failures) consecutive heartbeat failures — triggering exit(1)")
                exit(1)
            } else {
                healthLock.unlock()
                print("[SilbercueWDA] Heartbeat failed (\(failures)/\(Self.maxHeartbeatFailures))")
            }
        } else {
            healthLock.lock()
            _consecutiveHeartbeatFailures = 0
            _healthy = true
            _lastHeartbeat = Date()
            healthLock.unlock()
        }
    }

    func stop() async {
        await httpServer?.stop(timeout: 3)
    }
}

// MARK: - Router

/// Single-handler router — all requests go through handleRequest.
/// Path-component matching avoids regex overhead.
private struct Router: HTTPHandler {
    let wda: SilbercueWDAServer

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        let rawPath = request.path
        let pathOnly = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
        let parts = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        wda.beginCommand()
        defer { wda.endCommand() }

        do {
            return try await route(request, parts: parts)
        } catch let error as SilbercueWDAError {
            return wda.errorResponse(error.httpStatus, error.code, error.message)
        } catch {
            return wda.errorResponse(500, "INTERNAL_ERROR", "\(error)")
        }
    }

    private func route(_ request: HTTPRequest, parts: [String]) async throws -> HTTPResponse {
        switch parts.count {
        case 1:
            return try await routeTopLevel(request, name: parts[0])

        case 2 where parts[0] == "wda" && parts[1] == "scroll-info":
            return await wda.handleScrollInfo()

        case 2 where parts[0] == "wda" && parts[1] == "scroll-test":
            return await wda.handleScrollTest(request)

        case 2 where parts[0] == "wda" && parts[1] == "scroll-visible-test":
            return try await wda.handleScrollVisibleTest(request)

        case 2 where parts[0] == "session":
            return try await wda.handleSession(request, sessionId: parts[1])

        case 3 where parts[0] == "session":
            return try await routeSessionChild(request, sessionId: parts[1], child: parts[2])

        case 4 where parts[0] == "session" && parts[2] == "alert":
            return try await routeSessionAlert(request, sessionId: parts[1], action: parts[3])

        case 4 where parts[0] == "session" && parts[2] == "wda" && parts[3] == "tap":
            return await wda.handleWdaTap(request, sessionId: parts[1])

        case 4 where parts[0] == "session" && parts[2] == "wda" && parts[3] == "drag":
            return try await wda.handleWdaDrag(request, sessionId: parts[1])

        case 5 where parts[0] == "session" && parts[2] == "element":
            return try await routeElement(request, sessionId: parts[1], elementId: parts[3], action: parts[4])

        case 6 where parts[0] == "session" && parts[2] == "element" && parts[4] == "attribute":
            return try await wda.handleGetAttribute(sessionId: parts[1], elementId: parts[3], name: parts[5])

        default:
            return wda.errorResponse(404, "NOT_FOUND", "No route for \(request.method.rawValue) \(request.path)")
        }
    }

    private func routeTopLevel(_ request: HTTPRequest, name: String) async throws -> HTTPResponse {
        switch (request.method, name) {
        case (.GET, "status"): return wda.handleStatus()
        case (.GET, "health"): return wda.handleHealth()
        case (.GET, "source"): return try await wda.handleSource(request)
        case (.POST, "session"): return await wda.handleCreateSession(request)
        default:
            return wda.errorResponse(404, "NOT_FOUND", "No route for \(request.method.rawValue) /\(name)")
        }
    }

    private func routeSessionChild(_ request: HTTPRequest, sessionId: String, child: String) async throws -> HTTPResponse {
        switch (request.method, child) {
        case (.POST, "element"): return try await wda.handleFindElement(request, sessionId: sessionId)
        case (.POST, "elements"): return try await wda.handleFindElements(request, sessionId: sessionId)
        case (.GET, "screenshot"): return try await wda.handleScreenshot(request, sessionId: sessionId)
        case (.POST, "actions"): return try await wda.handleActions(request, sessionId: sessionId)
        case (.GET, "orientation"): return await wda.handleGetOrientation(sessionId: sessionId)
        case (.POST, "orientation"): return await wda.handleSetOrientation(request, sessionId: sessionId)
        default:
            return wda.errorResponse(404, "NOT_FOUND", "No route for \(request.method.rawValue) /session/*/\(child)")
        }
    }

    private func routeSessionAlert(_ request: HTTPRequest, sessionId: String, action: String) async throws -> HTTPResponse {
        switch (request.method, action) {
        case (.GET, "text"): return await wda.handleGetAlertText(sessionId: sessionId)
        case (.POST, "accept"): return await wda.handleAcceptAlert(request, sessionId: sessionId)
        case (.POST, "dismiss"): return await wda.handleDismissAlert(request, sessionId: sessionId)
        default:
            return wda.errorResponse(404, "NOT_FOUND", "No route for \(request.method.rawValue) /session/*/alert/\(action)")
        }
    }

    private func routeElement(_ request: HTTPRequest, sessionId: String, elementId: String, action: String) async throws -> HTTPResponse {
        switch (request.method, action) {
        case (.POST, "click"): return try await wda.handleClick(sessionId: sessionId, elementId: elementId)
        case (.GET, "text"): return try await wda.handleGetText(sessionId: sessionId, elementId: elementId)
        case (.GET, "rect"): return try await wda.handleGetRect(sessionId: sessionId, elementId: elementId)
        case (.POST, "value"): return try await wda.handleSetValue(request, sessionId: sessionId, elementId: elementId)
        case (.POST, "clear"): return try await wda.handleClear(sessionId: sessionId, elementId: elementId)
        case (.GET, "screenshot"): return try await wda.handleElementScreenshot(request, sessionId: sessionId, elementId: elementId)
        default:
            return wda.errorResponse(404, "NOT_FOUND", "No route for \(request.method.rawValue) /session/*/element/*/\(action)")
        }
    }
}

// MARK: - Route Handlers

extension SilbercueWDAServer {

    func handleStatus() -> HTTPResponse {
        let uptime = Int(Date().timeIntervalSince(startTime))
        let xcodeVersion = detectXcodeVersion()

        var valueDict: [String: Any] = [
            "ready": true,
            "message": "SilbercueWDA is ready",
            "build": [
                "productBundleIdentifier": "com.silbercue.wda.runner",
                "version": version,
            ],
            "os": ["name": "iOS", "version": cachedIOSVersion],
            "iosVersion": cachedIOSVersion,
            "xcodeVersion": xcodeVersion,
            "simulatorName": cachedSimulatorName,
            "deviceModel": cachedDeviceModel,
            "serverVersion": version,
            "uptime": uptime,
        ]

        let majorMinor = xcodeVersion.components(separatedBy: ".").prefix(2).joined(separator: ".")
        if xcodeVersion != "unknown" && !Self.testedXcodeVersions.contains(majorMinor) {
            valueDict["warning"] = "Untested Xcode version: \(xcodeVersion)"
        }

        return jsonResponse([
            "value": valueDict,
            "sessionId": sessionManager.currentSessionId as Any,
            "status": 0,
        ])
    }

    func handleHealth() -> HTTPResponse {
        let uptime = Int(Date().timeIntervalSince(startTime))
        healthLock.lock()
        let healthy = _healthy
        let lastHeartbeat = _lastHeartbeat
        let failures = _consecutiveHeartbeatFailures
        let activeCommands = _activeCommandCount
        let commandStart = _lastCommandStart
        healthLock.unlock()

        let iso8601 = lastHeartbeat.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
        let commandAge = commandStart.map { Int(Date().timeIntervalSince($0)) }

        var value: [String: Any] = [
            "healthy": healthy,
            "uptime": uptime,
            "lastHeartbeat": iso8601,
            "consecutiveFailures": failures,
            "activeCommands": activeCommands,
            "sessionActive": sessionManager.currentSessionId != nil,
        ]
        if let age = commandAge {
            value["oldestCommandAge"] = age
        }

        let body: [String: Any] = [
            "status": healthy ? 0 : 1,
            "value": value,
        ]
        return jsonResponse(body, statusCode: healthy ? 200 : 503)
    }

    func handleScrollInfo() async -> HTTPResponse {
        guard let metrics = await bridge.readScrollMetrics() else {
            return errorResponse(404, "NO_SCROLL_VIEW", "No scrollable container on screen")
        }
        return jsonResponse(["status": 0, "value": metrics.toDictionary])
    }

    /// Temporary diagnostic: perform N scroll gestures to test heartbeat safety.
    /// POST /wda/scroll-test {"direction":"up","count":15}
    func handleScrollTest(_ request: HTTPRequest) async -> HTTPResponse {
        let json = await parseBody(request)
        let direction = json["direction"] as? String ?? "up"
        let count = json["count"] as? Int ?? 5

        do {
            let result = try await bridge.testScrollGestures(direction: direction, count: count)
            return jsonResponse(["status": 0, "value": result.toDictionary])
        } catch {
            return errorResponse(500, "SCROLL_TEST_FAILED", "\(error)")
        }
    }

    /// Temporary diagnostic: test scrollToVisibleIfNeeded on a specific element.
    /// POST /wda/scroll-visible-test {"using":"accessibility id","value":"item_18"}
    func handleScrollVisibleTest(_ request: HTTPRequest) async throws -> HTTPResponse {
        let json = await parseBody(request)
        guard let using = json["using"] as? String,
              let value = json["value"] as? String else {
            return errorResponse(400, "MISSING_PARAMS", "Required: using, value")
        }
        let result = try await bridge.testScrollToVisible(using: using, value: value)
        return jsonResponse(["status": 0, "value": result.toDictionary])
    }

    func handleCreateSession(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionId = sessionManager.createSession()
        let json = await parseBody(request)

        // W3C: capabilities.alwaysMatch.bundleId — the standard path
        // Legacy: desiredCapabilities.bundleId — Appium/Selenium compat
        // Flat: capabilities.bundleId — simplified clients
        let w3cCaps = (json["capabilities"] as? [String: Any])?["alwaysMatch"] as? [String: Any]
        let flatCaps = json["capabilities"] as? [String: Any]
        let legacyCaps = json["desiredCapabilities"] as? [String: Any]
        let caps = w3cCaps ?? flatCaps ?? legacyCaps ?? [:]
        let bundleId = caps["bundleId"] as? String
            ?? caps["app"] as? String
            ?? "com.apple.springboard"

        await bridge.activate(bundleIdentifier: bundleId)
        let osVersion = await UIDevice.current.systemVersion

        return jsonResponse([
            "value": [
                "sessionId": sessionId,
                "capabilities": [
                    "bundleId": bundleId,
                    "sdkVersion": osVersion,
                ],
            ],
            "sessionId": sessionId,
            "status": 0,
        ])
    }

    func handleSession(_ request: HTTPRequest, sessionId: String) async throws -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session \(sessionId) not found")
        }

        if request.method == .DELETE {
            sessionManager.deleteSession()
            return jsonResponse(["value": NSNull(), "status": 0])
        }

        return jsonResponse([
            "value": ["sessionId": sessionId, "status": "active"],
            "sessionId": sessionId,
        ])
    }

    func handleFindElement(_ request: HTTPRequest, sessionId: String) async throws -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()

        let json = await parseBody(request)
        guard let using = json["using"] as? String,
              let value = json["value"] as? String else {
            return errorResponse(400, "MISSING_PARAMS", "Required: using, value")
        }

        let scroll = json["scroll"] as? Bool ?? false

        if scroll {
            let direction = json["direction"] as? String ?? "down"
            let maxSwipes = json["maxSwipes"] as? Int ?? 10
            let (elementId, swipes) = try await bridge.findElementWithScroll(
                using: using, value: value, direction: direction, maxSwipes: maxSwipes
            )
            var result: [String: Any] = ["ELEMENT": elementId, "swipes": swipes]
            // Enriched response: embed rect + label to save 2 HTTP roundtrips
            if let rect = try? await bridge.getRect(elementId: elementId) {
                result["rect"] = rect
            }
            if let label = try? await bridge.getAttribute("label", elementId: elementId), !label.isEmpty {
                result["label"] = label
            }
            return jsonResponse(["value": result, "status": 0])
        }

        let elementId = try await bridge.findElement(using: using, value: value)
        var result: [String: Any] = ["ELEMENT": elementId]
        // Enriched response: embed rect + label to save 2 HTTP roundtrips
        if let rect = try? await bridge.getRect(elementId: elementId) {
            result["rect"] = rect
        }
        if let label = try? await bridge.getAttribute("label", elementId: elementId), !label.isEmpty {
            result["label"] = label
        }
        return jsonResponse(["value": result, "status": 0])
    }

    func handleFindElements(_ request: HTTPRequest, sessionId: String) async throws -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()

        let json = await parseBody(request)
        guard let using = json["using"] as? String,
              let value = json["value"] as? String else {
            return errorResponse(400, "MISSING_PARAMS", "Required: using, value")
        }

        let elements = try await bridge.findElements(using: using, value: value)
        let result = elements.map { ["ELEMENT": $0] }
        return jsonResponse(["value": result, "status": 0])
    }

    func handleClick(sessionId: String, elementId: String) async throws -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        try await bridge.click(elementId: elementId)
        return jsonResponse(["value": NSNull(), "status": 0])
    }

    func handleGetText(sessionId: String, elementId: String) async throws -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        let text = try await bridge.getText(elementId: elementId)
        return jsonResponse(["value": text, "status": 0])
    }

    func handleGetRect(sessionId: String, elementId: String) async throws -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        let rect = try await bridge.getRect(elementId: elementId)
        return jsonResponse(["value": rect, "status": 0])
    }

    func handleSetValue(_ request: HTTPRequest, sessionId: String, elementId: String) async throws -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        let json = await parseBody(request)
        let chars = json["value"] as? [String] ?? []
        let text = chars.joined()
        try await bridge.setValue(elementId: elementId, text: text)
        return jsonResponse(["value": NSNull(), "status": 0])
    }

    func handleClear(sessionId: String, elementId: String) async throws -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        try await bridge.clear(elementId: elementId)
        return jsonResponse(["value": NSNull(), "status": 0])
    }

    func handleGetAttribute(sessionId: String, elementId: String, name: String) async throws -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        let val = try await bridge.getAttribute(name, elementId: elementId)
        return jsonResponse(["value": val, "status": 0])
    }

    /// Fast-path: coordinate tap — no MainActor hop, fire-and-forget.
    func handleWdaTap(_ request: HTTPRequest, sessionId: String) async -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        let json = await parseBody(request)
        guard let x = json["x"] as? Double, let y = json["y"] as? Double else {
            return errorResponse(400, "MISSING_PARAMS", "Required: x, y")
        }
        XCUIBridge.fireAndForgetTap(at: CGPoint(x: x, y: y))
        return jsonResponse(["value": NSNull(), "status": 0])
    }

    func handleWdaDrag(_ request: HTTPRequest, sessionId: String) async throws -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        let json = await parseBody(request)

        let sourceElementId = json["sourceElementId"] as? String
        let targetElementId = json["targetElementId"] as? String
        let fromX = json["fromX"] as? Double
        let fromY = json["fromY"] as? Double
        let toX = json["toX"] as? Double
        let toY = json["toY"] as? Double
        let pressDuration = json["pressDuration"] as? Double ?? 1.0
        let holdDuration = json["holdDuration"] as? Double ?? 0.3
        let velocity = json["velocity"] as? Double

        try await bridge.dragAndDrop(
            sourceElementId: sourceElementId, targetElementId: targetElementId,
            fromX: fromX, fromY: fromY, toX: toX, toY: toY,
            pressDuration: pressDuration, holdDuration: holdDuration,
            velocity: velocity
        )
        return jsonResponse(["value": NSNull(), "status": 0])
    }

    func handleGetOrientation(sessionId: String) async -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        let orientation = await bridge.getOrientation()
        return jsonResponse(["value": orientation, "status": 0])
    }

    func handleSetOrientation(_ request: HTTPRequest, sessionId: String) async -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        let json = await parseBody(request)
        guard let value = json["orientation"] as? String else {
            return errorResponse(400, "MISSING_PARAMS", "Required: orientation (PORTRAIT, LANDSCAPE, LANDSCAPE_LEFT, LANDSCAPE_RIGHT)")
        }
        do {
            try await bridge.setOrientation(value)
            let current = await bridge.getOrientation()
            return jsonResponse(["value": current, "status": 0])
        } catch let error as SilbercueWDAError {
            return errorResponse(error.httpStatus, error.code, error.message)
        } catch {
            return errorResponse(500, "ORIENTATION_FAILED", "\(error)")
        }
    }

    // MARK: - Alert Handling (W3C + batch extensions)

    func handleGetAlertText(sessionId: String) async -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        guard let info = await bridge.getAlertInfo() else {
            return errorResponse(404, "NO_ALERT", "No alert is currently visible")
        }
        return jsonResponse(["value": info.text, "buttons": info.buttons, "status": 0])
    }

    func handleAcceptAlert(_ request: HTTPRequest, sessionId: String) async -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        let json = await parseBody(request)
        let buttonLabel = json["name"] as? String
        let all = json["all"] as? Bool ?? false

        if all {
            let handled = await bridge.handleAllAlerts(accept: true)
            let details = handled.map { ["text": $0.text, "buttons": $0.buttons, "source": $0.source] }
            return jsonResponse(["status": 0, "value": ["count": handled.count, "alerts": details]])
        }

        do {
            let info = await bridge.getAlertInfo()
            try await bridge.acceptAlert(buttonLabel: buttonLabel)
            var result: [String: Any] = ["status": 0, "value": NSNull()]
            if let info {
                result["alertText"] = info.text
                result["buttons"] = info.buttons
            }
            return jsonResponse(result)
        } catch let error as SilbercueWDAError {
            return errorResponse(error.httpStatus, error.code, error.message)
        } catch {
            return errorResponse(500, "ALERT_FAILED", "\(error)")
        }
    }

    func handleDismissAlert(_ request: HTTPRequest, sessionId: String) async -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        let json = await parseBody(request)
        let buttonLabel = json["name"] as? String
        let all = json["all"] as? Bool ?? false

        if all {
            let handled = await bridge.handleAllAlerts(accept: false)
            let details = handled.map { ["text": $0.text, "buttons": $0.buttons, "source": $0.source] }
            return jsonResponse(["status": 0, "value": ["count": handled.count, "alerts": details]])
        }

        do {
            let info = await bridge.getAlertInfo()
            try await bridge.dismissAlert(buttonLabel: buttonLabel)
            var result: [String: Any] = ["status": 0, "value": NSNull()]
            if let info {
                result["alertText"] = info.text
                result["buttons"] = info.buttons
            }
            return jsonResponse(result)
        } catch let error as SilbercueWDAError {
            return errorResponse(error.httpStatus, error.code, error.message)
        } catch {
            return errorResponse(500, "ALERT_FAILED", "\(error)")
        }
    }

    func handleActions(_ request: HTTPRequest, sessionId: String) async throws -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        let bodyData = (try? await request.bodyData) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
        try await bridge.performActions(json)
        return jsonResponse(["value": NSNull(), "status": 0])
    }

    func handleSource(_ request: HTTPRequest) async throws -> HTTPResponse {
        let format = request.query.first(where: { $0.name == "format" })?.value ?? "json"
        let source = try await bridge.getSource(format: format)
        return jsonResponse(["value": source, "status": 0])
    }

    func handleScreenshot(_ request: HTTPRequest, sessionId: String) async throws -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        let format = request.query.first(where: { $0.name == "format" })?.value ?? "png"
        let quality = request.query.first(where: { $0.name == "quality" }).flatMap { Double($0.value) } ?? 0.8
        let scale = request.query.first(where: { $0.name == "scale" }).flatMap { Double($0.value) } ?? 1.0
        // Region crop: ?x=&y=&w=&h= (pixels)
        let cropX = request.query.first(where: { $0.name == "x" }).flatMap { Int($0.value) }
        let cropY = request.query.first(where: { $0.name == "y" }).flatMap { Int($0.value) }
        let cropW = request.query.first(where: { $0.name == "w" }).flatMap { Int($0.value) }
        let cropH = request.query.first(where: { $0.name == "h" }).flatMap { Int($0.value) }
        var rect: CGRect?
        if let x = cropX, let y = cropY, let w = cropW, let h = cropH {
            rect = CGRect(x: x, y: y, width: w, height: h)
        }

        let b64 = try await bridge.screenshot(format: format, quality: quality, scale: scale, cropRect: rect)
        return jsonResponse(["value": b64, "status": 0])
    }

    func handleElementScreenshot(_ request: HTTPRequest, sessionId: String, elementId: String) async throws -> HTTPResponse {
        guard sessionManager.isValid(sessionId: sessionId) else {
            return errorResponse(404, "INVALID_SESSION", "Session not found")
        }
        sessionManager.touch()
        let format = request.query.first(where: { $0.name == "format" })?.value ?? "png"
        let quality = request.query.first(where: { $0.name == "quality" }).flatMap { Double($0.value) } ?? 0.8
        let padding = request.query.first(where: { $0.name == "padding" }).flatMap { Int($0.value) } ?? 0
        let b64 = try await bridge.elementScreenshot(elementId: elementId, format: format, quality: quality, padding: padding)
        return jsonResponse(["value": b64, "status": 0])
    }
}

// MARK: - Helpers

extension SilbercueWDAServer {

    func jsonResponse(_ body: [String: Any], statusCode: Int = 200) -> HTTPResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        return HTTPResponse(
            statusCode: HTTPStatusCode(statusCode, phrase: ""),
            headers: [.contentType: "application/json"],
            body: data
        )
    }

    func errorResponse(_ httpStatus: Int, _ code: String, _ message: String) -> HTTPResponse {
        jsonResponse([
            "status": 1,
            "value": ["error": code, "message": message],
        ], statusCode: httpStatus)
    }

    func parseBody(_ request: HTTPRequest) async -> [String: Any] {
        guard let data = try? await request.bodyData, !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func detectXcodeVersion() -> String {
        let env = ProcessInfo.processInfo.environment

        if let version = env["XCODE_VERSION_ACTUAL"], !version.isEmpty {
            return formatXcodeVersion(version)
        }

        if let dtXcode = Bundle(for: SilbercueWDAServer.self).infoDictionary?["DTXcode"] as? String, !dtXcode.isEmpty {
            return formatXcodeVersion(dtXcode)
        }

        return "unknown"
    }

    private func formatXcodeVersion(_ raw: String) -> String {
        guard raw.count >= 4, let num = Int(raw) else { return raw }
        let major = num / 100
        let minor = (num % 100) / 10
        return "\(major).\(minor)"
    }
}
