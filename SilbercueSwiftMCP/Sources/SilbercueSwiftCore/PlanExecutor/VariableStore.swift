import Foundation

/// Scoped variable bindings within a single plan execution.
/// Not thread-safe — used only from PlanExecutor's sequential loop.
public final class VariableStore {
    private var bindings: [String: UIActions.ElementBinding] = [:]

    public init() {}

    public func bind(_ name: String, _ binding: UIActions.ElementBinding) {
        bindings[name] = binding
    }

    public func resolve(_ ref: String) throws -> UIActions.ElementBinding {
        guard ref.hasPrefix("$") else {
            throw PlanError.invalidVariable(ref)
        }
        let name = String(ref.dropFirst())
        guard let binding = bindings[name] else {
            throw PlanError.undefinedVariable(name, available: Array(bindings.keys))
        }
        return binding
    }

    /// Resolve "$var" → stored binding, or "plain text" → find by accessibility id.
    public func resolveTarget(_ target: StepTarget) async throws -> UIActions.ElementBinding {
        switch target {
        case .variable(let name):
            return try resolve("$\(name)")
        case .label(let label):
            return try await UIActions.find(using: "accessibility id", value: label)
        }
    }

    public var availableKeys: [String] { Array(bindings.keys) }
}
