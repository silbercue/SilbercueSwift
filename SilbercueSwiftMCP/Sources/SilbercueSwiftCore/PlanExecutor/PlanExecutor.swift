import Foundation
import MCP

public enum ErrorStrategy: String, Sendable {
    case abort
    case abortWithScreenshot = "abort_with_screenshot"
    case `continue` = "continue"
}

/// Outcome of a plan execution — either completed or suspended awaiting a decision.
public enum PlanOutcome: Sendable {
    case completed(ReportBuilder.PlanResult)
    case suspended(SuspendInfo)

    public struct SuspendInfo: Sendable {
        public let sessionId: String
        public let question: String
        public let screenshotBase64: String?
        public let partialReport: String
        public let stepsCompleted: Int
        public let stepsTotal: Int
    }
}

public final class PlanExecutor {
    private let variables = VariableStore()
    private let operatorBridge: OperatorBridge?
    private let onError: ErrorStrategy
    private let timeoutMs: UInt64
    private let startTime: CFAbsoluteTime

    // State for resume
    private var results: [ReportBuilder.StepResult] = []
    private var screenshots: [ReportBuilder.LabeledScreenshot] = []

    public init(
        operatorBridge: OperatorBridge? = nil,
        onError: ErrorStrategy = .abortWithScreenshot,
        timeoutMs: UInt64 = 30000,
        startTime: CFAbsoluteTime? = nil
    ) {
        self.operatorBridge = operatorBridge
        self.onError = onError
        self.timeoutMs = timeoutMs
        self.startTime = startTime ?? CFAbsoluteTimeGetCurrent()
    }

    // MARK: - Execute Plan

    public func execute(steps: [PlanStep], startAt: Int = 0) async -> PlanOutcome {
        for (offset, step) in steps.dropFirst(startAt).enumerated() {
            let index = startAt + offset

            // Timeout check
            let elapsed = UInt64((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            if elapsed > timeoutMs {
                results.append(ReportBuilder.StepResult(
                    index: index, description: step.description,
                    status: .failed("Plan timeout (\(timeoutMs)ms)"), elapsedMs: 0
                ))
                break
            }

            let stepStart = CFAbsoluteTimeGetCurrent()
            let outcome = await runStep(step, index: index, allSteps: steps)
            let stepMs = Int((CFAbsoluteTimeGetCurrent() - stepStart) * 1000)

            switch outcome {
            case .step(let status, let stepScreenshots):
                screenshots.append(contentsOf: stepScreenshots)
                results.append(ReportBuilder.StepResult(
                    index: index, description: step.description,
                    status: status, elapsedMs: stepMs
                ))

                if case .failed = status {
                    switch onError {
                    case .abort:
                        break
                    case .abortWithScreenshot:
                        if let ss = await captureScreenshot(label: "error-at-step-\(index + 1)") {
                            screenshots.append(ss)
                        }
                    case .continue:
                        continue
                    }
                    break
                }

            case .suspend(let info):
                // Plan is suspended — save state and return
                return .suspended(info)
            }
        }

        return .completed(buildResult())
    }

    /// Resume with pre-filled results/screenshots from a suspended session.
    public func restore(
        results: [ReportBuilder.StepResult],
        screenshots: [ReportBuilder.LabeledScreenshot],
        bindings: [String: UIActions.ElementBinding]
    ) {
        self.results = results
        self.screenshots = screenshots
        for (name, binding) in bindings {
            variables.bind(name, binding)
        }
    }

    /// Export current variable bindings for session persistence.
    public func exportBindings() -> [String: UIActions.ElementBinding] {
        variables.exportAll()
    }

    // MARK: - Step Dispatch

    private enum StepOutcome {
        case step(ReportBuilder.StepStatus, [ReportBuilder.LabeledScreenshot])
        case suspend(PlanOutcome.SuspendInfo)
    }

    private func runStep(_ step: PlanStep, index: Int, allSteps: [PlanStep]) async -> StepOutcome {
        do {
            var stepScreenshots: [ReportBuilder.LabeledScreenshot] = []

            switch step {
            case .navigate(let target, let scroll):
                let result = try await UIActions.navigate(target: target, scroll: scroll)
                if let ss = result.screenshot, case .image(let data, _, _, _) = ss {
                    stepScreenshots.append(ReportBuilder.LabeledScreenshot(label: "navigate-\(target)", base64: data))
                }

            case .navigateBack:
                guard let center = await UIActions.findBackButtonCenter() else {
                    return .step(.failed("No back button found"), [])
                }
                try await UIActions.tap(x: Double(center.x), y: Double(center.y))
                try await Task.sleep(nanoseconds: 300_000_000)

            case .find(let using, let value, let bindAs, let scroll):
                let binding = try await UIActions.find(using: using, value: value, scroll: scroll)
                if let name = bindAs {
                    variables.bind(name, binding)
                }

            case .findAll(let ids, let bindAs):
                let bindings = try await withThrowingTaskGroup(of: (Int, UIActions.ElementBinding).self) { group in
                    for (i, id) in ids.enumerated() {
                        group.addTask {
                            let b = try await UIActions.find(using: "accessibility id", value: id)
                            return (i, b)
                        }
                    }
                    var result = [(Int, UIActions.ElementBinding)]()
                    for try await pair in group { result.append(pair) }
                    return result.sorted(by: { $0.0 < $1.0 })
                }
                for (i, (_, binding)) in bindings.enumerated() {
                    if i < bindAs.count {
                        variables.bind(bindAs[i], binding)
                    }
                }

            case .click(let target):
                let binding = try await variables.resolveTarget(target)
                try await UIActions.click(elementId: binding.elementId)

            case .doubleTap(let target):
                let binding = try await variables.resolveTarget(target)
                guard let cx = binding.centerX, let cy = binding.centerY else {
                    return .step(.failed("No coordinates for double_tap"), [])
                }
                try await UIActions.doubleTap(x: Double(cx), y: Double(cy))

            case .longPress(let target, let durationMs):
                let binding = try await variables.resolveTarget(target)
                guard let cx = binding.centerX, let cy = binding.centerY else {
                    return .step(.failed("No coordinates for long_press"), [])
                }
                try await UIActions.longPress(x: Double(cx), y: Double(cy), durationMs: durationMs)

            case .swipe(let direction, let element):
                let (startX, startY, endX, endY) = try await resolveSwipe(direction: direction, element: element)
                try await UIActions.swipe(fromX: startX, fromY: startY, toX: endX, toY: endY)

            case .typeText(let text, let element):
                let elementId: String?
                if let el = element {
                    elementId = try await variables.resolveTarget(el).elementId
                } else {
                    elementId = nil
                }
                try await UIActions.typeText(text, elementId: elementId)

            case .screenshot(let label, _):
                if let ss = await captureScreenshot(label: label) {
                    stepScreenshots.append(ss)
                }

            case .wait(let ms):
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)

            case .waitFor(let element, let condition, let timeoutMs):
                try await waitForElement(element, condition: condition, timeoutMs: timeoutMs)

            case .verify(let condition):
                let result = await VerifyEngine.verify(condition)
                if !result.passed {
                    return .step(.failed(result.detail), [])
                }

            case .ifElementExists(let id, let thenSteps):
                let exists = (try? await UIActions.find(using: "accessibility id", value: id)) != nil
                if exists {
                    for (i, subStep) in thenSteps.enumerated() {
                        let subOutcome = await runStep(subStep, index: i, allSteps: allSteps)
                        switch subOutcome {
                        case .step(let subStatus, let subSS):
                            stepScreenshots.append(contentsOf: subSS)
                            if case .failed = subStatus {
                                return .step(subStatus, stepScreenshots)
                            }
                        case .suspend(let info):
                            return .suspend(info)
                        }
                    }
                }

            case .judge(let question, let wantScreenshot):
                return await handleJudge(
                    question: question, wantScreenshot: wantScreenshot,
                    stepIndex: index, allSteps: allSteps
                )

            case .handleUnexpected(let instruction):
                return await handleUnexpected(
                    instruction: instruction,
                    stepIndex: index, allSteps: allSteps
                )
            }

            return .step(.passed, stepScreenshots)
        } catch {
            return .step(.failed("\(error)"), [])
        }
    }

    // MARK: - Adaptive Steps (Operator) with 4-Tier Fallback

    private func handleJudge(
        question: String, wantScreenshot: Bool,
        stepIndex: Int, allSteps: [PlanStep]
    ) async -> StepOutcome {
        guard let bridge = operatorBridge else {
            return .step(.skipped("No operator configured"), [])  // Tier 4: Skip
        }

        var ssBase64: String?
        if wantScreenshot, let ss = await captureScreenshot(label: "judge") {
            ssBase64 = ss.base64
        }

        do {
            // Tries Tier 1 (Sampling) → Tier 2 (Direct API) → throws PauseForDecision
            let decision = try await bridge.ask(
                question: question,
                screenshotBase64: ssBase64,
                context: "Plan execution — operator judge step"
            )
            if decision.action == "abort" {
                return .step(.failed("Operator abort [operator]: \(decision.reasoning)"), [])
            }
            return .step(.passed, [])

        } catch is OperatorBridge.PauseForDecision {
            // Tier 3: Suspend plan, return control to client
            return await suspendPlan(
                question: question,
                screenshotBase64: ssBase64,
                context: "judge: \(question)",
                stepIndex: stepIndex,
                allSteps: allSteps
            )
        } catch {
            return .step(.failed("Operator error: \(error)"), [])
        }
    }

    private func handleUnexpected(
        instruction: String,
        stepIndex: Int, allSteps: [PlanStep]
    ) async -> StepOutcome {
        guard let bridge = operatorBridge else {
            return .step(.skipped("No operator configured"), [])  // Tier 4: Skip
        }

        // Check if an alert is visible
        let wda = try? await SessionState.shared.wdaClient()
        guard let wda, let alertInfo = await wda.getAlertText() else {
            return .step(.passed, [])  // No alert → nothing unexpected → pass
        }

        let ss = await captureScreenshot(label: "unexpected-alert")
        let question = "Alert visible: \"\(alertInfo.text)\" with buttons: \(alertInfo.buttons.joined(separator: ", ")). Instruction: \(instruction)"

        do {
            let decision = try await bridge.ask(
                question: question,
                screenshotBase64: ss?.base64,
                context: "Unexpected alert during plan execution"
            )

            switch decision.action {
            case "accept":
                _ = try? await wda.acceptAlert()
                return .step(.passed, ss.map { [$0] } ?? [])
            case "dismiss":
                _ = try? await wda.dismissAlert()
                return .step(.passed, ss.map { [$0] } ?? [])
            case "abort":
                return .step(.failed("Operator abort on alert [operator]: \(decision.reasoning)"), ss.map { [$0] } ?? [])
            default:
                return .step(.passed, ss.map { [$0] } ?? [])
            }

        } catch is OperatorBridge.PauseForDecision {
            return await suspendPlan(
                question: question,
                screenshotBase64: ss?.base64,
                context: "handle_unexpected: \(instruction)",
                stepIndex: stepIndex,
                allSteps: allSteps
            )
        } catch {
            return .step(.failed("Operator error handling alert: \(error)"), ss.map { [$0] } ?? [])
        }
    }

    // MARK: - Tier 3: Suspend Plan

    private func suspendPlan(
        question: String,
        screenshotBase64: String?,
        context: String,
        stepIndex: Int,
        allSteps: [PlanStep]
    ) async -> StepOutcome {
        let sessionId = UUID().uuidString

        let session = PlanSessionStore.SuspendedPlan(
            sessionId: sessionId,
            allSteps: allSteps,
            pausedAtIndex: stepIndex,
            pendingDecision: .init(
                question: question,
                screenshotBase64: screenshotBase64,
                context: context
            ),
            completedResults: results,
            collectedScreenshots: screenshots,
            variableBindings: exportBindings().mapValues { binding in
                PlanSessionStore.VariableBinding(
                    elementId: binding.elementId,
                    centerX: binding.centerX,
                    centerY: binding.centerY,
                    label: binding.label
                )
            },
            onError: onError,
            timeoutMs: timeoutMs,
            startTime: startTime,
            operatorBudget: 10,
            operatorCallsUsed: 0,
            createdAt: Date()
        )

        let _ = await PlanSessionStore.shared.store(session)

        let partialReport = ReportBuilder.buildReport(buildResult())

        return .suspend(PlanOutcome.SuspendInfo(
            sessionId: sessionId,
            question: question,
            screenshotBase64: screenshotBase64,
            partialReport: partialReport,
            stepsCompleted: results.count,
            stepsTotal: allSteps.count
        ))
    }

    // MARK: - Helpers

    private func buildResult() -> ReportBuilder.PlanResult {
        let totalMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        let passCount = results.filter { if case .passed = $0.status { return true }; return false }.count
        let failCount = results.filter { if case .failed = $0.status { return true }; return false }.count
        return ReportBuilder.PlanResult(
            steps: results,
            screenshots: screenshots,
            passed: failCount == 0,
            summary: "\(passCount)/\(results.count) passed (\(totalMs)ms)",
            elapsedMs: totalMs
        )
    }

    private func captureScreenshot(label: String) async -> ReportBuilder.LabeledScreenshot? {
        guard let img = await ActionScreenshot.capture(),
              case .image(let data, _, _, _) = img else { return nil }
        return ReportBuilder.LabeledScreenshot(label: label, base64: data)
    }

    private func waitForElement(_ elementId: String, condition: WaitCondition, timeoutMs: Int) async throws {
        let deadline = CFAbsoluteTimeGetCurrent() + Double(timeoutMs) / 1000.0
        let pollInterval: UInt64 = 200_000_000  // 200ms

        while CFAbsoluteTimeGetCurrent() < deadline {
            let found = (try? await UIActions.find(using: "accessibility id", value: elementId)) != nil
            switch condition {
            case .appears where found: return
            case .disappears where !found: return
            default: break
            }
            try await Task.sleep(nanoseconds: pollInterval)
        }

        let condStr = condition == .appears ? "appear" : "disappear"
        throw PlanError.stepFailed("Timeout: \"\(elementId)\" did not \(condStr) within \(timeoutMs)ms")
    }

    private func resolveSwipe(direction: String, element: StepTarget?) async throws -> (Double, Double, Double, Double) {
        var cx = 200.0, cy = 400.0
        if let el = element {
            let binding = try await variables.resolveTarget(el)
            if let x = binding.centerX, let y = binding.centerY {
                cx = Double(x); cy = Double(y)
            }
        }
        let dist = 200.0
        switch direction {
        case "up": return (cx, cy, cx, cy - dist)
        case "down": return (cx, cy, cx, cy + dist)
        case "left": return (cx, cy, cx - dist, cy)
        case "right": return (cx, cy, cx + dist, cy)
        default: return (cx, cy, cx, cy - dist)
        }
    }
}
