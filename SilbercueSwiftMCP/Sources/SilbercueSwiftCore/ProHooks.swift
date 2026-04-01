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
}
