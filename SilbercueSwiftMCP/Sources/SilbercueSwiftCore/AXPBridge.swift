import Foundation
import ObjectiveC

// MARK: - AXPBridge

/// Direct bridge to Apple's private AccessibilityPlatformTranslation framework.
/// Enables find_element via AXP instead of WDA HTTP, achieving ~30ms latency.
///
/// Architecture:
/// - Framework handles + AXPTranslator singleton are **shared** (static, loaded once)
/// - One shared AXPTranslationDispatcher maps tokens → SimDevices (multi-sim safe)
/// - Per-UDID instances hold SimDevice + iOS screen dimensions
/// - Per-UDID instances managed by AXPBridgeManager
public final class AXPBridge: @unchecked Sendable {

    // MARK: - Xcode Developer Dir

    private static let developerDir: String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}
        return "/Applications/Xcode.app/Contents/Developer"
    }()

    // MARK: - Framework Loading (one-time, shared across all instances)

    /// CoreSimulator handle — needed for SimDevice / SimServiceContext.
    nonisolated(unsafe) private static let coreSimHandle: UnsafeMutableRawPointer? = {
        dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW)
            ?? dlopen("\(developerDir)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW)
    }()

    /// AccessibilityPlatformTranslation handle.
    nonisolated(unsafe) private static let axpHandle: UnsafeMutableRawPointer? = {
        dlopen(
            "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation",
            RTLD_NOW
        )
    }()

    /// AXPTranslator.sharedInstance — singleton, shared across all per-UDID bridges.
    nonisolated(unsafe) private static let translator: AnyObject? = {
        guard axpHandle != nil else { return nil }
        guard let cls: AnyClass = objc_lookUpClass("AXPTranslator") else { return nil }
        let sel = NSSelectorFromString("sharedInstance")
        guard let method = class_getClassMethod(cls, sel) else { return nil }
        typealias SharedFn = @convention(c) (AnyObject, Selector) -> AnyObject
        let imp = method_getImplementation(method)
        return unsafeBitCast(imp, to: SharedFn.self)(cls, sel)
    }()

    /// Shared dispatcher — set once as bridgeTokenDelegate on the translator.
    /// Maps tokens → devices, enabling concurrent multi-simulator operations.
    private static let sharedDispatcher: AXPTranslationDispatcher? = {
        guard let translator = translator else { return nil }
        let dispatcher = AXPTranslationDispatcher()
        (translator as AnyObject).setValue(dispatcher, forKey: "bridgeTokenDelegate")
        return dispatcher
    }()

    // MARK: - Availability

    /// `true` when AXP framework loaded, translator resolved, and dispatcher set.
    public static var isAvailable: Bool {
        axpHandle != nil && translator != nil && sharedDispatcher != nil
    }

    // MARK: - Per-Instance State

    let device: NSObject          // SimDevice (CoreSimulator)
    let udid: String
    let iosPointSize: CGSize      // iOS logical point dimensions (e.g. 393x852)

    // MARK: - Init

    /// Creates an AXP bridge for a specific simulator UDID.
    /// Resolves SimDevice via CoreSimulator and computes screen dimensions.
    public init(udid: String) throws {
        guard Self.isAvailable else {
            throw AXPError.frameworkNotAvailable
        }

        guard let device = Self.resolveSimDevice(udid: udid) else {
            throw AXPError.deviceNotFound(udid)
        }
        self.device = device
        self.udid = udid
        self.iosPointSize = Self.resolveScreenPointSize(device: device)
    }

    // MARK: - AXP Core API

    /// Calls [AXPTranslator frontmostApplicationWithDisplayId:bridgeDelegateToken:]
    func getFrontmostAppTranslation(token: String) -> AnyObject? {
        guard let translator = Self.translator else { return nil }
        let sel = NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:")
        guard let method = class_getInstanceMethod(type(of: translator as AnyObject), sel) else {
            return nil
        }
        typealias TransFn = @convention(c) (AnyObject, Selector, UInt32, NSString) -> AnyObject?
        let imp = method_getImplementation(method)
        return unsafeBitCast(imp, to: TransFn.self)(translator, sel, 0, token as NSString)
    }

    /// Calls [AXPTranslator macPlatformElementFromTranslation:]
    func macPlatformElement(from translation: AnyObject) -> AnyObject? {
        guard let translator = Self.translator else { return nil }
        let sel = NSSelectorFromString("macPlatformElementFromTranslation:")
        guard let method = class_getInstanceMethod(type(of: translator as AnyObject), sel) else {
            return nil
        }
        typealias MacElemFn = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        let imp = method_getImplementation(method)
        return unsafeBitCast(imp, to: MacElemFn.self)(translator, sel, translation)
    }

    /// Sets bridgeDelegateToken on a translation or element object.
    func setBridgeToken(_ token: String, on obj: AnyObject) {
        obj.setValue(token, forKey: "bridgeDelegateToken")
    }

    /// Registers this bridge's device with the shared dispatcher for a given token.
    func registerToken(_ token: String, deadline: ContinuousClock.Instant) {
        Self.sharedDispatcher?.registerDevice(device, forToken: token, deadline: deadline)
    }

    /// Unregisters a token from the shared dispatcher.
    func unregisterToken(_ token: String) {
        Self.sharedDispatcher?.unregisterToken(token)
    }

    // MARK: - Find Element (Bulk Fetch + Client-Side Filter)

    /// Find a single element using bulk tree fetch + local filtering.
    /// Always performs a fresh tree walk (~30ms). No caching — Pro adds cache via hook.
    public func findElement(using strategy: String, value: String) throws -> AXPFindResult {
        guard strategy != "class chain" else {
            throw AXPError.unsupportedStrategy("class chain")
        }

        let start = ContinuousClock.now
        let (elements, rootFrame) = try fetchTree()

        guard let match = filterElement(elements, strategy: strategy, value: value) else {
            throw AXPError.elementNotFound(strategy, value)
        }

        return buildResult(from: match, rootFrame: rootFrame, start: start,
                         elementCount: elements.count, strategy: strategy)
    }

    // MARK: - Public API for Pro Cache Layer

    /// Fetches the full accessibility tree. One XPC round-trip via accessibilityChildren.
    /// Returns flat element array + root frame for coordinate transformation.
    public func fetchTree() throws -> ([BulkElement], CGRect) {
        let token = UUID().uuidString
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        registerToken(token, deadline: deadline)
        defer { unregisterToken(token) }

        guard let translation = getFrontmostAppTranslation(token: token) else {
            throw AXPError.noTranslationObject
        }
        setBridgeToken(token, on: translation as AnyObject)

        guard let rootElement = macPlatformElement(from: translation) else {
            throw AXPError.noMacPlatformElement
        }
        if let trans = (rootElement as AnyObject).value(forKey: "translation") as AnyObject? {
            setBridgeToken(token, on: trans)
        }

        let rootFrame = callFrameMethod(rootElement as AnyObject,
                                        selector: NSSelectorFromString("accessibilityFrame"))

        var elements: [BulkElement] = []
        elements.reserveCapacity(64)
        walkElement(rootElement as AnyObject, token: token, deadline: deadline, into: &elements)

        return (elements, rootFrame)
    }

    /// Filters the pre-fetched element list by strategy — pure local, no XPC.
    public func filterElement(_ elements: [BulkElement], strategy: String, value: String) -> BulkElement? {
        switch strategy {
        case "accessibility id":
            return elements.first { $0.identifier == value }
                ?? elements.first { $0.label == value }

        case "predicate string":
            let predicate = NSPredicate(format: value)
            return elements.first { elem in
                let dict: [String: Any] = [
                    "label": elem.label ?? "",
                    "name": elem.label ?? "",
                    "identifier": elem.identifier ?? "",
                    "value": elem.value ?? "",
                    "type": Self.axpRoleToWDAClass(elem.role ?? ""),
                    "elementType": Self.axpRoleToWDAClass(elem.role ?? ""),
                ]
                return predicate.evaluate(with: dict)
            }

        case "class name":
            let axpRole = Self.wdaClassToAXPRole(value)
            return elements.first { elem in
                guard let role = elem.role else { return false }
                return role.caseInsensitiveCompare(axpRole) == .orderedSame
            }

        default:
            return nil
        }
    }

    /// Builds an AXPFindResult from a matched element, transforming coordinates and caching.
    public func buildResult(from match: BulkElement, rootFrame: CGRect,
                           start: ContinuousClock.Instant, elementCount: Int,
                           strategy: String) -> AXPFindResult {
        let iosRect = transformFrame(match.frame, rootFrame: rootFrame)
        let syntheticId = "axp-\(UUID().uuidString)"
        let x = Int(iosRect.origin.x.rounded())
        let y = Int(iosRect.origin.y.rounded())
        let width = max(1, Int(iosRect.size.width.rounded()))
        let height = max(1, Int(iosRect.size.height.rounded()))

        AXPElementCache.store(
            id: syntheticId, centerX: x + width / 2, centerY: y + height / 2,
            label: match.label, value: match.value, role: match.role
        )

        let (secs, atto) = (ContinuousClock.now - start).components
        let elapsedMs = secs * 1000 + atto / 1_000_000_000_000_000
        Log.warn("AXP find (\(strategy)): \(elementCount) elements, matched in \(elapsedMs)ms")

        return AXPFindResult(
            syntheticId: syntheticId, x: x, y: y, width: width, height: height,
            label: match.label, role: match.role
        )
    }

    // MARK: - Bulk Tree Walk

    /// Recursively walks the full tree, serializing all elements into a flat array.
    /// accessibilityChildren returns children with pre-populated rawElementData,
    /// so subsequent property reads on children are local (no extra XPC calls).
    private func walkElement(_ element: AnyObject, token: String,
                            deadline: ContinuousClock.Instant,
                            into elements: inout [BulkElement]) {
        guard ContinuousClock.now < deadline else { return }

        let role = stringProperty(element, "accessibilityRole")
        let label = stringProperty(element, "accessibilityLabel")
        let identifier = stringProperty(element, "accessibilityIdentifier")
        let value = valueProperty(element, "accessibilityValue")
        let frame = callFrameMethod(element, selector: NSSelectorFromString("accessibilityFrame"))

        elements.append(BulkElement(role: role, label: label, identifier: identifier,
                                    value: value, frame: frame))

        if let trans = (element as AnyObject).value(forKey: "translation") as AnyObject? {
            setBridgeToken(token, on: trans)
        }

        guard let children = (element as AnyObject)
                .value(forKey: "accessibilityChildren") as? [AnyObject] else { return }

        for child in children {
            if ContinuousClock.now >= deadline { return }
            autoreleasepool {
                if let trans = (child as AnyObject).value(forKey: "translation") as AnyObject? {
                    setBridgeToken(token, on: trans)
                }
                walkElement(child, token: token, deadline: deadline, into: &elements)
            }
        }
    }

    // MARK: - Frame Transformation

    /// Transforms a macOS window-coordinate frame to iOS logical points.
    /// Uses uniform scaling (width-based) + vertical centering offset (letterboxing).
    public func transformFrame(_ macFrame: CGRect, rootFrame: CGRect) -> CGRect {
        guard rootFrame.width > 0, rootFrame.height > 0 else {
            return macFrame
        }

        let uniformScale = iosPointSize.width / rootFrame.width
        let yOffset = (iosPointSize.height - rootFrame.height * uniformScale) / 2

        return CGRect(
            x: (macFrame.origin.x - rootFrame.origin.x) * uniformScale,
            y: (macFrame.origin.y - rootFrame.origin.y) * uniformScale + yOffset,
            width: macFrame.size.width * uniformScale,
            height: macFrame.size.height * uniformScale
        )
    }

    // MARK: - Class Name Mapping (WDA ↔ AXP)

    private static let wdaToAXPMap: [String: String] = [
        "XCUIElementTypeButton": "AXButton",
        "XCUIElementTypeStaticText": "AXStaticText",
        "XCUIElementTypeTextField": "AXTextField",
        "XCUIElementTypeSecureTextField": "AXSecureTextField",
        "XCUIElementTypeTextView": "AXTextArea",
        "XCUIElementTypeImage": "AXImage",
        "XCUIElementTypeCell": "AXCell",
        "XCUIElementTypeTable": "AXTable",
        "XCUIElementTypeCollectionView": "AXCollectionView",
        "XCUIElementTypeSwitch": "AXSwitch",
        "XCUIElementTypeSlider": "AXSlider",
        "XCUIElementTypeNavigationBar": "AXNavigationBar",
        "XCUIElementTypeTabBar": "AXTabBar",
        "XCUIElementTypeToolbar": "AXToolbar",
        "XCUIElementTypeSearchField": "AXSearchField",
        "XCUIElementTypeScrollView": "AXScrollArea",
        "XCUIElementTypeAlert": "AXSheet",
        "XCUIElementTypeSheet": "AXSheet",
        "XCUIElementTypePicker": "AXPopUpButton",
        "XCUIElementTypeLink": "AXLink",
        "XCUIElementTypeOther": "AXGroup",
        "XCUIElementTypeApplication": "AXApplication",
        "XCUIElementTypeWindow": "AXWindow",
    ]

    private static let axpToWDAMap: [String: String] = {
        Dictionary(wdaToAXPMap.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    }()

    static func wdaClassToAXPRole(_ wdaClass: String) -> String {
        if let mapped = wdaToAXPMap[wdaClass] {
            return mapped
        }
        if wdaClass.hasPrefix("XCUIElementType") {
            return "AX" + String(wdaClass.dropFirst("XCUIElementType".count))
        }
        return wdaClass
    }

    static func axpRoleToWDAClass(_ axpRole: String) -> String {
        if let mapped = axpToWDAMap[axpRole] {
            return mapped
        }
        if axpRole.hasPrefix("AX") {
            return "XCUIElementType" + String(axpRole.dropFirst(2))
        }
        return axpRole
    }

    // MARK: - ObjC Helpers

    func stringProperty(_ obj: AnyObject, _ selector: String) -> String? {
        let sel = NSSelectorFromString(selector)
        guard obj.responds(to: sel) else { return nil }
        return obj.perform(sel)?.takeUnretainedValue() as? String
    }

    func valueProperty(_ obj: AnyObject, _ selector: String) -> String? {
        let sel = NSSelectorFromString(selector)
        guard obj.responds(to: sel) else { return nil }
        guard let val = obj.perform(sel)?.takeUnretainedValue() else { return nil }
        if let str = val as? String { return str }
        if let num = val as? NSNumber { return num.stringValue }
        return nil
    }

    func callFrameMethod(_ obj: AnyObject, selector: Selector) -> CGRect {
        guard let method = class_getInstanceMethod(type(of: obj as AnyObject), selector) else {
            return .zero
        }
        typealias FrameFn = @convention(c) (AnyObject, Selector) -> CGRect
        let imp = method_getImplementation(method)
        return unsafeBitCast(imp, to: FrameFn.self)(obj, selector)
    }

    // MARK: - SimDevice Resolution

    nonisolated(unsafe) private static var cachedServiceContext: NSObject?

    private static func resolveSimDevice(udid: String) -> NSObject? {
        guard coreSimHandle != nil else { return nil }

        let ctx: NSObject
        if let cached = cachedServiceContext {
            ctx = cached
        } else {
            guard let ctxClass = objc_lookUpClass("SimServiceContext") else { return nil }
            let sel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
            guard let result = (ctxClass as AnyObject)
                .perform(sel, with: developerDir as NSString, with: nil)?
                .takeUnretainedValue() as? NSObject else { return nil }
            cachedServiceContext = result
            ctx = result
        }

        let dsSel = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let deviceSet = ctx
            .perform(dsSel, with: nil)?
            .takeUnretainedValue() as? NSObject else { return nil }

        guard let devices = deviceSet
            .perform(NSSelectorFromString("devices"))?
            .takeUnretainedValue() as? [NSObject] else { return nil }

        let target = udid.uppercased()
        return devices.first { device in
            guard let nsuuid = device
                .perform(NSSelectorFromString("UDID"))?
                .takeUnretainedValue() as? NSUUID else { return false }
            return nsuuid.uuidString == target
        }
    }

    // MARK: - Screen Size Resolution

    private static func resolveScreenPointSize(device: NSObject) -> CGSize {
        let defaultSize = CGSize(width: 393, height: 852)

        guard let deviceType = device.value(forKey: "deviceType") else {
            return defaultSize
        }

        let pixelSize: CGSize
        if let size = (deviceType as AnyObject).value(forKey: "mainScreenSize") as? CGSize {
            pixelSize = size
        } else if let sizeValue = (deviceType as AnyObject).value(forKey: "mainScreenSize") as? NSValue {
            pixelSize = sizeValue.sizeValue
        } else {
            return defaultSize
        }

        let scale: CGFloat
        if let num = (deviceType as AnyObject).value(forKey: "mainScreenScale") as? NSNumber {
            scale = CGFloat(num.doubleValue)
        } else {
            scale = 3.0
        }

        guard scale > 0 else { return defaultSize }
        return CGSize(
            width: pixelSize.width / scale,
            height: pixelSize.height / scale
        )
    }

    // MARK: - XPC: sendAccessibilityRequest

    static func sendAccessibilityRequest(
        _ request: AnyObject,
        toDevice device: NSObject,
        timeoutSeconds: Double = 10.0
    ) throws -> AnyObject {
        let sel = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
        guard let method = class_getInstanceMethod(type(of: device), sel) else {
            throw AXPError.xpcMethodNotFound
        }

        typealias SendFn = @convention(c) (AnyObject, Selector, AnyObject, DispatchQueue, Any) -> Void
        let imp = method_getImplementation(method)
        let send = unsafeBitCast(imp, to: SendFn.self)

        let group = DispatchGroup()
        group.enter()

        let queue = DispatchQueue(label: "com.silbercueswift.axp.xpc-callback")
        var result: AnyObject?

        let completionBlock: @convention(block) (AnyObject?) -> Void = { response in
            result = response
            group.leave()
        }
        let completionObj: Any = completionBlock

        send(device, sel, request, queue, completionObj)

        let waitResult = group.wait(timeout: .now() + timeoutSeconds)
        if waitResult == .timedOut {
            throw AXPError.xpcTimeout(timeoutSeconds)
        }

        if let response = result {
            return response
        }

        return emptyAXPResponse()
    }

    static func emptyAXPResponse() -> AnyObject {
        if let cls: AnyClass = objc_lookUpClass("AXPTranslatorResponse"),
           let resp = (cls as AnyObject)
            .perform(NSSelectorFromString("emptyResponse"))?
            .takeUnretainedValue() {
            return resp
        }
        return NSNull()
    }
}

// MARK: - AXPBridgeManager

/// Per-UDID AXPBridge instance cache (analog to WDAClientManager).
public enum AXPBridgeManager {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bridges: [String: AXPBridge] = [:]

    public static func bridge(for udid: String) throws -> AXPBridge {
        lock.lock()
        defer { lock.unlock() }

        if let existing = bridges[udid] {
            return existing
        }

        let bridge = try AXPBridge(udid: udid)
        bridges[udid] = bridge
        return bridge
    }

    public static func removeBridge(for udid: String) {
        lock.lock()
        defer { lock.unlock() }
        bridges.removeValue(forKey: udid)
    }

    public static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        bridges.removeAll()
    }
}

// MARK: - AXPTranslationDispatcher

final class AXPTranslationDispatcher: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var tokenToDevice: [String: NSObject] = [:]
    private var tokenToDeadline: [String: ContinuousClock.Instant] = [:]

    func registerDevice(_ device: NSObject, forToken token: String, deadline: ContinuousClock.Instant? = nil) {
        lock.lock()
        defer { lock.unlock() }
        tokenToDevice[token] = device
        if let deadline = deadline {
            tokenToDeadline[token] = deadline
        }
    }

    func unregisterToken(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        tokenToDevice.removeValue(forKey: token)
        tokenToDeadline.removeValue(forKey: token)
    }

    private func device(forToken token: String) -> NSObject? {
        lock.lock()
        defer { lock.unlock() }
        return tokenToDevice[token]
    }

    private func deadline(forToken token: String) -> ContinuousClock.Instant? {
        lock.lock()
        defer { lock.unlock() }
        return tokenToDeadline[token]
    }

    @objc func accessibilityTranslationDelegateBridgeCallbackWithToken(_ token: NSString) -> Any {
        let tokenStr = token as String
        let device = self.device(forToken: tokenStr)
        let deadline = self.deadline(forToken: tokenStr)

        let callback: @convention(block) (AnyObject) -> AnyObject = { (request: AnyObject) -> AnyObject in
            guard let dev = device else {
                return AXPBridge.emptyAXPResponse()
            }

            let xpcTimeout: Double
            if let deadline = deadline {
                let remaining = deadline - ContinuousClock.now
                let remainingSecs = Double(remaining.components.seconds)
                    + Double(remaining.components.attoseconds) / 1e18
                if remainingSecs <= 0 {
                    return AXPBridge.emptyAXPResponse()
                }
                xpcTimeout = min(remainingSecs, 10.0)
            } else {
                xpcTimeout = 10.0
            }

            do {
                return try AXPBridge.sendAccessibilityRequest(
                    request, toDevice: dev, timeoutSeconds: xpcTimeout
                )
            } catch {
                Log.warn("AXP XPC callback failed: \(error.localizedDescription)")
                return AXPBridge.emptyAXPResponse()
            }
        }

        return callback
    }

    @objc func accessibilityTranslationConvertPlatformFrameToSystem(
        _ rect: CGRect, withToken token: NSString
    ) -> CGRect {
        return rect
    }

    @objc func accessibilityTranslationRootParentWithToken(_ token: NSString) -> AnyObject? {
        return nil
    }
}

// MARK: - BulkElement

/// Lightweight element data from bulk tree walk — used for client-side filtering.
/// All properties are pre-populated by the AXP framework (no lazy XPC).
public struct BulkElement: Sendable {
    public let role: String?
    public let label: String?
    public let identifier: String?
    public let value: String?
    public let frame: CGRect  // macOS AX window coordinates (pre-transform)

    public init(role: String?, label: String?, identifier: String?, value: String?, frame: CGRect) {
        self.role = role
        self.label = label
        self.identifier = identifier
        self.value = value
        self.frame = frame
    }
}

// MARK: - AXPFindResult

/// Result from an AXP find operation — all data needed for an ElementBinding.
public struct AXPFindResult: Sendable {
    public let syntheticId: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let label: String?
    public let role: String?

    public var centerX: Int { x + width / 2 }
    public var centerY: Int { y + height / 2 }
}

// MARK: - AXPElementCache

/// Caches AXP-found elements for follow-up calls (click, getText).
/// Keyed by synthetic "axp-{uuid}" ID, TTL 30 seconds.
public enum AXPElementCache {
    public struct CachedElement: Sendable {
        public let centerX: Int
        public let centerY: Int
        public let label: String?
        public let value: String?
        public let role: String?
        public let timestamp: ContinuousClock.Instant
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CachedElement] = [:]
    private static let ttl: Duration = .seconds(30)

    public static func store(
        id: String, centerX: Int, centerY: Int,
        label: String?, value: String? = nil, role: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        cache[id] = CachedElement(
            centerX: centerX, centerY: centerY,
            label: label, value: value, role: role,
            timestamp: ContinuousClock.now
        )
    }

    public static func lookup(_ id: String) -> CachedElement? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[id] else { return nil }
        if ContinuousClock.now - entry.timestamp > ttl {
            cache.removeValue(forKey: id)
            return nil
        }
        return entry
    }

    public static func evictExpired() {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        cache = cache.filter { now - $0.value.timestamp <= ttl }
    }
}

// MARK: - AXPError

public enum AXPError: Error, LocalizedError {
    case frameworkNotAvailable
    case deviceNotFound(String)
    case xpcMethodNotFound
    case xpcTimeout(Double)
    case noTranslationObject
    case noMacPlatformElement
    case elementNotFound(String, String)
    case unsupportedStrategy(String)

    public var errorDescription: String? {
        switch self {
        case .frameworkNotAvailable:
            return "AXP framework not available (AccessibilityPlatformTranslation.framework not loaded)"
        case .deviceNotFound(let udid):
            return "SimDevice not found for UDID \(String(udid.prefix(8)))…"
        case .xpcMethodNotFound:
            return "SimDevice.sendAccessibilityRequestAsync not found"
        case .xpcTimeout(let seconds):
            return "AXP XPC request timed out after \(String(format: "%.1f", seconds))s"
        case .noTranslationObject:
            return "No accessibility translation object — simulator may not have an active app"
        case .noMacPlatformElement:
            return "Could not convert AXP translation to platform element"
        case .elementNotFound(let strategy, let value):
            return "Element not found via AXP: \(strategy) = \(value)"
        case .unsupportedStrategy(let strategy):
            return "AXP does not support strategy '\(strategy)' — delegating to WDA"
        }
    }
}
