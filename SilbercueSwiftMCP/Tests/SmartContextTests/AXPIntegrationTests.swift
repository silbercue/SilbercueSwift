import Testing
@testable import SilbercueSwiftCore

// MARK: - AXP Integration Tests (Core-side)

@Suite("AXP ProHooks + Routing")
struct AXPProHooksTests {

    // MARK: - 5.4 Regression: Free-Tier path unchanged

    @Test("ProHooks: hook type signatures compile correctly")
    func hookTypeSignatures() {
        // Verify hook types exist and are Optional
        let _: ((@Sendable (String, String, String) async -> UIActions.ElementBinding?)?) =
            ProHooks.findElementHandler
        let _: ((@Sendable (String) async -> Bool)?) = ProHooks.clickElementHandler
        let _: ((@Sendable (String) async -> String?)?) = ProHooks.getTextHandler
    }

    // MARK: - 5.5 Prefix-based routing

    @Test("AXP prefix check: axp-elements are correctly identified")
    func axpPrefixCheck() {
        #expect("axp-12345".hasPrefix("axp-"))
        #expect("axp-abcdef-1234".hasPrefix("axp-"))
        #expect(!"element-42".hasPrefix("axp-"))
        #expect(!"wda-element".hasPrefix("axp-"))
        #expect(!"".hasPrefix("axp-"))
    }

    @Test("getText: axp-prefixed element returns cached text via ProHook")
    func getTextAXPElementReturnsCached() async {
        let previous = ProHooks.getTextHandler
        defer { ProHooks.getTextHandler = previous }

        ProHooks.getTextHandler = { elementId in
            elementId.hasPrefix("axp-") ? "Settings" : nil
        }

        let handler = ProHooks.getTextHandler!
        let text = await handler("axp-test-element")
        #expect(text == "Settings")

        let nilText = await handler("element-0")
        #expect(nilText == nil)
    }

    @Test("clickElementHandler: returns true for axp, false for non-axp")
    func clickElementHandlerRouting() async {
        let previous = ProHooks.clickElementHandler
        defer { ProHooks.clickElementHandler = previous }

        ProHooks.clickElementHandler = { elementId in
            elementId.hasPrefix("axp-")
        }

        let handler = ProHooks.clickElementHandler!
        #expect(await handler("axp-12345") == true)
        #expect(await handler("element-0") == false)
    }
}

@Suite("WDA Enriched Response Parsing")
struct WDAEnrichedResponseTests {

    @Test("ElementRect public init constructs correctly")
    func elementRectPublicInit() {
        let rect = WDAClient.ElementRect(x: 10, y: 20, width: 100, height: 50)
        #expect(rect.x == 10)
        #expect(rect.y == 20)
        #expect(rect.width == 100)
        #expect(rect.height == 50)
        #expect(rect.centerX == 60)
        #expect(rect.centerY == 45)
    }

    @Test("ElementBinding public init constructs correctly")
    func elementBindingPublicInit() {
        let rect = WDAClient.ElementRect(x: 0, y: 0, width: 200, height: 100)
        let binding = UIActions.ElementBinding(
            elementId: "axp-test", rect: rect, swipes: 0, label: "Test"
        )
        #expect(binding.elementId == "axp-test")
        #expect(binding.rect?.centerX == 100)
        #expect(binding.rect?.centerY == 50)
        #expect(binding.swipes == 0)
        #expect(binding.label == "Test")
    }

    @Test("ElementBinding with nil rect and label")
    func elementBindingNilOptionals() {
        let binding = UIActions.ElementBinding(
            elementId: "element-0", rect: nil, swipes: 3, label: nil
        )
        #expect(binding.elementId == "element-0")
        #expect(binding.rect == nil)
        #expect(binding.centerX == nil)
        #expect(binding.centerY == nil)
        #expect(binding.swipes == 3)
        #expect(binding.label == nil)
    }
}

@Suite("AXP Find Routing Logic")
struct AXPFindRoutingTests {

    @Test("Routing: scroll=true always skips AXP hook even with handler set")
    func scrollTrueSkipsAXP() async {
        let previous = ProHooks.findElementHandler
        defer { ProHooks.findElementHandler = previous }

        ProHooks.findElementHandler = { _, _, _ in
            Issue.record("AXP hook must NOT be called when scroll=true")
            return nil
        }

        // Replicate UIActions.find() routing logic
        let scroll = true
        var axpAttempted = false
        if !scroll, let handler = ProHooks.findElementHandler {
            _ = await handler("accessibility id", "test", "udid")
            axpAttempted = true
        }
        #expect(!axpAttempted, "scroll=true must always skip AXP")
    }

    @Test("Routing: scroll=false with handler triggers AXP path")
    func scrollFalseTriggersAXP() async {
        let previous = ProHooks.findElementHandler
        defer { ProHooks.findElementHandler = previous }

        ProHooks.findElementHandler = { _, _, _ in nil }

        let scroll = false
        var axpAttempted = false
        if !scroll, let handler = ProHooks.findElementHandler {
            _ = await handler("accessibility id", "test", "udid")
            axpAttempted = true
        }
        #expect(axpAttempted, "scroll=false with handler must try AXP")
    }

    @Test("Routing: scroll=false without handler skips AXP (Free tier)")
    func scrollFalseNoHandlerSkipsAXP() {
        let previous = ProHooks.findElementHandler
        defer { ProHooks.findElementHandler = previous }

        ProHooks.findElementHandler = nil

        let scroll = false
        var axpAttempted = false
        if !scroll, let _ = ProHooks.findElementHandler {
            axpAttempted = true
        }
        #expect(!axpAttempted, "scroll=false without handler must skip AXP")
    }

    @Test("AXP hook returning nil falls through to WDA path")
    func axpNilFallsToWDA() async {
        let previous = ProHooks.findElementHandler
        defer { ProHooks.findElementHandler = previous }

        ProHooks.findElementHandler = { _, _, _ in nil }

        let handler = ProHooks.findElementHandler!
        let result = await handler("accessibility id", "test", "udid")
        #expect(result == nil, "nil result means WDA fallback")
    }

    @Test("AXP hook returning binding is used directly")
    func axpSuccessUsesResult() async {
        let previous = ProHooks.findElementHandler
        defer { ProHooks.findElementHandler = previous }

        let expectedRect = WDAClient.ElementRect(x: 50, y: 100, width: 200, height: 44)
        ProHooks.findElementHandler = { using, value, sim in
            UIActions.ElementBinding(
                elementId: "axp-test-id", rect: expectedRect, swipes: 0, label: "Settings"
            )
        }

        let handler = ProHooks.findElementHandler!
        let result = await handler("accessibility id", "Settings", "test-udid")
        #expect(result != nil)
        #expect(result?.elementId == "axp-test-id")
        #expect(result?.elementId.hasPrefix("axp-") == true)
        #expect(result?.rect?.centerX == 150)
        #expect(result?.rect?.centerY == 122)
        #expect(result?.label == "Settings")
        #expect(result?.swipes == 0)
    }
}
