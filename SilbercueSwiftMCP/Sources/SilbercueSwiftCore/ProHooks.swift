import Foundation

/// Extension points for Pro module. Pro module sets these at registration time.
/// Free builds leave them nil — tools fall back to Free-tier behavior.
public enum ProHooks {
    /// Pro screenshot handler. Returns inline capture result or nil on failure.
    /// Set by Pro module to enable TurboCapture (~15ms via IOSurface/ScreenCaptureKit).
    public nonisolated(unsafe) static var screenshotHandler:
        (@Sendable (_ sim: String, _ format: String) async
         -> (base64: String, dataSize: Int, width: Int, height: Int, method: String)?)?

    /// Pro find_element handler via AXP (direct accessibility, ~10-15ms).
    /// Called when scroll=false. Returns nil to fall back to WDA.
    /// Parameters: (using, value, simulator_udid)
    public nonisolated(unsafe) static var findElementHandler:
        (@Sendable (_ using: String, _ value: String, _ simulator: String) async
         -> UIActions.ElementBinding?)?

    /// Pro click_element handler for AXP-cached elements.
    /// Checks AXPElementCache, taps at cached center via IndigoHID.
    /// Returns true if handled, false/nil to fall back to WDA.
    public nonisolated(unsafe) static var clickElementHandler:
        (@Sendable (_ elementId: String) async -> Bool)?

    /// Pro get_text handler for AXP-cached elements.
    /// Returns cached label/value from AXPElementCache, nil to fall back to WDA.
    public nonisolated(unsafe) static var getTextHandler:
        (@Sendable (_ elementId: String) async -> String?)?

    /// Pro get_source handler for pruned format via AXP cached tree (~0-5ms).
    /// Returns pruned element array or nil to fall back to Free AXP/WDA.
    /// Parameter: simulator_udid
    public nonisolated(unsafe) static var getSourceHandler:
        (@Sendable (_ simulator: String) async -> [[String: Any]]?)?

    /// Pro find_elements handler via AXP cached tree.
    /// Returns array of ElementBindings or nil to fall back to Free AXP/WDA.
    /// Parameters: (using, value, simulator_udid)
    public nonisolated(unsafe) static var findElementsHandler:
        (@Sendable (_ using: String, _ value: String, _ simulator: String) async
         -> [UIActions.ElementBinding]?)?

    /// Pro tap hold override. Reduces IndigoHID touch hold duration after validation.
    /// Free default: 15ms (safe for all gesture recognizers).
    public static func setTapHoldMs(_ ms: Int) {
        IndigoHIDClient.touchHoldMs = ms
    }
}
