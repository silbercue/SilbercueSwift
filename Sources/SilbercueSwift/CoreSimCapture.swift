import CoreGraphics
import CoreImage
import Foundation
import IOSurface

/// Direct Simulator framebuffer capture via CoreSimulator private APIs.
/// Reads the IOSurface backing the Simulator display — no TCC, no background process.
/// ~5-27ms per screenshot (5ms convert + 22ms PNG / 5ms JPEG).
enum CoreSimCapture {

    // MARK: - Framework Loading (one-time)

    nonisolated(unsafe) private static let coreSimHandle: UnsafeMutableRawPointer? = {
        dlopen(
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW)
    }()

    nonisolated(unsafe) private static let simKitHandle: UnsafeMutableRawPointer? = {
        dlopen(
            "/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
            RTLD_NOW)
    }()

    private static let ciContext = CIContext()

    // MARK: - Cached State (avoid re-traversal on every call)

    /// Cached SimServiceContext (~167ms to create).
    nonisolated(unsafe) private static var _serviceContext: NSObject?

    /// Cached descriptor that has the framebufferSurface property.
    /// The IOSurface itself changes on every frame, but the descriptor object is stable.
    nonisolated(unsafe) private static var _cachedDescriptor: NSObject?
    nonisolated(unsafe) private static var _cachedSurfaceSelector: Selector?
    nonisolated(unsafe) private static var _cachedSimulator: String?

    /// Whether CoreSimulator frameworks are available.
    static var isAvailable: Bool {
        coreSimHandle != nil
    }

    // MARK: - Public API

    /// Capture framebuffer as CGImage (no encoding, no file I/O).
    /// Synchronous version — only call from non-async contexts or DispatchQueue.
    static func captureImage(simulator: String = "booted") throws -> CGImage {
        guard coreSimHandle != nil else {
            throw CaptureError.frameworkNotFound
        }

        let surface = try getCachedSurface(simulator: simulator)

        let ciImage = CIImage(ioSurface: surface)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw CaptureError.conversionFailed
        }
        return cgImage
    }

    /// Async-safe version that runs the synchronous ObjC/XPC calls on a dedicated
    /// POSIX thread (DispatchQueue.global), NOT on Swift's Cooperative Thread Pool.
    /// This prevents thread pool exhaustion when CoreSimulator XPC calls block.
    static func captureImageAsync(simulator: String = "booted") async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                do {
                    let image = try captureImage(simulator: simulator)
                    continuation.resume(returning: image)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Cached Surface Access

    /// Get the IOSurface, reusing the cached descriptor path when possible.
    private static func getCachedSurface(simulator: String) throws -> IOSurfaceRef {
        // Fast path: reuse cached descriptor
        if simulator == _cachedSimulator,
            let descriptor = _cachedDescriptor,
            let surfaceSel = _cachedSurfaceSelector,
            let result = descriptor.perform(surfaceSel)?.takeUnretainedValue()
        {
            let raw = Unmanaged.passUnretained(result).toOpaque()
            let ref = unsafeBitCast(raw, to: IOSurfaceRef.self)
            if IOSurfaceGetWidth(ref) > 0 && IOSurfaceGetHeight(ref) > 0 {
                return ref
            }
        }

        // Slow path: full traversal, then cache
        let device = try findDevice(simulator: simulator)
        let (surface, descriptor, surfaceSel) = try findFramebufferSurface(device: device)

        _cachedDescriptor = descriptor
        _cachedSurfaceSelector = surfaceSel
        _cachedSimulator = simulator

        return surface
    }

    // MARK: - Service Context (cached)

    private static func getServiceContext() throws -> NSObject {
        if let cached = _serviceContext { return cached }

        guard let ctxClass = NSClassFromString("SimServiceContext") as? NSObject.Type else {
            throw CaptureError.frameworkNotFound
        }

        let devDir = "/Applications/Xcode.app/Contents/Developer" as NSString
        var error: NSError?
        let ctx: NSObject? = withUnsafeMutablePointer(to: &error) { errPtr in
            let result = (ctxClass as AnyObject).perform(
                sel("sharedServiceContextForDeveloperDir:error:"), with: devDir, with: errPtr)
            return result?.takeUnretainedValue() as? NSObject
        }

        guard let serviceContext = ctx else {
            throw CaptureError.noDevice(
                "SimServiceContext creation failed: \(error?.localizedDescription ?? "unknown")")
        }

        _serviceContext = serviceContext
        return serviceContext
    }

    // MARK: - Device Discovery

    private static func findDevice(simulator: String) throws -> NSObject {
        let serviceContext = try getServiceContext()

        var error: NSError?
        let deviceSet: NSObject? = withUnsafeMutablePointer(to: &error) { errPtr in
            let result = serviceContext.perform(
                sel("defaultDeviceSetWithError:"), with: errPtr)
            return result?.takeUnretainedValue() as? NSObject
        }

        guard let devSet = deviceSet else {
            throw CaptureError.noDevice(
                "Cannot get device set: \(error?.localizedDescription ?? "unknown")")
        }

        guard let devices = devSet.perform(sel("devices"))?.takeUnretainedValue() as? [NSObject]
        else {
            throw CaptureError.noDevice("Cannot enumerate devices")
        }

        if simulator == "booted" {
            for device in devices {
                if let state = device.value(forKey: "state") as? Int, state == 3 {
                    return device
                }
            }
            throw CaptureError.noDevice("No booted simulator found")
        } else {
            for device in devices {
                if let udid = device.perform(sel("UDID"))?.takeUnretainedValue() as? NSUUID,
                    udid.uuidString == simulator
                {
                    return device
                }
            }
            throw CaptureError.noDevice("Simulator \(simulator) not found")
        }
    }

    // MARK: - Framebuffer Access

    /// Find the IOSurface and cache the descriptor + selector for reuse.
    private static func findFramebufferSurface(device: NSObject) throws -> (
        IOSurfaceRef, NSObject, Selector
    ) {
        guard let io = device.value(forKey: "io") as? NSObject else {
            throw CaptureError.noFramebuffer("Cannot access device.io")
        }

        guard let ports = io.perform(sel("ioPorts"))?.takeUnretainedValue() as? [NSObject] else {
            throw CaptureError.noFramebuffer("Cannot access io.ioPorts")
        }

        for port in ports {
            guard
                let descriptor = port.perform(sel("descriptor"))?.takeUnretainedValue() as? NSObject
            else { continue }

            for selName in ["framebufferSurface", "ioSurface"] {
                let s = sel(selName)
                guard descriptor.responds(to: s),
                    let result = descriptor.perform(s)?.takeUnretainedValue()
                else { continue }

                let raw = Unmanaged.passUnretained(result).toOpaque()
                let ref = unsafeBitCast(raw, to: IOSurfaceRef.self)

                if IOSurfaceGetWidth(ref) > 0 && IOSurfaceGetHeight(ref) > 0 {
                    return (ref, descriptor, s)
                }
            }
        }

        throw CaptureError.noFramebuffer("No display port with IOSurface found")
    }

    // MARK: - Helpers

    private static func sel(_ name: String) -> Selector {
        NSSelectorFromString(name)
    }

    enum CaptureError: Error, CustomStringConvertible {
        case frameworkNotFound
        case noDevice(String)
        case noFramebuffer(String)
        case conversionFailed

        var description: String {
            switch self {
            case .frameworkNotFound:
                return "CoreSimulator.framework not found — Xcode not installed?"
            case .noDevice(let msg): return "Device: \(msg)"
            case .noFramebuffer(let msg): return "Framebuffer: \(msg)"
            case .conversionFailed: return "IOSurface → CGImage conversion failed"
            }
        }
    }
}
