import Foundation
import IOKit.hid

/// Detects a directly connected Luxafor Flag without claiming the device or
/// sending a HID report. Flag and Flag 2 currently expose the same VID/PID.
final class LuxaforDeviceDetector: OutputDeviceDetector {
    let id = "luxafor-flag"
    let displayName = "Luxafor Flag 2"

    private static let vendorID = 0x04D8
    private static let productID = 0xF372
    private let manager: IOHIDManager

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
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func currentStatus() -> OutputDeviceStatus {
        let isConnected = IOHIDManagerCopyDevices(manager).map { CFSetGetCount($0) > 0 } ?? false
        return OutputDeviceStatus(
            id: id,
            displayName: displayName,
            isConnected: isConnected,
            detail: isConnected ? "Connected via USB" : "Not detected"
        )
    }
}
