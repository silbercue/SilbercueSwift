import MCP

/// Central registry of all tools. Each module adds its tools here.
enum ToolRegistry {
    static var allTools: [Tool] {
        var tools: [Tool] = []
        tools += BuildTools.tools
        tools += SimTools.tools
        tools += ScreenshotTools.tools
        tools += UITools.tools
        tools += LogTools.tools
        tools += GitTools.tools
        tools += ConsoleTools.tools
        tools += TestTools.tools
        tools += VisualTools.tools
        return tools
    }

    static func dispatch(_ name: String, _ args: [String: Value]?) async -> CallTool.Result {
        switch name {
        // Build
        case "build_sim":         return await BuildTools.buildSim(args)
        case "clean":             return await BuildTools.clean(args)
        case "discover_projects": return await BuildTools.discoverProjects(args)
        case "list_schemes":      return await BuildTools.listSchemes(args)

        // Simulator
        case "list_sims":         return await SimTools.listSims(args)
        case "boot_sim":          return await SimTools.bootSim(args)
        case "shutdown_sim":      return await SimTools.shutdownSim(args)
        case "install_app":       return await SimTools.installApp(args)
        case "launch_app":        return await SimTools.launchApp(args)
        case "terminate_app":     return await SimTools.terminateApp(args)
        case "clone_sim":         return await SimTools.cloneSim(args)
        case "erase_sim":         return await SimTools.eraseSim(args)
        case "delete_sim":        return await SimTools.deleteSim(args)

        // Screenshots
        case "screenshot":        return await ScreenshotTools.screenshot(args)

        // UI Automation (WDA)
        case "wda_status":        return await UITools.wdaStatus(args)
        case "wda_create_session": return await UITools.wdaCreateSession(args)
        case "find_element":      return await UITools.findElement(args)
        case "find_elements":     return await UITools.findElements(args)
        case "click_element":     return await UITools.clickElement(args)
        case "tap_coordinates":   return await UITools.tapCoordinates(args)
        case "double_tap":        return await UITools.doubleTap(args)
        case "long_press":        return await UITools.longPress(args)
        case "swipe":             return await UITools.swipeAction(args)
        case "pinch":             return await UITools.pinchAction(args)
        case "type_text":         return await UITools.typeText(args)
        case "get_text":          return await UITools.getText(args)
        case "get_source":        return await UITools.getSource(args)

        // Logs
        case "start_log_capture": return await LogTools.startLogCapture(args)
        case "stop_log_capture":  return await LogTools.stopLogCapture(args)
        case "read_logs":         return await LogTools.readLogs(args)
        case "wait_for_log":      return await LogTools.waitForLog(args)

        // Git
        case "git_status":        return await GitTools.gitStatus(args)
        case "git_diff":          return await GitTools.gitDiff(args)
        case "git_log":           return await GitTools.gitLog(args)
        case "git_commit":        return await GitTools.gitCommit(args)
        case "git_branch":        return await GitTools.gitBranch(args)

        // App Console (print/NSLog capture)
        case "launch_app_console": return await ConsoleTools.launchAppConsole(args)
        case "read_app_console":   return await ConsoleTools.readAppConsole(args)
        case "stop_app_console":   return await ConsoleTools.stopAppConsole(args)

        // Testing & Diagnostics (xcresult)
        case "test_sim":           return await TestTools.testSim(args)
        case "test_failures":      return await TestTools.testFailures(args)
        case "test_coverage":      return await TestTools.testCoverage(args)
        case "build_and_diagnose": return await TestTools.buildAndDiagnose(args)

        // Visual Regression
        case "save_visual_baseline": return await VisualTools.saveVisualBaseline(args)
        case "compare_visual":       return await VisualTools.compareVisual(args)

        default:
            return .fail("Unknown tool: \(name)")
        }
    }
}
