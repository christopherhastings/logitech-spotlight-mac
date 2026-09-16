//  capture — connect to the remote, divert its buttons, print decoded events.
//  Use this to check the remote is talking and to learn each button's control ID.

import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

final class Printer: SpotlightDelegate {
    var lastMotion = Date.distantPast
    var motionCount = 0
    func spotlight(buttonDown cid: UInt16) {
        print(String(format: "DOWN  cid 0x%04X  (%@)", cid, Spotlight.controlName(cid)))
    }
    func spotlight(buttonUp cid: UInt16) {
        print(String(format: "UP    cid 0x%04X  (%@)", cid, Spotlight.controlName(cid)))
    }
    func spotlight(motionDX dx: Int, dy: Int) {
        motionCount += 1
        if Date().timeIntervalSince(lastMotion) > 0.25 {      // don't flood the terminal
            print("MOVE  dx \(dx)  dy \(dy)   (\(motionCount) samples so far)")
            lastMotion = Date()
        }
    }
    func spotlight(statusChanged connected: Bool, message: String) { print("STATUS \(message)") }
}

enum Restore { nonisolated(unsafe) static var device: Spotlight?
    static func run() { print("\nrestoring buttons…"); device?.stop(); exit(0) } }

let sl = Spotlight()
let printer = Printer()
sl.delegate = printer

if CommandLine.arguments.contains("--raw") {
    sl.rawReportHook = { print("RAW   " + $0.hex) }
}

do {
    try sl.start()
} catch {
    print("Could not reach the remote: \(error)")
    print("Switch the Spotlight on and make sure its channel is set to the USB receiver, then retry.")
    exit(1)
}

print("Device : \(sl.deviceName)  (device index \(sl.deviceIndex))")
if let b = sl.battery() { print("Battery: \(b.percent)%\(b.charging ? " (charging)" : "")") }
print("Controls reported by the device:")
for c in sl.controls {
    print(String(format: "  cid 0x%04X  task 0x%04X  flags 0x%02X%@%@  — %@",
                 c.cid, c.taskID, c.flags,
                 c.isDivertable ? "  divertable" : "",
                 c.supportsRawXY ? "  raw-XY" : "", c.name))
}

Restore.device = sl
sl.divertButtons()
print("\nButtons diverted. Press and hold them; move the remote while holding. Ctrl-C to stop.\n")

// Ctrl-C restores the buttons through the exit handler below.
signal(SIGINT) { _ in Restore.run() }

RunLoop.main.run()
