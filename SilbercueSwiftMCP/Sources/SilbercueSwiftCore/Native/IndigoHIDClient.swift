import Foundation
import ObjectiveC

/// Native touch injection via Apple's IndigoHID private framework.
/// Bypasses WDA HTTP for tap/swipe — delivers ~2-4x faster input.
///
/// Factory returns `nil` when Xcode frameworks or the simulator UDID aren't available.
/// Callers fall back to WDA in that case (zero functional loss).
final class IndigoHIDClient: @unchecked Sendable {
    private let hidClient: NSObject
    private let bridge = PrivateFrameworkBridge.shared
    private let screenWidth: CGFloat   // display pixels
    private let screenHeight: CGFloat  // display pixels
    private let screenScale: CGFloat   // e.g. 2.0 or 3.0

    // MARK: - Factory

    /// Returns `nil` if IndigoHID frameworks aren't available or the UDID can't be resolved.
    static func createIfAvailable(udid: String) -> IndigoHIDClient? {
        let bridge = PrivateFrameworkBridge.shared
        guard bridge.isAvailable else { return nil }

        guard let device = bridge.resolveSimDevice(udid: udid) else {
            Log.warn("IndigoHID: SimDevice not found for \(udid)")
            return nil
        }

        guard let info = screenInfo(for: device) else {
            Log.warn("IndigoHID: cannot read screen dimensions for \(udid)")
            return nil
        }

        guard let client = bridge.createHIDClient(device: device) else {
            Log.warn("IndigoHID: failed to create HID client for \(udid)")
            return nil
        }

        return IndigoHIDClient(
            hidClient: client,
            screenWidth: info.width,
            screenHeight: info.height,
            screenScale: info.scale
        )
    }

    private init(
        hidClient: NSObject,
        screenWidth: CGFloat, screenHeight: CGFloat, screenScale: CGFloat
    ) {
        self.hidClient = hidClient
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.screenScale = screenScale
    }

    // MARK: - Tap (iOS point coordinates)

    /// Minimum touch hold duration in milliseconds.
    /// Gesture recognizers in complex SwiftUI hierarchies need a minimum touch
    /// duration to distinguish tap from swipe-start or touch-cancel.
    /// 15ms is the conservative safe default. Pro validates and reduces this.
    nonisolated(unsafe) static var touchHoldMs: Int = 15

    func tap(x: Double, y: Double) async throws {
        try await sendTouch(.down, x: x, y: y)
        try await Task.sleep(for: .milliseconds(Self.touchHoldMs))
        try await sendTouch(.up, x: x, y: y)
    }

    // MARK: - Swipe (iOS point coordinates)

    func swipe(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        durationMs: Int = 300,
        steps: Int = 15
    ) async throws {
        let stepDelay = max(1, durationMs / steps)

        try await sendTouch(.down, x: fromX, y: fromY)

        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let cx = fromX + (toX - fromX) * t
            let cy = fromY + (toY - fromY) * t
            try await Task.sleep(for: .milliseconds(stepDelay))
            try await sendTouch(.down, x: cx, y: cy)
        }

        try await sendTouch(.up, x: toX, y: toY)
    }

    // MARK: - Message Building & Sending

    private enum Direction: Int32 { case down = 1, up = 2 }

    // Fixed header size (MachHeader=24 + innerSize=4 + eventType=4)
    private static let hdr = 32

    /// Screen size in pixels (as reported by SimDevice).
    private var screenPixels: CGSize {
        CGSize(width: screenWidth, height: screenHeight)
    }

    private func sendTouch(_ dir: Direction, x: Double, y: Double) async throws {
        guard let fn = bridge.mouseEvent6 else { throw IndigoHIDError.notAvailable }

        // 1. Convert iOS logical points to pixels and let the framework compute ratios.
        //    IndigoHIDMessageForMouseNSEvent expects pixel coordinates + pixel screen size.
        var pt = CGPoint(x: x * screenScale, y: y * screenScale)
        let raw = fn(&pt, nil, 0x32, dir.rawValue, screenPixels, 0)

        // 2. Read dynamic payload size
        let pld = Int(raw.load(fromByteOffset: 24, as: UInt32.self))
        let allocSize = malloc_size(raw)
        let baseSize = Self.hdr + pld

        // 3. If the function already allocated a full double-payload message, send as-is.
        //    Otherwise build the two-payload message.
        let msg: UnsafeMutableRawPointer
        let msgSize: Int
        if allocSize >= baseSize + pld {
            // Full message already built by framework — just update header.size
            msg = raw
            msgSize = allocSize
            (msg + 4).storeBytes(of: UInt32(msgSize), as: UInt32.self)
            // Send with freeWhenDone: true (framework allocated it)
            try await bridge.sendMessage(msg, via: hidClient)
        } else {
            // Build double-payload message
            msgSize = Self.hdr + pld * 2
            msg = UnsafeMutableRawPointer.allocate(byteCount: msgSize, alignment: 4)
            msg.copyMemory(from: raw, byteCount: Self.hdr)
            (msg + Self.hdr).copyMemory(from: raw + Self.hdr, byteCount: pld)

            let p2 = Self.hdr + pld
            (msg + p2).copyMemory(from: raw + Self.hdr, byteCount: pld)
            // Adjust second payload: touch.field1=1, field2=2
            // Event starts 16 bytes into payload (field1+timestamp+field3 = 4+8+4)
            (msg + p2 + 16).storeBytes(of: UInt32(1), as: UInt32.self)
            (msg + p2 + 20).storeBytes(of: UInt32(2), as: UInt32.self)

            (msg + 4).storeBytes(of: UInt32(msgSize), as: UInt32.self)
            (msg + 24).storeBytes(of: UInt32(pld), as: UInt32.self)

            free(raw)
            try await bridge.sendMessage(msg, via: hidClient)
        }
    }

    // MARK: - Screen Info (from SimDevice's deviceType via ObjC runtime)

    private static func screenInfo(
        for device: NSObject
    ) -> (width: CGFloat, height: CGFloat, scale: CGFloat)? {
        guard let deviceType = device
            .perform(NSSelectorFromString("deviceType"))?
            .takeUnretainedValue() as? NSObject else { return nil }

        // mainScreenSize -> CGSize (display pixels)
        let sizeSel = NSSelectorFromString("mainScreenSize")
        guard let sizeImp = class_getMethodImplementation(type(of: deviceType), sizeSel)
        else { return nil }
        typealias SizeFn = @convention(c) (NSObject, Selector) -> CGSize
        let size = unsafeBitCast(sizeImp, to: SizeFn.self)(deviceType, sizeSel)
        guard size.width > 0, size.height > 0 else { return nil }

        // mainScreenScale -> float (ObjC type encoding "f", 32-bit)
        let scaleSel = NSSelectorFromString("mainScreenScale")
        guard let scaleImp = class_getMethodImplementation(type(of: deviceType), scaleSel)
        else { return nil }
        typealias ScaleFn = @convention(c) (NSObject, Selector) -> Float
        let scale = CGFloat(unsafeBitCast(scaleImp, to: ScaleFn.self)(deviceType, scaleSel))
        guard scale > 0 else { return nil }

        return (size.width, size.height, scale)
    }
}
