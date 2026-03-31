import Foundation
import MCP

public enum ReportBuilder {

    public struct LabeledScreenshot: Sendable {
        public let label: String
        public let base64: String
    }

    public struct StepResult: Sendable {
        public let index: Int
        public let description: String
        public let status: StepStatus
        public let elapsedMs: Int
    }

    public enum StepStatus: Sendable {
        case passed
        case failed(String)
        case skipped(String)
    }

    public struct PlanResult: Sendable {
        public let steps: [StepResult]
        public let screenshots: [LabeledScreenshot]
        public let passed: Bool
        public let summary: String
        public let elapsedMs: Int
    }

    // MARK: - Report Text

    public static func buildReport(_ result: PlanResult) -> String {
        let passCount = result.steps.filter { if case .passed = $0.status { return true }; return false }.count
        let failCount = result.steps.filter { if case .failed = $0.status { return true }; return false }.count
        let skipCount = result.steps.filter { if case .skipped = $0.status { return true }; return false }.count

        var lines: [String] = []
        if result.passed {
            lines.append("Plan executed: \(result.summary)")
        } else {
            if let failIdx = result.steps.firstIndex(where: { if case .failed = $0.status { return true }; return false }) {
                lines.append("Plan FAILED at step \(failIdx + 1): \(passCount)/\(result.steps.count) steps, \(failCount) failed, \(skipCount) skipped (\(result.elapsedMs)ms)")
            } else {
                lines.append("Plan FAILED: \(result.summary)")
            }
        }

        lines.append("")
        lines.append("Steps:")
        for step in result.steps {
            let tag: String
            let suffix: String
            switch step.status {
            case .passed:
                tag = "[OK]  "
                suffix = " (\(step.elapsedMs)ms)"
            case .failed(let reason):
                tag = "[FAIL]"
                suffix = "\n         → \(reason)"
            case .skipped(let reason):
                tag = "[SKIP]"
                suffix = " (\(reason))"
            }
            lines.append("  \(tag) \(step.index + 1). \(step.description)\(suffix)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - MCP Response

    public static func buildMCPResponse(_ result: PlanResult) -> CallTool.Result {
        let report = buildReport(result)
        var content: [Tool.Content] = [
            .text(text: report, annotations: nil, _meta: nil)
        ]
        for ss in result.screenshots {
            content.append(.image(data: ss.base64, mimeType: "image/jpeg", annotations: nil, _meta: nil))
            content.append(.text(text: "[\(ss.label)]", annotations: nil, _meta: nil))
        }
        return .init(content: content, isError: result.passed ? nil : true)
    }
}
