import Foundation

struct ShellResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
}

enum Shell {
    /// Run a command with arguments, returning stdout/stderr/exitCode.
    static func run(
        _ executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 300
    ) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        if let env = environment {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            process.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Set termination handler BEFORE run() to avoid race condition.
        // Uses withCheckedContinuation instead of process.waitUntilExit() to avoid
        // blocking the Swift Cooperative Thread Pool. waitUntilExit() is synchronous
        // and permanently consumes a pool thread — with enough concurrent shell calls
        // or ESC-interrupted tasks, the pool is exhausted and ALL async work deadlocks.
        let terminationContinuation = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { proc in
            terminationContinuation.continuation.yield(proc.terminationStatus)
            terminationContinuation.continuation.finish()
        }

        try process.run()

        // Timeout watchdog
        let pid = process.processIdentifier
        let timeoutNanos = UInt64(timeout * 1_000_000_000)
        let timeoutTask = Task.detached {
            try? await Task.sleep(nanoseconds: timeoutNanos)
            kill(pid, SIGTERM)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            kill(pid, SIGKILL)
        }

        // Read output concurrently
        async let stdoutData = stdoutPipe.fileHandleForReading.readToEndAsync()
        async let stderrData = stderrPipe.fileHandleForReading.readToEndAsync()

        let (out, err) = try await (stdoutData, stderrData)

        // Await process exit without blocking the cooperative thread pool
        for await _ in terminationContinuation.stream {}
        timeoutTask.cancel()

        // Detect killed process (timeout or crash → uncaughtSignal)
        if process.terminationReason == .uncaughtSignal {
            let partialOut = String(data: out, encoding: .utf8) ?? ""
            return ShellResult(
                stdout: partialOut,
                stderr: "Process timed out after \(Int(timeout))s and was killed (signal \(process.terminationStatus))",
                exitCode: -1
            )
        }

        let stdout = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return ShellResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    /// Convenience for xcrun commands. Accepts an optional timeout (default: 300s).
    static func xcrun(timeout: TimeInterval = 300, _ arguments: String...) async throws -> ShellResult {
        try await run("/usr/bin/xcrun", arguments: Array(arguments), timeout: timeout)
    }

    /// Convenience for git commands
    static func git(_ arguments: [String], workingDirectory: String) async throws -> ShellResult {
        try await run("/usr/bin/git", arguments: arguments, workingDirectory: workingDirectory)
    }
}

// MARK: - FileHandle async read

extension FileHandle {
    func readToEndAsync() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let data = self.readDataToEndOfFile()
                continuation.resume(returning: data)
            }
        }
    }
}
