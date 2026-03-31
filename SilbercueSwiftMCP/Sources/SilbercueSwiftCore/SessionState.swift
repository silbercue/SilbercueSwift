import Foundation
import MCP

/// Session state actor — caches resolved project/scheme/simulator defaults.
/// Resolution order: explicit parameter → session default → auto-detect → error with options.
public actor SessionState {
    public static let shared = SessionState()

    // MARK: - Stored defaults

    public private(set) var project: String?
    public private(set) var scheme: String?
    public private(set) var simulator: String?
    public private(set) var bundleId: String?
    public private(set) var appPath: String?
    private(set) var nativeInput: IndigoHIDClient?
    private var nativeInputUDID: String?

    // Auto-promotion: consecutive explicit values become defaults
    private var projectStreak: (value: String, count: Int) = ("", 0)
    private var schemeStreak: (value: String, count: Int) = ("", 0)
    private var simulatorStreak: (value: String, count: Int) = ("", 0)
    private let promotionThreshold = 3

    // MARK: - Resolution (explicit → default → auto-detect)

    /// Resolve project path. Caches auto-detected result for the session.
    public func resolveProject(_ explicit: String?) async throws -> String {
        if let explicit {
            trackUsage(value: explicit, streak: &projectStreak, stored: &project)
            return explicit
        }
        if let stored = project { return stored }

        let detected = try await AutoDetect.project()
        self.project = detected
        Log.warn("Auto-detected project: \((detected as NSString).lastPathComponent)")
        return detected
    }

    /// Resolve scheme name. Caches auto-detected result for the session.
    public func resolveScheme(_ explicit: String?, project: String) async throws -> String {
        if let explicit {
            trackUsage(value: explicit, streak: &schemeStreak, stored: &scheme)
            return explicit
        }
        if let stored = scheme { return stored }

        let detected = try await AutoDetect.scheme(project: project)
        self.scheme = detected
        Log.warn("Auto-detected scheme: \(detected)")
        return detected
    }

    /// Resolve simulator to a full UDID. Handles names, short UDIDs, "booted", and auto-detect.
    /// All tools MUST use this to ensure consistent simulator selection.
    public func resolveSimulator(_ explicit: String?) async throws -> String {
        let raw: String
        if let explicit {
            trackUsage(value: explicit, streak: &simulatorStreak, stored: &simulator)
            raw = explicit
        } else if let stored = simulator {
            raw = stored
        } else {
            let udid = try await AutoDetect.simulator()
            initNativeInputIfNeeded(udid: udid)
            return udid
        }
        // Full UDID or "booted" → pass through (SimTools.resolveSimulator handles both)
        let udid = try await SimTools.resolveSimulator(raw)
        initNativeInputIfNeeded(udid: udid)
        return udid
    }

    // MARK: - Build info (populated after successful build_sim)

    public func setBuildInfo(bundleId: String, appPath: String?) {
        self.bundleId = bundleId
        self.appPath = appPath
    }

    public func resolveBundleId(_ explicit: String?) -> String? {
        explicit ?? bundleId
    }

    public func resolveAppPath(_ explicit: String?) -> String? {
        explicit ?? appPath
    }

    // MARK: - Manual defaults (set_defaults escape hatch)

    func setDefaults(project: String?, scheme: String?, simulator: String?) {
        if let p = project { self.project = p }
        if let s = scheme { self.scheme = s }
        if let sim = simulator { self.simulator = sim }
    }

    func showDefaults() -> String {
        var lines = ["Session defaults:"]
        lines.append("  project:   \(project ?? "(auto-detect)")")
        lines.append("  scheme:    \(scheme ?? "(auto-detect)")")
        lines.append("  simulator: \(simulator ?? "(auto-detect — queries booted sim each call)")")
        lines.append("  bundle_id: \(bundleId ?? "(from last build)")")
        lines.append("  app_path:  \(appPath ?? "(from last build)")")
        return lines.joined(separator: "\n")
    }

    func clearDefaults() {
        project = nil
        scheme = nil
        simulator = nil
        bundleId = nil
        appPath = nil
        nativeInput = nil
        nativeInputUDID = nil
        projectStreak = ("", 0)
        schemeStreak = ("", 0)
        simulatorStreak = ("", 0)
    }

    // MARK: - Native Input (IndigoHID)

    /// Discard stale HID client (e.g. after machPortInvalid).
    /// Next resolveSimulator() call will re-create it.
    func invalidateNativeInput() {
        nativeInput = nil
        nativeInputUDID = nil
    }

    private func initNativeInputIfNeeded(udid: String) {
        guard udid != nativeInputUDID else { return }
        nativeInputUDID = udid
        nativeInput = IndigoHIDClient.createIfAvailable(udid: udid)
        if nativeInput != nil {
            Log.warn("Input:      IndigoHID (native, ~48ms tap)")
        } else {
            Log.warn("Input:      WDA (http, ~200ms tap)")
        }
        Log.warn("Tree:       WDA (http, ~20ms)")
        Log.warn("Screenshot: simctl / TurboCapture (Pro)")
    }

    // MARK: - Auto-promotion

    private func trackUsage(
        value: String, streak: inout (value: String, count: Int), stored: inout String?
    ) {
        if value == streak.value {
            streak.count += 1
        } else {
            streak = (value, 1)
        }
        if streak.count >= promotionThreshold && stored != value {
            stored = value
            Log.warn("Auto-promoted session default: \(value) (used \(streak.count)x consecutively)")
        }
    }

    // MARK: - Tool registration

    static let registrations: [ToolRegistration] = [
        .init(tool: tools[0], handler: handleSetDefaults),
    ]

    // MARK: - Tool definition

    static let tools: [Tool] = [
        Tool(
            name: "set_defaults",
            description: """
                Set, show, or clear session defaults for project, scheme, and simulator. \
                These defaults are used when parameters are omitted from tool calls. \
                Usually not needed — the server auto-detects from the environment. \
                Use as escape hatch when auto-detection picks the wrong target.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object([
                        "type": .string("string"),
                        "description": .string("Default project path (.xcodeproj or .xcworkspace)"),
                    ]),
                    "scheme": .object([
                        "type": .string("string"),
                        "description": .string("Default scheme name"),
                    ]),
                    "simulator": .object([
                        "type": .string("string"),
                        "description": .string("Default simulator name or UDID"),
                    ]),
                    "action": .object([
                        "type": .string("string"),
                        "description": .string("'set' (default), 'show', or 'clear'"),
                        "enum": .array([.string("set"), .string("show"), .string("clear")]),
                    ]),
                ]),
            ])
        ),
    ]

    static func handleSetDefaults(_ args: [String: Value]?) async -> CallTool.Result {
        let action = args?["action"]?.stringValue ?? "set"
        let state = SessionState.shared

        switch action {
        case "show":
            return .ok(await state.showDefaults())
        case "clear":
            await state.clearDefaults()
            return .ok("Session defaults cleared. Auto-detection will be used for all parameters.")
        default:
            let project = args?["project"]?.stringValue
            let scheme = args?["scheme"]?.stringValue
            let simulator = args?["simulator"]?.stringValue

            if project == nil && scheme == nil && simulator == nil {
                return .ok(await state.showDefaults())
            }

            await state.setDefaults(project: project, scheme: scheme, simulator: simulator)
            return .ok(await state.showDefaults())
        }
    }
}
