// tests — the wire-format logic, checked without any hardware.
//
// Both bugs this project actually hit live in here: the report ID missing from
// byte 0 of the buffer, and a stale acknowledgement being read as the answer to
// the next request. Each has a test below.

import Foundation

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  ok   \(what)")
    } else {
        failures += 1
        let d = detail()
        print("  FAIL \(what)" + (d.isEmpty ? "" : "\n         \(d)"))
    }
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

// MARK: packet building

print("\nHIDPPWire.packet")

do {
    let p = HIDPPWire.packet(reportID: 0x10, device: 0x01, feature: 0x07,
                             function: 3, swID: 0x0A, params: [0x00, 0xDA, 0x33])
    // The bug: macOS needs the report ID in the buffer as well as in the API call.
    // Without it every field lands one byte early and the device answers 0x8F.
    expect(p[0] == 0x10, "report ID occupies byte 0", "got \(hex(p))")
    expect(p[1] == 0x01, "device index follows the report ID", "got \(hex(p))")
    expect(p[2] == 0x07, "feature index in byte 2", "got \(hex(p))")
    expect(p[3] == 0x3A, "function and software ID are packed into byte 3", "got \(hex(p))")
    expect(Array(p[4...6]) == [0x00, 0xDA, 0x33], "parameters start at byte 4", "got \(hex(p))")
    expect(p.count == 7, "short report is 7 bytes", "got \(p.count)")
}

do {
    expect(HIDPPWire.packet(reportID: 0x11, device: 1, feature: 1, function: 0,
                            swID: 1, params: []).count == 20, "long report is 20 bytes")
    expect(HIDPPWire.packet(reportID: 0x12, device: 1, feature: 1, function: 0,
                            swID: 1, params: []).count == 32, "very long report is 32 bytes")
    // Overlong parameters must be dropped, not crash.
    let p = HIDPPWire.packet(reportID: 0x10, device: 1, feature: 1, function: 0,
                             swID: 1, params: [UInt8](repeating: 0xEE, count: 40))
    expect(p.count == 7, "oversized parameters are truncated to the report size", "got \(p.count)")
}

// MARK: reply classification

print("\nHIDPPWire.classify")

func msg(_ b: [UInt8]) -> HIDPPMessage { HIDPPMessage(bytes: b) }

do {
    // A genuine answer to getCidReporting (feature 0x07, function 2).
    let reply = msg([0x11, 0x01, 0x07, 0x2A, 0x00, 0xD8, 0x11])
    expect(HIDPPWire.classify(reply, device: 1, feature: 0x07, function: 2) == .answer,
           "an answer matching device, feature and function is accepted")

    // The bug: setCidReporting (function 3) is acknowledged even when we did not
    // wait for it. That ack carries our software ID, so matching on the ID alone
    // returned it as the answer to the next question — which is how the button
    // readback came back shifted by two rows.
    let staleAck = msg([0x11, 0x01, 0x07, 0x3A, 0x00, 0x00, 0x00])
    expect(HIDPPWire.classify(staleAck, device: 1, feature: 0x07, function: 2) == .unrelated,
           "a stale ack for a different function is rejected")

    let otherFeature = msg([0x11, 0x01, 0x06, 0x2A, 0x00, 0x00, 0x00])
    expect(HIDPPWire.classify(otherFeature, device: 1, feature: 0x07, function: 2) == .unrelated,
           "an answer from a different feature is rejected")

    let otherDevice = msg([0x11, 0x02, 0x07, 0x2A, 0x00, 0x00, 0x00])
    expect(HIDPPWire.classify(otherDevice, device: 1, feature: 0x07, function: 2) == .unrelated,
           "an answer from a different device index is rejected")
}

do {
    // HID++ 1.0 error: [10][device][8F][origFeature][origFunction][code]
    let err = msg([0x10, 0x01, 0x8F, 0x00, 0x15, 0x09, 0x00])
    expect(HIDPPWire.classify(err, device: 1, feature: 0x00, function: 1) == .failure(9),
           "a 1.0 error reports its code")
    expect(HIDPPWire.classify(err, device: 1, feature: 0x07, function: 1) == .unrelated,
           "a 1.0 error for another feature is not our failure")

    // HID++ 2.0 error: [FF][device][feature][function|swID][code]
    let err2 = msg([0xFF, 0x01, 0x07, 0x2A, 0x08])
    expect(HIDPPWire.classify(err2, device: 1, feature: 0x07, function: 2) == .failure(8),
           "a 2.0 error reports its code")
    expect(HIDPPWire.classify(err2, device: 1, feature: 0x07, function: 3) == .unrelated,
           "a 2.0 error for another function is not our failure")
}

do {
    // Short or malformed reports must never index out of bounds.
    for n in 0...4 {
        _ = HIDPPWire.classify(msg([UInt8](repeating: 0xFF, count: n)),
                               device: 1, feature: 1, function: 1)
    }
    expect(true, "truncated reports are handled without crashing")
}

// MARK: event decoding

print("\nSpotlight.decodeButtons")

do {
    // Real capture: the top button held, control 0x00D8.
    expect(Spotlight.decodeButtons([0x11, 0x01, 0x07, 0x00, 0x00, 0xD8, 0x00, 0x00]) == [0x00D8],
           "one held control is decoded")
    expect(Spotlight.decodeButtons([0x11, 0x01, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00]).isEmpty,
           "all-zero means everything released")
    expect(Spotlight.decodeButtons([0x11, 0x01, 0x07, 0x00, 0x00, 0xDA, 0x00, 0xDC]) == [0x00DA, 0x00DC],
           "two simultaneous controls are decoded")
    expect(Spotlight.decodeButtons([0x11, 0x01]).isEmpty, "a truncated report decodes to nothing")
}

print("\nSpotlight.decodeMotion")

do {
    // Big-endian signed 16-bit pairs. Measured values saturate at plus/minus 127.
    expect(Spotlight.decodeMotion([0x11, 0x01, 0x07, 0x10, 0x00, 0x7F, 0xFF, 0x81])
           ?? (0, 0) == (127, -127), "positive and negative deltas decode")
    expect(Spotlight.decodeMotion([0x11, 0x01, 0x07, 0x10, 0xFF, 0xFF, 0x00, 0x01])
           ?? (0, 0) == (-1, 1), "sign extension across the high byte is respected")
    expect(Spotlight.decodeMotion([0x11, 0x01, 0x07, 0x10, 0x00, 0x00, 0x00, 0x00]) == nil,
           "a zero sample is discarded rather than reported as movement")
    expect(Spotlight.decodeMotion([0x11, 0x01, 0x07]) == nil, "a truncated report decodes to nothing")
}

// MARK: control naming

print("\nSpotlight control identity")

do {
    expect(Spotlight.isHoldControl(0x00D8) && Spotlight.isHoldControl(0x00DA)
           && Spotlight.isHoldControl(0x00DC), "the three gyro-streaming controls are hold controls")
    expect(!Spotlight.isHoldControl(0x0050) && !Spotlight.isHoldControl(0x00D9)
           && !Spotlight.isHoldControl(0x00DB), "the three press controls are not hold controls")
    expect(Spotlight.controlName(0x00FF).contains("00FF"),
           "an unrecognised control still shows its hex ID so it can be mapped")
}

// MARK: presentation timer

print("\nController.timerEnd")

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    func at(_ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(timeZone: cal.timeZone, year: 2026, month: 9,
                                      day: 16, hour: h, minute: m))!
    }

    let noon = at(12, 0)

    let countdown = Controller.timerEnd(usesClockTime: false, minutes: 20,
                                        finishMinuteOfDay: 0, now: noon, calendar: cal)
    expect(countdown == at(12, 20), "a countdown ends the given number of minutes from now",
           "got \(countdown)")

    let later = Controller.timerEnd(usesClockTime: true, minutes: 20,
                                    finishMinuteOfDay: 15 * 60, now: noon, calendar: cal)
    expect(later == at(15, 0), "a clock time later today is taken as today", "got \(later)")

    // The case that matters: setting a 9am finish during an afternoon talk must
    // not produce a timer that has already expired.
    let passed = Controller.timerEnd(usesClockTime: true, minutes: 20,
                                     finishMinuteOfDay: 9 * 60, now: noon, calendar: cal)
    expect(passed > noon, "a clock time already past today rolls to tomorrow", "got \(passed)")
    expect(passed == cal.date(byAdding: .day, value: 1, to: at(9, 0))!,
           "and lands at the same time tomorrow", "got \(passed)")
}

// MARK: result

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("all good")
