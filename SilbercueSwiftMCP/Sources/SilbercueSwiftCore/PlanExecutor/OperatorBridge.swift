import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Optional LLM bridge for adaptive plan steps (judge, handle_unexpected).
/// Calls Anthropic API directly via URLSession — no SDK dependency.
/// Without API key: adaptive steps gracefully degrade to SKIP.
public actor OperatorBridge {

    public struct Decision: Sendable {
        public let action: String       // "accept", "dismiss", "skip", "abort", "continue"
        public let reasoning: String
    }

    private let apiKey: String
    private let model: String
    private let timeout: TimeInterval = 5
    private var callCount = 0
    private let maxCalls: Int

    public var callsUsed: Int { callCount }

    public init(model: String, maxCalls: Int = 10) throws {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            self.apiKey = key
        } else if let key = ProcessInfo.processInfo.environment["SILBERCUESWIFT_OPERATOR_KEY"], !key.isEmpty {
            self.apiKey = key
        } else {
            throw PlanError.operatorError("No API key. Set ANTHROPIC_API_KEY or SILBERCUESWIFT_OPERATOR_KEY env var.")
        }

        switch model.lowercased() {
        case "haiku": self.model = "claude-haiku-4-5-20251001"
        case "sonnet": self.model = "claude-sonnet-4-6-20250827"
        case "opus": self.model = "claude-opus-4-6-20250527"
        default: self.model = model
        }
        self.maxCalls = maxCalls
    }

    /// Ask the operator with a question, optional screenshot, and execution context.
    public func ask(
        question: String,
        screenshotBase64: String? = nil,
        context: String = ""
    ) async throws -> Decision {
        guard callCount < maxCalls else {
            throw PlanError.operatorError("Budget exceeded: \(callCount)/\(maxCalls) operator calls used")
        }

        var content: [[String: Any]] = []
        if let ss = screenshotBase64 {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": ss,
                ],
            ])
        }
        content.append([
            "type": "text",
            "text": """
                You are a fast UI test operator. Answer concisely.

                Context: \(context)

                Question: \(question)

                Respond with JSON only: {"action": "accept|dismiss|skip|abort|continue", "reasoning": "one line"}
                """,
        ])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 150,
            "messages": [["role": "user", "content": content]],
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = jsonData
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlanError.operatorError("Non-HTTP response from Anthropic API")
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            throw PlanError.operatorError("Anthropic API \(httpResponse.statusCode): \(body)")
        }

        callCount += 1
        return try parseDecision(data)
    }

    private nonisolated func parseDecision(_ data: Data) throws -> Decision {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]],
              let firstBlock = contentArray.first,
              let text = firstBlock["text"] as? String else {
            throw PlanError.operatorError("Cannot parse Anthropic response")
        }

        let jsonStr: String
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            jsonStr = String(text[start...end])
        } else {
            throw PlanError.operatorError("No JSON in operator response: \(text)")
        }

        guard let decisionData = jsonStr.data(using: .utf8),
              let decision = try JSONSerialization.jsonObject(with: decisionData) as? [String: Any],
              let action = decision["action"] as? String else {
            throw PlanError.operatorError("Invalid decision JSON: \(jsonStr)")
        }

        return Decision(action: action, reasoning: decision["reasoning"] as? String ?? "")
    }

    /// Factory: create bridge if model specified. Returns nil (no error) if no model.
    /// Throws if model specified but no API key.
    public static func create(model: String?, maxCalls: Int = 10) throws -> OperatorBridge? {
        guard let model, !model.isEmpty else { return nil }
        return try OperatorBridge(model: model, maxCalls: maxCalls)
    }
}
