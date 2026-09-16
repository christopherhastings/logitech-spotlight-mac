// pairing — read the receiver's HID++ 1.0 pairing table. Works while the remote is asleep.
import Foundation
import IOKit.hid

setvbuf(stdout, nil, _IOLBF, 0)

func prop(_ d: IOHIDDevice, _ k: String) -> Int {
    ((IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue) ?? -1
}
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x046D, kIOHIDProductIDKey: 0xC53E] as CFDictionary)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
guard let all = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
      let dev = all.first(where: { prop($0, kIOHIDPrimaryUsagePageKey) == 0xFF00 }) else {
    print("receiver not found"); exit(1)
}
guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("could not open receiver — is Presenter.app still running?"); exit(1)
}

nonisolated(unsafe) var inbox: [[UInt8]] = []
var buf = [UInt8](repeating: 0, count: 64)
buf.withUnsafeMutableBufferPointer { p in
    IOHIDDeviceRegisterInputReportCallback(dev, p.baseAddress!, 64, { _, _, _, _, _, r, len in
        var b = [UInt8](repeating: 0, count: len); for i in 0..<len { b[i] = r[i] }
        inbox.append(b)
    }, nil)
}
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

/// HID++ 1.0: [reportID][deviceIndex][subID][register][params...]
func reg(_ reportID: UInt8, _ subID: UInt8, _ register: UInt8, _ params: [UInt8] = []) -> [UInt8]? {
    let size = reportID == 0x10 ? 7 : 20
    var pkt = [UInt8](repeating: 0, count: size)
    pkt[0] = reportID; pkt[1] = 0xFF; pkt[2] = subID; pkt[3] = register
    for (i, p) in params.enumerated() where 4 + i < size { pkt[4 + i] = p }
    inbox.removeAll()
    guard pkt.withUnsafeBufferPointer({
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportID), $0.baseAddress!, pkt.count)
    }) == kIOReturnSuccess else { return nil }
    let deadline = Date().addingTimeInterval(0.4)
    while Date() < deadline && inbox.isEmpty { CFRunLoopRunInMode(.defaultMode, 0.02, true) }
    return inbox.first
}

print("=== receiver 046d:c53e pairing table ===\n")

if let r = reg(0x10, 0x81, 0x00) { print("notification flags : \(hex(r))") }
if let r = reg(0x10, 0x81, 0x02) { print("connection state   : \(hex(r))   (byte 5 = devices paired)") }

// Register 0xB5: pairing information. 0x20+n = device name, 0x00+n = wireless PID etc.
for n: UInt8 in 0..<6 {
    guard let info = reg(0x11, 0x83, 0xB5, [0x20 + n]), info.count > 6, info[2] != 0x8F else { continue }
    let len = Int(info[5])
    let name = String(decoding: info[6..<min(6 + len, info.count)], as: UTF8.self)
    var line = String(format: "device %d: \"%@\"", n + 1, name)
    if let p = reg(0x11, 0x83, 0xB5, [0x00 + n]), p.count > 11, p[2] != 0x8F {
        line += String(format: "   wireless PID 0x%02X%02X  type 0x%02X", p[10], p[11], p[7])
        line += "   raw " + hex(Array(p.prefix(14)))
    }
    print(line)
}

print("\n(no output above means nothing is paired to this receiver)")
