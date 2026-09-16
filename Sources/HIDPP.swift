//  HIDPP.swift — HID++ 2.0 transport for the Logitech USB receiver.
//
//  Wire format notes (learned by probing 046d:c53e on macOS 27):
//   * IOHIDDeviceSetReport wants the report ID BOTH as the CFIndex argument
//     and as byte 0 of the buffer, otherwise every field shifts by one.
//   * Input reports arrive with the report ID already at byte 0.
//   * Short report 0x10 = 7 bytes, long 0x11 = 20 bytes, very long 0x12 = 32.
//
//  Layout:  [reportID][deviceIndex][featureIndex][funcIdx<<4 | swId][params...]
//  Errors:  [0x10][deviceIndex][0x8F][origFeatureIdx][origFunc][errorCode][0]
//           [0xFF][deviceIndex][origFeatureIdx][origFunc][errorCode]        (HID++ 2.0)

import Foundation
import IOKit.hid

let kLogitechVID = 0x046D
let kSpotlightReceiverPID = 0xC53E

/// How we reached the remote. Bluetooth firmware only accepts long (0x11) reports,
/// where the USB receiver is happy with short (0x10) ones too.
enum HIDPPTransport {
    case usbReceiver
    case bluetooth

    /// Report ID to use for a request that carries no more than three parameters.
    var shortReportID: UInt8 { self == .bluetooth ? 0x11 : 0x10 }
    var label: String { self == .bluetooth ? "Bluetooth" : "USB receiver" }
}

struct HIDPPMessage {
    var bytes: [UInt8]
    var reportID: UInt8 { bytes.first ?? 0 }
    var deviceIndex: UInt8 { bytes.count > 1 ? bytes[1] : 0 }
    var featureIndex: UInt8 { bytes.count > 2 ? bytes[2] : 0 }
    var funcByte: UInt8 { bytes.count > 3 ? bytes[3] : 0 }
    var funcIndex: UInt8 { funcByte >> 4 }
    var swID: UInt8 { funcByte & 0x0F }
    /// Payload after the 4-byte header.
    var params: ArraySlice<UInt8> { bytes.count > 4 ? bytes[4...] : [] }
    var isError: Bool { featureIndex == 0x8F || reportID == 0xFF }
    var hex: String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

enum HIDPPError: Error, CustomStringConvertible {
    case noReceiver
    case noVendorInterface
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case timeout
    case deviceError(UInt8)
    case featureNotSupported(UInt16)

    var description: String {
        switch self {
        case .noReceiver: return "Logitech receiver (046d:c53e) not plugged in"
        case .noVendorInterface: return "receiver has no HID++ vendor interface"
        case .openFailed(let r): return String(format: "could not open HID device (0x%08X)", r)
        case .writeFailed(let r): return String(format: "HID write failed (0x%08X)", r)
        case .timeout: return "remote did not answer — is it switched on and set to the receiver channel?"
        case .deviceError(let c): return "device returned HID++ error \(c) (\(HIDPPError.name(c)))"
        case .featureNotSupported(let f): return String(format: "device does not support feature 0x%04X", f)
        }
    }
    static func name(_ c: UInt8) -> String {
        switch c {
        case 1: return "unknown"; case 2: return "invalid argument"; case 3: return "out of range"
        case 4: return "hardware error"; case 5: return "internal"; case 6: return "invalid feature index"
        case 7: return "invalid function id"; case 8: return "busy"; case 9: return "unsupported / device off"
        default: return "code \(c)" }
    }
}

/// How an incoming report relates to a request we sent.
enum HIDPPReply: Equatable {
    case answer
    case failure(UInt8)
    case unrelated
}

/// The wire-format rules, kept free of IOKit so they can be tested without hardware.
enum HIDPPWire {
    static func size(for reportID: UInt8) -> Int {
        switch reportID {
        case 0x10: return 7
        case 0x11: return 20
        default:   return 32
        }
    }

    /// macOS wants the report ID as byte 0 of the buffer *as well as* the CFIndex
    /// argument to IOHIDDeviceSetReport. Omitting it shifts every field by one.
    static func packet(reportID: UInt8, device: UInt8, feature: UInt8,
                       function: UInt8, swID: UInt8, params: [UInt8]) -> [UInt8] {
        let n = size(for: reportID)
        var pkt = [UInt8](repeating: 0, count: n)
        pkt[0] = reportID
        pkt[1] = device
        pkt[2] = feature
        pkt[3] = (function << 4) | swID
        for (i, p) in params.enumerated() where 4 + i < n { pkt[4 + i] = p }
        return pkt
    }

    /// Decide whether `msg` answers the request described by the other arguments.
    /// Writes we do not wait on are acknowledged too, so matching on the software
    /// ID alone lets a stale ack be read as the answer to a later question.
    static func classify(_ msg: HIDPPMessage, device: UInt8, feature: UInt8,
                         function: UInt8) -> HIDPPReply {
        let b = msg.bytes
        // HID++ 2.0 error: [FF][device][feature][function|swID][code]
        if msg.reportID == 0xFF {
            guard b.count > 4, b[2] == feature, (b[3] >> 4) == function else { return .unrelated }
            return .failure(b[4])
        }
        // HID++ 1.0 error: [10][device][8F][origFeature][origFunction][code]
        if msg.featureIndex == 0x8F {
            guard b.count > 5, b[3] == feature else { return .unrelated }
            return .failure(b[5])
        }
        guard msg.deviceIndex == device,
              msg.featureIndex == feature,
              msg.funcIndex == function else { return .unrelated }
        return .answer
    }
}

/// Owns the receiver's 0xFF00 vendor interface and pumps it on its own run loop thread.
final class HIDPPLink {
    /// Held for the lifetime of the link — releasing the manager closes the device
    /// underneath us and every write then fails with kIOReturnNotOpen.
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private(set) var transport: HIDPPTransport = .usbReceiver
    private var inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    private let lock = NSCondition()
    private var pending: [HIDPPMessage] = []
    private let swID: UInt8 = 0x0A

    /// Unsolicited notifications (button presses, motion, connect/disconnect).
    var onNotification: ((HIDPPMessage) -> Void)?
    /// Every raw report, for the capture/learn tool.
    var onRawReport: ((HIDPPMessage) -> Void)?
    /// The receiver or Bluetooth remote disappeared.
    var onDeviceRemoved: (() -> Void)?

    // MARK: open / close

    func open() throws {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match any Logitech HID++ vendor interface, so the same code path serves
        // the USB receiver and a Spotlight paired straight over Bluetooth.
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: kLogitechVID,
                                            kIOHIDPrimaryUsagePageKey: 0xFF00,
                                            kIOHIDPrimaryUsageKey: 0x01] as CFDictionary)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        guard let all = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !all.isEmpty else {
            throw HIDPPError.noReceiver
        }
        func intProp(_ d: IOHIDDevice, _ k: String) -> Int {
            ((IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue) ?? -1
        }
        func strProp(_ d: IOHIDDevice, _ k: String) -> String {
            (IOHIDDeviceGetProperty(d, k as CFString) as? String) ?? ""
        }
        // Prefer the dedicated receiver when both are present.
        let chosen = all.first(where: { intProp($0, kIOHIDProductIDKey) == kSpotlightReceiverPID })
                  ?? all.first!
        transport = strProp(chosen, kIOHIDTransportKey).lowercased().contains("bluetooth")
                  ? .bluetooth : .usbReceiver

        let r = IOHIDDeviceOpen(chosen, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { throw HIDPPError.openFailed(r) }
        device = chosen

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, removed in
            guard let ctx else { return }
            let link = Unmanaged<HIDPPLink>.fromOpaque(ctx).takeUnretainedValue()
            if removed == link.device { DispatchQueue.main.async { link.onDeviceRemoved?() } }
        }, Unmanaged.passUnretained(self).toOpaque())

        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self, let dev = self.device else { return }
            self.runLoop = CFRunLoopGetCurrent()
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(dev, self.inputBuffer, 64, { ctx, _, _, _, _, report, length in
                guard let ctx else { return }
                let link = Unmanaged<HIDPPLink>.fromOpaque(ctx).takeUnretainedValue()
                var b = [UInt8](repeating: 0, count: length)
                for i in 0..<length { b[i] = report[i] }
                link.dispatch(HIDPPMessage(bytes: b))
            }, ctx)
            IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            ready.signal()
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.2, false)
            }
        }
        t.name = "HIDPPLink"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
    }

    func close() {
        thread?.cancel()
        if let rl = runLoop { CFRunLoopStop(rl) }
        if let d = device { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let m = manager { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil; manager = nil
    }

    private func dispatch(_ msg: HIDPPMessage) {
        onRawReport?(msg)
        // A message is a candidate reply if it carries our software ID. Which
        // request it answers is decided in `request()` — fire-and-forget writes
        // also get acknowledged, and those stale acks must not be mistaken for
        // the answer to a later question.
        let sw: UInt8?
        switch msg.reportID {
        case 0xFF:                       // HID++ 2.0 error: [FF][dev][feat][func|sw][err]
            sw = msg.bytes.count > 3 ? msg.bytes[3] & 0x0F : nil
        default:
            sw = msg.featureIndex == 0x8F        // HID++ 1.0 error: [10][dev][8F][subID][addr][err]
                ? nil                            // 1.0 errors carry no software ID
                : msg.swID
        }
        if (sw != nil && sw == swID) || msg.featureIndex == 0x8F || msg.reportID == 0xFF {
            lock.lock()
            pending.append(msg)
            // Acks for writes we do not wait on land here with nothing reading
            // them; without a cap they would accumulate for the whole session.
            if pending.count > 16 { pending.removeFirst(pending.count - 16) }
            lock.signal()
            lock.unlock()
        } else {
            onNotification?(msg)
        }
    }

    // MARK: requests

    private func write(_ pkt: [UInt8], reportID: UInt8) throws {
        guard let dev = device else { throw HIDPPError.noReceiver }
        let r = pkt.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportID), $0.baseAddress!, pkt.count)
        }
        guard r == kIOReturnSuccess else { throw HIDPPError.writeFailed(r) }
    }

    /// Send a HID++ request and wait for the reply that actually answers it.
    /// `reportID: 0` means "whatever this transport prefers" — Bluetooth firmware
    /// rejects short reports, so it always needs 0x11.
    @discardableResult
    func request(reportID: UInt8 = 0, device deviceIndex: UInt8, feature: UInt8,
                 function: UInt8, params: [UInt8] = [], timeout: TimeInterval = 0.5) throws -> HIDPPMessage {
        let rid = reportID == 0 ? transport.shortReportID : reportID
        lock.lock(); pending.removeAll(); lock.unlock()
        try write(HIDPPWire.packet(reportID: rid, device: deviceIndex, feature: feature,
                                   function: function, swID: swID, params: params),
                  reportID: rid)

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            while pending.isEmpty {
                if !lock.wait(until: deadline) { lock.unlock(); throw HIDPPError.timeout }
            }
            let msg = pending.removeFirst()
            lock.unlock()

            switch HIDPPWire.classify(msg, device: deviceIndex, feature: feature, function: function) {
            case .answer:            return msg
            case .failure(let code): throw HIDPPError.deviceError(code)
            case .unrelated:         continue     // stale ack, or an answer to something else
            }
        }
    }

    /// Fire-and-forget (used for vibration, where some firmware never replies).
    func send(reportID: UInt8 = 0, device deviceIndex: UInt8, feature: UInt8,
              function: UInt8, params: [UInt8] = []) throws {
        let rid = reportID == 0 ? transport.shortReportID : reportID
        try write(HIDPPWire.packet(reportID: rid, device: deviceIndex, feature: feature,
                                   function: function, swID: swID, params: params),
                  reportID: rid)
    }

    // MARK: root feature lookup

    /// Root feature 0x0000, function 0: map a feature ID to this device's feature index.
    func featureIndex(device deviceIndex: UInt8, feature id: UInt16) throws -> UInt8 {
        let r = try request(device: deviceIndex, feature: 0x00, function: 0,
                            params: [UInt8(id >> 8), UInt8(id & 0xFF), 0])
        let idx = r.bytes.count > 4 ? r.bytes[4] : 0
        guard idx != 0 else { throw HIDPPError.featureNotSupported(id) }
        return idx
    }

    /// Root function 1 — also serves as a ping. Returns (major, minor).
    func protocolVersion(device deviceIndex: UInt8) throws -> (UInt8, UInt8) {
        let r = try request(device: deviceIndex, feature: 0x00, function: 1, params: [0, 0, 0xAA])
        guard r.bytes.count > 5 else { throw HIDPPError.timeout }
        return (r.bytes[4], r.bytes[5])
    }
}
