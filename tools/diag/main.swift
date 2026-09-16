// diag — set button diversion with acknowledged writes, read the config back,
// then dump raw HID++ traffic so we can see exactly what a hold produces.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

final class Quiet: SpotlightDelegate {
    func spotlight(buttonDown cid: UInt16) {}
    func spotlight(buttonUp cid: UInt16) {}
    func spotlight(motionDX dx: Int, dy: Int) {}
    func spotlight(statusChanged connected: Bool, message: String) {}
}

let sl = Spotlight()
let q = Quiet()
sl.delegate = q
do { try sl.start() } catch { print("no remote: \(error)"); exit(1) }
print("Device: \(sl.deviceName)\n")

let cids = sl.controls.map { $0.cid }

print("--- getCidReporting before ---")
for c in sl.controls { print(sl.describeReporting(c.cid)) }

print("\n--- setCidReporting (acknowledged) ---")
for c in sl.controls where c.isDivertable {
    let flags: UInt8 = c.supportsRawXY ? 0x33 : 0x03
    print(String(format: "cid 0x%04X flags 0x%02X -> %@", c.cid, flags, sl.setReporting(c.cid, flags)))
}

print("\n--- getCidReporting after ---")
for c in sl.controls { print(sl.describeReporting(c.cid)) }

print("\n--- raw traffic for 15s: hold the BIG button and wave, then hold FORWARD and wave ---")
sl.rawReportHook = { print("RAW " + $0.hex) }
RunLoop.main.run(until: Date().addingTimeInterval(15))
print("\ndone")
sl.stop()
