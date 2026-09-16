// status — read-only check: is the remote there, and has Presenter taken the buttons over?
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

final class Quiet: SpotlightDelegate {
    func spotlight(buttonDown cid: UInt16) {}
    func spotlight(buttonUp cid: UInt16) {}
    func spotlight(motionDX dx: Int, dy: Int) {}
    func spotlight(statusChanged connected: Bool, message: String) {}
}

let sl = Spotlight()
let quiet = Quiet()          // must outlive the assignment; delegate is weak
sl.delegate = quiet
do { try sl.start() } catch {
    print("Remote not reachable: \(error)")
    if "\(error)".contains("busy") {
        print("\nThe remote talks to one program at a time and Presenter.app has it.")
        print("Quit Presenter from its menu bar icon first, then run this again.")
    }
    exit(1)
}

print("Remote  : \(sl.deviceName)")
if let b = sl.battery() { print("Battery : \(b.percent)%\(b.charging ? " (charging)" : "")") }

var takenOver = 0
for c in sl.controls where c.isDivertable {
    let line = sl.describeReporting(c.cid)
    if line.contains("divert=1") { takenOver += 1 }
    print(line)
}
print("")
print(takenOver > 0
      ? "=> Presenter HAS taken the buttons over (\(takenOver) of \(sl.controls.filter{$0.isDivertable}.count)). Accessibility is granted."
      : "=> Presenter has NOT taken the buttons over. Accessibility is still missing.")
