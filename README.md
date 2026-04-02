# SilbercueSwift

[![GitHub Release](https://img.shields.io/github/v/release/silbercue/SilbercueSwift)](https://github.com/silbercue/SilbercueSwift/releases)
[![Free — 49 tools](https://img.shields.io/badge/Free-49_tools-brightgreen)](https://github.com/silbercue/SilbercueSwift#free-vs-pro)
[![Pro available](https://img.shields.io/badge/Pro-58_tools-blueviolet)](https://polar.sh/silbercueswift)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![MCP Registry](https://img.shields.io/badge/MCP_Registry-published-green)](https://registry.modelcontextprotocol.io)
[![Platform](https://img.shields.io/badge/platform-macOS_13%2B-blue)]()
[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange)](https://swift.org)

The fastest, most complete MCP server for iOS development. One Swift binary, 58 tools, zero dependencies. **SilbercueSwift has the most complete toolset of any alternative out there.**

Built for [Claude Code](https://claude.ai/claude-code), [Cursor](https://cursor.sh), and any MCP-compatible AI agent.

> **Looking for an alternative to existing iOS MCP servers?** SilbercueSwift covers the full feature set of XcodeBuildMCP, Appium-MCP, and iosef in a single binary — plus xcresult parsing, UI automation, code coverage, and up to 75x faster screenshots. [See comparison below](#comparison-with-other-mcp-servers).

## Why SilbercueSwift?

Every iOS MCP server has the same problem: **raw xcodebuild output is useless for AI agents.** 500 lines of build log, stderr noise mistaken for errors, no structured test results. Agents waste minutes parsing what a human sees in seconds.

SilbercueSwift fixes this. It parses `.xcresult` bundles — the same structured data Xcode uses internally — and returns exactly what the agent needs: pass/fail counts, failure messages with file:line, code coverage per file, and failure screenshots.

| What you get | XcodeBuildMCP | Appium-MCP | iosef | SilbercueSwift |
|---|---|---|---|---|
| Screenshot latency | ~1127ms | ~77ms | ~83ms | **~316ms** (<img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> **~15ms**, 75x) |
| View hierarchy | ~259ms | ~938ms | ~44ms | **~31ms** (<img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> **~5ms**) |
| Find element | — | 76ms | 50ms | **31ms** (<img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> **<1ms** + auto-scroll) |
| Tap (coordinates) | 235ms | 470ms | 48ms | **16ms** (<img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> **4ms**) |
| Swipe | 1284ms | 2685ms | 262ms | **~250ms** |
| Build for simulator | Yes | — | — | **Yes** |
| Build + Run in one call | Yes (sequential) | — | — | **Yes (parallel, ~9s faster)** |
| Structured test results | Partial | — | — | **Full xcresult JSON** |
| Failure screenshots from xcresult | — | — | — | **Auto-exported** |
| Code coverage per file | Basic | — | — | **Sorted, filterable** |
| Build error diagnosis | stderr parsing | — | — | **xcresult JSON with file:line** |
| Navigate (find + tap + verify) | — | — | — | **1 call (~380ms)** |
| Double tap | — | — | — | **~60ms** |
| Drag & drop | — | Coordinates only (3 calls) | — | **Element-to-element (1 call)** |
| Scroll to element | — | Manual swipe loop | — | **SmartScroll (1 call)** <img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> |
| Alert handling | — | Single alert | — | **3-tier search + batch accept_all** <img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> |
| iOS 18 ContactsUI dialog | — | — | — | **Supported** |
| Batch UI automation | — | — | — | **run_plan: multi-step plans with adaptive decisions** |
| Log filtering | Subsystem only | — | Partial | **Topic-filtered: 90% fewer tokens** <img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> |
| Console log per failed test | — | — | — | **Optional** |
| Wait for log pattern | — | — | — | **Regex + timeout** |
| Visual regression | — | — | — | **Baseline + pixel diff** <img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> |
| Multi-device check | — | — | — | **Dark Mode, Landscape, iPad** <img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> |
| Cross-platform (Android) | — | Yes | — | — |
| Tools | 77 (Rust) | 61 (Node.js + Appium) | 15 (Swift) | **58 (Native Swift, 8.5MB)** |
| Cold start | ~400ms | ~1000ms | ~100ms | **~50ms** |

### Where SilbercueSwift really shines

> ![killer feat](https://img.shields.io/badge/killer%20feat-%23FFD700?style=flat-square) **Screenshots up to 75x faster** — ~316ms (<img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> ~15ms)

Free tier screenshots (~316ms) are faster than XcodeBuildMCP (~1127ms) and most alternatives. Pro brings latency down to ~15ms — 5x faster than Appium, 75x faster than XcodeBuildMCP. Agents can take screenshots freely without penalty at either tier.

> ![killer feat](https://img.shields.io/badge/killer%20feat-%23FFD700?style=flat-square) **Structured test results from xcresult bundles** — zero guesswork on failures

When a test fails, the agent gets the error message, the exact file:line, a screenshot of the failure state, and optionally the console output — all parsed from Apple's `.xcresult` format. No guessing from 500 lines of xcodebuild stderr. This is the difference between "agent knows what broke" and "agent guesses what broke".

> ![killer feat](https://img.shields.io/badge/killer%20feat-%23FFD700?style=flat-square) **Single binary, zero dependencies** — 58 tools, install in 10 seconds

`brew install silbercueswift` — done. 8.5MB native Swift binary. No Node.js, no npm, no Appium server, no Python, no Java, no Rust toolchain. Cold start in ~50ms. The fastest way to get an iOS MCP server running.

> ![killer feat](https://img.shields.io/badge/killer%20feat-%23FFD700?style=flat-square) **Agent reads only what matters — 90% fewer tokens, zero wasted calls** (topic filtering <img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center">)

Free tier already strips noise: 15 known noise processes are excluded at capture time, and duplicate lines are collapsed (79% I/O reduction). Pro adds topic filtering — `read_logs` categorizes lines into 8 topics and shows only app + crashes by default, with a menu: `network(87) lifecycle(12) springboard(8)`. The agent opens specific topics in one call — no guessing, no iteration.

> ![strong](https://img.shields.io/badge/strong-%23C0C0C0?style=flat-square) **One call to dismiss all permission dialogs** — 3 alerts in 1 roundtrip <img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center">

Every app shows 2–3 permission dialogs on first launch. Other servers require the agent to screenshot → find button → click, per dialog. `handle_alert(action: "accept_all")` clears them all in a single call, searching across SpringBoard, ContactsUI, and the active app. Free tier handles alerts individually with `accept` / `dismiss`.

> ![strong](https://img.shields.io/badge/strong-%23C0C0C0?style=flat-square) **Drag & drop with element IDs** — 1 call instead of 3 <img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center">

"Drag item A above item B" is a single call: `drag_and_drop(source_element: "el-0", target_element: "el-1")`. The competition only supports raw coordinates, forcing the agent to find both elements, extract their frames, and build a W3C Actions sequence — 3 calls minimum.

> ![strong](https://img.shields.io/badge/strong-%23C0C0C0?style=flat-square) **Auto-scroll to off-screen elements** — no more manual swipe loops <img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center">

`find_element(using: "accessibility id", value: "Save", scroll: true)` scrolls automatically until the element appears. SmartScroll handles UIKit, SwiftUI, and lazy-loaded lists — no guessing scroll direction.

> ![strong](https://img.shields.io/badge/strong-%23C0C0C0?style=flat-square) **View hierarchy in ~31ms (Free) / ~5ms (Pro)** — up to 188x faster element inspection

`get_source` returns the full UI tree in ~31ms (Free) or ~5ms (Pro). The fastest competitor takes 44ms, most take 250ms+. This makes element inspection practically free for agents.

> ![killer feat](https://img.shields.io/badge/killer%20feat-%23FFD700?style=flat-square) **Navigate in one call** — find + tap + settle + screenshot in ~380ms

`navigate(to: "Settings")` finds the element, taps it, waits for the screen to settle, and returns a verification screenshot — all in a single call. No competitor offers this. Agents save 3-4 tool calls per navigation step.

> ![strong](https://img.shields.io/badge/strong-%23C0C0C0?style=flat-square) **Batch UI automation** — run_plan executes multi-step plans with adaptive decisions

`run_plan` takes a sequence of UI steps and executes them server-side. When a step needs a decision (unexpected dialog, element not found), it falls back through 4 tiers — from MCP sampling to pause & resume. No more "one tool call per tap" overhead.

## Quick Start

### Install via Homebrew

```bash
brew tap silbercue/silbercue
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

One command — installs globally for all projects:

```bash
claude mcp add --scope user SilbercueSwift /opt/homebrew/bin/SilbercueSwift
```

> **Note:** Use the full path (`/opt/homebrew/bin/SilbercueSwift`). Claude Code starts MCP servers without a full shell PATH, so bare command names won't be found.

### Uninstall

```bash
claude mcp remove --scope user SilbercueSwift
brew uninstall silbercueswift
brew untap silbercue/silbercue
```

## Free vs Pro

SilbercueSwift ships 49 tools for free — build, test, simulate, automate UI, capture logs, and take screenshots. No time limit, no signup.

Pro adds 9 tools and faster internals for teams and power users who need the full picture.

| | Free | Pro |
|---|---|---|
| Build, test, sim management | 49 tools | 58 tools |
| Screenshot | ~316ms | **~15ms (75x faster)** |
| Structured test results (xcresult) | Yes | Yes |
| Find element | 31ms | **<1ms** |
| View hierarchy | 31ms | **~5ms** |
| Tap (coordinates) | 16ms | **4ms** |
| Click / type / swipe / double tap / long press / drag & drop | Yes | Yes |
| Navigate (find + tap + verify) | Yes | Yes |
| Batch UI automation (run_plan) | Yes | Yes |
| Alert handling | Single accept/dismiss | + Batch accept_all / dismiss_all |
| Log capture | Smart + verbose | + App mode, topic filtering |
| Console capture, git tools | Yes | Yes |
| Scroll to element | — | SmartScroll |
| Visual regression | — | Baseline + pixel diff |
| Multi-device check | — | Dark Mode, Landscape, iPad |
| Accessibility check | — | Dynamic Type rendering |
| Localization check | — | Multi-language + RTL |
| Pinch / zoom | — | Yes |

Pro costs 12 EUR/month. [Get a license on Polar.sh](https://polar.sh/silbercueswift), then:

```bash
silbercueswift activate <YOUR-LICENSE-KEY>
```

## 58 Tools in 14 Categories

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

### Simulator (12 tools)

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
| `sim_status` | Simulator state (booted/shutdown, device type, runtime) |
| `sim_inspect` | Detailed simulator info (data path, log path, UDID) |

### UI Automation (16 tools)

Native input for gestures, WDA for element queries and alerts — no Appium, no Node.js, no Python.

| Tool | Description | Latency |
|---|---|---|
| `handle_alert` | **Accept, dismiss, or batch-handle system & in-app alerts** | ~200ms |
| `find_element` / `find_elements` | Find elements by accessibility ID, predicate, class chain. **`scroll: true` auto-scrolls** until the element appears (SmartScroll — 3 fallback strategies) | **31ms** (<img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> **<1ms**) |
| `click_element` | Tap a UI element | **~75ms** |
| `tap_coordinates` | Coordinate-based tap | **~16ms** (<img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> **~4ms**) |
| `double_tap` / `long_press` | Double tap or long press at coordinates | **~60ms** / **~1000ms** |
| `swipe` | Directional swipe | **~250ms** |
| `pinch` | Zoom in/out | ~400ms <img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> |
| `drag_and_drop` | **Drag from source to target** — element-to-element, coordinates, or mixed. Smart defaults for reorderable lists, Kanban boards, sliders | **~1.3s** |
| `navigate` | **Find + tap + settle + screenshot in 1 call** — saves 3-4 roundtrips | **~380ms** |
| `type_text` / `get_text` | Type into or read from elements | ~100-300ms |
| `get_source` | Full view hierarchy (JSON/XML) | **~31ms** (<img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center"> **~5ms**) |
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
| `screenshot` | Free: **~316ms** / Pro: **~15ms** |

### Logs (4 tools)

| Tool | Description |
|---|---|
| `start_log_capture` | **Smart-filtered os_log stream** — 3 modes: `smart` (default, topic filtering enabled), `app` (tight stream, auto-detected), `verbose` (unfiltered). Deduplicates repetitive lines. |
| `stop_log_capture` | Stop capture |
| `read_logs` | **Topic-filtered reading** — default: app + crashes only. Response includes topic menu with line counts. Add topics via `include` parameter. |
| `wait_for_log` | Wait for regex pattern with timeout — eliminates sleep() hacks |

#### Smart Log Filtering — 4 layers, zero config

```bash
# Start capture (default: smart mode — broad stream, topic filtering enabled)
start_log_capture()

# Read logs — default shows only app logs + crashes + topic menu
read_logs()
# → --- 230 buffered, 42 shown [app, crashes] ---
# → Topics: app(35) crashes(2) | network(87) lifecycle(12) springboard(8) widgets(0) background(3) system(83)
# → Hint: include=["network"] to add SSL/TLS + background transfer logs
# → ---
# → [42 filtered lines]

# Agent sees network(87) and wants SSL details — one call:
read_logs(include: ["network"])

# Narrow stream for production monitoring:
start_log_capture(mode: "app")

# Bypass mode logic with explicit predicate:
start_log_capture(subsystem: "com.apple.SwiftUI")
```

**4 filter layers:**
1. **Stream-side noise exclusion** — 15 known noise processes + subsystem/category exclusions removed before buffering. Server-side filtering in `logd` — 79% I/O reduction.
2. **3 capture modes** — `smart` (default, broad stream for topic filtering), `app` (tight, auto-detected bundle ID + process name), `verbose` (unfiltered).
3. **Read-time topic filtering** — `read_logs` categorizes every buffered line into 8 topics (app, crashes, network, lifecycle, springboard, widgets, background, system). Default shows only app + crashes. Agent adds topics as needed — stateless per call.
4. **Buffer deduplication** — 60 identical heartbeat lines become 2: the line itself + `... repeated 59x`.

**8 topics with LLM-optimized menu:**
| Topic | Matches | Use case |
|---|---|---|
| `app` (always on) | subsystem == bundleId OR process == appName | Your app: os_log, print(), NSLog() |
| `crashes` (always on) | fault-level logs | Crashes from any process |
| `network` | trustd, nsurlsessiond | SSL/TLS certs, background transfers |
| `lifecycle` | runningboardd, com.apple.runningboard.* | Jetsam, memory pressure, app kills |
| `springboard` | SpringBoard | Push notifications, app state |
| `widgets` | chronod | WidgetKit timeline, refresh budget |
| `background` | com.apple.xpc.activity.* | BGTaskScheduler, background fetch |
| `system` | everything else | WARNING: high volume |

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

### Accessibility (1 tool) <img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center">

| Tool | Description |
|---|---|
| `accessibility_check` | Render screens across Dynamic Type content size categories — detects truncation and layout issues |

### Localization (1 tool) <img src="https://img.shields.io/badge/Pro-blueviolet?style=flat-square" align="center">

| Tool | Description |
|---|---|
| `localization_check` | Render screens across languages including RTL (Arabic, Hebrew) — detects layout breaks |

### Automation (2 tools)

| Tool | Description |
|---|---|
| `run_plan` | Execute a multi-step UI automation plan server-side — adaptive decisions with 4-tier fallback |
| `run_plan_decide` | Resume a paused plan with a decision — for clients without MCP sampling |

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

Measured on M3 MacBook Pro, iOS 26.4 Simulator. All values are median of 5 runs after 2 warmups.

| Action | iosef | XcodeBuildMCP | Appium-MCP | SS Free | SS Pro |
|---|---|---|---|---|---|
| Screenshot | 83ms | 1127ms | 77ms | 316ms | **15ms** |
| Find element | 50ms | N/A | 76ms | **31ms** | **<1ms** |
| Tap (coordinates) | 48ms | 235ms | 470ms | **16ms** | **4ms** |
| Swipe | 262ms | 1284ms | 2685ms | **~250ms** | **~250ms** |
| View hierarchy | 44ms | 259ms | 938ms | **31ms** | **5ms** |
| Navigate (1 call) | — | — | — | **~380ms** | **~380ms** |
| Double tap | — | — | — | **~84ms** | **~60ms** |
| Drag & drop | — | coords only | — | **~1.3s** | **~1.3s** |
| Handle alert | — | — | 118ms | **~200ms** | **~200ms** |
| Handle 3 alerts (batch) | — | — | 3 calls | **~800ms (1 call)** | **~800ms (1 call)** |
| Scroll to element | — | — | swipe loop | **—** | **Automatic** |
| Build (clean) | — | 2501ms | — | 3188ms | **1800ms** |
| Simulator list | 12ms | 567ms | — | **15ms** | **15ms** |
| Cold start | ~100ms | ~400ms | ~1000ms | **~50ms** | **~50ms** |
| Binary size | ~5MB | ~4MB | ~200MB | **8.5MB** | **8.5MB** |

## Comparison with other MCP servers

See [feature comparison table above](#why-silbercueswift) for a detailed breakdown vs [XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP), [Appium-MCP](https://github.com/anthropics/appium-mcp), and [iosef](https://github.com/riwsky/iosef). All three are excellent projects that pioneered iOS MCP tooling. SilbercueSwift combines all their feature sets with deeper integration into a single native binary. The only trade-off: SilbercueSwift is iOS-only (no Android, watchOS, tvOS, or visionOS).

## Architecture

```
SilbercueSwift (8.5MB Swift binary)
├── MCP SDK (modelcontextprotocol/swift-sdk)
├── StdioTransport (JSON-RPC)
└── 58 Tools in 14 Categories
    Build · Test · Simulator · Screenshot · UI Automation
    Logs · Console · Visual Regression · Multi-Device
    Accessibility · Localization · Automation · Git · Session
```

No Node.js. No Python. No Appium server. No Selenium. One binary.

## Requirements

- macOS 13+
- Xcode 15+ (for `xcresulttool` and `simctl`)
- Swift 6.0+ (for building from source)
- WebDriverAgent installed on simulator (for UI automation tools)

## License

The core binary and all 49 free tools are **MIT licensed** — see [LICENSE](LICENSE). Use them however you want, commercially or otherwise.

Pro tools (9 additional tools + faster internals) require a [paid license](https://polar.sh/silbercueswift). The license validation code (`LicenseManager.swift`) is included in the source for transparency — you can see exactly what it checks and when.

## Contributing

Issues and pull requests welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.
