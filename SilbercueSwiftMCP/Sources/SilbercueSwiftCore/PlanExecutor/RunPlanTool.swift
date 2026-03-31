import Foundation
import MCP

public enum RunPlanTool {

    public static let tool = Tool(
        name: "run_plan",
        description: "Execute a structured test plan deterministically. Runs find/click/verify/screenshot steps internally without LLM round-trips. Returns a compact execution report. 50x faster than individual tool calls for sequential UI interactions. Use operator_model for adaptive steps (judge, handle_unexpected).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "steps": .object([
                    "type": .string("array"),
                    "description": .string("Ordered list of plan steps. Each step is a JSON object with one action key: navigate, navigate_back, find, find_all, click, double_tap, long_press, swipe, type, screenshot, wait, wait_for, verify, if_element_exists, judge, handle_unexpected"),
                    "items": .object(["type": .string("object")]),
                ]),
                "on_error": .object([
                    "type": .string("string"),
                    "enum": .array([.string("abort_with_screenshot"), .string("continue"), .string("abort")]),
                    "description": .string("Error strategy. Default: abort_with_screenshot"),
                ]),
                "timeout_ms": .object([
                    "type": .string("number"),
                    "description": .string("Total plan timeout in ms. Default: 30000"),
                ]),
                "operator_model": .object([
                    "type": .string("string"),
                    "description": .string("LLM model for adaptive steps: 'haiku', 'sonnet', or full model ID. Requires ANTHROPIC_API_KEY env var. Omit for pure deterministic execution."),
                ]),
                "operator_budget": .object([
                    "type": .string("number"),
                    "description": .string("Max operator LLM calls per plan. Default: 10"),
                ]),
            ]),
            "required": .array([.string("steps")]),
        ])
    )

    public static let registration = ToolRegistration(tool: tool, handler: handle)

    static func handle(_ args: [String: Value]?) async -> CallTool.Result {
        // Pro gate
        if !(await LicenseManager.shared.isPro) {
            return .fail(
                "run_plan is a [PRO] feature.\n"
                + "Batch UI automation: 50x faster than individual tool calls.\n"
                + "Execute find/click/verify/screenshot sequences in one call.\n\n"
                + "Level up here → \(LicenseManager.upgradeURL)\n"
                + "Then: silbercueswift activate <YOUR-KEY>"
            )
        }

        // Parse steps
        guard case .array(let stepsVal) = args?["steps"] else {
            return .fail("Missing required: steps (array)")
        }

        let steps: [PlanStep]
        do {
            steps = try PlanParser.parse(stepsVal)
        } catch {
            return .fail("Plan parse error: \(error)")
        }

        // Parse options
        let onError = args?["on_error"]?.stringValue
            .flatMap(ErrorStrategy.init(rawValue:)) ?? .abortWithScreenshot
        let timeoutMs = args?["timeout_ms"]?.intValue.map(UInt64.init) ?? 30000
        let operatorModel = args?["operator_model"]?.stringValue
        let operatorBudget = args?["operator_budget"]?.intValue ?? 10

        // Create operator bridge (optional)
        let bridge: OperatorBridge?
        do {
            bridge = try OperatorBridge.create(model: operatorModel, maxCalls: operatorBudget)
        } catch {
            // API key missing but operator requested — warn but continue deterministically
            Log.warn("run_plan: Operator disabled: \(error)")
            bridge = nil
        }

        // Execute
        let executor = PlanExecutor(
            operatorBridge: bridge,
            onError: onError,
            timeoutMs: timeoutMs
        )
        let result = await executor.execute(steps: steps)

        return ReportBuilder.buildMCPResponse(result)
    }
}
