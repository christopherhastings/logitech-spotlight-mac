//  Spotlight.swift — Logitech Spotlight presenter on top of the HID++ link.
//
//  What this does that macOS does not: the remote's buttons are "diverted" with
//  feature 0x1B04 so the device stops emitting plain keystrokes and instead sends
//  HID++ press/release events plus a raw gyro dx/dy stream while a button is held.
//  That gyro stream is the whole point — it is what drives the spotlight circle,
//  the magnifier and the pointer, and it is the part macOS has no driver for.

import Foundation

enum Feat {
    static let root: UInt16              = 0x0000
    static let featureSet: UInt16        = 0x0001
    static let deviceName: UInt16        = 0x0005
    static let batteryStatus: UInt16     = 0x1000
    static let unifiedBattery: UInt16    = 0x1004
    static let haptic: UInt16            = 0x19B0
    static let presenterControl: UInt16  = 0x1A00
    static let reprogControlsV4: UInt16  = 0x1B04
    static let wirelessStatus: UInt16    = 0x1D4B
}

/// One reprogrammable control as the device describes itself.
struct ControlInfo {
    var cid: UInt16
    var taskID: UInt16
    var flags: UInt8
    var position: UInt8
    var group: UInt8
    var groupMask: UInt8
    var additionalFlags: UInt8

    var isDivertable: Bool { flags & 0x20 != 0 }
    var supportsRawXY: Bool { additionalFlags & 0x01 != 0 }
    var name: String { Spotlight.controlName(cid) }
}

struct BatteryState {
    var percent: Int
    var charging: Bool
}

protocol SpotlightDelegate: AnyObject {
    func spotlight(buttonDown cid: UInt16)
    func spotlight(buttonUp cid: UInt16)
    /// Raw gyro delta while a diverted button is held. Units are device counts.
    func spotlight(motionDX dx: Int, dy: Int)
    func spotlight(statusChanged connected: Bool, message: String)
}

final class Spotlight {
    private let link = HIDPPLink()
    private(set) var deviceIndex: UInt8 = 1
    var transport: HIDPPTransport { link.transport }
    private(set) var connected = false
    private(set) var controls: [ControlInfo] = []
    private(set) var deviceName: String = "Spotlight"

    private var fReprog: UInt8 = 0
    private var fBattery: UInt8 = 0
    private var fBatteryIsUnified = false
    private var fHaptic: UInt8 = 0

    private var heldCIDs: Set<UInt16> = []

    weak var delegate: SpotlightDelegate?
    /// Set by the capture tool to see every raw report.
    var rawReportHook: ((HIDPPMessage) -> Void)? {
        get { link.onRawReport } set { link.onRawReport = newValue }
    }

    // MARK: lifecycle

    func start() throws {
        link.onNotification = { [weak self] msg in self?.handle(msg) }
        try link.open()
        try connect()
    }

    func stop() {
        if connected { restoreButtons() }
        link.close()
        connected = false
    }

    /// Find the paired remote, resolve its feature indices, read its control list.
    func connect() throws {
        var found: UInt8? = nil
        var lastError: Error = HIDPPError.timeout
        for idx: UInt8 in 1...6 {
            do {
                let (major, _) = try link.protocolVersion(device: idx)
                if major >= 2 { found = idx; break }
            } catch { lastError = error }
        }
        guard let idx = found else {
            connected = false
            delegate?.spotlight(statusChanged: false, message: "\(lastError)")
            throw lastError
        }
        deviceIndex = idx

        fReprog = try link.featureIndex(device: idx, feature: Feat.reprogControlsV4)
        if let b = try? link.featureIndex(device: idx, feature: Feat.unifiedBattery) {
            fBattery = b; fBatteryIsUnified = true
        } else if let b = try? link.featureIndex(device: idx, feature: Feat.batteryStatus) {
            fBattery = b; fBatteryIsUnified = false
        }
        fHaptic = (try? link.featureIndex(device: idx, feature: Feat.haptic)) ?? 0
        deviceName = (try? readDeviceName(idx)) ?? "Spotlight"

        controls = try readControls(idx)
        connected = true
        delegate?.spotlight(statusChanged: true,
                            message: "\(deviceName) connected (device \(idx), \(controls.count) controls)")
    }

    private func readDeviceName(_ idx: UInt8) throws -> String {
        let f = try link.featureIndex(device: idx, feature: Feat.deviceName)
        let lenMsg = try link.request(device: idx, feature: f, function: 0)
        let total = Int(lenMsg.bytes.count > 4 ? lenMsg.bytes[4] : 0)
        var out = [UInt8]()
        var offset = 0
        while out.count < total && offset < 64 {
            let chunk = try link.request(reportID: 0x11, device: idx, feature: f,
                                        function: 1, params: [UInt8(offset)])
            out.append(contentsOf: chunk.bytes[4...].prefix(total - out.count).filter { $0 != 0 })
            offset += 16
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func readControls(_ idx: UInt8) throws -> [ControlInfo] {
        let count = Int(try link.request(device: idx, feature: fReprog, function: 0).bytes[4])
        var out: [ControlInfo] = []
        for i in 0..<count {
            guard let m = try? link.request(reportID: 0x11, device: idx, feature: fReprog,
                                            function: 1, params: [UInt8(i)]) else { continue }
            let b = m.bytes
            guard b.count >= 15 else { continue }
            out.append(ControlInfo(cid: UInt16(b[4]) << 8 | UInt16(b[5]),
                                   taskID: UInt16(b[6]) << 8 | UInt16(b[7]),
                                   flags: b[8], position: b[9], group: b[10],
                                   groupMask: b[11], additionalFlags: b[12]))
        }
        return out
    }

    // MARK: diversion

    /// Take over every control the device will let us take over.
    func divertButtons() {
        for c in controls where c.isDivertable {
            // flags: bit0 divert, bit1 dvalid, bit4 rawXY, bit5 rawXYvalid
            var flags: UInt8 = 0x03                       // divert + dvalid
            if c.supportsRawXY { flags |= 0x30 }          // rawXY + rawXYvalid
            _ = try? link.request(reportID: 0x11, device: deviceIndex, feature: fReprog, function: 3,
                                  params: [UInt8(c.cid >> 8), UInt8(c.cid & 0xFF), flags], timeout: 0.5)
        }
    }

    /// Hand the buttons back so the remote still works as a plain clicker after we quit.
    func restoreButtons() {
        for c in controls where c.isDivertable {
            var flags: UInt8 = 0x02                       // dvalid, divert off
            if c.supportsRawXY { flags |= 0x20 }          // rawXYvalid, rawXY off
            try? link.send(reportID: 0x11, device: deviceIndex, feature: fReprog, function: 3,
                           params: [UInt8(c.cid >> 8), UInt8(c.cid & 0xFF), flags])
            usleep(20_000)
        }
    }

    /// Diagnostics: set one control's reporting flags and report what the device said.
    func setReporting(_ cid: UInt16, _ flags: UInt8) -> String {
        do {
            let r = try link.request(reportID: 0x11, device: deviceIndex, feature: fReprog, function: 3,
                                     params: [UInt8(cid >> 8), UInt8(cid & 0xFF), flags])
            return "ok (" + r.hex + ")"
        } catch { return "FAILED: \(error)" }
    }

    /// Diagnostics: read one control's current reporting flags.
    func describeReporting(_ cid: UInt16) -> String {
        do {
            let r = try link.request(reportID: 0x11, device: deviceIndex, feature: fReprog, function: 2,
                                     params: [UInt8(cid >> 8), UInt8(cid & 0xFF)])
            let f = r.bytes.count > 6 ? r.bytes[6] : 0
            return String(format: "  cid 0x%04X  flags 0x%02X  divert=%d rawXY=%d   raw %@",
                          cid, f, (f & 0x01) != 0 ? 1 : 0, (f & 0x10) != 0 ? 1 : 0, r.hex)
        } catch { return String(format: "  cid 0x%04X  read failed: %@", cid, "\(error)") }
    }

    // MARK: battery & haptics

    func battery() -> BatteryState? {
        guard fBattery != 0, let m = try? link.request(device: deviceIndex, feature: fBattery, function: 0),
              m.bytes.count > 6 else { return nil }
        if fBatteryIsUnified {
            return BatteryState(percent: Int(m.bytes[4]), charging: m.bytes[6] != 0)
        }
        return BatteryState(percent: Int(m.bytes[4]), charging: m.bytes[6] == 0x01)
    }

    /// Buzz the remote. `duration` is in device units (0x00–0x0A), intensity 0–255.
    func vibrate(duration: UInt8 = 0x05, intensity: UInt8 = 0x80) {
        guard fHaptic != 0 else { return }
        try? link.send(device: deviceIndex, feature: fHaptic, function: 1,
                       params: [duration, 0xE8, intensity])
    }

    // MARK: incoming events

    private func handle(_ msg: HIDPPMessage) {
        // Receiver-level connect / disconnect (HID++ 1.0 notification 0x41).
        if msg.deviceIndex != deviceIndex || msg.featureIndex != fReprog {
            if msg.featureIndex == 0x41 {
                let gone = msg.bytes.count > 4 && (msg.bytes[4] & 0x40) != 0
                DispatchQueue.main.async {
                    self.delegate?.spotlight(statusChanged: !gone,
                                             message: gone ? "remote went away" : "remote reconnected")
                }
            }
            return
        }

        switch msg.funcIndex {
        case 0:   // divertedButtons: up to four 16-bit CIDs, zero-padded
            var now = Set<UInt16>()
            let b = msg.bytes
            var i = 4
            while i + 1 < b.count && i < 12 {
                let cid = UInt16(b[i]) << 8 | UInt16(b[i + 1])
                if cid != 0 { now.insert(cid) }
                i += 2
            }
            let pressed = now.subtracting(heldCIDs)
            let released = heldCIDs.subtracting(now)
            heldCIDs = now
            DispatchQueue.main.async {
                for c in pressed { self.delegate?.spotlight(buttonDown: c) }
                for c in released { self.delegate?.spotlight(buttonUp: c) }
            }

        case 1:   // divertedRawMouseXy: two big-endian signed 16-bit deltas
            let b = msg.bytes
            guard b.count >= 8 else { return }
            let dx = Int(Int16(bitPattern: UInt16(b[4]) << 8 | UInt16(b[5])))
            let dy = Int(Int16(bitPattern: UInt16(b[6]) << 8 | UInt16(b[7])))
            guard dx != 0 || dy != 0 else { return }
            DispatchQueue.main.async { self.delegate?.spotlight(motionDX: dx, dy: dy) }

        default:
            break
        }
    }

    // MARK: naming

    /// Logitech control IDs seen on presenters. Anything unknown shows as its hex CID
    /// and can still be mapped in Settings.
    static func controlName(_ cid: UInt16) -> String {
        switch cid {
        case 0x0050: return "Top button — press"
        case 0x00D8: return "Top button — hold"
        case 0x00D9: return "Big button — press"
        case 0x00DA: return "Big button — hold"
        case 0x00DB: return "Back button — press"
        case 0x00DC: return "Back button — hold"
        default:     return String(format: "Button 0x%04X", cid)
        }
    }

    /// The remote reports a separate control ID for a held button, and streams
    /// gyro data only for those. Measured on this device: 0x00D8 / 0x00DA / 0x00DC.
    static func isHoldControl(_ cid: UInt16) -> Bool {
        cid == 0x00D8 || cid == 0x00DA || cid == 0x00DC
    }

    /// True if this control streams gyro while held, according to the device itself.
    func streamsMotion(_ cid: UInt16) -> Bool {
        controls.first(where: { $0.cid == cid })?.supportsRawXY ?? Spotlight.isHoldControl(cid)
    }
}
