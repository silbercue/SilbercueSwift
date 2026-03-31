import Foundation

public enum VerifyEngine {

    public struct VerifyResult: Sendable {
        public let passed: Bool
        public let detail: String
    }

    public static func verify(_ condition: VerifyCondition) async -> VerifyResult {
        switch condition {
        case .screenContains(let labels):
            return await verifyScreenContains(labels)
        case .elementLabel(let id, let equals, let contains):
            return await verifyElementLabel(id: id, equals: equals, contains: contains)
        case .elementExists(let id):
            return await verifyElementExists(id, shouldExist: true)
        case .elementNotExists(let id):
            return await verifyElementExists(id, shouldExist: false)
        case .elementCount(let using, let value, let equals, let gte):
            return await verifyElementCount(using: using, value: value, equals: equals, gte: gte)
        }
    }

    // MARK: - Implementations

    private static func verifyScreenContains(_ labels: [String]) async -> VerifyResult {
        do {
            let elements = try await UIActions.getSourcePruned()
            let allText = elements.compactMap { elem -> [String] in
                var texts: [String] = []
                if let l = elem["label"] as? String { texts.append(l) }
                if let id = elem["id"] as? String { texts.append(id) }
                if let v = elem["value"] as? String { texts.append(v) }
                return texts
            }.flatMap { $0 }

            var missing: [String] = []
            for label in labels {
                if !allText.contains(where: { $0.localizedCaseInsensitiveContains(label) }) {
                    missing.append(label)
                }
            }
            if missing.isEmpty {
                return VerifyResult(passed: true, detail: "screen contains all \(labels.count) labels")
            }
            return VerifyResult(passed: false, detail: "missing: \(missing.joined(separator: ", "))")
        } catch {
            return VerifyResult(passed: false, detail: "get_source failed: \(error)")
        }
    }

    private static func verifyElementLabel(id: String, equals: String?, contains: String?) async -> VerifyResult {
        do {
            let binding = try await UIActions.find(using: "accessibility id", value: id)
            let label = binding.label ?? ""
            if let expected = equals {
                if label == expected {
                    return VerifyResult(passed: true, detail: "\(id) label = \"\(label)\"")
                }
                return VerifyResult(passed: false, detail: "\(id) label = \"\(label)\" (expected: \"\(expected)\")")
            }
            if let sub = contains {
                if label.localizedCaseInsensitiveContains(sub) {
                    return VerifyResult(passed: true, detail: "\(id) label contains \"\(sub)\"")
                }
                return VerifyResult(passed: false, detail: "\(id) label = \"\(label)\" (expected contains: \"\(sub)\")")
            }
            return VerifyResult(passed: true, detail: "\(id) label = \"\(label)\"")
        } catch {
            return VerifyResult(passed: false, detail: "\(id) not found: \(error)")
        }
    }

    private static func verifyElementExists(_ id: String, shouldExist: Bool) async -> VerifyResult {
        do {
            _ = try await UIActions.find(using: "accessibility id", value: id)
            if shouldExist {
                return VerifyResult(passed: true, detail: "\"\(id)\" exists")
            }
            return VerifyResult(passed: false, detail: "\"\(id)\" exists (expected: not exists)")
        } catch {
            if shouldExist {
                return VerifyResult(passed: false, detail: "\"\(id)\" not found")
            }
            return VerifyResult(passed: true, detail: "\"\(id)\" not found (as expected)")
        }
    }

    private static func verifyElementCount(using: String, value: String, equals: Int?, gte: Int?) async -> VerifyResult {
        do {
            let elements = try await WDAClient.shared.findElements(using: using, value: value)
            let count = elements.count
            if let expected = equals {
                if count == expected {
                    return VerifyResult(passed: true, detail: "count(\(value)) = \(count)")
                }
                return VerifyResult(passed: false, detail: "count(\(value)) = \(count) (expected: \(expected))")
            }
            if let min = gte {
                if count >= min {
                    return VerifyResult(passed: true, detail: "count(\(value)) = \(count) (>= \(min))")
                }
                return VerifyResult(passed: false, detail: "count(\(value)) = \(count) (expected: >= \(min))")
            }
            return VerifyResult(passed: true, detail: "count(\(value)) = \(count)")
        } catch {
            return VerifyResult(passed: false, detail: "find_elements failed: \(error)")
        }
    }
}
