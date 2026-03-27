import Foundation
import MCP

enum TestTools {
    static let tools: [Tool] = [
        Tool(
            name: "test_sim",
            description: """
                Run xcodebuild test on simulator and return structured xcresult summary. \
                Shows passed/failed/skipped/expected-failure counts and duration. \
                Much more useful than raw xcodebuild log output.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object(["type": .string("string"), "description": .string("Path to .xcodeproj or .xcworkspace")]),
                    "scheme": .object(["type": .string("string"), "description": .string("Xcode scheme name")]),
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name, e.g. 'iPhone 16'. Default: iPhone 16")]),
                    "configuration": .object(["type": .string("string"), "description": .string("Build configuration (Debug/Release). Default: Debug")]),
                    "testplan": .object(["type": .string("string"), "description": .string("Test plan name (optional)")]),
                    "filter": .object(["type": .string("string"), "description": .string("Test filter, e.g. 'MyTests/testFoo' or 'MyTests' (optional)")]),
                    "coverage": .object(["type": .string("boolean"), "description": .string("Enable code coverage collection. Default: false")]),
                ]),
                "required": .array([.string("project"), .string("scheme")]),
            ])
        ),
        Tool(
            name: "test_failures",
            description: """
                Get only failed tests with their error messages from an xcresult bundle. \
                Either provide an xcresult_path from a previous test_sim run, \
                or provide project/scheme to run tests first. \
                Returns test name + failure message for each failed test.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "xcresult_path": .object(["type": .string("string"), "description": .string("Path to existing .xcresult bundle. If provided, skips running tests.")]),
                    "project": .object(["type": .string("string"), "description": .string("Path to .xcodeproj or .xcworkspace (used if xcresult_path not provided)")]),
                    "scheme": .object(["type": .string("string"), "description": .string("Xcode scheme name (used if xcresult_path not provided)")]),
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name. Default: iPhone 16")]),
                    "include_console": .object(["type": .string("boolean"), "description": .string("Include console output (print/NSLog) for each failed test. Default: false. Use when assertion message alone is not enough to diagnose the failure.")]),
                ]),
            ])
        ),
        Tool(
            name: "test_coverage",
            description: """
                Get code coverage report per file from an xcresult bundle. \
                Either provide xcresult_path or project/scheme (will run tests with coverage enabled). \
                Returns file paths with line coverage percentage, sorted by coverage ascending.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "xcresult_path": .object(["type": .string("string"), "description": .string("Path to existing .xcresult bundle (must have been built with coverage enabled)")]),
                    "project": .object(["type": .string("string"), "description": .string("Path to .xcodeproj or .xcworkspace")]),
                    "scheme": .object(["type": .string("string"), "description": .string("Xcode scheme name")]),
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name. Default: iPhone 16")]),
                    "min_coverage": .object(["type": .string("number"), "description": .string("Only show files below this coverage %. Default: 100 (show all)")]),
                ]),
            ])
        ),
        Tool(
            name: "build_and_diagnose",
            description: """
                Build an iOS app and extract structured errors/warnings from the xcresult bundle. \
                Returns only actionable diagnostics (errors, warnings) with file paths and line numbers. \
                Much more useful than raw xcodebuild output for diagnosing build failures.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object(["type": .string("string"), "description": .string("Path to .xcodeproj or .xcworkspace")]),
                    "scheme": .object(["type": .string("string"), "description": .string("Xcode scheme name")]),
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name. Default: iPhone 16")]),
                    "configuration": .object(["type": .string("string"), "description": .string("Build configuration (Debug/Release). Default: Debug")]),
                ]),
                "required": .array([.string("project"), .string("scheme")]),
            ])
        ),
    ]

    // MARK: - Shared helpers

    /// Generate a unique xcresult path
    private static func xcresultPath(prefix: String) -> String {
        let ts = Int(Date().timeIntervalSince1970)
        return "/tmp/ss-\(prefix)-\(ts).xcresult"
    }

    /// Build xcodebuild arguments common to build/test.
    /// Resolves simulator name to UDID for reliable destination matching
    /// (names with special chars like "iPad Pro 13-inch (M4)" fail with name= destinations).
    private static func xcodebuildBaseArgs(
        project: String, scheme: String, simulator: String, configuration: String
    ) async -> [String] {
        let isWorkspace = project.hasSuffix(".xcworkspace")
        let projectFlag = isWorkspace ? "-workspace" : "-project"

        // Resolve destination: UDID > booted UDID > name fallback
        let destination: String
        if isUDID(simulator) {
            destination = "platform=iOS Simulator,id=\(simulator)"
        } else if simulator == "booted" {
            if let udid = await resolveBootedUDID() {
                destination = "platform=iOS Simulator,id=\(udid)"
            } else {
                destination = "platform=iOS Simulator,name=\(simulator)"
            }
        } else if let udid = await resolveSimulatorUDID(name: simulator) {
            destination = "platform=iOS Simulator,id=\(udid)"
        } else {
            destination = "platform=iOS Simulator,name=\(simulator)"
        }

        return [
            projectFlag, project,
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", destination,
            "-skipMacroValidation",
        ]
    }

    // MARK: - Simulator Resolution (shared with BuildTools)

    private static func isUDID(_ s: String) -> Bool {
        let pattern = #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#
        return s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func resolveSimulatorUDID(name: String) async -> String? {
        guard let result = try? await Shell.xcrun("simctl", "list", "devices", "-j"),
              result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else {
            return nil
        }

        let nameLower = name.lowercased()
        var exactMatch: String?
        var caseInsensitiveMatch: String?
        var containsMatch: String?
        var bootedContainsMatch: String?

        for (_, deviceList) in devices {
            for device in deviceList {
                guard let deviceName = device["name"] as? String,
                      let udid = device["udid"] as? String else { continue }
                let isAvailable = device["isAvailable"] as? Bool ?? false
                let isBooted = (device["state"] as? String) == "Booted"
                guard isAvailable || isBooted else { continue }

                if deviceName == name {
                    exactMatch = udid
                } else if exactMatch == nil && deviceName.lowercased() == nameLower {
                    caseInsensitiveMatch = udid
                } else if deviceName.lowercased().contains(nameLower) {
                    if isBooted { bootedContainsMatch = udid }
                    else if containsMatch == nil { containsMatch = udid }
                }
            }
        }
        return exactMatch ?? caseInsensitiveMatch ?? bootedContainsMatch ?? containsMatch
    }

    private static func resolveBootedUDID() async -> String? {
        guard let result = try? await Shell.xcrun("simctl", "list", "devices", "booted", "-j"),
              result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else {
            return nil
        }
        for (_, deviceList) in devices {
            for device in deviceList {
                if let state = device["state"] as? String, state == "Booted",
                   let udid = device["udid"] as? String {
                    return udid
                }
            }
        }
        return nil
    }

    /// Run xcodebuild test and return the xcresult path
    private static func runTests(
        project: String, scheme: String, simulator: String,
        configuration: String, testplan: String?, filter: String?,
        coverage: Bool, resultPath: String
    ) async throws -> (ShellResult, String) {
        // Remove old xcresult if exists
        _ = try? await Shell.run("/bin/rm", arguments: ["-rf", resultPath])

        var args = await xcodebuildBaseArgs(
            project: project, scheme: scheme,
            simulator: simulator, configuration: configuration
        )
        args += ["-resultBundlePath", resultPath]

        if coverage {
            args += ["-enableCodeCoverage", "YES"]
        }

        if let plan = testplan {
            args += ["-testPlan", plan]
        }

        if let f = filter {
            args += ["-only-testing", f]
        }

        args += ["test"]

        let result = try await Shell.run(
            "/usr/bin/xcodebuild", arguments: args, timeout: 600
        )
        return (result, resultPath)
    }

    /// Run xcodebuild build and return the xcresult path
    private static func runBuild(
        project: String, scheme: String, simulator: String,
        configuration: String, resultPath: String
    ) async throws -> (ShellResult, String) {
        _ = try? await Shell.run("/bin/rm", arguments: ["-rf", resultPath])

        var args = await xcodebuildBaseArgs(
            project: project, scheme: scheme,
            simulator: simulator, configuration: configuration
        )
        args += [
            "-parallelizeTargets",
            "-resultBundlePath", resultPath,
            "build",
        ]
        args += ["COMPILATION_CACHE_ENABLE_CACHING=YES"]

        let result = try await Shell.run(
            "/usr/bin/xcodebuild", arguments: args, timeout: 600
        )
        return (result, resultPath)
    }

    /// Parse xcresult test summary JSON
    private static func parseTestSummary(_ path: String) async -> String? {
        guard let result = try? await Shell.run(
            "/usr/bin/xcrun",
            arguments: ["xcresulttool", "get", "test-results", "summary", "--path", path, "--compact"]
        ), result.succeeded else { return nil }
        return result.stdout
    }

    /// Parse xcresult test details JSON
    private static func parseTestDetails(_ path: String) async -> String? {
        guard let result = try? await Shell.run(
            "/usr/bin/xcrun",
            arguments: ["xcresulttool", "get", "test-results", "tests", "--path", path, "--compact"]
        ), result.succeeded else { return nil }
        return result.stdout
    }

    /// Parse xcresult build results JSON
    private static func parseBuildResults(_ path: String) async -> String? {
        guard let result = try? await Shell.run(
            "/usr/bin/xcrun",
            arguments: ["xcresulttool", "get", "build-results", "--path", path, "--compact"]
        ), result.succeeded else { return nil }
        return result.stdout
    }

    /// Export failure attachments (screenshots) from xcresult
    /// Returns array of (testId, filePath) tuples for exported images
    private static func exportFailureAttachments(_ xcresultPath: String) async -> [(test: String, path: String)] {
        let outputDir = "/tmp/ss-attachments-\(Int(Date().timeIntervalSince1970))"
        guard let _ = try? await Shell.run("/bin/mkdir", arguments: ["-p", outputDir]),
              let result = try? await Shell.run(
                  "/usr/bin/xcrun",
                  arguments: [
                      "xcresulttool", "export", "attachments",
                      "--path", xcresultPath,
                      "--output-path", outputDir,
                      "--only-failures",
                  ]
              ), result.succeeded else {
            return []
        }

        // Parse manifest.json for exported files
        guard let manifestResult = try? await Shell.run("/bin/cat", arguments: ["\(outputDir)/manifest.json"]),
              let data = manifestResult.stdout.data(using: .utf8),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var attachments: [(test: String, path: String)] = []
        for entry in manifest {
            let testName = (entry["testIdentifier"] as? String) ?? (entry["testName"] as? String) ?? "?"
            if let fileName = entry["exportedFileName"] as? String {
                let filePath = "\(outputDir)/\(fileName)"
                attachments.append((test: testName, path: filePath))
            } else if let files = entry["attachments"] as? [[String: Any]] {
                for file in files {
                    if let fileName = file["exportedFileName"] as? String {
                        let filePath = "\(outputDir)/\(fileName)"
                        attachments.append((test: testName, path: filePath))
                    }
                }
            }
        }
        return attachments
    }

    /// Extract console output per failed test from xcresult action log
    /// Returns dict: testName → emittedOutput
    private static func extractFailedTestConsole(_ xcresultPath: String) async -> [String: String] {
        guard let result = try? await Shell.run(
            "/usr/bin/xcrun",
            arguments: ["xcresulttool", "get", "log", "--path", xcresultPath, "--type", "action", "--compact"]
        ), result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var consoleByTest: [String: String] = [:]

        // Recursively find test case subsections with testDetails.emittedOutput
        func findTestOutput(in node: [String: Any]) {
            if let testDetails = node["testDetails"] as? [String: Any],
               let testName = testDetails["testName"] as? String,
               let emitted = testDetails["emittedOutput"] as? String {
                // Only keep if it looks like a failure
                if emitted.contains("failed") || emitted.contains("issue") {
                    // Trim to just the useful parts (skip "Test started" boilerplate)
                    let lines = emitted.split(separator: "\n", omittingEmptySubsequences: false)
                    let useful = lines.filter { !$0.hasPrefix("◇ Test") && !$0.isEmpty }
                    if !useful.isEmpty {
                        consoleByTest[testName] = useful.joined(separator: "\n")
                    }
                }
            }

            if let subsections = node["subsections"] as? [[String: Any]] {
                for sub in subsections {
                    findTestOutput(in: sub)
                }
            }
        }

        findTestOutput(in: json)
        return consoleByTest
    }

    /// Parse coverage report via xccov
    private static func parseCoverage(_ path: String) async -> String? {
        guard let result = try? await Shell.run(
            "/usr/bin/xcrun",
            arguments: ["xccov", "view", "--report", "--json", path]
        ), result.succeeded else { return nil }
        return result.stdout
    }

    // MARK: - Tool Implementations

    static func testSim(_ args: [String: Value]?) async -> CallTool.Result {
        guard let project = args?["project"]?.stringValue,
              let scheme = args?["scheme"]?.stringValue else {
            return .fail("Missing required: project, scheme")
        }

        let simulator = args?["simulator"]?.stringValue ?? "iPhone 16"
        let configuration = args?["configuration"]?.stringValue ?? "Debug"
        let testplan = args?["testplan"]?.stringValue
        let filter = args?["filter"]?.stringValue
        let coverage = args?["coverage"]?.boolValue ?? false
        let resultPath = xcresultPath(prefix: "test")

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (buildResult, path) = try await runTests(
                project: project, scheme: scheme, simulator: simulator,
                configuration: configuration, testplan: testplan,
                filter: filter, coverage: coverage, resultPath: resultPath
            )
            let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)

            // Parse xcresult summary
            if let summaryJSON = await parseTestSummary(path),
               let data = summaryJSON.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var summary = formatTestSummary(json, elapsed: elapsed, xcresultPath: path)

                // If tests failed, export failure screenshots
                let result = (json["result"] as? String) ?? ""
                if result == "Failed" {
                    let attachments = await exportFailureAttachments(path)
                    if !attachments.isEmpty {
                        summary += "\n\nFailure screenshots (\(attachments.count)):"
                        for att in attachments {
                            summary += "\n  \(att.path)"
                        }
                    }
                }

                let hasFailures = (json["failedTests"] as? Int ?? 0) > 0
                return hasFailures ? .fail(summary) : .ok(summary)
            }

            // Fallback: no xcresult parseable
            if buildResult.succeeded {
                return .ok("Tests passed in \(elapsed)s (xcresult parse failed)\nxcresult: \(path)")
            } else {
                let errorLines = buildResult.stderr.split(separator: "\n")
                    .filter { $0.contains("error:") || $0.contains("failed") }
                    .prefix(20)
                    .joined(separator: "\n")
                return .fail("Tests FAILED in \(elapsed)s\n\(errorLines)\nxcresult: \(path)")
            }
        } catch {
            return .fail("Test error: \(error)")
        }
    }

    static func testFailures(_ args: [String: Value]?) async -> CallTool.Result {
        let xcresultPath: String

        if let provided = args?["xcresult_path"]?.stringValue {
            xcresultPath = provided
        } else {
            guard let project = args?["project"]?.stringValue,
                  let scheme = args?["scheme"]?.stringValue else {
                return .fail("Missing required: xcresult_path OR (project + scheme)")
            }
            let simulator = args?["simulator"]?.stringValue ?? "iPhone 16"
            let path = Self.xcresultPath(prefix: "fail")

            do {
                let (_, p) = try await runTests(
                    project: project, scheme: scheme, simulator: simulator,
                    configuration: "Debug", testplan: nil, filter: nil,
                    coverage: false, resultPath: path
                )
                xcresultPath = p
            } catch {
                return .fail("Test run error: \(error)")
            }
        }

        let includeConsole = args?["include_console"]?.boolValue ?? false

        // Parse test details and extract failures
        guard let detailsJSON = await parseTestDetails(xcresultPath),
              let data = detailsJSON.data(using: .utf8) else {
            return .fail("Failed to parse xcresult at \(xcresultPath)")
        }

        // Export failure screenshots if available
        let attachments = await exportFailureAttachments(xcresultPath)

        // Extract console output per failed test if requested
        let consoleByTest = includeConsole ? await extractFailedTestConsole(xcresultPath) : [:]

        return formatTestFailures(data, xcresultPath: xcresultPath, attachments: attachments, consoleByTest: consoleByTest)
    }

    static func testCoverage(_ args: [String: Value]?) async -> CallTool.Result {
        let xcresultPath: String

        if let provided = args?["xcresult_path"]?.stringValue {
            xcresultPath = provided
        } else {
            guard let project = args?["project"]?.stringValue,
                  let scheme = args?["scheme"]?.stringValue else {
                return .fail("Missing required: xcresult_path OR (project + scheme)")
            }
            let simulator = args?["simulator"]?.stringValue ?? "iPhone 16"
            let path = Self.xcresultPath(prefix: "cov")

            do {
                let (_, p) = try await runTests(
                    project: project, scheme: scheme, simulator: simulator,
                    configuration: "Debug", testplan: nil, filter: nil,
                    coverage: true, resultPath: path
                )
                xcresultPath = p
            } catch {
                return .fail("Test run error: \(error)")
            }
        }

        let minCoverage = args?["min_coverage"]?.numberValue ?? 100.0

        guard let coverageJSON = await parseCoverage(xcresultPath),
              let data = coverageJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .fail("Failed to parse coverage from \(xcresultPath). Was coverage enabled during the test run?")
        }

        return formatCoverageReport(json, minCoverage: minCoverage, xcresultPath: xcresultPath)
    }

    static func buildAndDiagnose(_ args: [String: Value]?) async -> CallTool.Result {
        guard let project = args?["project"]?.stringValue,
              let scheme = args?["scheme"]?.stringValue else {
            return .fail("Missing required: project, scheme")
        }

        let simulator = args?["simulator"]?.stringValue ?? "iPhone 16"
        let configuration = args?["configuration"]?.stringValue ?? "Debug"
        let resultPath = xcresultPath(prefix: "build")

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (buildResult, path) = try await runBuild(
                project: project, scheme: scheme, simulator: simulator,
                configuration: configuration, resultPath: resultPath
            )
            let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)

            // Parse build results from xcresult
            if let buildJSON = await parseBuildResults(path),
               let data = buildJSON.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return formatBuildDiagnosis(json, succeeded: buildResult.succeeded, elapsed: elapsed, xcresultPath: path)
            }

            // Fallback
            if buildResult.succeeded {
                return .ok("Build succeeded in \(elapsed)s (no diagnostics)\nxcresult: \(path)")
            } else {
                let errorLines = buildResult.stderr.split(separator: "\n")
                    .filter { $0.contains("error:") }
                    .prefix(20)
                    .joined(separator: "\n")
                return .fail("Build FAILED in \(elapsed)s\n\(errorLines)\nxcresult: \(path)")
            }
        } catch {
            return .fail("Build error: \(error)")
        }
    }

    // MARK: - Formatting helpers

    private static func formatTestSummary(_ json: [String: Any], elapsed: String, xcresultPath: String) -> String {
        var lines: [String] = []

        // Overall result
        let result = (json["result"] as? String) ?? "unknown"
        let icon = result == "Passed" ? "PASSED" : "FAILED"
        lines.append("Tests \(icon) in \(elapsed)s")

        // Statistics — top-level keys in xcresulttool output
        var statParts: [String] = []
        if let total = json["totalTestCount"] as? Int { statParts.append("\(total) total") }
        if let passed = json["passedTests"] as? Int, passed > 0 { statParts.append("\(passed) passed") }
        if let failed = json["failedTests"] as? Int, failed > 0 { statParts.append("\(failed) FAILED") }
        if let skipped = json["skippedTests"] as? Int, skipped > 0 { statParts.append("\(skipped) skipped") }
        if let expected = json["expectedFailures"] as? Int, expected > 0 { statParts.append("\(expected) expected-failure") }
        if !statParts.isEmpty {
            lines.append(statParts.joined(separator: ", "))
        }

        // Inline failure summaries
        if let failures = json["testFailures"] as? [[String: Any]] {
            for failure in failures.prefix(20) {
                let testName = (failure["testName"] as? String) ?? (failure["testIdentifierString"] as? String) ?? "?"
                let message = (failure["failureText"] as? String) ?? ""
                lines.append("FAIL: \(testName)")
                if !message.isEmpty { lines.append("  \(message)") }
            }
        }

        // Devices
        if let devices = json["devicesAndConfigurations"] as? [[String: Any]] {
            for device in devices {
                if let d = device["device"] as? [String: Any],
                   let name = d["deviceName"] as? String,
                   let os = d["osVersion"] as? String {
                    lines.append("Device: \(name) (\(os))")
                }
            }
        }

        // Environment
        if let env = json["environmentDescription"] as? String {
            lines.append("Env: \(env)")
        }

        lines.append("xcresult: \(xcresultPath)")
        return lines.joined(separator: "\n")
    }

    private static func formatTestFailures(
        _ data: Data, xcresultPath: String,
        attachments: [(test: String, path: String)] = [],
        consoleByTest: [String: String] = [:]
    ) -> CallTool.Result {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .fail("Failed to parse test details JSON")
        }

        var failures: [String] = []

        // Recursively find failed test cases in the testNodes tree.
        // Structure: testNodes[] > children[] (suites) > children[] (test cases)
        // Failed test cases have result:"Failed" and children with nodeType:"Failure Message"
        func findFailures(in node: [String: Any]) {
            let nodeType = (node["nodeType"] as? String) ?? ""
            let result = (node["result"] as? String) ?? ""
            let name = (node["name"] as? String) ?? ""
            let identifier = (node["nodeIdentifier"] as? String) ?? ""

            if nodeType == "Test Case" && result == "Failed" {
                // Collect failure messages from children
                var messages: [String] = []
                if let children = node["children"] as? [[String: Any]] {
                    for child in children {
                        if (child["nodeType"] as? String) == "Failure Message" {
                            let msg = (child["name"] as? String) ?? ""
                            messages.append(msg)
                        }
                    }
                }
                var failLine = "FAIL: \(name) [\(identifier)]"
                if !messages.isEmpty {
                    failLine += "\n  " + messages.joined(separator: "\n  ")
                }

                // Attach screenshots for this failure
                let matchingScreenshots = attachments.filter { $0.test.contains(identifier) || identifier.contains($0.test) }
                for screenshot in matchingScreenshots {
                    failLine += "\n  Screenshot: \(screenshot.path)"
                }

                // Attach console output if requested
                // Try matching by function name (e.g. "buchfarbenCount()")
                let funcName = identifier.split(separator: "/").last.map(String.init) ?? identifier
                if let console = consoleByTest[funcName] ?? consoleByTest[identifier] {
                    failLine += "\n  Console:\n    " + console.replacingOccurrences(of: "\n", with: "\n    ")
                }

                failures.append(failLine)
                return
            }

            // Recurse into children (suites, plans, etc.)
            if let children = node["children"] as? [[String: Any]] {
                for child in children {
                    findFailures(in: child)
                }
            }
        }

        if let testNodes = json["testNodes"] as? [[String: Any]] {
            for node in testNodes {
                findFailures(in: node)
            }
        }

        if failures.isEmpty {
            return .ok("No test failures found.\nxcresult: \(xcresultPath)")
        }

        var output = "\(failures.count) test failure(s):\n\n" + failures.joined(separator: "\n\n")

        // List all screenshots at the end for easy access
        if !attachments.isEmpty {
            output += "\n\nFailure screenshots (\(attachments.count)):"
            for att in attachments {
                output += "\n  \(att.path)"
            }
        }

        output += "\n\nxcresult: \(xcresultPath)"
        let truncated = output.count > 50000 ? String(output.prefix(50000)) + "\n... [truncated]" : output
        return .fail(truncated)
    }

    private static func formatCoverageReport(_ json: [String: Any], minCoverage: Double, xcresultPath: String) -> CallTool.Result {
        var lines: [String] = []

        // Overall coverage
        if let lineCoverage = json["lineCoverage"] as? Double {
            lines.append(String(format: "Overall coverage: %.1f%%", lineCoverage * 100))
        }

        // Per-target coverage
        if let targets = json["targets"] as? [[String: Any]] {
            for target in targets {
                let name = (target["name"] as? String) ?? "?"
                let cov = (target["lineCoverage"] as? Double) ?? 0
                lines.append(String(format: "\nTarget: %@ (%.1f%%)", name, cov * 100))

                // Per-file coverage
                if let files = target["files"] as? [[String: Any]] {
                    var fileEntries: [(String, Double)] = []
                    for file in files {
                        let path = (file["path"] as? String) ?? (file["name"] as? String) ?? "?"
                        let fileCov = (file["lineCoverage"] as? Double) ?? 0
                        let pct = fileCov * 100
                        if pct < minCoverage {
                            // Show just filename, not full path
                            let shortPath = (path as NSString).lastPathComponent
                            fileEntries.append((shortPath, pct))
                        }
                    }
                    // Sort by coverage ascending
                    fileEntries.sort { $0.1 < $1.1 }
                    for (path, pct) in fileEntries {
                        lines.append(String(format: "  %6.1f%% %@", pct, path))
                    }
                }
            }
        }

        lines.append("\nxcresult: \(xcresultPath)")
        let output = lines.joined(separator: "\n")
        let truncated = output.count > 50000 ? String(output.prefix(50000)) + "\n... [truncated]" : output
        return .ok(truncated)
    }

    private static func formatBuildDiagnosis(
        _ json: [String: Any], succeeded: Bool, elapsed: String, xcresultPath: String
    ) -> CallTool.Result {
        var lines: [String] = []
        let status = succeeded ? "SUCCEEDED" : "FAILED"
        lines.append("Build \(status) in \(elapsed)s")

        // xcresulttool build-results JSON has top-level keys:
        // errorCount, warningCount, analyzerWarningCount, errors[], warnings[], analyzerWarnings[]
        let errorCount = (json["errorCount"] as? Int) ?? 0
        let warningCount = (json["warningCount"] as? Int) ?? 0
        let analyzerCount = (json["analyzerWarningCount"] as? Int) ?? 0

        if errorCount > 0 || warningCount > 0 || analyzerCount > 0 {
            var parts: [String] = []
            if errorCount > 0 { parts.append("\(errorCount) error(s)") }
            if warningCount > 0 { parts.append("\(warningCount) warning(s)") }
            if analyzerCount > 0 { parts.append("\(analyzerCount) analyzer warning(s)") }
            lines.append(parts.joined(separator: ", "))
        }

        // Extract individual errors
        func extractIssues(from key: String, prefix: String) {
            guard let issues = json[key] as? [[String: Any]] else { return }
            for issue in issues {
                let message = (issue["message"] as? String) ?? "No message"

                var location = ""

                // Primary: sourceURL (format: "file:///path/to/file.swift#...LineNumber=10...")
                if let sourceURL = issue["sourceURL"] as? String {
                    let cleanURL: String
                    if let hashIndex = sourceURL.firstIndex(of: "#") {
                        cleanURL = String(sourceURL[sourceURL.startIndex..<hashIndex])
                    } else {
                        cleanURL = sourceURL
                    }
                    let path = cleanURL.hasPrefix("file://") ? String(cleanURL.dropFirst(7)) : cleanURL
                    let shortPath = (path as NSString).lastPathComponent

                    // Extract line number from URL fragment
                    var lineNum: String?
                    if let hashIndex = sourceURL.firstIndex(of: "#") {
                        let fragment = String(sourceURL[sourceURL.index(after: hashIndex)...])
                        let params = fragment.split(separator: "&")
                        for param in params {
                            if param.hasPrefix("StartingLineNumber=") {
                                lineNum = String(param.dropFirst("StartingLineNumber=".count))
                                break
                            }
                        }
                    }
                    location = " (\(shortPath)"
                    if let line = lineNum { location += ":\(line)" }
                    location += ")"
                }
                // Fallback: documentLocation (older xcresult format)
                else if let loc = issue["documentLocation"] as? [String: Any] {
                    let url = (loc["url"] as? String) ?? ""
                    let path = url.hasPrefix("file://") ? String(url.dropFirst(7)) : url
                    let shortPath = (path as NSString).lastPathComponent
                    location = " (\(shortPath))"
                }

                lines.append("\(prefix)\(location): \(message)")
            }
        }

        extractIssues(from: "errors", prefix: "ERROR")
        extractIssues(from: "warnings", prefix: "WARNING")
        extractIssues(from: "analyzerWarnings", prefix: "ANALYZER")

        // Destination info
        if let dest = json["destination"] as? [String: Any] {
            let name = (dest["deviceName"] as? String) ?? ""
            let os = (dest["osVersion"] as? String) ?? ""
            if !name.isEmpty { lines.append("Device: \(name) (\(os))") }
        }

        if errorCount == 0 && warningCount == 0 && analyzerCount == 0 {
            lines.append(succeeded ? "No errors or warnings" : "Build failed (check xcresult for details)")
        }

        lines.append("xcresult: \(xcresultPath)")
        let output = lines.joined(separator: "\n")
        let truncated = output.count > 50000 ? String(output.prefix(50000)) + "\n... [truncated]" : output

        return succeeded ? .ok(truncated) : .fail(truncated)
    }
}
