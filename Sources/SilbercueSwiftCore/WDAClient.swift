import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Which WDA backend to use for UI automation.
enum WDABackend: String, Sendable {
    case silbercueWDA   // Our own lightweight WDA replacement
    case originalWDA    // Facebook's WebDriverAgent

    var bundleId: String {
        switch self {
        case .silbercueWDA: return "com.silbercue.wda.runner.xctrunner"
        case .originalWDA:  return "com.facebook.WebDriverAgentRunner.xctrunner"
        }
    }

    var displayName: String {
        switch self {
        case .silbercueWDA: return "SilbercueWDA"
        case .originalWDA:  return "Original WDA (Facebook)"
        }
    }
}

/// Direct HTTP client for WebDriverAgent — no Appium overhead.
/// WDA runs on http://localhost:8100 by default.
/// Supports both SilbercueWDA and Original WDA with automatic fallback.
actor WDAClient {
    static let shared = WDAClient()

    private var baseURL = ProcessInfo.processInfo.environment["WDA_BASE_URL"] ?? "http://localhost:8100"
    private var sessionId: String?
    private var knownSessionIds: [String] = []  // Track all created sessions

    /// Active WDA backend. Default: SilbercueWDA with fallback to Original WDA.
    private(set) var backend: WDABackend = .silbercueWDA

    /// Info message when fallback was triggered (nil = no fallback).
    private(set) var fallbackInfo: String?

    /// Guard against concurrent deploys.
    private var isDeploying = false

    /// Handle to the background xcodebuild test process (for cleanup).
    private var deployTask: Task<Void, Never>?

    /// Default timeout for WDA requests (fast fail instead of endless hang)
    private let requestTimeout: TimeInterval = 10
    /// Quick timeout for health-check pings
    private let healthCheckTimeout: TimeInterval = 2

    // MARK: - Configuration

    func setBaseURL(_ url: String) {
        self.baseURL = url
    }

    func setBackend(_ newBackend: WDABackend) {
        self.backend = newBackend
        self.fallbackInfo = nil
    }

    // MARK: - HTTP Helpers

    private func request(
        method: String,
        path: String,
        body: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> (Data, Int) {
        let effectiveTimeout = timeout ?? requestTimeout
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else {
            throw WDAError.invalidURL(urlString)
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = effectiveTimeout

        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Freeze request as let for safe capture in task group closures
        let finalReq = req
        let finalTimeout = effectiveTimeout

        // Hard timeout wrapper — guarantees we never hang longer than effectiveTimeout.
        // URLRequest.timeoutInterval only measures idle time between packets, not total duration.
        // If WDA accepts the connection but never responds, timeoutInterval may never fire.
        return try await withThrowingTaskGroup(of: (Data, Int).self) { group in
            group.addTask {
                let (data, response) = try await URLSession.shared.data(for: finalReq)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                return (data, statusCode)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(finalTimeout * 1_000_000_000))
                throw WDAError.wdaNotResponding
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw WDAError.wdaNotResponding
            }
            return result
        }
    }

    private func jsonRequest(
        method: String,
        path: String,
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let (data, statusCode) = try await request(method: method, path: path, body: body)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8) ?? "?"
            throw WDAError.invalidResponse("Status \(statusCode): \(text)")
        }

        if statusCode >= 400 {
            let errorMsg = (json["value"] as? [String: Any])?["message"] as? String ?? "\(json)"
            throw WDAError.wdaError(statusCode, errorMsg)
        }

        return json
    }

    // MARK: - Health Check & Auto-Restart

    /// Ping WDA /status with a fast 2s timeout. Returns true if WDA is responsive.
    func isHealthy() async -> Bool {
        do {
            let (_, statusCode) = try await request(method: "GET", path: "/status", timeout: healthCheckTimeout)
            return statusCode < 400
        } catch {
            return false
        }
    }

    /// Restart current backend by terminating and relaunching the xctrunner on the given simulator.
    func restartWDA(simulator: String = "booted") async throws {
        let bid = backend.bundleId
        // Kill any lingering WDA process
        let _ = try? await Shell.xcrun(timeout: 5, "simctl", "terminate", simulator, bid)

        // Clean up port 8100 — prevents binding conflicts when old WDA left the port occupied.
        // This was previously only done in deploySilbercueWDA, causing restartWDA to fail silently.
        await cleanupPort8100()

        // Pause for clean shutdown and port release (0.5s was too short for TIME_WAIT)
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s

        // Relaunch WDA with explicit timeout
        let result = try await Shell.xcrun(timeout: 10, "simctl", "launch", simulator, bid)
        guard result.succeeded else {
            throw WDAError.wdaRestart("Failed to restart \(backend.displayName): \(result.stderr)")
        }
        // Wait for WDA to become ready (poll up to 10s)
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            if await isHealthy() {
                sessionId = nil
                knownSessionIds.removeAll() // All old sessions are invalid after restart
                return
            }
        }
        throw WDAError.wdaRestart("\(backend.displayName) did not become ready within 10s after restart")
    }

    /// Kill any process holding port 8100 to prevent binding conflicts.
    private func cleanupPort8100() async {
        if let result = try? await Shell.run("/usr/bin/lsof", arguments: ["-ti", ":8100"], timeout: 5),
           result.succeeded, !result.stdout.isEmpty {
            for pidStr in result.stdout.split(separator: "\n") {
                if let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)) {
                    kill(pid, SIGKILL)
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s for port release
        }
    }

    /// Kill any WDA process on port 8100 and terminate known runners.
    private func cleanupWDAProcesses(simulator: String) async {
        let _ = try? await Shell.xcrun(timeout: 5, "simctl", "terminate", simulator, WDABackend.silbercueWDA.bundleId)
        let _ = try? await Shell.xcrun(timeout: 5, "simctl", "terminate", simulator, WDABackend.originalWDA.bundleId)
        await cleanupPort8100()
    }

    /// Deploy SilbercueWDA to the simulator: build-for-testing + start via xcodebuild test.
    /// Returns true if deploy succeeded and server is healthy, false otherwise.
    /// If a deploy is already in progress, waits for it instead of starting a new one.
    func deploySilbercueWDA(simulator: String = "booted") async -> Bool {
        // H3 fix: If another deploy is in progress, wait for it instead of triggering premature fallback.
        // Actor isolation guarantees isDeploying is checked atomically (no await before the set).
        if isDeploying {
            Log.warn("deploySilbercueWDA: concurrent call detected, waiting for existing deploy")
            for i in 1...15 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if await isHealthy() {
                    Log.warn("deploySilbercueWDA: existing deploy succeeded after \(i * 2)s wait")
                    return true
                }
            }
            Log.warn("deploySilbercueWDA: existing deploy did not succeed within 30s")
            return false
        }

        isDeploying = true
        defer { isDeploying = false }

        // H2 fix: Kill lingering processes before deploy (not just Task.cancel)
        deployTask?.cancel()
        deployTask = nil
        await cleanupWDAProcesses(simulator: simulator)

        // Find SilbercueWDA project — check env var first, then common relative location
        let projectDir: String
        if let envDir = ProcessInfo.processInfo.environment["SILBERCUEWDA_DIR"],
           FileManager.default.fileExists(atPath: envDir + "/SilbercueWDA.xcodeproj") {
            projectDir = envDir
        } else {
            // Try relative to this binary's known repo layout: <repo>/SilbercueWDA
            let candidates = [
                FileManager.default.currentDirectoryPath + "/SilbercueWDA",
                FileManager.default.currentDirectoryPath + "/../SilbercueWDA",
            ]
            guard let found = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0 + "/SilbercueWDA.xcodeproj")
            }) else {
                return false
            }
            projectDir = found
        }

        // Resolve UDID for xcodebuild destination
        let udid = await resolveSimulatorUDID(simulator)

        // Find or create DerivedData for SilbercueWDA
        let derivedData = await findOrCreateDerivedData(projectDir: projectDir)

        // Step 1: Build with -target (Xcode 26 workaround: -scheme can't find
        // iOS Simulator destinations for UI testing bundles)
        let buildArgs = [
            "xcodebuild",
            "-project", "\(projectDir)/SilbercueWDA.xcodeproj",
            "-target", "SilbercueWDARunner",
            "-sdk", "iphonesimulator",
            "-arch", "arm64",
            "-configuration", "Debug",
            "SYMROOT=\(derivedData)/Build/Products",
            "OBJROOT=\(derivedData)/Build/Intermediates.noindex",
            "build",
        ]
        let buildResult: ShellResult
        do {
            buildResult = try await Shell.run("/usr/bin/xcrun", arguments: buildArgs, timeout: 120)
        } catch {
            Log.warn("deploySilbercueWDA build error: \(error)")
            return false
        }
        guard buildResult.succeeded else {
            Log.warn("deploySilbercueWDA build failed: \(buildResult.stderr.prefix(500))")
            return false
        }

        // Step 2: Find xctestrun file and start test-without-building
        let xctestrun = await findXctestrun(derivedData: derivedData)
        guard let xctestrun else {
            Log.warn("deploySilbercueWDA: no xctestrun file found in \(derivedData)")
            return false
        }

        let testArgs = [
            "xcodebuild", "test-without-building",
            "-xctestrun", xctestrun,
            "-destination", "id=\(udid)",
        ]
        deployTask = Task.detached {
            _ = try? await Shell.run("/usr/bin/xcrun", arguments: testArgs, timeout: 3600)
        }

        // Step 3: Poll for server readiness (up to 30s)
        for _ in 1...15 {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
            if await isHealthy() {
                return true
            }
        }
        return false
    }

    /// Find existing DerivedData for SilbercueWDA, or return a predictable path.
    private func findOrCreateDerivedData(projectDir: String) async -> String {
        let ddBase = NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData"
        // Search for existing SilbercueWDA DerivedData
        if let result = try? await Shell.run("/usr/bin/find", arguments: [
            ddBase, "-maxdepth", "1", "-name", "SilbercueWDA-*", "-type", "d",
        ], timeout: 5), result.succeeded {
            let dirs = result.stdout.split(separator: "\n").map(String.init)
            if let first = dirs.first { return first }
        }
        return ddBase + "/SilbercueWDA-deploy"
    }

    /// Find the most recent arm64 xctestrun file in DerivedData.
    private func findXctestrun(derivedData: String) async -> String? {
        let productsDir = derivedData + "/Build/Products"
        if let result = try? await Shell.run("/usr/bin/find", arguments: [
            productsDir, "-name", "*arm64.xctestrun", "-type", "f",
        ], timeout: 5), result.succeeded {
            let files = result.stdout.split(separator: "\n").map(String.init)
            return files.first
        }
        return nil
    }

    /// Resolve simulator identifier to actual UDID.
    private func resolveSimulatorUDID(_ simulator: String) async -> String {
        guard simulator == "booted" else { return simulator }
        let shellResult: ShellResult
        do {
            shellResult = try await Shell.xcrun(timeout: 15, "simctl", "list", "devices", "booted", "-j")
        } catch {
            Log.warn("WDA resolveSimulatorUDID failed: \(error)")
            return simulator
        }
        guard shellResult.succeeded,
              let data = shellResult.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else {
            return simulator
        }
        for (_, sims) in devices {
            for sim in sims {
                if let state = sim["state"] as? String, state == "Booted",
                   let udid = sim["udid"] as? String {
                    return udid
                }
            }
        }
        return simulator
    }

    /// Health-check with auto-restart and fallback chain.
    /// Always tries in fixed order: healthy? → restart current → deploy SilbercueWDA → fallback Original WDA.
    /// H1 fix: Backend state is only updated AFTER confirming which backend is actually running.
    func ensureWDARunning(simulator: String = "booted") async throws {
        // 1. Already healthy? Done — whatever backend is active, it works.
        if await isHealthy() { return }

        // 2. Try restarting current backend
        do {
            try await restartWDA(simulator: simulator)
            return
        } catch {
            // Restart failed, continue with fallback chain
        }

        // 3. Always try SilbercueWDA deploy (preferred backend)
        backend = .silbercueWDA
        fallbackInfo = nil
        if await deploySilbercueWDA(simulator: simulator) {
            sessionId = nil
            return
        }

        // 4. SilbercueWDA deploy failed → fallback to Original WDA
        backend = .originalWDA
        fallbackInfo = "SilbercueWDA not available — using Original WDA as fallback"
        sessionId = nil

        if await isHealthy() { return }
        do {
            try await restartWDA(simulator: simulator)
            return
        } catch {
            // Original WDA also failed
        }

        // 5. Nothing works
        throw WDAError.noBackendAvailable
    }

    // MARK: - Session Management

    /// Number of tracked sessions (for leak detection)
    var sessionCount: Int { knownSessionIds.count }

    /// Warning message if too many sessions are open, nil otherwise.
    var sessionWarning: String? {
        knownSessionIds.count > 2
            ? "⚠️ \(knownSessionIds.count) WDA sessions tracked. Consider deleting unused sessions to avoid resource leaks."
            : nil
    }

    func createSession(bundleId: String? = nil) async throws -> String {
        var capabilities: [String: Any] = [:]
        if let bid = bundleId {
            capabilities["bundleId"] = bid
        }

        let body: [String: Any] = [
            "capabilities": [
                "alwaysMatch": capabilities
            ]
        ]

        let json = try await jsonRequest(method: "POST", path: "/session", body: body)

        guard let sessionId = json["sessionId"] as? String
                ?? (json["value"] as? [String: Any])?["sessionId"] as? String else {
            throw WDAError.noSession
        }

        self.sessionId = sessionId
        if !knownSessionIds.contains(sessionId) {
            knownSessionIds.append(sessionId)
        }
        return sessionId
    }

    func deleteSession() async throws {
        guard let sid = sessionId else { return }
        do {
            _ = try await request(method: "DELETE", path: "/session/\(sid)")
        } catch {
            Log.warn("deleteSession(\(sid)) failed: \(error)")
        }
        knownSessionIds.removeAll { $0 == sid }
        sessionId = nil
    }

    func ensureSession() async throws -> String {
        if let sid = sessionId {
            // Quick health check with fast timeout
            do {
                let (_, status) = try await request(method: "GET", path: "/session/\(sid)", timeout: healthCheckTimeout)
                if status < 400 { return sid }
            } catch {
                // Session check failed — WDA might be unresponsive
                // Try auto-restart before creating a new session
                try await ensureWDARunning()
            }
        } else {
            // No session yet — still check if WDA is alive before trying to create one
            // This prevents a 10s hang on createSession if WDA is dead
            try await ensureWDARunning()
        }
        return try await createSession()
    }

    // MARK: - Element Finding

    func findElement(using strategy: String, value: String, scroll: Bool = false, direction: String = "auto", maxSwipes: Int = 10) async throws -> (elementId: String, swipes: Int) {
        let sid = try await ensureSession()
        var body: [String: Any] = ["using": strategy, "value": value]
        if scroll {
            body["scroll"] = true
            body["direction"] = direction
            body["maxSwipes"] = maxSwipes
        }
        let json = try await jsonRequest(
            method: "POST",
            path: "/session/\(sid)/element",
            body: body
        )

        guard let element = json["value"] as? [String: Any],
              let elementId = element["ELEMENT"] as? String ?? element.values.first as? String else {
            throw WDAError.elementNotFound(strategy, value)
        }
        let swipes = element["swipes"] as? Int ?? 0
        return (elementId, swipes)
    }

    func findElements(using strategy: String, value: String) async throws -> [String] {
        let sid = try await ensureSession()
        let json = try await jsonRequest(
            method: "POST",
            path: "/session/\(sid)/elements",
            body: ["using": strategy, "value": value]
        )

        guard let elements = json["value"] as? [[String: Any]] else { return [] }
        return elements.compactMap { elem in
            elem["ELEMENT"] as? String ?? elem.values.first as? String
        }
    }

    // MARK: - Element Interaction

    func click(elementId: String) async throws {
        let sid = try await ensureSession()
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/element/\(elementId)/click")
    }

    func getText(elementId: String) async throws -> String {
        let sid = try await ensureSession()
        let json = try await jsonRequest(method: "GET", path: "/session/\(sid)/element/\(elementId)/text")
        return json["value"] as? String ?? ""
    }

    func setValue(elementId: String, text: String) async throws {
        let sid = try await ensureSession()
        _ = try await jsonRequest(
            method: "POST",
            path: "/session/\(sid)/element/\(elementId)/value",
            body: ["value": Array(text).map(String.init)]
        )
    }

    func clearElement(elementId: String) async throws {
        let sid = try await ensureSession()
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/element/\(elementId)/clear")
    }

    func getElementAttribute(_ attribute: String, elementId: String) async throws -> String {
        let sid = try await ensureSession()
        let json = try await jsonRequest(method: "GET", path: "/session/\(sid)/element/\(elementId)/attribute/\(attribute)")
        return json["value"] as? String ?? ""
    }

    // MARK: - Touch Actions (W3C Actions API)

    func tap(x: Double, y: Double) async throws {
        let sid = try await ensureSession()
        let actions: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": Int(x), "y": Int(y)],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": 50],
                    ["type": "pointerUp", "button": 0],
                ]
            ]]
        ]
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/actions", body: actions)
    }

    func doubleTap(x: Double, y: Double) async throws {
        let sid = try await ensureSession()
        let actions: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": Int(x), "y": Int(y)],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": 30],
                    ["type": "pointerUp", "button": 0],
                    ["type": "pause", "duration": 50],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": 30],
                    ["type": "pointerUp", "button": 0],
                ]
            ]]
        ]
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/actions", body: actions)
    }

    func longPress(x: Double, y: Double, durationMs: Int = 1000) async throws {
        let sid = try await ensureSession()
        let actions: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": Int(x), "y": Int(y)],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": durationMs],
                    ["type": "pointerUp", "button": 0],
                ]
            ]]
        ]
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/actions", body: actions)
    }

    func swipe(startX: Double, startY: Double, endX: Double, endY: Double, durationMs: Int = 300) async throws {
        let sid = try await ensureSession()
        let actions: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": Int(startX), "y": Int(startY)],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pointerMove", "duration": durationMs, "x": Int(endX), "y": Int(endY)],
                    ["type": "pointerUp", "button": 0],
                ]
            ]]
        ]
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/actions", body: actions)
    }

    func pinch(centerX: Double, centerY: Double, scale: Double, durationMs: Int = 500) async throws {
        let sid = try await ensureSession()
        let offset = 100.0
        let isZoomIn = scale > 1.0

        let finger1Start = isZoomIn ? (x: centerX, y: centerY - 10) : (x: centerX, y: centerY - offset)
        let finger1End   = isZoomIn ? (x: centerX, y: centerY - offset) : (x: centerX, y: centerY - 10)
        let finger2Start = isZoomIn ? (x: centerX, y: centerY + 10) : (x: centerX, y: centerY + offset)
        let finger2End   = isZoomIn ? (x: centerX, y: centerY + offset) : (x: centerX, y: centerY + 10)

        let actions: [String: Any] = [
            "actions": [
                [
                    "type": "pointer",
                    "id": "finger1",
                    "parameters": ["pointerType": "touch"],
                    "actions": [
                        ["type": "pointerMove", "duration": 0, "x": Int(finger1Start.x), "y": Int(finger1Start.y)],
                        ["type": "pointerDown", "button": 0],
                        ["type": "pointerMove", "duration": durationMs, "x": Int(finger1End.x), "y": Int(finger1End.y)],
                        ["type": "pointerUp", "button": 0],
                    ]
                ],
                [
                    "type": "pointer",
                    "id": "finger2",
                    "parameters": ["pointerType": "touch"],
                    "actions": [
                        ["type": "pointerMove", "duration": 0, "x": Int(finger2Start.x), "y": Int(finger2Start.y)],
                        ["type": "pointerDown", "button": 0],
                        ["type": "pointerMove", "duration": durationMs, "x": Int(finger2End.x), "y": Int(finger2End.y)],
                        ["type": "pointerUp", "button": 0],
                    ]
                ],
            ]
        ]
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/actions", body: actions)
    }

    func dragAndDrop(
        sourceElement: String? = nil, targetElement: String? = nil,
        fromX: Double? = nil, fromY: Double? = nil,
        toX: Double? = nil, toY: Double? = nil,
        pressDurationMs: Int = 1000, holdDurationMs: Int = 300,
        velocity: Double? = nil
    ) async throws {
        let sid = try await ensureSession()
        var body: [String: Any] = [
            "pressDuration": Double(pressDurationMs) / 1000.0,
            "holdDuration": Double(holdDurationMs) / 1000.0,
        ]
        if let se = sourceElement { body["sourceElementId"] = se }
        if let te = targetElement { body["targetElementId"] = te }
        if let x = fromX { body["fromX"] = x }
        if let y = fromY { body["fromY"] = y }
        if let x = toX { body["toX"] = x }
        if let y = toY { body["toY"] = y }
        if let v = velocity { body["velocity"] = v }
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/wda/drag", body: body)
    }

    // MARK: - Alert Handling

    struct AlertInfo: Sendable {
        let text: String
        let buttons: [String]
    }

    struct BatchAlertResult: Sendable {
        let count: Int
        let alerts: [AlertDetail]

        struct AlertDetail: Sendable {
            let text: String
            let buttons: [String]
            let source: String
        }
    }

    /// Get alert text. Returns nil if no alert is visible (404 from WDA).
    func getAlertText() async -> AlertInfo? {
        guard let sid = try? await ensureSession() else { return nil }
        do {
            let json = try await jsonRequest(method: "GET", path: "/session/\(sid)/alert/text")
            let text = json["value"] as? String ?? ""
            let buttons = json["buttons"] as? [String] ?? []
            return AlertInfo(text: text, buttons: buttons)
        } catch {
            return nil // No alert visible
        }
    }

    /// Accept the current alert or all visible alerts.
    func acceptAlert(buttonLabel: String? = nil, all: Bool = false) async throws -> AlertInfo? {
        let sid = try await ensureSession()
        var body: [String: Any] = [:]
        if let label = buttonLabel { body["name"] = label }
        if all { body["all"] = true }

        let json = try await jsonRequest(method: "POST", path: "/session/\(sid)/alert/accept", body: body.isEmpty ? nil : body)
        let text = json["alertText"] as? String
        let buttons = json["buttons"] as? [String]
        if let text, let buttons {
            return AlertInfo(text: text, buttons: buttons)
        }
        return nil
    }

    /// Dismiss the current alert or all visible alerts.
    func dismissAlert(buttonLabel: String? = nil, all: Bool = false) async throws -> AlertInfo? {
        let sid = try await ensureSession()
        var body: [String: Any] = [:]
        if let label = buttonLabel { body["name"] = label }
        if all { body["all"] = true }

        let json = try await jsonRequest(method: "POST", path: "/session/\(sid)/alert/dismiss", body: body.isEmpty ? nil : body)
        let text = json["alertText"] as? String
        let buttons = json["buttons"] as? [String]
        if let text, let buttons {
            return AlertInfo(text: text, buttons: buttons)
        }
        return nil
    }

    /// Accept or dismiss all visible alerts in batch. Returns count + details.
    func handleAllAlerts(accept: Bool) async throws -> BatchAlertResult {
        let sid = try await ensureSession()
        let path = accept ? "/session/\(sid)/alert/accept" : "/session/\(sid)/alert/dismiss"
        let json = try await jsonRequest(method: "POST", path: path, body: ["all": true])

        guard let value = json["value"] as? [String: Any] else {
            return BatchAlertResult(count: 0, alerts: [])
        }
        let count = value["count"] as? Int ?? 0
        let alertDicts = value["alerts"] as? [[String: Any]] ?? []
        let alerts = alertDicts.map {
            BatchAlertResult.AlertDetail(
                text: $0["text"] as? String ?? "",
                buttons: $0["buttons"] as? [String] ?? [],
                source: $0["source"] as? String ?? ""
            )
        }
        return BatchAlertResult(count: count, alerts: alerts)
    }

    // MARK: - View Hierarchy

    func getSource(format: String = "json") async throws -> String {
        // Health check first — getSource bypasses session management, so fail fast if WDA is dead
        guard await isHealthy() else {
            throw WDAError.wdaNotResponding
        }
        let (data, statusCode) = try await request(method: "GET", path: "/source?format=\(format)")
        guard statusCode < 400 else {
            throw WDAError.invalidResponse("Source request failed with status \(statusCode)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Screenshot via WDA

    func wdaScreenshot() async throws -> Data {
        let sid = try await ensureSession()
        let json = try await jsonRequest(method: "GET", path: "/session/\(sid)/screenshot")
        guard let b64 = json["value"] as? String,
              let data = Data(base64Encoded: b64) else {
            throw WDAError.invalidResponse("Invalid screenshot data")
        }
        return data
    }

    // MARK: - Device Orientation

    func getOrientation() async throws -> String {
        let sid = try await ensureSession()
        let json = try await jsonRequest(method: "GET", path: "/session/\(sid)/orientation")
        return json["value"] as? String ?? "PORTRAIT"
    }

    func setOrientation(_ orientation: String) async throws -> String {
        let sid = try await ensureSession()
        let json = try await jsonRequest(
            method: "POST",
            path: "/session/\(sid)/orientation",
            body: ["orientation": orientation]
        )
        return json["value"] as? String ?? orientation
    }

    // MARK: - Status

    struct WDAStatus: Sendable {
        let ready: Bool
        let bundleId: String
        let raw: String
    }

    func status() async throws -> WDAStatus {
        let json = try await jsonRequest(method: "GET", path: "/status")
        let value = json["value"] as? [String: Any]
        let ready = value?["ready"] as? Bool ?? false
        let bundleId = (value?["build"] as? [String: Any])?["productBundleIdentifier"] as? String ?? "?"
        let raw = String(data: (try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)) ?? Data(), encoding: .utf8) ?? ""
        return WDAStatus(ready: ready, bundleId: bundleId, raw: raw)
    }
}

// MARK: - Errors

enum WDAError: Error, CustomStringConvertible {
    case invalidURL(String)
    case invalidResponse(String)
    case wdaError(Int, String)
    case noSession
    case elementNotFound(String, String)
    case wdaRestart(String)
    case wdaNotResponding
    case noBackendAvailable

    var description: String {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .wdaError(let code, let msg): return "WDA error \(code): \(msg)"
        case .noSession: return "No WDA session"
        case .elementNotFound(let strategy, let value): return "Element not found: \(strategy)=\(value)"
        case .wdaRestart(let msg): return "WDA restart failed: \(msg)"
        case .wdaNotResponding: return "WDA not responding (timeout >10s). Try: wda_create_session or restart the simulator."
        case .noBackendAvailable: return "No WDA backend available. Neither SilbercueWDA nor Original WDA could be started. Install SilbercueWDA or start WebDriverAgent."
        }
    }
}
