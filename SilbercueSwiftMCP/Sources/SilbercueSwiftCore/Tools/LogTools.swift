import Foundation
import MCP

/// Real-time log streaming via `simctl spawn booted log stream`.
/// Uses a background process that captures logs into a buffer with deduplication.
actor LogCapture {
    static let shared = LogCapture()

    private var process: Process?
    private var buffer: [String] = []
    private var pipe: Pipe?
    private let maxLines = 5000

    // Deduplication state
    private var lastMessageContent: String?
    private var repeatCount: Int = 0

    /// The capture mode used when start() was called (for topic-filter warnings)
    private(set) var captureMode: String = "smart"

    func start(arguments: [String], mode: String = "smart") throws {
        self.captureMode = mode
        // Stop existing capture (flushes dedup state)
        stop()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = arguments

        let p = Pipe()
        proc.standardOutput = p
        proc.standardError = FileHandle.nullDevice
        self.pipe = p

        // Read output in background
        p.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Task { [weak self] in
                await self?.appendLine(line)
            }
        }

        try proc.run()
        self.process = proc
    }

    private func appendLine(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            guard !line.isEmpty else { continue }
            let content = stripTimestamp(line)

            if content == lastMessageContent {
                repeatCount += 1
            } else {
                flushRepeat()
                lastMessageContent = content
                repeatCount = 0
                buffer.append(line)
            }
        }
        if buffer.count > maxLines {
            buffer.removeFirst(buffer.count - maxLines)
        }
    }

    /// Strip the compact-format timestamp prefix for dedup comparison.
    /// Compact format: "2026-03-29 16:45:12.345 Df  processName  message..."
    /// We strip everything up to and including the first tab or double-space after the timestamp.
    private func stripTimestamp(_ line: String) -> String {
        // Find the third space (after "date time level") to get to the message content
        var spaceCount = 0
        for (i, ch) in line.enumerated() {
            if ch == " " || ch == "\t" {
                spaceCount += 1
                // After "YYYY-MM-DD HH:MM:SS.sss Lv" there are ~3 space-separated fields
                if spaceCount >= 4 {
                    return String(line.dropFirst(i + 1))
                }
            }
        }
        return line
    }

    private func flushRepeat() {
        if repeatCount > 0 {
            buffer.append("  ... repeated \(repeatCount)x")
            repeatCount = 0
        }
    }

    func stop() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        flushRepeat()
        lastMessageContent = nil
        process = nil
        pipe = nil
    }

    func readAndClear() -> [String] {
        flushRepeat()
        let result = buffer
        buffer.removeAll()
        lastMessageContent = nil
        return result
    }

    func read(last: Int?) -> [String] {
        flushRepeat()
        if let n = last {
            return Array(buffer.suffix(n))
        }
        return buffer
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }
}

enum LogTools {

    // MARK: - Noise blacklist (measured on iOS 26.4 idle simulator, >90% of noise)

    static let noiseProcesses = [
        // v1.1.0 (11)
        "proactiveeventtrackerd", "locationd", "mediaanalysisd",
        "apsd", "cfprefsd", "pairedsyncd", "mDNSResponder",
        "backboardd", "DTServiceHub", "geod", "itunesstored",
        // v1.2.0 — verified guaranteed noise (4)
        "geoanalyticsd", "UserEventAgent", "fontservicesd", "amsengagementd",
    ]

    static let noiseSubsystems = ["com.apple.defaults"]

    static let noiseSubsystemCategories: [(subsystem: String, category: String)] = [
        (subsystem: "com.apple.network", category: "endpoint"),  // 42% of noise
    ]

    // MARK: - Topic system for read-time filtering

    struct ParsedLogLine {
        let processName: String   // "locationd", "SpringBoard", "MyApp"
        let logType: String       // "Db", "Df", "De", "Di"
        let subsystem: String?    // "com.apple.locationd.Motion" (nil if missing)
        let category: String?     // "Motion", "endpoint" (nil if missing)
    }

    /// O(1) topic lookup for known processes
    static let processTopics: [String: String] = [
        "trustd": "network", "nsurlsessiond": "network",
        "runningboardd": "lifecycle",
        "SpringBoard": "springboard",
        "chronod": "widgets",
    ]

    /// Parse a compact-format log line into its components.
    /// Returns nil for headers, dedup lines, and unparseable lines.
    ///
    /// Format: `YYYY-MM-DD HH:MM:SS.mmm Ty  Process[PID:TID] [subsystem:category] message`
    /// or:     `YYYY-MM-DD HH:MM:SS.mmm Ty  Process[PID:TID] (Framework) message`
    static func parseLine(_ line: String) -> ParsedLogLine? {
        // Skip dedup lines and headers
        guard !line.isEmpty,
              !line.hasPrefix("  "),           // "  ... repeated Nx"
              !line.hasPrefix("Timestamp"),     // header line
              line.count > 26                   // minimum: timestamp(23) + space + Ty(2)
        else { return nil }

        let chars = Array(line.unicodeScalars)

        // Position 24-25: log type (Db, Df, De, Di)
        guard chars.count > 25 else { return nil }
        let logType = String(chars[24...25].map { Character($0) })

        // After log type + whitespace: process name until '[' or '('
        var idx = 26
        // Skip whitespace
        while idx < chars.count && (chars[idx] == " " || chars[idx] == "\t") {
            idx += 1
        }
        guard idx < chars.count else { return nil }

        // Collect process name
        let procStart = idx
        while idx < chars.count && chars[idx] != "[" && chars[idx] != "(" && chars[idx] != " " {
            idx += 1
        }
        guard idx > procStart else { return nil }
        let processName = String(chars[procStart..<idx].map { Character($0) })

        // Skip PID:TID block [xxxxx:yyyyy]
        if idx < chars.count && chars[idx] == "[" {
            while idx < chars.count && chars[idx] != "]" { idx += 1 }
            if idx < chars.count { idx += 1 } // skip ']'
        }

        // Skip whitespace
        while idx < chars.count && chars[idx] == " " { idx += 1 }

        // Optional [subsystem:category]
        var subsystem: String?
        var category: String?
        if idx < chars.count && chars[idx] == "[" {
            idx += 1 // skip '['
            let subStart = idx
            while idx < chars.count && chars[idx] != ":" && chars[idx] != "]" { idx += 1 }
            subsystem = String(chars[subStart..<idx].map { Character($0) })

            if idx < chars.count && chars[idx] == ":" {
                idx += 1
                let catStart = idx
                while idx < chars.count && chars[idx] != "]" { idx += 1 }
                category = String(chars[catStart..<idx].map { Character($0) })
            }
        }

        return ParsedLogLine(processName: processName, logType: logType,
                             subsystem: subsystem, category: category)
    }

    /// Categorize a parsed log line into topic(s).
    /// Always includes `app` (if matching) and `crashes` (if fault). Returns `system` as fallback.
    static func categorize(_ parsed: ParsedLogLine, bundleId: String?, processName: String?) -> Set<String> {
        var topics = Set<String>()

        // app: subsystem matches bundleId OR process matches processName
        if let bid = bundleId, let sub = parsed.subsystem, sub == bid {
            topics.insert("app")
        }
        if let pname = processName, parsed.processName == pname {
            topics.insert("app")
        }

        // crashes: fault level
        if parsed.logType == "Df" {
            topics.insert("crashes")
        }

        // Process-based topics (O(1) lookup)
        if let topic = processTopics[parsed.processName] {
            topics.insert(topic)
        }

        // Subsystem-prefix-based topics
        if let sub = parsed.subsystem {
            if sub.hasPrefix("com.apple.runningboard") {
                topics.insert("lifecycle")
            }
            if sub.hasPrefix("com.apple.xpc.activity") {
                topics.insert("background")
            }
        }

        // system fallback: if no other topic matched
        if topics.isEmpty {
            topics.insert("system")
        }

        return topics
    }

    // MARK: - Topic filtering

    /// All known topic names in display order
    static let allTopics = ["app", "crashes", "network", "lifecycle", "springboard", "widgets", "background", "system"]

    /// Topic descriptions for LLM hint
    static let topicHints: [String: String] = [
        "network": "SSL/TLS + background transfers",
        "lifecycle": "app kills, Jetsam, memory pressure",
        "springboard": "push notifications, app state",
        "widgets": "WidgetKit timeline, refresh budget",
        "background": "BGTaskScheduler, background fetch",
        "system": "WARNING: high volume, system internals",
    ]

    struct TopicFilterResult {
        let filteredLines: [String]
        let topicCounts: [String: Int]
        let totalLines: Int
    }

    /// Single-pass filter: categorize each line, count topics, collect matching lines.
    static func filterByTopics(
        lines: [String],
        include: Set<String>,
        bundleId: String?,
        processName: String?
    ) -> TopicFilterResult {
        var counts: [String: Int] = [:]
        for t in allTopics { counts[t] = 0 }

        var filtered: [String] = []
        var lastTopics: Set<String> = []

        for line in lines {
            let topics: Set<String>

            if line.hasPrefix("  ") {
                // Dedup line ("  ... repeated Nx") — inherits previous line's topics
                topics = lastTopics
            } else if let parsed = parseLine(line) {
                topics = categorize(parsed, bundleId: bundleId, processName: processName)
                lastTopics = topics
            } else {
                continue // header or unparseable
            }

            // Update counts
            for t in topics {
                counts[t, default: 0] += 1
            }

            // Include if any topic matches
            if !topics.isDisjoint(with: include) {
                filtered.append(line)
            }
        }

        return TopicFilterResult(filteredLines: filtered, topicCounts: counts, totalLines: lines.count)
    }

    /// Build the topic summary header for read_logs response.
    static func buildTopicSummary(
        result: TopicFilterResult,
        include: Set<String>,
        captureMode: String,
        bundleId: String?
    ) -> String {
        let shownTopics = include.sorted().joined(separator: ", ")
        var lines: [String] = []

        lines.append("--- \(result.totalLines) buffered, \(result.filteredLines.count) shown [\(shownTopics)] ---")

        // Topic counts: active first, then available
        let active = allTopics.filter { include.contains($0) }
            .map { "\($0)(\(result.topicCounts[$0] ?? 0))" }
        let available = allTopics.filter { !include.contains($0) }
            .map { "\($0)(\(result.topicCounts[$0] ?? 0))" }
        lines.append("Topics: \(active.joined(separator: " ")) | \(available.joined(separator: " "))")

        // Hint for hidden topics with lines
        let hiddenWithLines = allTopics.filter { !include.contains($0) && (result.topicCounts[$0] ?? 0) > 0 }
        if !hiddenWithLines.isEmpty {
            let hintTopics = hiddenWithLines.prefix(3).map { topic in
                if let desc = topicHints[topic] { return "\(topic) (\(desc))" }
                return topic
            }
            lines.append("Hint: include=[\(hiddenWithLines.prefix(3).map { "\"\($0)\"" }.joined(separator: ","))] to add \(hintTopics.joined(separator: ", ")) logs")
        }

        // Warning: capture mode mismatch
        if captureMode == "app" && include.count > 2 {
            lines.append("WARNING: capture mode is 'app' — only app logs are in the stream. Use start_log_capture mode='smart' for topic filtering.")
        }

        // Warning: no bundleId
        if bundleId == nil {
            lines.append("Note: no bundleId in session — 'app' topic may be empty. Run build_sim first.")
        }

        lines.append("---")
        return lines.joined(separator: "\n")
    }

    // MARK: - Process name derivation

    /// Derive the executable name from an .app bundle's Info.plist (CFBundleExecutable).
    /// Uses PropertyListSerialization, no shell call needed.
    static func deriveProcessName(from appPath: String) -> String? {
        let plistPath = appPath.hasSuffix("/")
            ? "\(appPath)Info.plist" : "\(appPath)/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any],
              let execName = plist["CFBundleExecutable"] as? String
        else { return nil }
        return execName
    }

    // MARK: - Predicate builder

    /// Build the complete `xcrun simctl spawn ... log stream` argument array.
    /// Returns (args, note) where note describes what filtering was applied.
    static func buildLogArgs(
        simulator: String,
        mode: String,
        level: String,
        process: String?,
        subsystem: String?,
        predicate: String?
    ) async -> (args: [String], note: String) {
        var args = ["simctl", "spawn", simulator, "log", "stream", "--style", "compact", "--level", level]

        // Explicit overrides bypass mode logic entirely (backward compatible)
        if subsystem != nil || predicate != nil {
            var predicateParts: [String] = []
            if let sub = subsystem {
                let sanitized = sub.replacingOccurrences(of: "'", with: "\\'")
                predicateParts.append("subsystem == '\(sanitized)'")
            }
            if let pred = predicate {
                predicateParts.append(pred)
            }
            if !predicateParts.isEmpty {
                args += ["--predicate", predicateParts.joined(separator: " AND ")]
            }
            if let proc = process {
                args += ["--process", proc]
            }
            return (args, "mode: override (explicit subsystem/predicate)")
        }

        // Explicit --process flag (most efficient, server-side in logd)
        if let proc = process {
            args += ["--process", proc]
            return (args, "mode: process filter '\(proc)' (server-side, --process flag)")
        }

        switch mode {
        case "app":
            // Auto-detect from SessionState
            let bundleId = await SessionState.shared.bundleId
            let appPath = await SessionState.shared.appPath
            let processName = appPath.flatMap { deriveProcessName(from: $0) }

            if let bid = bundleId, let pname = processName {
                // Best case: filter by subsystem (os_log) OR process (print/NSLog) + fault passthrough
                let safeBid = bid.replacingOccurrences(of: "'", with: "\\'")
                let safePname = pname.replacingOccurrences(of: "'", with: "\\'")
                let pred = "(subsystem == '\(safeBid)' OR process == '\(safePname)') OR logType == \"fault\""
                args += ["--predicate", pred]
                return (args, "mode: app (subsystem: \(bid), process: \(pname), +faults)")
            } else if let bid = bundleId {
                // Only bundleId available — subsystem filter + fault passthrough
                let safeBid = bid.replacingOccurrences(of: "'", with: "\\'")
                let pred = "subsystem == '\(safeBid)' OR logType == \"fault\""
                args += ["--predicate", pred]
                return (args, "mode: app (subsystem: \(bid), +faults)")
            } else {
                // No session state — fall back to smart mode
                Log.warn("app mode requested but no bundleId in session — falling back to smart mode")
                let pred = smartModePredicate()
                args += ["--predicate", pred]
                return (args, "mode: smart (fallback — no bundleId, run build_sim first for app mode)")
            }

        case "verbose":
            return (args, "mode: verbose (no filter, all system logs)")

        default: // "smart"
            let pred = smartModePredicate()
            args += ["--predicate", pred]
            return (args, "mode: smart (noise blacklist: \(noiseProcesses.count) processes excluded)")
        }
    }

    /// Build the NOT predicate that excludes known noise processes, subsystems, and categories.
    static func smartModePredicate() -> String {
        var exclusions = noiseProcesses.map { "process == '\($0)'" }
        exclusions += noiseSubsystems.map { "subsystem == '\($0)'" }
        exclusions += noiseSubsystemCategories.map {
            "(subsystem == '\($0.subsystem)' AND category == '\($0.category)')"
        }
        return "NOT (\(exclusions.joined(separator: " OR ")))"
    }

    // MARK: - Tool definitions

    static let tools: [Tool] = [
        Tool(
            name: "start_log_capture",
            description: """
                Start capturing real-time logs from a simulator with smart filtering. \
                Modes: 'smart' (default) — system-wide minus known noise, enables topic filtering in read_logs. \
                'app' — only your app's logs + crashes (tight stream, but limits topic filtering). \
                'verbose' — unfiltered, all system logs. \
                Override: set 'subsystem' or 'predicate' to bypass mode logic entirely. \
                Deduplicates consecutive identical log lines automatically.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name or UDID. Auto-detected from booted simulator if omitted.")]),
                    "mode": .object([
                        "type": .string("string"),
                        "description": .string("Filter mode. 'app': only app logs + crashes (needs prior build_sim). 'smart': all logs minus noise. 'verbose': unfiltered."),
                        "enum": .array([.string("app"), .string("smart"), .string("verbose")]),
                    ]),
                    "process": .object(["type": .string("string"), "description": .string("Filter by process name (uses efficient --process flag, server-side in logd). Bypasses mode logic.")]),
                    "subsystem": .object(["type": .string("string"), "description": .string("Filter by subsystem, e.g. 'com.myapp'. Bypasses mode logic.")]),
                    "predicate": .object(["type": .string("string"), "description": .string("Custom NSPredicate filter. Bypasses mode logic.")]),
                    "level": .object(["type": .string("string"), "description": .string("Log level: default, info, debug. Default: debug")]),
                ]),
            ])
        ),
        Tool(
            name: "stop_log_capture",
            description: "Stop the running log capture.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        Tool(
            name: "read_logs",
            description: """
                Read captured log lines with topic-based filtering. \
                Default shows only app logs + crashes. Response includes a topic menu with line counts — \
                add topics via 'include' to see more (e.g. network for SSL, lifecycle for Jetsam). \
                Topics reset each call (stateless). Consecutive identical lines are auto-deduplicated.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "include": .object([
                        "type": .string("array"),
                        "description": .string("Topics to add: network, lifecycle, springboard, widgets, background, system. Default: app + crashes only."),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "last": .object(["type": .string("number"), "description": .string("Only return last N lines (applied after topic filtering)")]),
                    "clear": .object(["type": .string("boolean"), "description": .string("Clear buffer after reading. Default: false")]),
                ]),
            ])
        ),
        Tool(
            name: "wait_for_log",
            description: """
                Wait for a specific log pattern to appear in the log stream. \
                Starts log capture if not already running (uses 'smart' mode for broad visibility). \
                Returns the matching line(s). \
                Eliminates the need for sleep() hacks when waiting for app state changes.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object(["type": .string("string"), "description": .string("Regex pattern to match in log lines")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Max seconds to wait. Default: 30")]),
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name or UDID. Auto-detected if omitted (used if log capture not running).")]),
                    "subsystem": .object(["type": .string("string"), "description": .string("Filter by subsystem (used if log capture not running)")]),
                ]),
                "required": .array([.string("pattern")]),
            ])
        ),
    ]

    // MARK: - Registration

    static let registrations: [ToolRegistration] = tools.compactMap { tool in
        let handler: (@Sendable ([String: Value]?) async -> CallTool.Result)? = switch tool.name {
        case "start_log_capture": startLogCapture
        case "stop_log_capture": stopLogCapture
        case "read_logs": readLogs
        case "wait_for_log": waitForLog
        default: nil
        }
        guard let h = handler else { return nil }
        return ToolRegistration(tool: tool, handler: h)
    }

    // MARK: - Handlers

    static func startLogCapture(_ args: [String: Value]?) async -> CallTool.Result {
        let sim: String
        do {
            sim = try await SessionState.shared.resolveSimulator(args?["simulator"]?.stringValue)
        } catch {
            return .fail("\(error)")
        }
        let mode = args?["mode"]?.stringValue ?? "smart"
        let process = args?["process"]?.stringValue
        let subsystem = args?["subsystem"]?.stringValue
        let predicate = args?["predicate"]?.stringValue
        let level = args?["level"]?.stringValue ?? "debug"

        // Pro gate: app mode requires Pro
        if mode == "app", !(await LicenseManager.shared.isPro) {
            return .fail(
                "\"mode: app\" is a [PRO] feature.\n"
                + "Captures only your app's logs + crashes — tight stream, zero noise.\n"
                + "Free: 'smart' mode (default) or 'verbose'.\n\n"
                + "Level up here → \(LicenseManager.upgradeURL)\n"
                + "Then: silbercueswift activate <YOUR-KEY>")
        }

        let (logArgs, note) = await buildLogArgs(
            simulator: sim, mode: mode, level: level,
            process: process, subsystem: subsystem, predicate: predicate
        )

        do {
            try await LogCapture.shared.start(arguments: logArgs, mode: mode)
            return .ok("Log capture started (\(note))")
        } catch {
            return .fail("Failed to start log capture: \(error)")
        }
    }

    static func stopLogCapture(_ args: [String: Value]?) async -> CallTool.Result {
        await LogCapture.shared.stop()
        return .ok("Log capture stopped")
    }

    static func readLogs(_ args: [String: Value]?) async -> CallTool.Result {
        let last = args?["last"]?.intValue
        let clear = args?["clear"]?.boolValue ?? false

        // Parse include topics — support array or single string (LLM error tolerance)
        var includeTopics: Set<String> = ["app", "crashes"]
        if let arr = args?["include"]?.arrayValue {
            for v in arr {
                if let s = v.stringValue { includeTopics.insert(s) }
            }
        } else if let single = args?["include"]?.stringValue {
            includeTopics.insert(single)
        }

        let isRunning = await LogCapture.shared.isRunning
        let captureMode = await LogCapture.shared.captureMode
        let allLines: [String]
        if clear {
            allLines = await LogCapture.shared.readAndClear()
        } else {
            allLines = await LogCapture.shared.read(last: nil) // read all for filtering
        }

        if allLines.isEmpty {
            return .ok("No log lines captured" + (isRunning ? " (capture is running)" : " (capture not running)"))
        }

        // Pro gate: custom topic filtering requires Pro
        let requestedCustomTopics = includeTopics.subtracting(["app", "crashes"])
        if !requestedCustomTopics.isEmpty, !(await LicenseManager.shared.isPro) {
            let topics = requestedCustomTopics.sorted().joined(separator: ", ")
            return .fail(
                "Topic filtering is a [PRO] feature.\n"
                + "Shows only what matters — \(topics) — on demand.\n"
                + "Free: app + crashes (already 90% noise-free).\n\n"
                + "Level up here → \(LicenseManager.upgradeURL)\n"
                + "Then: silbercueswift activate <YOUR-KEY>")
        }

        // Get session info for topic categorization
        let bundleId = await SessionState.shared.bundleId
        let appPath = await SessionState.shared.appPath
        let processName = appPath.flatMap { deriveProcessName(from: $0) }

        // Filter by topics
        let filterResult = filterByTopics(
            lines: allLines, include: includeTopics,
            bundleId: bundleId, processName: processName
        )

        // Apply `last` AFTER filtering
        let finalLines: [String]
        if let n = last {
            finalLines = Array(filterResult.filteredLines.suffix(n))
        } else {
            finalLines = filterResult.filteredLines
        }

        // Build summary header
        let summary = buildTopicSummary(
            result: filterResult, include: includeTopics,
            captureMode: captureMode, bundleId: bundleId
        )

        let output = finalLines.joined(separator: "\n")
        let truncated = output.count > 50000 ? String(output.prefix(50000)) + "\n... [truncated]" : output
        return .ok("\(summary)\n\(truncated)")
    }

    static func waitForLog(_ args: [String: Value]?) async -> CallTool.Result {
        guard let pattern = args?["pattern"]?.stringValue else {
            return .fail("Missing required: pattern")
        }

        let timeout = args?["timeout"]?.numberValue ?? 30.0
        let subsystem = args?["subsystem"]?.stringValue
        let simulator: String
        do {
            simulator = try await SessionState.shared.resolveSimulator(args?["simulator"]?.stringValue)
        } catch {
            return .fail("\(error)")
        }

        // Compile regex
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return .fail("Invalid regex pattern: \(pattern)")
        }

        // Start log capture if not running — use smart mode for broad visibility
        let wasRunning = await LogCapture.shared.isRunning
        if !wasRunning {
            let (logArgs, _) = await buildLogArgs(
                simulator: simulator, mode: "smart", level: "debug",
                process: nil, subsystem: subsystem, predicate: nil
            )
            do {
                try await LogCapture.shared.start(arguments: logArgs)
            } catch {
                return .fail("Failed to start log capture: \(error)")
            }
        }

        // Clear existing buffer to only match new lines
        _ = await LogCapture.shared.readAndClear()

        let startTime = CFAbsoluteTimeGetCurrent()
        let deadline = startTime + timeout
        var matchedLines: [String] = []

        // Poll for matches
        while CFAbsoluteTimeGetCurrent() < deadline {
            let lines = await LogCapture.shared.readAndClear()
            for line in lines {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    matchedLines.append(line)
                }
            }

            if !matchedLines.isEmpty {
                let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - startTime)
                let output = matchedLines.joined(separator: "\n")
                let truncated = output.count > 10000 ? String(output.prefix(10000)) + "\n... [truncated]" : output
                return .ok("Pattern matched after \(elapsed)s (\(matchedLines.count) line(s)):\n\(truncated)")
            }

            // Sleep briefly before next poll
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - startTime)
        return .fail("Timeout after \(elapsed)s — pattern '\(pattern)' not found")
    }
}
