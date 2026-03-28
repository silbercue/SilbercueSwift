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

    /// Cached SimServiceContext (expensive to create: ~167ms, reuse across calls).
    nonisolated(unsafe) private static var _serviceContext: NSObject?

    /// Whether CoreSimulator frameworks are available.
    static var isAvailable: Bool {
        coreSimHandle != nil
    }

    // MARK: - Public API

    /// Capture framebuffer as CGImage (no encoding, no file I/O).
    static func captureImage(simulator: String = "booted") throws -> CGImage {
        guard coreSimHandle != nil else {
            throw CaptureError.frameworkNotFound
        }

        let device = try findDevice(simulator: simulator)
        let surface = try getFramebufferSurface(device: device)

        let ciImage = CIImage(ioSurface: surface)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw CaptureError.conversionFailed
        }
        return cgImage
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

        // serviceContext.defaultDeviceSetWithError: → SimDeviceSet
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
            // state == 3 means booted
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

    private static func getFramebufferSurface(device: NSObject) throws -> IOSurfaceRef {
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

            // Try framebufferSurface (Xcode 13.2+), then ioSurface (older)
            if let surface = extractSurface(from: descriptor, selector: "framebufferSurface") {
                return surface
            }
            if let surface = extractSurface(from: descriptor, selector: "ioSurface") {
                return surface
            }
        }

        throw CaptureError.noFramebuffer("No display port with IOSurface found")
    }

    private static func extractSurface(from descriptor: NSObject, selector: String)
        -> IOSurfaceRef?
    {
        let s = sel(selector)
        guard descriptor.responds(to: s),
            let result = descriptor.perform(s)?.takeUnretainedValue()
        else { return nil }

        let raw = Unmanaged.passUnretained(result).toOpaque()
        let surfaceRef = unsafeBitCast(raw, to: IOSurfaceRef.self)

        guard IOSurfaceGetWidth(surfaceRef) > 0 && IOSurfaceGetHeight(surfaceRef) > 0 else {
            return nil
        }
        return surfaceRef
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
