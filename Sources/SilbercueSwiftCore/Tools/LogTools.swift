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

    func start(arguments: [String]) throws {
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
        "proactiveeventtrackerd", "locationd", "mediaanalysisd",
        "apsd", "cfprefsd", "pairedsyncd", "mDNSResponder",
        "backboardd", "DTServiceHub", "geod", "itunesstored",
    ]

    // MARK: - Process name derivation

    /// Derive the executable name from an .app bundle's Info.plist (CFBundleExecutable).
    /// Pattern from MultiDeviceTools.swift — uses PropertyListSerialization, no shell call needed.
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
                predicateParts.append("subsystem == '\(sub)'")
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
                let pred = "(subsystem == '\(bid)' OR process == '\(pname)') OR logType == \"fault\""
                args += ["--predicate", pred]
                return (args, "mode: app (subsystem: \(bid), process: \(pname), +faults)")
            } else if let bid = bundleId {
                // Only bundleId available — subsystem filter + fault passthrough
                let pred = "subsystem == '\(bid)' OR logType == \"fault\""
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

    /// Build the NOT predicate that excludes known noise processes.
    static func smartModePredicate() -> String {
        let exclusions = noiseProcesses.map { "process == '\($0)'" }.joined(separator: " OR ")
        return "NOT (\(exclusions))"
    }

    // MARK: - Tool definitions

    static let tools: [Tool] = [
        Tool(
            name: "start_log_capture",
            description: """
                Start capturing real-time logs from a simulator with smart filtering. \
                Modes: 'app' (default) — only your app's logs + crashes, auto-detected from last build. \
                'smart' — system-wide minus known noise (locationd, proactiveeventtrackerd, etc.). \
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
                Read captured log lines. Consecutive identical lines are auto-deduplicated \
                (shown as '... repeated Nx'). Optionally get only the last N lines or clear after reading.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "last": .object(["type": .string("number"), "description": .string("Only return last N lines")]),
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

    // MARK: - Handlers

    static func startLogCapture(_ args: [String: Value]?) async -> CallTool.Result {
        let sim: String
        do {
            sim = try await SessionState.shared.resolveSimulator(args?["simulator"]?.stringValue)
        } catch {
            return .fail("\(error)")
        }
        let mode = args?["mode"]?.stringValue ?? "app"
        let process = args?["process"]?.stringValue
        let subsystem = args?["subsystem"]?.stringValue
        let predicate = args?["predicate"]?.stringValue
        let level = args?["level"]?.stringValue ?? "debug"

        let (logArgs, note) = await buildLogArgs(
            simulator: sim, mode: mode, level: level,
            process: process, subsystem: subsystem, predicate: predicate
        )

        do {
            try await LogCapture.shared.start(arguments: logArgs)
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

        let isRunning = await LogCapture.shared.isRunning
        let lines: [String]
        if clear {
            lines = await LogCapture.shared.readAndClear()
        } else {
            lines = await LogCapture.shared.read(last: last)
        }

        if lines.isEmpty {
            return .ok("No log lines captured" + (isRunning ? " (capture is running)" : " (capture not running)"))
        }

        let output = lines.joined(separator: "\n")
        let truncated = output.count > 50000 ? String(output.prefix(50000)) + "\n... [truncated]" : output
        return .ok("\(lines.count) log lines\(clear ? " (buffer cleared)" : ""):\n\(truncated)")
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
