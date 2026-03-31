import Foundation
import MCP

public enum ErrorStrategy: String, Sendable {
    case abort
    case abortWithScreenshot = "abort_with_screenshot"
    case `continue` = "continue"
}

public final class PlanExecutor {
    private let variables = VariableStore()
    private let operatorBridge: OperatorBridge?
    private let onError: ErrorStrategy
    private let timeoutMs: UInt64

    public init(
        operatorBridge: OperatorBridge? = nil,
        onError: ErrorStrategy = .abortWithScreenshot,
        timeoutMs: UInt64 = 30000
    ) {
        self.operatorBridge = operatorBridge
        self.onError = onError
        self.timeoutMs = timeoutMs
    }

    // MARK: - Execute Plan

    public func execute(steps: [PlanStep]) async -> ReportBuilder.PlanResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        var results: [ReportBuilder.StepResult] = []
        var screenshots: [ReportBuilder.LabeledScreenshot] = []

        for (index, step) in steps.enumerated() {
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
            let (status, stepScreenshots) = await runStep(step, index: index)
            let stepMs = Int((CFAbsoluteTimeGetCurrent() - stepStart) * 1000)

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
        }

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        let passCount = results.filter { if case .passed = $0.status { return true }; return false }.count
        let allPassed = passCount == results.count

        return ReportBuilder.PlanResult(
            steps: results,
            screenshots: screenshots,
            passed: allPassed,
            summary: "\(passCount)/\(results.count) passed (\(totalMs)ms)",
            elapsedMs: totalMs
        )
    }

    // MARK: - Step Dispatch

    private func runStep(_ step: PlanStep, index: Int) async -> (ReportBuilder.StepStatus, [ReportBuilder.LabeledScreenshot]) {
        do {
            var screenshots: [ReportBuilder.LabeledScreenshot] = []

            switch step {
            case .navigate(let target, let scroll):
                let result = try await UIActions.navigate(target: target, scroll: scroll)
                if let ss = result.screenshot, case .image(let data, _, _, _) = ss {
                    screenshots.append(ReportBuilder.LabeledScreenshot(label: "navigate-\(target)", base64: data))
                }

            case .navigateBack:
                guard let center = await UIActions.findBackButtonCenter() else {
                    return (.failed("No back button found"), [])
                }
                try await WDAClient.shared.tap(x: Double(center.x), y: Double(center.y))
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
                    return (.failed("No coordinates for double_tap"), [])
                }
                try await WDAClient.shared.doubleTap(x: Double(cx), y: Double(cy))

            case .longPress(let target, let durationMs):
                let binding = try await variables.resolveTarget(target)
                guard let cx = binding.centerX, let cy = binding.centerY else {
                    return (.failed("No coordinates for long_press"), [])
                }
                try await WDAClient.shared.longPress(x: Double(cx), y: Double(cy), durationMs: durationMs)

            case .swipe(let direction, let element):
                let (startX, startY, endX, endY) = try await resolveSwipe(direction: direction, element: element)
                try await WDAClient.shared.swipe(startX: startX, startY: startY, endX: endX, endY: endY)

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
                    screenshots.append(ss)
                }

            case .wait(let ms):
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)

            case .waitFor(let element, let condition, let timeoutMs):
                try await waitForElement(element, condition: condition, timeoutMs: timeoutMs)

            case .verify(let condition):
                let result = await VerifyEngine.verify(condition)
                if !result.passed {
                    return (.failed(result.detail), [])
                }

            case .ifElementExists(let id, let thenSteps):
                let exists = (try? await UIActions.find(using: "accessibility id", value: id)) != nil
                if exists {
                    for (i, subStep) in thenSteps.enumerated() {
                        let (subStatus, subSS) = await runStep(subStep, index: i)
                        screenshots.append(contentsOf: subSS)
                        if case .failed = subStatus {
                            return (subStatus, screenshots)
                        }
                    }
                }

            case .judge(let question, let wantScreenshot):
                return await handleJudge(question: question, wantScreenshot: wantScreenshot)

            case .handleUnexpected(let instruction):
                return await handleUnexpected(instruction: instruction)
            }

            return (.passed, screenshots)
        } catch {
            return (.failed("\(error)"), [])
        }
    }

    // MARK: - Adaptive Steps (Operator)

    private func handleJudge(question: String, wantScreenshot: Bool) async -> (ReportBuilder.StepStatus, [ReportBuilder.LabeledScreenshot]) {
        guard let bridge = operatorBridge else {
            return (.skipped("No operator configured"), [])
        }

        var ssBase64: String?
        if wantScreenshot, let ss = await captureScreenshot(label: "judge") {
            ssBase64 = ss.base64
        }

        do {
            let decision = try await bridge.ask(
                question: question,
                screenshotBase64: ssBase64,
                context: "Plan execution — operator judge step"
            )
            if decision.action == "abort" {
                return (.failed("Operator abort: \(decision.reasoning)"), [])
            }
            return (.passed, [])
        } catch {
            return (.failed("Operator error: \(error)"), [])
        }
    }

    private func handleUnexpected(instruction: String) async -> (ReportBuilder.StepStatus, [ReportBuilder.LabeledScreenshot]) {
        guard let bridge = operatorBridge else {
            return (.skipped("No operator configured"), [])
        }

        // Check if an alert is visible
        guard let alertInfo = await WDAClient.shared.getAlertText() else {
            return (.passed, [])  // No alert → nothing unexpected → pass
        }

        // Alert visible — ask operator what to do
        let ss = await captureScreenshot(label: "unexpected-alert")
        do {
            let decision = try await bridge.ask(
                question: "Alert visible: \"\(alertInfo.text)\" with buttons: \(alertInfo.buttons.joined(separator: ", ")). Instruction: \(instruction)",
                screenshotBase64: ss?.base64,
                context: "Unexpected alert during plan execution"
            )

            switch decision.action {
            case "accept":
                _ = try? await WDAClient.shared.acceptAlert()
                return (.passed, ss.map { [$0] } ?? [])
            case "dismiss":
                _ = try? await WDAClient.shared.dismissAlert()
                return (.passed, ss.map { [$0] } ?? [])
            case "abort":
                return (.failed("Operator abort on alert: \(decision.reasoning)"), ss.map { [$0] } ?? [])
            default:
                return (.passed, ss.map { [$0] } ?? [])
            }
        } catch {
            return (.failed("Operator error handling alert: \(error)"), ss.map { [$0] } ?? [])
        }
    }

    // MARK: - Helpers

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
        // Default: center of screen, 200px swipe distance
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
