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
final class LuxaforOutput: BrightnessAdjustableOutput, OutputDeviceDetector {
    let id = "luxafor-flag"
    let displayName = "Luxafor Flag 2"

    private static let vendorID = 0x04D8
    private static let productID = 0xF372
    private static let allLEDs: UInt8 = 0xFF
    private let manager: IOHIDManager
    private(set) var brightness: Double
    private var lastSignal: AttentionSignal?
    private var lastIlluminated: Bool?
    private var lastPublishDate = Date.distantPast

    init(brightness: Double = 1) {
        self.brightness = min(max(brightness, 0), 1)
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

    func setBrightness(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        guard clamped != brightness else { return }
        brightness = clamped
        // Force the next output tick to apply the new intensity even when the
        // activity signal itself has not changed.
        lastSignal = nil
    }

    func publish(_ signal: AttentionSignal) throws {
        let now = Date()
        let illuminated = signal.isLit(at: now)
        let needsReassertion = now.timeIntervalSince(lastPublishDate) >= 2
        guard signal != lastSignal || illuminated != lastIlluminated || needsReassertion else {
            return
        }
        try send(Self.report(for: signal, illuminated: illuminated, brightness: brightness))
        lastSignal = signal
        lastIlluminated = illuminated
        lastPublishDate = now
    }

    private func send(_ reportBytes: [UInt8]) throws {
        guard hasAccess else { throw LuxaforOutputError.permissionRequired }
        guard let device = firstDevice() else { throw LuxaforOutputError.disconnected }
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            if openResult == kIOReturnNotPermitted {
                throw LuxaforOutputError.permissionRequired
            }
            throw LuxaforOutputError.openFailed(openResult)
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        var report = reportBytes
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
            throw LuxaforOutputError.writeFailed(writeResult)
        }
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

    private static func report(
        for signal: AttentionSignal,
        illuminated: Bool,
        brightness: Double
    ) -> [UInt8] {
        if signal.isBlinking && !illuminated {
            return solid(red: 0, green: 0, blue: 0)
        }
        switch signal {
        case .inactive:
            return solid(red: 0, green: 0, blue: 0)
        case .idle:
            return solid(red: 0, green: 0, blue: scaled(255, by: brightness))
        case .active:
            return solid(red: 0, green: scaled(255, by: brightness), blue: 0)
        case .partialAttention:
            return solid(
                red: scaled(255, by: brightness),
                green: scaled(255, by: brightness),
                blue: 0
            )
        case .fullAttention:
            return solid(red: scaled(255, by: brightness), green: 0, blue: 0)
        }
    }

    private static func scaled(_ component: UInt8, by brightness: Double) -> UInt8 {
        UInt8((Double(component) * min(max(brightness, 0), 1)).rounded())
    }

    private static func solid(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        [1, allLEDs, red, green, blue, 0, 0, 0]
    }

}
