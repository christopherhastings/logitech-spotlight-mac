// hidpp_probe — talk HID++ 2.0 to the Logitech receiver's vendor interface.
import Foundation
import IOKit.hid

let SWID: UInt8 = 0x05
setvbuf(stdout, nil, _IOLBF, 0)

let VID = 0x046D, PID = 0xC53E
func prop(_ d: IOHIDDevice, _ k: String) -> Int {
    guard let v = IOHIDDeviceGetProperty(d, k as CFString) else { return -1 }
    return (v as? NSNumber)?.intValue ?? -1
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID] as CFDictionary)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { print("no devices"); exit(1) }
guard let dev = set.first(where: { prop($0, kIOHIDPrimaryUsagePageKey) == 0xFF00 && prop($0, kIOHIDPrimaryUsageKey) == 0x01 })
else { print("no HID++ vendor interface"); exit(1) }

IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
var inbuf = [UInt8](repeating: 0, count: 64)
var replies: [[UInt8]] = []
var notifications: [[UInt8]] = []

let cb: IOHIDReportCallback = { _, _, _, _, rid, rpt, len in
    var b = [UInt8](repeating: 0, count: len)
    for i in 0..<len { b[i] = rpt[i] }
    // byte2 = feature index for replies; >=0x80 or swId==0 means notification
    if b.count >= 4 && (b[3] & 0x0F) == SWID { replies.append(b) } else { notifications.append(b) }
}
inbuf.withUnsafeMutableBufferPointer { p in
    IOHIDDeviceRegisterInputReportCallback(dev, p.baseAddress!, 64, cb, nil)
}
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let SW: UInt8 = 0x05
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

@discardableResult
func send(_ reportID: UInt8, _ devIdx: UInt8, _ feat: UInt8, _ funcSw: UInt8, _ params: [UInt8]) -> [UInt8]? {
    // macOS SetReport wants the report ID as byte 0 of the buffer as well.
    let size = reportID == 0x10 ? 7 : (reportID == 0x11 ? 20 : 32)
    var pkt = [UInt8](repeating: 0, count: size)
    pkt[0] = reportID; pkt[1] = devIdx; pkt[2] = feat; pkt[3] = funcSw
    for (i, p) in params.enumerated() where 4 + i < size { pkt[4 + i] = p }
    replies.removeAll()
    let r = pkt.withUnsafeBufferPointer {
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportID), $0.baseAddress!, pkt.count)
    }
    if r != kIOReturnSuccess { print(String(format: "  setReport err 0x%08X", r)); return nil }
    let deadline = Date().addingTimeInterval(0.35)
    while Date() < deadline && replies.isEmpty { CFRunLoopRunInMode(.defaultMode, 0.02, true) }
    return replies.first
}

print("=== HID++ probe: receiver 046d:c53e ===\n")

// Receiver itself is device index 0xFF. Paired devices are 1..6.
for idx: UInt8 in [0xFF, 1, 2, 3, 4, 5, 6] {
    // root.getProtocolVersion (feature 0x0000, func 1) doubles as ping
    guard let r = send(0x10, idx, 0x00, (1 << 4) | SW, [0, 0, 0xAA]) else {
        print(String(format: "idx %02X: no response", idx)); continue
    }
    if r[1] == 0x8F {
        print(String(format: "idx %02X: HID++1.0 error (no device paired here) [%@]", idx, hex(r)))
        continue
    }
    print(String(format: "idx %02X: HID++ %d.%d  raw %@", idx, r[4], r[5], hex(r)))

    // feature table size: feature 0x0001 (IFeatureSet) — first find its index via root.getFeature
    func featureIndex(_ id: UInt16) -> UInt8? {
        guard let f = send(0x10, idx, 0x00, (0 << 4) | SW, [UInt8(id >> 8), UInt8(id & 0xFF), 0]) else { return nil }
        return f[4] == 0 ? nil : f[4]
    }
    for (name, id) in [("IFeatureSet", UInt16(0x0001)), ("DeviceName", 0x0005), ("BatteryUnified", 0x1000),
                       ("BatteryVoltage", 0x1001), ("ReprogControlsV4", 0x1B04), ("PresenterCtl", 0x1A00),
                       ("Spotlight/0x1B04", 0x1B04), ("SpecialKeysMSE", 0x1B00),
                       ("Gesture2", 0x6501), ("MousePointer", 0x2200), ("HiResScroll", 0x2121),
                       ("PresenterVendor_1B05", 0x1B05), ("Backlight", 0x1982), ("ChangeHost", 0x1814),
                       ("Spotlight_1A01", 0x1A01), ("Spotlight_1A02", 0x1A02)] {
        if let fi = featureIndex(id) {
            print(String(format: "    feature %@ (0x%04X) -> index 0x%02X", name, id, fi))
        }
    }
    // dump whole feature table
    if let fsIdx = featureIndex(0x0001), let cnt = send(0x10, idx, fsIdx, (0 << 4) | SW, [0,0,0]) {
        let n = Int(cnt[4])
        print("    feature table (\(n) features):")
        for i in 0...n {
            if let f = send(0x10, idx, fsIdx, (1 << 4) | SW, [UInt8(i), 0, 0]) {
                let fid = (UInt16(f[4]) << 8) | UInt16(f[5])
                print(String(format: "      [%02d] 0x%04X  flags 0x%02X", i, fid, f[6]))
            }
        }
    }
}

print("\n=== notifications seen during probe ===")
for n in notifications { print("  " + hex(n)) }
