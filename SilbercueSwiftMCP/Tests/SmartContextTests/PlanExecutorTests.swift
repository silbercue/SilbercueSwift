import Testing
import MCP
@testable import SilbercueSwiftCore

// MARK: - PlanParser Tests

@Suite("PlanParser")
struct PlanParserTests {

    @Test("Parse navigate step")
    func parseNavigate() throws {
        let steps = try PlanParser.parse([
            .object(["navigate": .string("Button & Tap Tests")])
        ])
        #expect(steps.count == 1)
        #expect(steps[0].description == "navigate \"Button & Tap Tests\"")
    }

    @Test("Parse navigate with scroll")
    func parseNavigateScroll() throws {
        let steps = try PlanParser.parse([
            .object(["navigate": .string("Settings"), "scroll": .bool(true)])
        ])
        #expect(steps.count == 1)
        if case .navigate(let target, let scroll) = steps[0] {
            #expect(target == "Settings")
            #expect(scroll == true)
        } else {
            Issue.record("Expected navigate step")
        }
    }

    @Test("Parse navigate_back")
    func parseNavigateBack() throws {
        let steps = try PlanParser.parse([
            .object(["navigate_back": .bool(true)])
        ])
        #expect(steps.count == 1)
        if case .navigateBack = steps[0] {} else {
            Issue.record("Expected navigateBack step")
        }
    }

    @Test("Parse find with bind")
    func parseFind() throws {
        let steps = try PlanParser.parse([
            .object(["find": .string("Double Tap Zone"), "as": .string("target")])
        ])
        #expect(steps.count == 1)
        if case .find(let using, let value, let bindAs, _) = steps[0] {
            #expect(using == "accessibility id")
            #expect(value == "Double Tap Zone")
            #expect(bindAs == "target")
        } else {
            Issue.record("Expected find step")
        }
    }

    @Test("Parse find with predicate")
    func parseFindPredicate() throws {
        let steps = try PlanParser.parse([
            .object([
                "find": .object(["using": .string("predicate string"), "value": .string("label CONTAINS 'foo'")]),
                "as": .string("x")
            ])
        ])
        if case .find(let using, let value, _, _) = steps[0] {
            #expect(using == "predicate string")
            #expect(value == "label CONTAINS 'foo'")
        } else {
            Issue.record("Expected find step with predicate")
        }
    }

    @Test("Parse click with variable")
    func parseClickVariable() throws {
        let steps = try PlanParser.parse([
            .object(["click": .string("$target")])
        ])
        if case .click(let target) = steps[0] {
            if case .variable(let name) = target {
                #expect(name == "target")
            } else {
                Issue.record("Expected variable target")
            }
        } else {
            Issue.record("Expected click step")
        }
    }

    @Test("Parse click with label")
    func parseClickLabel() throws {
        let steps = try PlanParser.parse([
            .object(["click": .string("Tap Me")])
        ])
        if case .click(let target) = steps[0] {
            if case .label(let l) = target {
                #expect(l == "Tap Me")
            } else {
                Issue.record("Expected label target")
            }
        } else {
            Issue.record("Expected click step")
        }
    }

    @Test("Parse double_tap")
    func parseDoubleTap() throws {
        let steps = try PlanParser.parse([
            .object(["double_tap": .string("$zone")])
        ])
        if case .doubleTap(let target) = steps[0] {
            if case .variable(let name) = target {
                #expect(name == "zone")
            } else { Issue.record("Expected variable") }
        } else { Issue.record("Expected doubleTap step") }
    }

    @Test("Parse long_press with duration")
    func parseLongPress() throws {
        let steps = try PlanParser.parse([
            .object(["long_press": .string("$btn"), "duration_ms": .int(2000)])
        ])
        if case .longPress(_, let dur) = steps[0] {
            #expect(dur == 2000)
        } else { Issue.record("Expected longPress step") }
    }

    @Test("Parse screenshot")
    func parseScreenshot() throws {
        let steps = try PlanParser.parse([
            .object(["screenshot": .object(["label": .string("final"), "quality": .string("full")])])
        ])
        if case .screenshot(let label, let quality) = steps[0] {
            #expect(label == "final")
            #expect(quality == "full")
        } else { Issue.record("Expected screenshot step") }
    }

    @Test("Parse wait")
    func parseWait() throws {
        let steps = try PlanParser.parse([
            .object(["wait": .int(500)])
        ])
        if case .wait(let ms) = steps[0] {
            #expect(ms == 500)
        } else { Issue.record("Expected wait step") }
    }

    @Test("Parse wait_for")
    func parseWaitFor() throws {
        let steps = try PlanParser.parse([
            .object(["wait_for": .object([
                "element": .string("spinner"),
                "disappears": .bool(true),
                "timeout_ms": .int(3000)
            ])])
        ])
        if case .waitFor(let el, let cond, let timeout) = steps[0] {
            #expect(el == "spinner")
            #expect(cond == .disappears)
            #expect(timeout == 3000)
        } else { Issue.record("Expected waitFor step") }
    }

    @Test("Parse verify screen_contains")
    func parseVerifyScreenContains() throws {
        let steps = try PlanParser.parse([
            .object(["verify": .object([
                "screen_contains": .array([.string("Tap Me"), .string("Double Tap Zone")])
            ])])
        ])
        if case .verify(let cond) = steps[0] {
            if case .screenContains(let labels) = cond {
                #expect(labels == ["Tap Me", "Double Tap Zone"])
            } else { Issue.record("Expected screenContains") }
        } else { Issue.record("Expected verify step") }
    }

    @Test("Parse verify element_label equals")
    func parseVerifyElementLabel() throws {
        let steps = try PlanParser.parse([
            .object(["verify": .object([
                "element_label": .string("tap-count"),
                "equals": .string("Tap Count: 1")
            ])])
        ])
        if case .verify(let cond) = steps[0] {
            if case .elementLabel(let id, let eq, let cont) = cond {
                #expect(id == "tap-count")
                #expect(eq == "Tap Count: 1")
                #expect(cont == nil)
            } else { Issue.record("Expected elementLabel") }
        } else { Issue.record("Expected verify step") }
    }

    @Test("Parse verify element_exists")
    func parseVerifyExists() throws {
        let steps = try PlanParser.parse([
            .object(["verify": .object(["element_exists": .string("btn-tap")])])
        ])
        if case .verify(let cond) = steps[0] {
            if case .elementExists(let id) = cond {
                #expect(id == "btn-tap")
            } else { Issue.record("Expected elementExists") }
        } else { Issue.record("Expected verify step") }
    }

    @Test("Parse if_element_exists")
    func parseIfElementExists() throws {
        let steps = try PlanParser.parse([
            .object([
                "if_element_exists": .string("banner"),
                "then": .array([
                    .object(["click": .string("Dismiss")]),
                    .object(["wait": .int(300)])
                ])
            ])
        ])
        if case .ifElementExists(let id, let then) = steps[0] {
            #expect(id == "banner")
            #expect(then.count == 2)
        } else { Issue.record("Expected ifElementExists step") }
    }

    @Test("Parse judge step")
    func parseJudge() throws {
        let steps = try PlanParser.parse([
            .object(["judge": .object([
                "question": .string("Is the page loaded?"),
                "screenshot": .bool(true)
            ])])
        ])
        if case .judge(let q, let ss) = steps[0] {
            #expect(q == "Is the page loaded?")
            #expect(ss == true)
        } else { Issue.record("Expected judge step") }
    }

    @Test("Parse handle_unexpected")
    func parseHandleUnexpected() throws {
        let steps = try PlanParser.parse([
            .object(["handle_unexpected": .string("Dismiss any alerts")])
        ])
        if case .handleUnexpected(let instr) = steps[0] {
            #expect(instr == "Dismiss any alerts")
        } else { Issue.record("Expected handleUnexpected step") }
    }

    @Test("Parse multi-step plan")
    func parseMultiStep() throws {
        let steps = try PlanParser.parse([
            .object(["navigate": .string("Button & Tap Tests")]),
            .object(["verify": .object(["screen_contains": .array([.string("Tap Me")])])]),
            .object(["find": .string("Double Tap Zone"), "as": .string("target")]),
            .object(["double_tap": .string("$target")]),
            .object(["wait": .int(300)]),
            .object(["verify": .object(["element_label": .string("doubletap-count"), "contains": .string("Double Tap: 1")])]),
            .object(["screenshot": .object(["label": .string("after-double-tap")])])
        ])
        #expect(steps.count == 7)
    }

    @Test("Parse error on unknown step")
    func parseUnknownStep() {
        #expect(throws: PlanError.self) {
            try PlanParser.parse([
                .object(["unknown_action": .string("foo")])
            ])
        }
    }

    @Test("Parse error on non-object step")
    func parseNonObject() {
        #expect(throws: PlanError.self) {
            try PlanParser.parse([.string("not an object")])
        }
    }

    @Test("Parse swipe")
    func parseSwipe() throws {
        let steps = try PlanParser.parse([
            .object(["swipe": .object(["direction": .string("up"), "element": .string("$list")])])
        ])
        if case .swipe(let dir, let el) = steps[0] {
            #expect(dir == "up")
            if case .variable(let name) = el {
                #expect(name == "list")
            } else { Issue.record("Expected variable element") }
        } else { Issue.record("Expected swipe step") }
    }

    @Test("Parse type text")
    func parseTypeText() throws {
        let steps = try PlanParser.parse([
            .object(["type": .object(["text": .string("Hello"), "element": .string("$field")])])
        ])
        if case .typeText(let text, let el) = steps[0] {
            #expect(text == "Hello")
            if case .variable(let name) = el {
                #expect(name == "field")
            } else { Issue.record("Expected variable element") }
        } else { Issue.record("Expected typeText step") }
    }

    @Test("Parse find_all")
    func parseFindAll() throws {
        let steps = try PlanParser.parse([
            .object([
                "find_all": .array([.string("btn1"), .string("btn2")]),
                "as": .array([.string("a"), .string("b")])
            ])
        ])
        if case .findAll(let ids, let binds) = steps[0] {
            #expect(ids == ["btn1", "btn2"])
            #expect(binds == ["a", "b"])
        } else { Issue.record("Expected findAll step") }
    }

    @Test("Parse verify element_count")
    func parseVerifyCount() throws {
        let steps = try PlanParser.parse([
            .object(["verify": .object([
                "element_count": .object(["using": .string("class name"), "value": .string("XCUIElementTypeCell")]),
                "gte": .int(3)
            ])])
        ])
        if case .verify(let cond) = steps[0] {
            if case .elementCount(_, let val, let eq, let gte) = cond {
                #expect(val == "XCUIElementTypeCell")
                #expect(eq == nil)
                #expect(gte == 3)
            } else { Issue.record("Expected elementCount") }
        } else { Issue.record("Expected verify step") }
    }
}

// MARK: - VariableStore Tests

@Suite("VariableStore")
struct VariableStoreTests {

    @Test("Bind and resolve variable")
    func bindResolve() throws {
        let store = VariableStore()
        let binding = UIActions.ElementBinding(elementId: "elem-1", rect: nil, swipes: 0, label: "Test")
        store.bind("myVar", binding)
        let resolved = try store.resolve("$myVar")
        #expect(resolved.elementId == "elem-1")
        #expect(resolved.label == "Test")
    }

    @Test("Resolve undefined variable throws")
    func resolveUndefined() {
        let store = VariableStore()
        store.bind("x", UIActions.ElementBinding(elementId: "e1", rect: nil, swipes: 0, label: nil))
        #expect(throws: PlanError.self) {
            try store.resolve("$unknown")
        }
    }

    @Test("Resolve without $ prefix throws")
    func resolveWithoutPrefix() {
        let store = VariableStore()
        #expect(throws: PlanError.self) {
            try store.resolve("noprefix")
        }
    }

    @Test("Available keys")
    func availableKeys() {
        let store = VariableStore()
        store.bind("a", UIActions.ElementBinding(elementId: "e1", rect: nil, swipes: 0, label: nil))
        store.bind("b", UIActions.ElementBinding(elementId: "e2", rect: nil, swipes: 0, label: nil))
        #expect(store.availableKeys.sorted() == ["a", "b"])
    }

    @Test("Overwrite binding")
    func overwrite() throws {
        let store = VariableStore()
        store.bind("x", UIActions.ElementBinding(elementId: "old", rect: nil, swipes: 0, label: nil))
        store.bind("x", UIActions.ElementBinding(elementId: "new", rect: nil, swipes: 0, label: nil))
        let resolved = try store.resolve("$x")
        #expect(resolved.elementId == "new")
    }
}

// MARK: - ReportBuilder Tests

@Suite("ReportBuilder")
struct ReportBuilderTests {

    @Test("Report all passed")
    func reportAllPassed() {
        let result = ReportBuilder.PlanResult(
            steps: [
                .init(index: 0, description: "navigate \"Home\"", status: .passed, elapsedMs: 50),
                .init(index: 1, description: "click \"Button\"", status: .passed, elapsedMs: 20),
                .init(index: 2, description: "screenshot \"done\"", status: .passed, elapsedMs: 15),
            ],
            screenshots: [],
            passed: true,
            summary: "3/3 passed (85ms)",
            elapsedMs: 85
        )
        let report = ReportBuilder.buildReport(result)
        #expect(report.contains("Plan executed: 3/3 passed"))
        #expect(report.contains("[OK]"))
        #expect(!report.contains("[FAIL]"))
    }

    @Test("Report with failure")
    func reportWithFailure() {
        let result = ReportBuilder.PlanResult(
            steps: [
                .init(index: 0, description: "navigate \"Home\"", status: .passed, elapsedMs: 50),
                .init(index: 1, description: "verify exists \"btn\"", status: .failed("\"btn\" not found"), elapsedMs: 30),
                .init(index: 2, description: "screenshot", status: .skipped("aborted"), elapsedMs: 0),
            ],
            screenshots: [],
            passed: false,
            summary: "1/3 passed (80ms)",
            elapsedMs: 80
        )
        let report = ReportBuilder.buildReport(result)
        #expect(report.contains("Plan FAILED at step 2"))
        #expect(report.contains("[FAIL]"))
        #expect(report.contains("[SKIP]"))
        #expect(report.contains("\"btn\" not found"))
    }

    @Test("Report with skipped steps")
    func reportWithSkipped() {
        let result = ReportBuilder.PlanResult(
            steps: [
                .init(index: 0, description: "judge", status: .skipped("No operator configured"), elapsedMs: 0),
            ],
            screenshots: [],
            passed: false,
            summary: "0/1 passed (0ms)",
            elapsedMs: 0
        )
        let report = ReportBuilder.buildReport(result)
        #expect(report.contains("[SKIP]"))
        #expect(report.contains("No operator configured"))
    }

    @Test("MCP response includes screenshots")
    func mcpResponseWithScreenshots() {
        let result = ReportBuilder.PlanResult(
            steps: [.init(index: 0, description: "screenshot", status: .passed, elapsedMs: 10)],
            screenshots: [
                .init(label: "test-shot", base64: "abc123base64data")
            ],
            passed: true,
            summary: "1/1 passed (10ms)",
            elapsedMs: 10
        )
        let response = ReportBuilder.buildMCPResponse(result)
        #expect(response.content.count == 3) // text + image + label
        #expect(response.isError == nil)
    }

    @Test("MCP response isError on failure")
    func mcpResponseError() {
        let result = ReportBuilder.PlanResult(
            steps: [.init(index: 0, description: "verify", status: .failed("nope"), elapsedMs: 5)],
            screenshots: [],
            passed: false,
            summary: "0/1 passed (5ms)",
            elapsedMs: 5
        )
        let response = ReportBuilder.buildMCPResponse(result)
        #expect(response.isError == true)
    }
}

// MARK: - StepTarget Tests

@Suite("StepTarget")
struct StepTargetTests {

    @Test("Variable target from $prefix")
    func variableTarget() {
        let t = StepTarget("$myVar")
        if case .variable(let name) = t {
            #expect(name == "myVar")
        } else { Issue.record("Expected variable") }
    }

    @Test("Label target without $prefix")
    func labelTarget() {
        let t = StepTarget("Tap Me")
        if case .label(let l) = t {
            #expect(l == "Tap Me")
        } else { Issue.record("Expected label") }
    }

    @Test("Empty string is label")
    func emptyString() {
        let t = StepTarget("")
        if case .label(let l) = t {
            #expect(l == "")
        } else { Issue.record("Expected label") }
    }

    @Test("$ alone is variable with empty name")
    func dollarAlone() {
        let t = StepTarget("$")
        if case .variable(let name) = t {
            #expect(name == "")
        } else { Issue.record("Expected variable") }
    }
}

// MARK: - PlanStep Description Tests

@Suite("PlanStep.description")
struct PlanStepDescriptionTests {

    @Test("Navigate description")
    func navigateDesc() {
        let step = PlanStep.navigate(target: "Home", scroll: false)
        #expect(step.description == "navigate \"Home\"")
    }

    @Test("Find with bind description")
    func findDesc() {
        let step = PlanStep.find(using: "accessibility id", value: "btn", bindAs: "x", scroll: false)
        #expect(step.description == "find \"btn\" → $x")
    }

    @Test("Click variable description")
    func clickVarDesc() {
        let step = PlanStep.click(target: .variable("btn"))
        #expect(step.description == "click $btn")
    }

    @Test("Click label description")
    func clickLabelDesc() {
        let step = PlanStep.click(target: .label("OK"))
        #expect(step.description == "click \"OK\"")
    }

    @Test("Wait description")
    func waitDesc() {
        let step = PlanStep.wait(ms: 500)
        #expect(step.description == "wait 500ms")
    }

    @Test("Verify screen_contains description")
    func verifyDesc() {
        let step = PlanStep.verify(condition: .screenContains(["A", "B"]))
        #expect(step.description == "verify screen_contains [A, B]")
    }
}
