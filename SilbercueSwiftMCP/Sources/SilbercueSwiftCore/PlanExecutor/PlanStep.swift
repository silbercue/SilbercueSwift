import Foundation
import MCP

// MARK: - Step Target

public enum StepTarget: Sendable {
    case variable(String)  // "$varName" → lookup in VariableStore
    case label(String)     // "Button Text" → implicit find by label

    public init(_ raw: String) {
        if raw.hasPrefix("$") {
            self = .variable(String(raw.dropFirst()))
        } else {
            self = .label(raw)
        }
    }
}

// MARK: - Wait Condition

public enum WaitCondition: Sendable {
    case appears
    case disappears
}

// MARK: - Verify Condition

public enum VerifyCondition: Sendable {
    case screenContains([String])
    case elementLabel(id: String, equals: String?, contains: String?)
    case elementExists(String)
    case elementNotExists(String)
    case elementCount(using: String, value: String, equals: Int?, gte: Int?)
}

// MARK: - Plan Step

public enum PlanStep: Sendable {
    case navigate(target: String, scroll: Bool)
    case navigateBack
    case find(using: String, value: String, bindAs: String?, scroll: Bool)
    case findAll(ids: [String], bindAs: [String])
    case click(target: StepTarget)
    case doubleTap(target: StepTarget)
    case longPress(target: StepTarget, durationMs: Int)
    case swipe(direction: String, element: StepTarget?)
    case typeText(text: String, element: StepTarget?)
    case screenshot(label: String, quality: String)
    case wait(ms: Int)
    case waitFor(element: String, condition: WaitCondition, timeoutMs: Int)
    case verify(condition: VerifyCondition)
    case ifElementExists(id: String, then: [PlanStep])
    case judge(question: String, screenshot: Bool)
    case handleUnexpected(instruction: String)

    public var description: String {
        switch self {
        case .navigate(let t, _): return "navigate \"\(t)\""
        case .navigateBack: return "navigate_back"
        case .find(_, let v, let bind, _):
            return bind != nil ? "find \"\(v)\" → $\(bind!)" : "find \"\(v)\""
        case .findAll(let ids, let binds):
            return "find_all [\(ids.joined(separator: ", "))] → [\(binds.map { "$\($0)" }.joined(separator: ", "))]"
        case .click(let t): return "click \(targetDesc(t))"
        case .doubleTap(let t): return "double_tap \(targetDesc(t))"
        case .longPress(let t, let ms): return "long_press \(targetDesc(t)) (\(ms)ms)"
        case .swipe(let dir, let el):
            return el != nil ? "swipe \(dir) on \(targetDesc(el!))" : "swipe \(dir)"
        case .typeText(let text, _): return "type \"\(text)\""
        case .screenshot(let label, _): return "screenshot \"\(label)\""
        case .wait(let ms): return "wait \(ms)ms"
        case .waitFor(let el, let cond, let ms):
            let c = cond == .appears ? "appears" : "disappears"
            return "wait_for \"\(el)\" \(c) (\(ms)ms)"
        case .verify(let cond): return verifyDesc(cond)
        case .ifElementExists(let id, let steps):
            return "if_element_exists \"\(id)\" then [\(steps.count) steps]"
        case .judge(let q, _): return "judge: \"\(q)\""
        case .handleUnexpected(let instr): return "handle_unexpected: \"\(instr)\""
        }
    }

    private func targetDesc(_ t: StepTarget) -> String {
        switch t {
        case .variable(let v): return "$\(v)"
        case .label(let l): return "\"\(l)\""
        }
    }

    private func verifyDesc(_ c: VerifyCondition) -> String {
        switch c {
        case .screenContains(let labels):
            return "verify screen_contains [\(labels.joined(separator: ", "))]"
        case .elementLabel(let id, let eq, let cont):
            if let eq { return "verify \(id) == \"\(eq)\"" }
            if let cont { return "verify \(id) contains \"\(cont)\"" }
            return "verify \(id) label"
        case .elementExists(let id): return "verify exists \"\(id)\""
        case .elementNotExists(let id): return "verify not_exists \"\(id)\""
        case .elementCount(_, let v, let eq, let gte):
            if let eq { return "verify count(\(v)) == \(eq)" }
            if let gte { return "verify count(\(v)) >= \(gte)" }
            return "verify count(\(v))"
        }
    }
}

// MARK: - Plan Parser

public enum PlanParser {

    public static func parse(_ stepsValue: [Value]) throws -> [PlanStep] {
        try stepsValue.enumerated().map { idx, val in
            guard case .object(let dict) = val else {
                throw PlanError.parseFailed("Step \(idx): expected object")
            }
            return try parseStep(dict, index: idx)
        }
    }

    static func parseStep(_ dict: [String: Value], index: Int) throws -> PlanStep {
        // Discriminator: first recognized key
        if let target = dict["navigate"]?.stringValue {
            let scroll = dict["scroll"]?.boolValue ?? false
            return .navigate(target: target, scroll: scroll)
        }
        if dict["navigate_back"]?.boolValue == true {
            return .navigateBack
        }
        if let findVal = dict["find"] {
            let bindAs = dict["as"]?.stringValue
            let scroll = dict["scroll"]?.boolValue ?? false
            if let label = findVal.stringValue {
                return .find(using: "accessibility id", value: label, bindAs: bindAs, scroll: scroll)
            }
            if case .object(let findDict) = findVal {
                let using = findDict["using"]?.stringValue ?? "accessibility id"
                let value = findDict["value"]?.stringValue ?? ""
                return .find(using: using, value: value, bindAs: bindAs, scroll: scroll)
            }
            throw PlanError.parseFailed("Step \(index): invalid 'find' value")
        }
        if let findAllVal = dict["find_all"] {
            guard case .array(let ids) = findAllVal,
                  case .array(let binds) = dict["as"] else {
                throw PlanError.parseFailed("Step \(index): find_all requires arrays for find_all and as")
            }
            return .findAll(
                ids: ids.compactMap(\.stringValue),
                bindAs: binds.compactMap(\.stringValue)
            )
        }
        if let clickVal = dict["click"]?.stringValue {
            return .click(target: StepTarget(clickVal))
        }
        if let dtVal = dict["double_tap"]?.stringValue {
            return .doubleTap(target: StepTarget(dtVal))
        }
        if let lpVal = dict["long_press"]?.stringValue {
            let dur = dict["duration_ms"]?.intValue ?? 1000
            return .longPress(target: StepTarget(lpVal), durationMs: dur)
        }
        if case .object(let swipeDict) = dict["swipe"] {
            let dir = swipeDict["direction"]?.stringValue ?? "up"
            let el = swipeDict["element"]?.stringValue.map(StepTarget.init)
            return .swipe(direction: dir, element: el)
        }
        if case .object(let typeDict) = dict["type"] {
            let text = typeDict["text"]?.stringValue ?? ""
            let el = typeDict["element"]?.stringValue.map(StepTarget.init)
            return .typeText(text: text, element: el)
        }
        if case .object(let ssDict) = dict["screenshot"] {
            let label = ssDict["label"]?.stringValue ?? "screenshot"
            let quality = ssDict["quality"]?.stringValue ?? "compact"
            return .screenshot(label: label, quality: quality)
        }
        if let ms = dict["wait"]?.intValue {
            return .wait(ms: ms)
        }
        if case .object(let wfDict) = dict["wait_for"] {
            let el = wfDict["element"]?.stringValue ?? ""
            let disappears = wfDict["disappears"]?.boolValue ?? false
            let timeout = wfDict["timeout_ms"]?.intValue ?? 5000
            return .waitFor(
                element: el,
                condition: disappears ? .disappears : .appears,
                timeoutMs: timeout
            )
        }
        if case .object(let vDict) = dict["verify"] {
            return .verify(condition: try parseVerify(vDict, index: index))
        }
        if let ifId = dict["if_element_exists"]?.stringValue {
            guard case .array(let thenSteps) = dict["then"] else {
                throw PlanError.parseFailed("Step \(index): if_element_exists requires 'then' array")
            }
            let parsed = try thenSteps.enumerated().map { i, v in
                guard case .object(let d) = v else {
                    throw PlanError.parseFailed("Step \(index).then[\(i)]: expected object")
                }
                return try parseStep(d, index: i)
            }
            return .ifElementExists(id: ifId, then: parsed)
        }
        if case .object(let jDict) = dict["judge"] {
            let q = jDict["question"]?.stringValue ?? ""
            let ss = jDict["screenshot"]?.boolValue ?? true
            return .judge(question: q, screenshot: ss)
        }
        if let instr = dict["handle_unexpected"]?.stringValue {
            return .handleUnexpected(instruction: instr)
        }

        throw PlanError.parseFailed("Step \(index): unrecognized step type. Keys: \(dict.keys.sorted().joined(separator: ", "))")
    }

    private static func parseVerify(_ dict: [String: Value], index: Int) throws -> VerifyCondition {
        if case .array(let labels) = dict["screen_contains"] {
            return .screenContains(labels.compactMap(\.stringValue))
        }
        if let id = dict["element_label"]?.stringValue {
            return .elementLabel(
                id: id,
                equals: dict["equals"]?.stringValue,
                contains: dict["contains"]?.stringValue
            )
        }
        if let id = dict["element_exists"]?.stringValue {
            return .elementExists(id)
        }
        if let id = dict["element_not_exists"]?.stringValue {
            return .elementNotExists(id)
        }
        if case .object(let ecDict) = dict["element_count"] {
            let using = ecDict["using"]?.stringValue ?? "class name"
            let value = ecDict["value"]?.stringValue ?? ""
            return .elementCount(
                using: using, value: value,
                equals: dict["equals"]?.intValue,
                gte: dict["gte"]?.intValue
            )
        }
        throw PlanError.parseFailed("Step \(index): unrecognized verify condition. Keys: \(dict.keys.sorted().joined(separator: ", "))")
    }
}
