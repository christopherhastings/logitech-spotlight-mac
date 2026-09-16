// hiddump — enumerate Logitech receiver HID interfaces and dump every input report.
import Foundation
import IOKit.hid

let VID = 0x046D
setvbuf(stdout, nil, _IOLBF, 0)

func prop(_ d: IOHIDDevice, _ key: String) -> Int {
    guard let v = IOHIDDeviceGetProperty(d, key as CFString) else { return -1 }
    return (v as? NSNumber)?.intValue ?? -1
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: VID] as CFDictionary)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))

guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
    print("No Logitech HID devices found (or Input Monitoring permission denied).")
    exit(1)
}

var devs: [IOHIDDevice] = []
for d in set {
    let pid = prop(d, kIOHIDProductIDKey)
    guard pid == 0xC53E else { continue }
    devs.append(d)
}
devs.sort { prop($0, kIOHIDPrimaryUsageKey) < prop($1, kIOHIDPrimaryUsageKey) }

print("Logitech receiver interfaces:")
for d in devs {
    let up = prop(d, kIOHIDPrimaryUsagePageKey), u = prop(d, kIOHIDPrimaryUsageKey)
    print(String(format: "  usagePage 0x%04X  usage 0x%02X  maxIn %d  maxOut %d",
                 up, u, prop(d, kIOHIDMaxInputReportSizeKey), prop(d, kIOHIDMaxOutputReportSizeKey)))
}
print("\nPress buttons on the remote. Ctrl-C to stop.\n")

var bufs: [ObjectIdentifier: UnsafeMutablePointer<UInt8>] = [:]

let cb: IOHIDReportCallback = { ctx, result, sender, type, reportID, report, length in
    let dev = Unmanaged<AnyObject>.fromOpaque(sender!).takeUnretainedValue() as! IOHIDDevice
    let up = prop(dev, kIOHIDPrimaryUsagePageKey), u = prop(dev, kIOHIDPrimaryUsageKey)
    var hex = ""
    for i in 0..<length { hex += String(format: "%02X ", report[i]) }
    let t = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
    print(String(format: "[%@] page 0x%04X/0x%02X id %d len %2d : %@", t, up, u, Int(reportID), length, hex))
}

for d in devs {
    IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    let n = max(prop(d, kIOHIDMaxInputReportSizeKey), 64)
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
    bufs[ObjectIdentifier(d)] = buf
    IOHIDDeviceRegisterInputReportCallback(d, buf, n, cb, nil)
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
}

CFRunLoopRun()
