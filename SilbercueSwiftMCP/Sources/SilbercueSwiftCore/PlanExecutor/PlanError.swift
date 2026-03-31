import Foundation

public enum PlanError: Error, CustomStringConvertible {
    case invalidStep(String)
    case invalidVariable(String)
    case undefinedVariable(String, available: [String])
    case verifyFailed(String)
    case timeout(stepIndex: Int, totalMs: UInt64)
    case stepFailed(String)
    case operatorError(String)
    case parseFailed(String)

    public var description: String {
        switch self {
        case .invalidStep(let msg): return "Invalid step: \(msg)"
        case .invalidVariable(let ref): return "Invalid variable ref: '\(ref)' (must start with $)"
        case .undefinedVariable(let name, let available):
            return "Undefined variable '$\(name)'. Available: \(available.map { "$\($0)" }.joined(separator: ", "))"
        case .verifyFailed(let detail): return "Verify failed: \(detail)"
        case .timeout(let idx, let ms): return "Plan timeout (\(ms)ms) at step \(idx)"
        case .stepFailed(let msg): return "Step failed: \(msg)"
        case .operatorError(let msg): return "Operator error: \(msg)"
        case .parseFailed(let msg): return "Parse failed: \(msg)"
        }
    }
}
