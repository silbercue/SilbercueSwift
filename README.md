# SilbercueSwift

[![GitHub Release](https://img.shields.io/github/v/release/silbercue/SilbercueSwift)](https://github.com/silbercue/SilbercueSwift/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![MCP Registry](https://img.shields.io/badge/MCP_Registry-published-green)](https://registry.modelcontextprotocol.io)
[![Platform](https://img.shields.io/badge/platform-macOS_13%2B-blue)]()
[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange)](https://swift.org)

The fastest, most complete MCP server for iOS development. One Swift binary, 51 tools, zero dependencies. **SilbercueSwift has the most complete toolset of any alternative out there.**

Built for [Claude Code](https://claude.ai/claude-code), [Cursor](https://cursor.sh), and any MCP-compatible AI agent.

> **Looking for an alternative to existing iOS MCP servers?** SilbercueSwift covers the full feature set of both XcodeBuildMCP and Appium-MCP in a single binary — plus xcresult parsing, direct WDA UI automation, code coverage, and 44x faster screenshots. [See comparison below](#comparison-with-other-mcp-servers).

## Why SilbercueSwift?

Every iOS MCP server has the same problem: **raw xcodebuild output is useless for AI agents.** 500 lines of build log, stderr noise mistaken for errors, no structured test results. Agents waste minutes parsing what a human sees in seconds.

SilbercueSwift fixes this. It parses `.xcresult` bundles — the same structured data Xcode uses internally — and returns exactly what the agent needs: pass/fail counts, failure messages with file:line, code coverage per file, and failure screenshots.

| What you get | XcodeBuildMCP | Appium-MCP | SilbercueSwift |
|---|---|---|---|
| Build for simulator | Yes | — | **Yes** |
| Build + Run in one call | Yes (sequential) | — | **Yes (parallel, ~9s faster)** |
| Structured test results | Partial | — | **Full xcresult JSON** |
| Failure screenshots from xcresult | — | — | **Auto-exported** |
| Code coverage per file | Basic | — | **Sorted, filterable** |
| Build error diagnosis | stderr parsing | — | **xcresult JSON with file:line** |
| Find element | — | Yes | **Yes + auto-scroll** |
| Tap / swipe / pinch | — | Yes | **Yes** |
| Drag & drop | — | Coordinates only (3 calls) | **Element-to-element (1 call)** |
| Scroll to element | — | Manual swipe loop | **3-tier auto-scroll (1 call)** |
| Alert handling | — | Single alert | **3-tier search + batch accept_all** |
| iOS 18 ContactsUI dialog | — | — | **Supported** |
| Screenshot latency | 13.2s | ~500ms+ | **0.3s (44x)** |
| View hierarchy | 15.5s | ~15s | **~20ms (750x)** |
| Console log per failed test | — | — | **Optional** |
| Wait for log pattern | — | — | **Regex + timeout** |
| Visual regression | — | — | **Baseline + pixel diff** |
| Multi-device check | — | — | **Dark Mode, Landscape, iPad** |
| Cross-platform (Android) | — | Yes | — |
| Runtime | Node.js (~50MB) | Node.js + Appium (~200MB) | **Native Swift (8.5MB)** |
| Cold start | ~400ms | ~1s | **~50ms** |

### Where SilbercueSwift really shines

> `killer feat 🥇` **Screenshots in 0.3s instead of 13s** — 44x faster visual feedback

SilbercueSwift reads the simulator framebuffer directly via CoreSimulator's IOSurface API. No simctl subprocess, no PNG round-trip. The agent gets a screenshot in 300ms. With the competition, it takes 13 seconds — long enough for the agent to lose context. Agents can take screenshots freely without penalty.

> `killer feat 🥇` **Structured test results from xcresult bundles** — zero guesswork on failures

When a test fails, the agent gets the error message, the exact file:line, a screenshot of the failure state, and optionally the console output — all parsed from Apple's `.xcresult` format. No guessing from 500 lines of xcodebuild stderr. This is the difference between "agent knows what broke" and "agent guesses what broke".

> `killer feat 🥇` **Single binary, zero dependencies** — install in 10 seconds

`brew install silbercueswift` — done. 8.5MB native Swift binary. No Node.js, no npm, no Appium server, no Python, no Java. Cold start in ~50ms. The fastest way to get an iOS MCP server running.

> `strong 🥈` **One call to dismiss all permission dialogs** — 3 alerts in 1 roundtrip

Every app shows 2–3 permission dialogs on first launch. Other servers require the agent to screenshot → find button → click, per dialog. `handle_alert(action: "accept_all")` clears them all in a single call, searching across SpringBoard, ContactsUI, and the active app.

> `strong 🥈` **Drag & drop with element IDs** — 1 call instead of 3

"Drag item A above item B" is a single call: `drag_and_drop(source_element: "el-0", target_element: "el-1")`. The competition only supports raw coordinates, forcing the agent to find both elements, extract their frames, and build a W3C Actions sequence — 3 calls minimum.

> `strong 🥈` **Auto-scroll to off-screen elements** — no more manual swipe loops

`find_element(using: "accessibility id", value: "Save", scroll: true)` scrolls automatically until the element appears. Three fallback strategies ensure it works with UIKit, SwiftUI, and lazy-loaded lists. No guessing scroll direction.

> `strong 🥈` **View hierarchy in 20ms** — 750x faster element inspection

`get_source` returns the full UI tree in ~20ms. The competition takes 15 seconds. This makes element inspection practically free for agents.

## Quick Start

### Install via Homebrew

```bash
brew tap silbercue/tools
brew install silbercueswift
```

### Or build from source

```bash
git clone https://github.com/silbercue/SilbercueSwift.git
cd SilbercueSwift
swift build -c release
cp .build/release/SilbercueSwift /usr/local/bin/
```

### Configure in Claude Code

Add to your `.mcp.json`:

```json
{
  "mcpServers": {
    "SilbercueSwift": {
      "command": "SilbercueSwift"
    }
  }
}
```

Or for global availability, add to `~/.claude/.mcp.json`.

## 51 Tools in 11 Categories

### Build (5 tools)

| Tool | Description |
|---|---|
| `build_sim` | Build for iOS Simulator — returns structured errors + caches bundle ID & app path |
| `build_run_sim` | Build + boot + install + launch in one call — parallel 2-phase pipeline, ~9s faster than sequential |
| `clean` | Clean build artifacts |
| `discover_projects` | Find .xcodeproj/.xcworkspace files |
| `list_schemes` | List available schemes |

### Testing & Diagnostics (4 tools)

| Tool | Description |
|---|---|
| `test_sim` | Run tests + structured xcresult summary (pass/fail/duration) |
| `test_failures` | Failed tests with error messages, file:line, and failure screenshots |
| `test_coverage` | Code coverage per file, sorted and filterable |
| `build_and_diagnose` | Build + structured errors/warnings from xcresult |

### Simulator (10 tools)

| Tool | Description |
|---|---|
| `list_sims` | List available simulators |
| `boot_sim` | Boot a simulator |
| `shutdown_sim` | Shut down a simulator |
| `install_app` | Install .app bundle |
| `launch_app` | Launch app by bundle ID |
| `terminate_app` | Terminate running app |
| `clone_sim` | Clone an existing simulator |
| `erase_sim` | Erase simulator content and settings |
| `delete_sim` | Delete a simulator |
| `set_orientation` | Rotate device (PORTRAIT, LANDSCAPE_LEFT, LANDSCAPE_RIGHT) via WDA |

### UI Automation via WebDriverAgent (15 tools)

Direct HTTP communication with WDA — no Appium, no Node.js, no Python.

| Tool | Description | Latency |
|---|---|---|
| `handle_alert` | **Accept, dismiss, or batch-handle system & in-app alerts** | ~200ms |
| `find_element` / `find_elements` | Find elements by accessibility ID, predicate, class chain. **`scroll: true` auto-scrolls** until the element appears (3-tier: scrollToVisible → calculated drag → iterative with stall detection) | ~100ms |
| `click_element` | Tap a UI element | ~400ms |
| `tap_coordinates` / `double_tap` / `long_press` | Coordinate-based gestures | ~200ms |
| `swipe` / `pinch` | Directional swipe, zoom in/out | ~400-600ms |
| `drag_and_drop` | **Drag from source to target** — element-to-element, coordinates, or mixed. Smart defaults for reorderable lists, Kanban boards, sliders | ~2300ms |
| `type_text` / `get_text` | Type into or read from elements | ~100-300ms |
| `get_source` | Full view hierarchy (JSON/XML) | ~20ms |
| `wda_status` / `wda_create_session` | WDA health check & session management | ~50-100ms |

#### handle_alert — the smartest alert handler

```bash
# Accept a single alert with smart defaults
handle_alert(action: "accept")

# Dismiss with a specific button label
handle_alert(action: "dismiss", button_label: "Not Now")

# Batch-accept ALL alerts after app launch (unique to SilbercueSwift)
handle_alert(action: "accept_all")
```

**3-tier alert search** — finds alerts across:
1. **Springboard** — system permission dialogs (Location, Camera, Tracking)
2. **ContactsUI** — iOS 18+ Contacts "Limited Access" dialog (separate process)
3. **Active app** — in-app `UIAlertController` dialogs

**Smart defaults** — knows which button to tap:
- Accept: "Allow" → "Allow While Using App" → "OK" → "Continue" → last button
- Dismiss: "Don't Allow" (handles Unicode U+2019) → "Cancel" → "Not Now" → first button

**Batch mode** — `accept_all` / `dismiss_all` loops through multiple sequential alerts server-side. One HTTP roundtrip instead of N. Returns details of every handled alert.

These capabilities go beyond what other iOS MCP servers currently offer.

### Screenshots (1 tool)

| Tool | Latency |
|---|---|
| `screenshot` | **0.3s** (3-tier: CoreSimulator IOSurface → ScreenCaptureKit → simctl) |

### Logs (4 tools)

| Tool | Description |
|---|---|
| `start_log_capture` | Real-time os_log stream |
| `stop_log_capture` | Stop capture |
| `read_logs` | Read captured lines (last N, clear buffer) |
| `wait_for_log` | Wait for regex pattern with timeout — eliminates sleep() hacks |

### Console (3 tools)

| Tool | Description |
|---|---|
| `launch_app_console` | Launch app with stdout/stderr capture |
| `read_app_console` | Read console output |
| `stop_app_console` | Stop console capture |

### Git (5 tools)

| Tool | Description |
|---|---|
| `git_status` / `git_diff` / `git_log` | Read operations |
| `git_commit` / `git_branch` | Write operations |

### Visual Regression (2 tools)

| Tool | Description |
|---|---|
| `save_visual_baseline` | Save a screenshot as a named baseline |
| `compare_visual` | Compare current screen against baseline — pixel diff + match score |

### Multi-Device (1 tool)

| Tool | Description |
|---|---|
| `multi_device_check` | Run visual checks across multiple simulators (Dark Mode, Landscape, iPad) — returns layout scores |

### Session (1 tool)

| Tool | Description |
|---|---|
| `set_defaults` | Set default project, scheme, simulator — avoids repeating params |

## xcresult Parsing — The Killer Feature

### The Problem

Every Xcode MCP server returns raw `xcodebuild` output. For a test run, that's 500+ lines of noise. AI agents can't reliably extract which tests failed and why.

### The Solution

SilbercueSwift uses `xcresulttool` to parse the `.xcresult` bundle — the same structured data Xcode's Test Navigator uses.

```
# One call, structured result
test_sim(project: "MyApp.xcodeproj", scheme: "MyApp")

→ Tests FAILED in 15.2s
  12 total, 10 passed, 2 FAILED
  FAIL: Login shows error message
    LoginTests.swift:47: XCTAssertTrue failed
  FAIL: Profile image loads
    ProfileTests.swift:112: Expected non-nil value

  Failure screenshots (2):
    /tmp/ss-attachments/LoginTests_failure.png
    /tmp/ss-attachments/ProfileTests_failure.png

  Device: iPhone 16 Pro (18.2)
  xcresult: /tmp/ss-test-1774607917.xcresult
```

The agent gets:
- **Pass/fail counts** — immediate overview
- **Failure messages with file:line** — actionable
- **Failure screenshots** — visual context (Claude is multimodal)
- **xcresult path** — reusable for `test_failures` or `test_coverage`

### Deep Failure Analysis

```
test_failures(xcresult_path: "/tmp/ss-test-*.xcresult", include_console: true)

→ FAIL: Login shows error message [LoginTests/testErrorMessage()]
    LoginTests.swift:47: XCTAssertTrue failed
    Screenshot: /tmp/ss-attachments/LoginTests_failure.png
    Console:
      [LoginService] Network timeout after 5.0s
      [LoginService] Retrying with fallback URL...
      ✘ Test "Login shows error message" failed after 6.2s
```

### Code Coverage

```
test_coverage(project: "MyApp.xcodeproj", scheme: "MyApp", min_coverage: 80)

→ Overall coverage: 72.3%

  Target: MyApp.app (74.1%)
      0.0% AnalyticsService.swift
     45.2% LoginViewModel.swift
     67.8% ProfileManager.swift

  Target: MyAppTests.xctest (62.0%)
     ...
```

## Benchmarks

Measured on M3 MacBook Pro, iOS 18.2 Simulator:

| Action | Konkurrenz (best of) | SilbercueSwift |
|---|---|---|
| Screenshot | 13.2s | **0.3s** (44x) |
| Find element | ~500ms | **~100ms** (5x) |
| Click element | ~500ms | **~400ms** |
| View hierarchy | ~15s | **~20ms** (750x) |
| Handle alert | ~500ms | **~200ms** |
| Handle 3 alerts (batch) | ~1500ms (3 calls) | **~800ms (1 call)** |
| Drag & drop (element-to-element) | ~3 calls required | **1 call (~2.3s)** |
| Scroll to element | Manual swipe loop | **Automatic (1 call)** |
| Simulator list | ~2s | **0.2s** |
| Cold start | ~400ms–1s | **~50ms** |
| Binary size | ~50–200MB | **8.5MB** |

## Comparison with other MCP servers

See [feature comparison table above](#why-silbercueswift) for a detailed breakdown vs [XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP) and [Appium-MCP](https://github.com/anthropics/appium-mcp). Both are excellent projects that pioneered iOS MCP tooling. SilbercueSwift builds on their ideas and combines both feature sets with deeper integration into a single native binary. The only trade-off: SilbercueSwift is iOS-only (no Android, watchOS, tvOS, or visionOS).

## Architecture

```
SilbercueSwift (8.5MB Swift binary)
├── MCP SDK (modelcontextprotocol/swift-sdk)
├── StdioTransport (JSON-RPC)
└── Tools/
    ├── BuildTools       → xcodebuild (parallel pipeline, 3-tier app info)
    ├── TestTools        → xcodebuild test + xcresulttool + xccov
    ├── SimTools         → simctl + WDA orientation
    ├── ScreenshotTools  → CoreSimulator IOSurface → ScreenCaptureKit → simctl
    ├── UITools          → WebDriverAgent (direct HTTP, 3-tier alert search)
    ├── LogTools         → log stream + regex pattern matching
    ├── ConsoleTools     → stdout/stderr capture
    ├── VisualTools      → pixel diff + layout scoring
    ├── MultiDeviceTools → parallel sim checks
    ├── GitTools         → git
    └── SessionState     → auto-detect + cached defaults
```

No Node.js. No Python. No Appium server. No Selenium. One binary.

## Requirements

- macOS 13+
- Xcode 15+ (for `xcresulttool` and `simctl`)
- Swift 6.0+ (for building from source)
- WebDriverAgent installed on simulator (for UI automation tools)

## License

MIT License — see [LICENSE](LICENSE).

## Contributing

Issues and pull requests welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.
