// learn — self-paced. Each step waits for you to press Enter, so there is no
// timing to get wrong. Reports exactly what the remote sent for each step.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

final class Recorder: SpotlightDelegate {
    var downs: [UInt16] = []
    var motion: [(Int, Int)] = []
    var heldDuringMotion: Set<UInt16> = []
    var currentlyDown: Set<UInt16> = []
    let lock = NSLock()

    func reset() { lock.lock(); downs = []; motion = []; heldDuringMotion = []; lock.unlock() }
    func spotlight(buttonDown cid: UInt16) { lock.lock(); downs.append(cid); currentlyDown.insert(cid); lock.unlock() }
    func spotlight(buttonUp cid: UInt16) { lock.lock(); currentlyDown.remove(cid); lock.unlock() }
    func spotlight(motionDX dx: Int, dy: Int) {
        lock.lock(); motion.append((dx, dy)); heldDuringMotion.formUnion(currentlyDown); lock.unlock()
    }
    func spotlight(statusChanged connected: Bool, message: String) {}

    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        var out: [String] = []
        if downs.isEmpty && motion.isEmpty { return "nothing received" }
        if !downs.isEmpty {
            var seen: [UInt16] = []
            for d in downs where !seen.contains(d) { seen.append(d) }
            out.append("buttons: " + seen.map { String(format: "0x%04X", $0) }.joined(separator: ", ")
                       + "   (\(downs.count) press\(downs.count == 1 ? "" : "es"))")
        }
        if !motion.isEmpty {
            let dxs = motion.map { $0.0 }, dys = motion.map { $0.1 }
            let mag = motion.map { abs($0.0) + abs($0.1) }
            let held = heldDuringMotion.map { String(format: "0x%04X", $0) }.joined(separator: ", ")
            out.append(String(format: "motion : %d samples  dx %d…%d  dy %d…%d  typical step %d  while holding %@",
                              motion.count, dxs.min()!, dxs.max()!, dys.min()!, dys.max()!,
                              mag.sorted()[mag.count / 2],
                              held.isEmpty ? "(no button!)" : held))
        } else {
            out.append("motion : none")
        }
        return out.joined(separator: "\n       ")
    }
}

/// Run the HID run loop while waiting for a line on stdin.
func waitForEnter() {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { _ = readLine(); done.signal() }
    while done.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

let sl = Spotlight()
let rec = Recorder()
sl.delegate = rec

do { try sl.start() } catch {
    print("Could not reach the remote: \(error)")
    print("Switch it on / plug it in and try again.")
    exit(1)
}

print("Device : \(sl.deviceName)")
if let b = sl.battery() { print("Battery: \(b.percent)%") }
print("\nTaking over the buttons…")
sl.divertButtons()

print("Checking the takeover actually applied:")
for c in sl.controls where c.isDivertable { print(sl.describeReporting(c.cid)) }

let steps = [
    "Press the TOP button once or twice.",
    "Press the MIDDLE button once or twice.",
    "Press the BOTTOM button once or twice.",
    "HOLD the TOP button down and swing the remote left/right and up/down. Let go when done.",
    "HOLD the MIDDLE button down and swing the remote around. Let go when done.",
    "HOLD the BOTTOM button down and swing the remote around. Let go when done.",
]

print("""

────────────────────────────────────────────────────────
Six steps. Take as long as you like on each one.
Do the thing it asks, THEN come back here and press Enter.
────────────────────────────────────────────────────────
""")

for (i, step) in steps.enumerated() {
    rec.reset()
    print("\n[\(i + 1)/\(steps.count)] \(step)")
    print("        …then press Enter here.")
    waitForEnter()
    print("     => " + rec.summary())
}

print("\nAll done — giving the buttons back to the remote.")
sl.stop()
