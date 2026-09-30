import Foundation
import IOKit.hid

enum LuxaforOutputError: LocalizedError {
    case disconnected
    case permissionRequired
    case openFailed(IOReturn)
    case writeFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .disconnected:
            return "Luxafor Flag 2 is not connected."
        case .permissionRequired:
            return "Input Monitoring permission is required."
        case .openFailed(let result):
            return String(format: "Could not open Luxafor (0x%08x).", result)
        case .writeFailed(let result):
            return String(format: "Could not send Luxafor color (0x%08x).", result)
        }
    }
}

/// Discovers and controls a directly connected Luxafor Flag over USB HID.
/// Flag and Flag 2 expose the same VID, PID, and eight-byte output report.
final class LuxaforOutput: ActivityOutput, OutputDeviceDetector {
    let id = "luxafor-flag"
    let displayName = "Luxafor Flag 2"

    private static let vendorID = 0x04D8
    private static let productID = 0xF372
    private static let allLEDs: UInt8 = 0xFF
    private static let strobeSpeed: UInt8 = 30
    private let manager: IOHIDManager
    private var lastSignal: AttentionSignal?
    private var lastPublishDate = Date.distantPast

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
    }

    func currentStatus() -> OutputDeviceStatus {
        let connected = firstDevice() != nil
        let ready = connected && hasAccess
        let detail: String
        if !connected {
            detail = "Not detected"
        } else if ready {
            detail = "Connected via USB"
        } else {
            detail = "Connected · Input Monitoring required"
        }
        return OutputDeviceStatus(
            id: id,
            displayName: displayName,
            isConnected: connected,
            isReady: ready,
            detail: detail
        )
    }

    func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func publish(_ signal: AttentionSignal) throws {
        guard hasAccess else { throw LuxaforOutputError.permissionRequired }
        guard let device = firstDevice() else {
            lastSignal = nil
            throw LuxaforOutputError.disconnected
        }

        let refreshesStrobe = signal.isBlinking
            && Date().timeIntervalSince(lastPublishDate) >= 30
        guard signal != lastSignal || refreshesStrobe else { return }

        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            lastSignal = nil
            if openResult == kIOReturnNotPermitted {
                throw LuxaforOutputError.permissionRequired
            }
            throw LuxaforOutputError.openFailed(openResult)
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        var report = Self.report(for: signal)
        let writeResult = report.withUnsafeMutableBytes { bytes in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                0,
                bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                bytes.count
            )
        }
        guard writeResult == kIOReturnSuccess else {
            lastSignal = nil
            throw LuxaforOutputError.writeFailed(writeResult)
        }
        lastSignal = signal
        lastPublishDate = Date()
    }

    private var hasAccess: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private func firstDevice() -> IOHIDDevice? {
        guard let devices = IOHIDManagerCopyDevices(manager), CFSetGetCount(devices) > 0 else {
            return nil
        }
        var values = [UnsafeRawPointer?](repeating: nil, count: CFSetGetCount(devices))
        CFSetGetValues(devices, &values)
        guard let pointer = values.compactMap({ $0 }).first else { return nil }
        return Unmanaged<IOHIDDevice>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func report(for signal: AttentionSignal) -> [UInt8] {
        switch signal {
        case .inactive:
            return solid(red: 0, green: 0, blue: 0)
        case .idle:
            return solid(red: 0, green: 0, blue: 255)
        case .active:
            return strobe(red: 0, green: 255, blue: 0)
        case .partialAttention:
            return strobe(red: 255, green: 255, blue: 0)
        case .fullAttention:
            return strobe(red: 255, green: 0, blue: 0)
        }
    }

    private static func solid(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        [1, allLEDs, red, green, blue, 0, 0, 0]
    }

    private static func strobe(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        [3, allLEDs, red, green, blue, strobeSpeed, 0, 0xFF]
    }
}

private extension AttentionSignal {
    var isBlinking: Bool {
        self == .active || self == .partialAttention || self == .fullAttention
    }
}
