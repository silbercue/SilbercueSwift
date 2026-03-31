import MCP

/// A registered tool: MCP schema + async handler.
public struct ToolRegistration: Sendable {
    public let tool: Tool
    public let handler: @Sendable ([String: Value]?) async -> CallTool.Result

    public init(tool: Tool, handler: @escaping @Sendable ([String: Value]?) async -> CallTool.Result) {
        self.tool = tool
        self.handler = handler
    }
}

/// Central registry of all tools. Supports dynamic registration for Pro module.
public enum ToolRegistry {
    /// Registered tools — populated at startup by registerFreeTools() and optionally by Pro module.
    nonisolated(unsafe) private static var registrations: [String: ToolRegistration] = [:]

    /// Register tools (additive — safe to call multiple times).
    public static func register(_ regs: [ToolRegistration]) {
        for r in regs { registrations[r.tool.name] = r }
    }

    /// Returns all registered tools.
    public static func allTools() -> [Tool] {
        registrations.values.map(\.tool)
    }

    /// Dispatch a tool call by name.
    public static func dispatch(_ name: String, _ args: [String: Value]?) async -> CallTool.Result {
        guard let reg = registrations[name] else {
            return .fail("Unknown tool: \(name)")
        }
        return await reg.handler(args)
    }

    /// Register all Free-tier tools. Called once from main.swift at startup.
    public static func registerFreeTools() {
        register(SessionState.registrations)
        register(BuildTools.registrations)
        register(SimTools.registrations)
        register(ScreenshotTools.registrations)
        register(UITools.registrations)
        register(LogTools.registrations)
        register(GitTools.registrations)
        register(ConsoleTools.registrations)
        register(TestTools.registrations)
        register([RunPlanTool.registration])
    }
}
