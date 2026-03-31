# Story: Tier 3 — Orchestra/Operator-Architektur

**Quelle:** STORY-llm-interaction-optimization.md, Tier 3
**Prioritaet:** High — reduziert Round-Trips um ~85%, LLM-Wartezeit von 15min auf ~1min
**Aufwand:** ~14-16h gesamt (run_plan 10h + Haiku Operator 4-6h)
**Tier:** Pro
**Voraussetzungen:** Tier 1 Items 1+2 (Frame in find_element, element_id in Gesten) — bereits erledigt

---

## Kernproblem

Das LLM ist der Flaschenhals, nicht die Tools.

| Metrik | Messwert (E2E-Session) |
|--------|----------------------|
| Tool-Antwortzeit | 10-60ms |
| LLM-Denkzeit zwischen Calls | 2-30s |
| Tool-Zeit gesamt (70 Calls) | ~4s |
| LLM-Wartezeit gesamt | ~5-15min |
| **LLM-Anteil an Gesamtzeit** | **99%** |

Tier 1+2 reduzieren die Anzahl der Round-Trips (70 → 35). Aber jeder Trip
geht durch das langsame Orchestrator-LLM. `run_plan` eliminiert den LLM
aus der Ausfuehrungsschleife komplett.

---

## Architektur-Uebersicht

```
┌─────────────────────────────────────────────────────────────┐
│  OPUS / SONNET  (Orchestrator — Claude Code / MCP Client)   │
│  Plant strategisch, schreibt run_plan JSON, bewertet Report │
│  1 Tool-Call pro Testsequenz statt 10-15                    │
└──────────────────┬──────────────────────────────────────────┘
                   │ run_plan({ steps: [...] })
                   ▼
┌─────────────────────────────────────────────────────────────┐
│  PlanExecutor  (im MCP-Server, deterministisch)             │
│  Parst JSON → fuehrt Steps sequentiell aus → Report         │
│  Nutzt WDAClient + ActionScreenshot direkt (kein MCP-Loop)  │
│  ~500ms fuer 6-Step-Plan statt ~25s via Orchestrator        │
│                                                             │
│  Bei Fehler + operator_model gesetzt:                       │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  HAIKU  (Operator — Anthropic API, optional)           │ │
│  │  Bekommt: Screenshot + Kontext + Frage                 │ │
│  │  Liefert: Entscheidung (accept/dismiss/skip/abort)     │ │
│  │  200-500ms pro Entscheidung                            │ │
│  └────────────────────────────────────────────────────────┘ │
└──────────────────┬──────────────────────────────────────────┘
                   │ Kompakter Report + optionale Screenshots
                   ▼
┌─────────────────────────────────────────────────────────────┐
│  Orchestrator empfaengt Report, plant naechsten Schritt     │
└─────────────────────────────────────────────────────────────┘
```

---

## Komponente 1: run_plan Tool

### Tool-Schema

```json
{
  "name": "run_plan",
  "description": "Execute a structured test plan deterministically. Runs find/click/verify/screenshot steps internally without LLM round-trips. Returns a compact execution report. 50x faster than individual tool calls for sequential UI interactions.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "steps": {
        "type": "array",
        "description": "Ordered list of plan steps to execute",
        "items": { "type": "object" }
      },
      "on_error": {
        "type": "string",
        "enum": ["abort_with_screenshot", "continue", "abort"],
        "description": "Default error strategy. Default: abort_with_screenshot"
      },
      "timeout_ms": {
        "type": "number",
        "description": "Total plan timeout in ms. Default: 30000"
      },
      "operator_model": {
        "type": "string",
        "description": "LLM model for adaptive steps (e.g. 'haiku'). Requires ANTHROPIC_API_KEY env var. Omit for pure deterministic execution."
      }
    },
    "required": ["steps"]
  }
}
```

### Step-Typen (Plan-DSL)

Jeder Step ist ein JSON-Objekt mit genau einem Aktions-Key.
`$variablen` referenzieren vorher gebundene Element-IDs.

#### Navigation

```json
{"navigate": "Screen Name"}
{"navigate": "Screen Name", "scroll": true}
{"navigate_back": true}
```

Intern: `find_element` → `click_element` → `sleep(300ms)` → compact screenshot.
`navigate_back`: Findet Back-Button via bekannter Heuristik (BackButton ID, dann class chain).

#### Element-Suche

```json
{"find": "accessibility_id or label", "as": "varName"}
{"find": {"using": "predicate string", "value": "label CONTAINS 'foo'"}, "as": "varName"}
{"find_all": ["id1", "id2"], "as": ["var1", "var2"]}
```

Speichert in VariableStore: `{ element_id, frame: {x,y,w,h}, center: {x,y}, label }`.
`find_all`: Parallel via WDA, gebundene Variablen pro Element.

#### Aktionen

```json
{"click": "$varName"}
{"click": "direct label"}
{"double_tap": "$varName"}
{"long_press": "$varName", "duration_ms": 1000}
{"swipe": {"direction": "up", "element": "$varName"}}
{"swipe": {"direction": "down"}}
{"type": {"text": "Hello", "element": "$varName"}}
{"type": {"text": "Hello"}}
```

`"direct label"` ohne `$`-Prefix: Shorthand fuer find-by-label + click (intern aufgeloest).
Mit `$`: Nutzt gespeicherte element_id, kein erneuter Find.

#### Verifikation

```json
{"verify": {"screen_contains": ["Label A", "Label B"]}}
{"verify": {"element_label": "accessibility_id", "equals": "expected text"}}
{"verify": {"element_label": "accessibility_id", "contains": "partial"}}
{"verify": {"element_exists": "accessibility_id"}}
{"verify": {"element_not_exists": "accessibility_id"}}
{"verify": {"element_count": {"using": "class name", "value": "XCUIElementTypeCell"}, "equals": 5}}
{"verify": {"element_count": {"using": "class name", "value": "XCUIElementTypeCell"}, "gte": 3}}
```

Jede Verifikation produziert PASS/FAIL im Report.
Bei FAIL greift die `on_error`-Strategie (Step-Level oder Plan-Level).

#### Screenshot

```json
{"screenshot": {"label": "after-double-tap"}}
{"screenshot": {"label": "final-state", "quality": "full"}}
```

Default quality: `compact`. Screenshots werden als Image-Content in der MCP-Response zurueckgegeben.
Label dient als Beschriftung im Report.

#### Timing

```json
{"wait": 500}
{"wait_for": {"element": "loading-spinner", "disappears": true, "timeout_ms": 5000}}
{"wait_for": {"element": "success-banner", "appears": true, "timeout_ms": 3000}}
```

`wait`: Feste Pause in ms.
`wait_for`: Pollt Element-Existenz alle 200ms bis Bedingung erfuellt oder Timeout.

#### Kontrollfluss

```json
{"if_element_exists": "optional-banner", "then": [
  {"click": "Dismiss"},
  {"wait": 300}
]}
```

Einfache bedingte Ausfuehrung. Kein Nesting tiefer als 1 Ebene — das ist ein
Plan-Executor, keine Programmiersprache. Komplexe Logik gehoert ins Orchestrator-LLM.

#### Adaptiv (erfordert Operator)

```json
{"judge": {"screenshot": true, "question": "Is the settings page fully loaded?"}}
{"handle_unexpected": "If an alert appears, read it and decide accept or dismiss"}
```

Diese Steps werden nur ausgefuehrt wenn `operator_model` gesetzt ist.
Ohne Operator: `judge` wird zu SKIP (Warning im Report), `handle_unexpected` wird ignoriert.

---

## Komponente 2: PlanExecutor Engine

### Interner Aufbau

```
PlanExecutor (actor)
├── PlanParser          — JSON → [PlanStep] (validiert Schema)
├── VariableStore       — $name → ElementBinding { id, frame, center, label }
├── StepRunner          — Fuehrt einzelnen Step aus, nutzt WDAClient direkt
├── VerifyEngine        — Prueft Assertions gegen WDA-Zustand
├── ReportBuilder       — Sammelt Step-Ergebnisse, generiert kompakten Report
└── OperatorBridge?     — Optional: Haiku-API-Client fuer adaptive Steps
```

### Dateistruktur (im Pro-Modul)

```
Sources/SilbercueSwiftPro/
├── PlanExecutor/
│   ├── PlanExecutor.swift       — Hauptklasse, orchestriert Steps
│   ├── PlanParser.swift         — JSON → [PlanStep] Typen
│   ├── PlanStep.swift           — enum PlanStep { case navigate, find, click, ... }
│   ├── VariableStore.swift      — $variable Bindungen
│   ├── StepRunner.swift         — Fuehrt Steps via WDAClient aus
│   ├── VerifyEngine.swift       — Assertion-Logik
│   ├── ReportBuilder.swift      — Ergebnis-Aggregation
│   └── OperatorBridge.swift     — Haiku-API-Client (optional)
├── Tools/
│   ├── RunPlanTool.swift        — MCP Tool-Definition + Handler
│   └── ... (bestehende Pro-Tools)
```

### Kernklasse: PlanExecutor

```swift
actor PlanExecutor {
    private let wda: WDAClient
    private let variables: VariableStore
    private let report: ReportBuilder
    private let operator_: OperatorBridge?
    private let onError: ErrorStrategy
    private let timeoutMs: UInt64

    enum ErrorStrategy { case abort, abortWithScreenshot, continue_ }

    struct PlanResult {
        let steps: [StepResult]
        let screenshots: [LabeledScreenshot]
        let passed: Bool
        let summary: String       // "6/6 passed (487ms)"
        let elapsedMs: Int
    }

    struct StepResult {
        let index: Int
        let description: String   // "find 'Double Tap Zone' as $target"
        let status: Status        // .passed, .failed(reason), .skipped
        let elapsedMs: Int
    }

    enum Status {
        case passed
        case failed(String)
        case skipped(String)
    }

    func execute(steps: [PlanStep]) async -> PlanResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        var results: [StepResult] = []
        var screenshots: [LabeledScreenshot] = []

        for (index, step) in steps.enumerated() {
            // Timeout-Check
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if UInt64(elapsed * 1000) > timeoutMs {
                results.append(StepResult(
                    index: index,
                    description: step.description,
                    status: .failed("Plan timeout (\(timeoutMs)ms)"),
                    elapsedMs: 0
                ))
                break
            }

            let stepStart = CFAbsoluteTimeGetCurrent()
            let result = await runStep(step, index: index)
            let stepMs = Int((CFAbsoluteTimeGetCurrent() - stepStart) * 1000)

            // Collect screenshots from step
            if let ss = result.screenshot {
                screenshots.append(ss)
            }

            let stepResult = StepResult(
                index: index,
                description: step.description,
                status: result.status,
                elapsedMs: stepMs
            )
            results.append(stepResult)

            // Error handling
            if case .failed(let reason) = result.status {
                switch onError {
                case .abort:
                    break // exit loop
                case .abortWithScreenshot:
                    if let ss = await captureErrorScreenshot(step: index, reason: reason) {
                        screenshots.append(ss)
                    }
                    break // exit loop after screenshot
                case .continue_:
                    continue
                }
                break
            }
        }

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        let passCount = results.filter { if case .passed = $0.status { return true }; return false }.count
        let allPassed = passCount == results.count

        return PlanResult(
            steps: results,
            screenshots: screenshots,
            passed: allPassed,
            summary: "\(passCount)/\(results.count) passed (\(totalMs)ms)",
            elapsedMs: totalMs
        )
    }
}
```

### Warum direkte WDA-Calls statt ToolRegistry.dispatch?

```
Option A: ToolRegistry.dispatch("find_element", args)
  + Wiederverwendung der gesamten Tool-Logik (Smart Context, Caching, etc.)
  - Serialisierung: [String: Value] → Tool → [String: Value] → Response-String parsen
  - Screenshot-Handling: Tool gibt Base64-String zurueck, wir brauchen CGImage
  - ~2-5ms Overhead pro Call (bei 6 Steps: 12-30ms — akzeptabel)

Option B: WDAClient direkt aufrufen
  + Kein Serialisierungs-Overhead
  + Typsicherheit: find gibt ElementBinding zurueck, nicht String
  + Screenshot als CGImage, nicht Base64
  - Dupliziert Logik (Smart Scroll, element Frame lookup, etc.)
```

**Entscheidung: Hybrid-Approach.**

Fuer atomare WDA-Operationen (find, click, get_rect): WDAClient direkt.
Fuer komplexe Operationen die bestehende Logik kapseln (navigate, scroll-find):
Interne Swift-Funktionen extrahieren aus den bestehenden Tool-Handlern.

Konkret: Die Kernlogik aus `UITools.findElement`, `UITools.navigate`, etc. in
wiederverwendbare Funktionen refactoren, die sowohl vom Tool-Handler als auch
vom PlanExecutor aufgerufen werden koennen.

```swift
// Vorher (nur Tool-Handler):
enum UITools {
    static func findElement(_ args: [String: Value]?) async -> CallTool.Result { ... }
}

// Nachher (extrahierte Kernlogik):
enum UIActions {
    struct ElementBinding {
        let id: String
        let frame: CGRect
        let center: CGPoint
        let label: String?
    }

    /// Kern-Find-Logik — genutzt von UITools.findElement UND PlanExecutor
    static func find(using: String, value: String, scroll: Bool = false) async throws -> ElementBinding { ... }

    /// Kern-Click-Logik
    static func click(elementId: String) async throws { ... }

    /// Kern-Navigate-Logik
    static func navigate(target: String, back: Bool = false, settlMs: Int = 300) async throws -> CGImage? { ... }
}

// Tool-Handler wird duenner Wrapper:
enum UITools {
    static func findElement(_ args: [String: Value]?) async -> CallTool.Result {
        let binding = try await UIActions.find(using: using, value: value, scroll: scroll)
        return .ok("element-\(binding.id) found — frame: ...")
    }
}
```

Dieser Refactor ist der **einzige architekturelle Eingriff** in die bestehende Free-Codebase.
Er macht den Free-Code besser (duennere Handler, testbare Kernlogik) und ermoeglicht
dem Pro-PlanExecutor die Wiederverwendung ohne Duplizierung.

---

## Komponente 3: VariableStore

```swift
/// Scoped variable bindings within a plan execution.
final class VariableStore {
    private var bindings: [String: ElementBinding] = [:]

    struct ElementBinding {
        let elementId: String
        let frame: CGRect
        let center: CGPoint
        let label: String?
    }

    func bind(_ name: String, _ binding: ElementBinding) {
        bindings[name] = binding
    }

    func resolve(_ ref: String) throws -> ElementBinding {
        guard ref.hasPrefix("$") else {
            throw PlanError.invalidVariable(ref)
        }
        let name = String(ref.dropFirst())
        guard let binding = bindings[name] else {
            throw PlanError.undefinedVariable(name, available: Array(bindings.keys))
        }
        return binding
    }

    /// Resolve a step target: "$var" → stored binding, "plain text" → find by label
    func resolveOrFind(_ target: String) async throws -> ElementBinding {
        if target.hasPrefix("$") {
            return try resolve(target)
        }
        // Implicit find by label
        return try await UIActions.find(using: "accessibility id", value: target)
    }
}
```

Variable-Referenzen in Steps:
- `"$target"` → Lookup in VariableStore (schnell, kein WDA-Call)
- `"Double Tap Zone"` → Impliziter Find via WDA (15ms)
- Fehler wenn `$undeclared` referenziert wird → klare Fehlermeldung mit verfuegbaren Variablen

---

## Komponente 4: VerifyEngine

```swift
enum VerifyEngine {
    struct VerifyResult {
        let passed: Bool
        let detail: String  // "tap-count label = 'Tap Count: 1' (expected: 'Tap Count: 1')"
    }

    static func verify(_ condition: VerifyCondition) async -> VerifyResult {
        switch condition {
        case .screenContains(let labels):
            // get_source(pruned) → check each label exists
            ...
        case .elementLabel(let id, let matcher):
            // find_element(id) → get label → match
            ...
        case .elementExists(let id):
            // find_element(id) → found?
            ...
        case .elementNotExists(let id):
            // find_element(id) → NOT found = PASS
            ...
        case .elementCount(let query, let matcher):
            // find_elements(query) → count → match
            ...
        }
    }
}
```

Verify-Steps sind der Kern des Werteversprechens: Das Orchestrator-LLM muss nicht
mehr Screenshots visuell parsen um "Tap Count: 1" zu lesen. Der PlanExecutor prueft
programmatisch und meldet PASS/FAIL.

---

## Komponente 5: ReportBuilder

### Report-Format (zurueck an Orchestrator)

**Kompakt bei Erfolg** — das LLM braucht nicht jeden Step einzeln zu lesen:

```
Plan executed: 6/6 passed (487ms)

Steps:
  [OK]   1. navigate "Button & Tap Tests" (82ms)
  [OK]   2. verify screen_contains ["Tap Me", "Double Tap Zone"] (15ms)
  [OK]   3. find "Double Tap Zone" → $target (12ms)
  [OK]   4. double_tap $target at (201, 403) (20ms)
  [OK]   5. verify doubletap-count = "Double Tap: 1" (8ms)
  [OK]   6. screenshot "after-double-tap" (16ms)

[Screenshot: after-double-tap]
```

**Ausfuehrlich bei Fehler** — das LLM braucht Kontext fuer Diagnose:

```
Plan FAILED at step 5: 4/6 steps, 1 failed, 1 skipped (523ms)

Steps:
  [OK]   1. navigate "Button & Tap Tests" (82ms)
  [OK]   2. verify screen_contains ["Tap Me", "Double Tap Zone"] (15ms)
  [OK]   3. find "Double Tap Zone" → $target (12ms)
  [OK]   4. double_tap $target at (201, 403) (20ms)
  [FAIL] 5. verify doubletap-count = "Double Tap: 1"
         → Actual: "Double Tap: 0" (element found, label mismatch)
  [SKIP] 6. screenshot (aborted)

[Screenshot: error-at-step-5]
```

### MCP Response

```swift
func buildMCPResponse(_ result: PlanResult) -> CallTool.Result {
    var content: [Tool.Content] = [
        .text(text: result.report, annotations: nil, _meta: nil)
    ]

    // Labeled screenshots
    for ss in result.screenshots {
        content.append(.image(data: ss.base64, mimeType: "image/jpeg", annotations: nil, _meta: nil))
        content.append(.text(text: ss.label, annotations: nil, _meta: nil))
    }

    return .init(content: content, isError: result.passed ? nil : true)
}
```

---

## Komponente 6: OperatorBridge (Haiku)

### Wann der Operator einspringt

Der Operator ist **nicht** im Haupt-Ausfuehrungspfad. Er wird nur aufgerufen bei:

1. **`judge`-Step**: Explizit im Plan angeforderte visuelle/semantische Beurteilung
2. **`handle_unexpected`-Step**: Reaktion auf unerwarteten Zustand
3. **Optionaler Fallback**: Wenn `on_error: "escalate"` gesetzt und ein Step fehlschlaegt

Ohne `operator_model` im Plan: Alle adaptiven Steps werden SKIP mit Warning.

### API-Integration

```swift
actor OperatorBridge {
    private let apiKey: String
    private let model: String  // "claude-haiku-4-5-20251001"
    private let timeout: TimeInterval = 5  // Haiku muss schnell sein

    struct Decision {
        let action: String       // "accept", "dismiss", "skip", "abort", "continue"
        let reasoning: String    // Einzeiler fuer Report
    }

    /// Frage den Operator mit Screenshot + Kontext
    func ask(
        question: String,
        screenshot: Data?,      // JPEG, compact quality
        context: String          // Bisherige Plan-Ausfuehrung als Text
    ) async throws -> Decision {
        var content: [[String: Any]] = []

        // Screenshot als Vision-Input
        if let ss = screenshot {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": ss.base64EncodedString()
                ]
            ])
        }

        // Frage + Kontext
        content.append([
            "type": "text",
            "text": """
                You are a fast UI test operator. Answer concisely.

                Context: \(context)

                Question: \(question)

                Respond with JSON: {"action": "accept|dismiss|skip|abort|continue", "reasoning": "one line"}
                """
        ])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 100,
            "messages": [["role": "user", "content": content]]
        ]

        // Direct HTTP call to Anthropic API
        let response = try await httpPost(
            url: "https://api.anthropic.com/v1/messages",
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json"
            ],
            body: body,
            timeout: timeout
        )

        return try parseDecision(response)
    }
}
```

### API-Key Handling

```
Prioritaet:
1. Env ANTHROPIC_API_KEY (gesetzt vom User oder Claude Code)
2. Env SILBERCUESWIFT_OPERATOR_KEY (dedizierter Key fuer Operator)
3. Nicht gesetzt → operator_model wird ignoriert, Warning im Report
```

Kein Key im Code, kein Key in Config-Dateien. Nur Environment.

### Kosten-Kontrolle

Haiku-Vision-Call mit kompaktem Screenshot (~50KB): ~0.001$ pro Call.
Bei 3-5 Operator-Calls pro Plan: ~0.005$ pro Plan-Ausfuehrung.
Das ist vernachlaessigbar gegenueber den Opus-Calls die eingespart werden
(ein Opus-Call mit Screenshot: ~0.05-0.10$).

**Budget-Limit:** Optionaler `operator_budget` Parameter im Plan.
Default: max 10 Operator-Calls pro Plan. Danach: `abort_with_screenshot`.

---

## Beispiel-Szenarien

### Szenario 1: E2E Double-Tap Test (deterministisch)

**Orchestrator schickt:**
```json
{
  "steps": [
    {"navigate": "Button & Tap Tests"},
    {"verify": {"screen_contains": ["Tap Me", "Double Tap Zone", "Long Press Zone"]}},
    {"find": "Double Tap Zone", "as": "target"},
    {"double_tap": "$target"},
    {"wait": 300},
    {"verify": {"element_label": "doubletap-count", "contains": "Double Tap: 1"}},
    {"screenshot": {"label": "double-tap-verified"}}
  ],
  "on_error": "abort_with_screenshot"
}
```

**Execution trace:**
```
  1. navigate "Button & Tap Tests"
     → find("Button & Tap Tests") 12ms → click 8ms → settle 300ms → screenshot 16ms
  2. verify screen_contains
     → get_source(pruned) 25ms → check 3 labels → all found
  3. find "Double Tap Zone" → $target
     → find 10ms → rect {x:101, y:363, w:200, h:80} → center (201, 403)
  4. double_tap $target
     → WDA POST /wda/doubleTap {x:201, y:403} 18ms
  5. wait 300
     → sleep 300ms
  6. verify doubletap-count contains "Double Tap: 1"
     → find("doubletap-count") 8ms → label "Double Tap: 1" → PASS
  7. screenshot "double-tap-verified"
     → capture compact 16ms

  Total: 7/7 passed (736ms)
```

**Vergleich:**
- Vorher: 10 Round-Trips, ~25s LLM-Wartezeit
- Nachher: 1 Round-Trip, ~3s LLM-Denkzeit + 736ms Ausfuehrung

### Szenario 2: Navigation durch 5 Screens (deterministisch)

**Orchestrator schickt:**
```json
{
  "steps": [
    {"navigate": "Button & Tap Tests"},
    {"screenshot": {"label": "buttons"}},
    {"navigate_back": true},
    {"navigate": "Drag & Drop Tests"},
    {"screenshot": {"label": "drag-drop"}},
    {"navigate_back": true},
    {"navigate": "Scroll & List Tests"},
    {"screenshot": {"label": "scroll-list"}},
    {"navigate_back": true},
    {"navigate": "Text Input Tests"},
    {"screenshot": {"label": "text-input"}},
    {"navigate_back": true},
    {"navigate": "Visual Regression Tests"},
    {"screenshot": {"label": "visual-regression"}}
  ]
}
```

**Vorher:** 5 Screens × (find + click + screenshot + navigate_back) = ~20 Calls, ~60s
**Nachher:** 1 Call, ~4s Ausfuehrung

### Szenario 3: Alert-Handling mit Operator (adaptiv)

```json
{
  "steps": [
    {"navigate": "Settings"},
    {"click": "Delete Account"},
    {"wait": 500},
    {"handle_unexpected": "An alert may appear. If it asks for confirmation, accept it. If it shows an error, screenshot and abort."},
    {"verify": {"screen_contains": ["Account Deleted"]}}
  ],
  "operator_model": "haiku",
  "on_error": "abort_with_screenshot"
}
```

**Execution trace (adaptiv):**
```
  1. navigate "Settings" → OK (350ms)
  2. click "Delete Account" → OK (25ms)
  3. wait 500ms
  4. handle_unexpected
     → Check: Alert visible? → JA, Text: "Are you sure? This cannot be undone."
     → Operator (Haiku): screenshot + question
     → Haiku: {"action": "accept", "reasoning": "Confirmation dialog, user wants deletion"}
     → accept_alert → OK (180ms + 450ms Haiku)
  5. verify screen_contains ["Account Deleted"] → PASS
```

### Szenario 4: Scroll-Heavy Test (deterministisch)

```json
{
  "steps": [
    {"navigate": "Scroll & List Tests"},
    {"find": {"using": "accessibility id", "value": "item-42"}, "as": "item"},
    {"verify": {"element_exists": "item-42"}},
    {"click": "$item"},
    {"verify": {"screen_contains": ["Item 42 Detail"]}},
    {"screenshot": {"label": "item-42-detail"}}
  ]
}
```

Hier nutzt `find` intern SmartScroll (scroll: true ist Default im PlanExecutor,
weil off-screen Elemente der haeufigste Fehlerfall sind).

---

## Implementierungsplan

### Phase 1: UIActions Refactor (Core, 2-3h)

Extrahiere wiederverwendbare Kernlogik aus UITools in `UIActions`:

```
Sources/SilbercueSwiftCore/
├── UIActions.swift (NEU)     — find, click, navigate, getSource, typeText
├── Tools/UITools.swift       — Tool-Handler werden duenne Wrapper
```

**Betroffene Funktionen:**
- `UITools.findElement` → `UIActions.find()` + Wrapper
- `UITools.clickElement` → `UIActions.click()` + Wrapper
- `UITools.navigate` → `UIActions.navigate()` + Wrapper
- `UITools.getSource` (pruned) → `UIActions.getSourcePruned()` + Wrapper

**Akzeptanzkriterien Phase 1:**
- [ ] UIActions.find() gibt ElementBinding zurueck (id, frame, center, label)
- [ ] UIActions.click() nimmt elementId, wirft bei Fehler
- [ ] UIActions.navigate() gibt optionales CGImage zurueck
- [ ] Alle bestehenden UITools-Handler nutzen UIActions intern
- [ ] Keine Verhaltensaenderung fuer bestehende Tool-Aufrufe (Regression-Test)

### Phase 2: PlanParser + PlanStep Types (Pro, 1-2h)

```swift
enum PlanStep {
    case navigate(target: String, back: Bool, scroll: Bool, settlMs: Int)
    case find(using: String, value: String, bindAs: String?, scroll: Bool)
    case findAll(ids: [String], bindAs: [String])
    case click(target: StepTarget)          // $var oder "label"
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

    /// Human-readable step description fuer Report
    var description: String { ... }
}

enum StepTarget {
    case variable(String)    // "$varName"
    case label(String)       // "Button Text"
}
```

**Akzeptanzkriterien Phase 2:**
- [ ] PlanParser.parse(json) → [PlanStep] fuer alle Step-Typen
- [ ] Validierungsfehler bei unbekannten Keys, fehlenden Required-Fields
- [ ] StepTarget erkennt $-Prefix korrekt

### Phase 3: PlanExecutor + StepRunner (Pro, 3-4h)

Kern-Executor der Steps sequentiell ausfuehrt.

**Akzeptanzkriterien Phase 3:**
- [ ] PlanExecutor.execute(steps) liefert PlanResult
- [ ] navigate-Step nutzt UIActions.navigate()
- [ ] find-Step bindet Variable in VariableStore
- [ ] click/doubleTap/longPress nutzen gespeicherte element_id
- [ ] verify-Steps pruefen Bedingungen via WDA
- [ ] screenshot-Steps capturen compact/full
- [ ] wait/waitFor funktionieren mit Timeout
- [ ] on_error: abort/continue/abort_with_screenshot
- [ ] Plan-Timeout bricht Ausfuehrung ab
- [ ] ifElementExists fuehrt bedingt aus

### Phase 4: ReportBuilder + MCP-Integration (Pro, 1-2h)

Report-Generator und Tool-Registration.

**Akzeptanzkriterien Phase 4:**
- [ ] Kompakter Report bei Erfolg (Step-Liste, Timing, Summary)
- [ ] Detaillierter Report bei Fehler (Reason, Actual vs Expected)
- [ ] Screenshots als Image-Content in MCP-Response
- [ ] run_plan in ToolRegistry registriert (Pro-Tier)
- [ ] Tool-Schema korrekt, Claude Code erkennt das Tool

### Phase 5: OperatorBridge / Haiku (Pro, 4-6h)

Optionale LLM-Integration fuer adaptive Steps.

**Akzeptanzkriterien Phase 5:**
- [ ] OperatorBridge.ask() sendet Haiku-Request via Anthropic API
- [ ] Vision-Input: Compact Screenshot als Base64
- [ ] Timeout: 5s, danach Fallback zu abort_with_screenshot
- [ ] judge-Step: Screenshot + Frage → Haiku → Decision
- [ ] handle_unexpected: Alert-Check → Haiku wenn Alert sichtbar
- [ ] Budget-Limit: max N Operator-Calls pro Plan
- [ ] Ohne API-Key: Adaptive Steps werden SKIP mit Warning
- [ ] Ohne operator_model: Adaptive Steps werden SKIP (kein Warning)

---

## Risiken und Mitigationen

### Risiko 1: WDA-Session wird stale waehrend Plan

**Problem:** Langer Plan (30s+), WDA-Session kann timeout'en.
**Mitigation:** PlanExecutor prueft WDA-Health vor erstem Step und nach Fehlern.
Bei stale Session: Auto-Recreate (wie launch_app es bereits tut).

### Risiko 2: Element-IDs werden ungueltig nach Navigation

**Problem:** `find` auf Screen A gibt element-3. Nach `navigate` zu Screen B
ist element-3 nicht mehr gueltig.
**Mitigation:** VariableStore markiert Bindings mit dem Screen-Context
(NavigationBar-Label). Bei Cross-Screen-Referenz: Warning oder Auto-Refind.

### Risiko 3: Plan-DSL wird zu komplex

**Problem:** Feature Creep — Loops, Conditionals, Subroutines...
**Mitigation:** Strikte Grenze: Maximal 1 Ebene if/then. Keine Loops, keine
Variablen-Arithmetik. Komplexe Logik gehoert ins Orchestrator-LLM. Der Plan
ist ein Ausfuehrungs-Rezept, keine Programmiersprache.

### Risiko 4: Haiku-Operator verzoegert Ausfuehrung

**Problem:** 500ms pro Haiku-Call addiert sich bei vielen adaptiven Steps.
**Mitigation:** Budget-Limit (default 10). Deterministische Steps sind immer
schneller. Operator nur fuer echte Entscheidungen, nie fuer routinemaessige
Verifikation.

### Risiko 5: API-Key-Sicherheit

**Problem:** API-Key liegt im Environment, MCP-Server hat Zugang.
**Mitigation:** Key wird nur fuer Haiku-Calls genutzt, nie geloggt, nie in
Reports ausgegeben. Operator-Feature ist opt-in (kein Key = kein Operator).

---

## USP-Impact

### Differenzierung

Kein anderer iOS MCP-Server hat:
- Einen eingebauten Plan-Executor fuer batch UI-Automation
- LLM-in-the-Loop Fehlerbehandlung (Haiku als Operator)
- Deterministische Ausfuehrung mit ~500ms statt ~25s pro Testsequenz

### Positionierung

```
         Geschwindigkeit
              ▲
              │
  run_plan ●  │                    ← 500ms/Sequenz, 0 LLM-Overhead
              │
              │
              │          ● Tier 1+2 Optimierungen
              │
              │
              │                    ● Andere MCP-Server (jeder Step = LLM Round-Trip)
              │
              └──────────────────────────────────────────► Intelligenz
                  deterministisch    einfache         strategische
                  (kein LLM)         Entscheidungen   Planung
                                     (Haiku)          (Opus)
```

### Monetarisierung

`run_plan` ist ein klarer Pro-Feature:
- Free-User: Einzelne Tools (find, click, screenshot) — funktioniert, aber langsam
- Pro-User: run_plan fuer batch-Ausfuehrung — 50x schneller, zuverlaessiger
- Pro-User + API-Key: run_plan + Haiku Operator — adaptiv, intelligent

Der Sprung von "10 einzelne Calls" zu "1 run_plan Call" ist so gross, dass er
allein den Pro-Preis rechtfertigt.

---

## Metriken fuer Erfolg

| Metrik | Heute | Nach run_plan | Ziel |
|--------|-------|--------------|------|
| Round-Trips pro E2E-Session | ~70 | ~8-12 | <15 |
| LLM-Wartezeit pro Session | ~15min | ~1min | <2min |
| Tool-Ausfuehrungszeit | ~4s | ~8s (mehr Steps pro Call) | <10s |
| Fehlerrate (falscher Screen, verpasster Tap) | ~10% | ~2% | <5% |
| Context-Window-Verbrauch | ~50k Token | ~15k Token | <20k |

---

## Abhaengigkeiten

```
Tier 1 (erledigt)
  ├── #1 Frame in find_element ✓
  └── #2 element_id in Gesten ✓
        │
        ▼
Phase 1: UIActions Refactor (Core)    ← einziger Free-Eingriff
        │
        ▼
Phase 2: PlanParser (Pro)
        │
        ▼
Phase 3: PlanExecutor (Pro)           ← Kern-Deliverable
        │
        ▼
Phase 4: Report + MCP (Pro)           ← nutzbar ab hier
        │
        ▼
Phase 5: OperatorBridge (Pro)         ← optional, eigenstaendiges Add-on
```
