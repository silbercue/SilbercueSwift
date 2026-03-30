# Architecture: Open Core Module Split

## Overview

SilbercueSwift uses an Open Core model with two packages:

```
SilbercueSwiftCore (public, MIT)     SilbercueSwiftPro (private)
├── Shell, SessionState, WDAClient   ├── FramebufferCapture (15ms screenshots)
├── AutoDetect, SimStateCache        ├── CoreSimCapture (IOSurface)
├── ToolRegistry, ProHooks           ├── VisualTools, MultiDeviceTools
├── LicenseManager                   ├── AccessibilityTools, LocalizationTools
├── BuildTools, SimTools             ├── ProGestureTools, ProTestTools
├── ScreenshotTools, UITools (Free)  └── ProRegistration (entry point)
├── TestTools (testSim only)
├── LogTools, GitTools, ConsoleTools
└── 42 tools total                       +13 tools = 55 total
```

## How it works

### Tool Registration (ToolRegistry.swift)

Tools are registered dynamically via `ToolRegistration` (tool schema + handler pair):

```swift
ToolRegistry.registerFreeTools()          // 42 Free tools
SilbercueSwiftPro.register()              // +13 Pro tools (if module linked)
```

Each tool module provides a `registrations` array:
```swift
static let registrations: [ToolRegistration] = tools.compactMap { tool in
    let handler = switch tool.name {
    case "build_sim": buildSim
    case "build_run_sim": buildRunSim
    // ...
    default: nil
    }
    guard let h = handler else { return nil }
    return ToolRegistration(tool: tool, handler: h)
}
```

### Pro Hooks (ProHooks.swift)

For inline Pro enhancements (where a Free tool has a faster Pro path), ProHooks provides injection points:

```swift
// Free code checks if Pro registered a handler:
if let proHandler = ProHooks.screenshotHandler,
   let result = await proHandler(sim, format) {
    return result  // Pro: ~15ms TurboCapture
}
return await simctlScreenshot(...)  // Free: ~310ms simctl
```

## Developer Workflows

### 1. Update a Free feature

Change code in the public repo only. Example: improve `build_sim` in `BuildTools.swift`.

```
Edit → Test → Commit → Tag → CI builds combined binary automatically
```

No changes needed in Pro repo. Pro depends on Core and picks up changes at next build.

### 2. Add a new Pro-only tool

Change code in the Pro repo only.

1. Create `NewTool.swift` in `SilbercueSwiftPro/Sources/SilbercueSwiftPro/Tools/`
2. Add `ToolRegistry.register(NewTool.registrations)` to `ProRegistration.swift`
3. Commit + push Pro repo
4. Tag the public repo → CI builds combined binary with the new tool

No changes needed in the public repo.

### 3. Move a Pro tool to Free

Change both repos.

1. **Pro repo:** Remove tool from `ProRegistration.register()` and delete the source file
2. **Public repo:** Add the tool to the appropriate `*Tools.swift` and its `registrations` array
3. Commit both repos, tag public repo

### 4. Free feature with Pro boost

Two patterns available, depending on complexity:

#### Pattern A: ProHooks callback (separate logic in Pro)

Use when Pro has its own implementation (e.g., different algorithm, private API access).

**Public repo — add a hook in `ProHooks.swift`:**
```swift
public nonisolated(unsafe) static var myFeatureHandler:
    (@Sendable (_ param: String) async -> Result?)?
```

**Public repo — use the hook with fallback in the tool:**
```swift
if let proHandler = ProHooks.myFeatureHandler,
   let result = await proHandler(param) {
    return result  // Pro path
}
return await freeImplementation(param)  // Free fallback
```

**Pro repo — set the hook in `ProRegistration.swift`:**
```swift
ProHooks.myFeatureHandler = { param in
    try? await ProSpecificImplementation.run(param)
}
```

Existing example: `screenshotHandler` (Free: simctl ~310ms, Pro: IOSurface ~15ms).

#### Pattern B: Inline `isPro` check (simple parameter gate)

Use when Pro just unlocks a parameter or mode — no separate implementation needed.

```swift
// In the Free tool handler:
if someProParam {
    guard await LicenseManager.shared.isPro else {
        return .fail("Pro feature. Upgrade: \(LicenseManager.upgradeURL)")
    }
    // Pro-only code path (small, uses Core infrastructure)
}
```

Existing examples: `accept_all`, `dismiss_all`, `scroll:true`, log `app` mode, custom topics.

**When to use which:**

| Situation | Pattern |
|-----------|---------|
| Pro has different algorithm or private API | ProHooks callback |
| Pro just unlocks a parameter/mode, <20 lines | Inline `isPro` check |
| Pro code would expose proprietary logic | ProHooks callback |

### Inline Pro-Gates (5 spots in Free repo)

These use Core infrastructure (WDAClient, LogCapture) and contain no proprietary algorithm:

| File | Feature | Gate |
|------|---------|------|
| UITools.swift:240 | accept_all | `LicenseManager.shared.isPro` |
| UITools.swift:262 | dismiss_all | `LicenseManager.shared.isPro` |
| UITools.swift:364 | scroll:true | `LicenseManager.shared.isPro` |
| LogTools.swift:563 | app mode | `LicenseManager.shared.isPro` |
| LogTools.swift:617 | custom topics | `LicenseManager.shared.isPro` |

## Building

### Free only (public repo)

```bash
cd SilbercueSwiftMCP && swift build
```

Result: Binary with 42 Free tools. `#if canImport(SilbercueSwiftPro)` is false.

### Combined Free+Pro (both repos)

```bash
./SilbercueSwiftMCP/scripts/build-combined.sh
```

The script temporarily injects `SilbercueSwiftPro` as a dependency into `Package.swift`, builds a release binary, then restores the original. The binary contains all 55 tools (13 gated by `LicenseManager.isPro`).

Optional argument for custom Pro repo path:
```bash
./SilbercueSwiftMCP/scripts/build-combined.sh /path/to/SilbercueSwiftPro
```

Default: `../../SilbercueSwiftPro` (sibling directory).

## Release Process

### Automated (v3.0.1+)

```bash
git tag -a v3.1.0 -m "description"
git push origin v3.1.0
```

GitHub Actions (`.github/workflows/release.yml`) handles everything:
1. Checks out public + private repo (via `PRO_DEPLOY_KEY` secret)
2. Runs `build-combined.sh`
3. Creates GitHub Release with signed tarball
4. Updates Homebrew formula (`silbercue/homebrew-silbercue`)

### Manual (if CI unavailable)

```bash
./SilbercueSwiftMCP/scripts/build-combined.sh
cd SilbercueSwiftMCP
codesign -s - .build/release/SilbercueSwift
tar -czf silbercueswift-v3.1.0-macos-arm64.tar.gz -C .build/release SilbercueSwift
gh release create v3.1.0 silbercueswift-v3.1.0-macos-arm64.tar.gz --generate-notes
# Then update Homebrew formula version + SHA256
```

### Secrets (GitHub Actions)

| Secret | Purpose | Scope |
|--------|---------|-------|
| `PRO_DEPLOY_KEY` | SSH read access to SilbercueSwiftPro | Deploy key on Pro repo |
| `HOMEBREW_TOKEN` | Push access to homebrew-silbercue | PAT or OAuth token |
| `GITHUB_TOKEN` | Create releases (automatic) | Built-in |

## Distribution

Users install a single pre-built binary via Homebrew. The binary contains both Free and Pro code. Pro tools are gated at runtime by `LicenseManager`.

```
brew tap silbercue/silbercue
brew install silbercueswift          # 55 tools, 42 active
silbercueswift activate <KEY>        # 55 tools active
```

Free users never see Pro tool names in `tools/list` — they only appear after activation.

### How `#if canImport` works in this setup

`#if canImport(SilbercueSwiftPro)` is a **compile-time** check in `main.swift`. It is:
- **true** in the combined binary (built via `build-combined.sh` or CI)
- **false** when building from the public repo alone (`swift build` without Pro)

When true, `main.swift` calls `SilbercueSwiftPro.register()` if `LicenseManager.isPro` is also true at runtime. This double gate ensures Pro tools require both compilation AND a valid license.
