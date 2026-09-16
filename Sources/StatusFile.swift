//  StatusFile.swift — the app publishes what it thinks is true, so problems can be
//  diagnosed without guessing. Written to:
//    ~/Library/Application Support/Presenter/status.json

import AppKit

enum StatusFile {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Presenter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("status.json")
    }

    static func write(_ c: Controller) {
        var d: [String: Any] = [
            "updated": ISO8601DateFormatter().string(from: Date()),
            "pid": getpid(),
            "bundlePath": Bundle.main.bundlePath,
            "accessibility": Actions.hasAccessibility,
            "screenRecording": CGPreflightScreenCaptureAccess(),
            "remoteConnected": c.device.connected,
            "buttonsTakenOver": c.diverted,
            "status": c.statusText,
            "overlayVisible": c.overlay.isVisible,
            "screens": NSScreen.screens.count,
        ]
        if c.device.connected {
            d["deviceName"] = c.device.deviceName
            d["transport"] = c.device.transport.label
            d["controls"] = c.device.controls.map { String(format: "0x%04X", $0.cid) }
        }
        if let b = c.battery { d["batteryPercent"] = b.percent }
        d["buttonsSeen"] = c.seenCIDs.map { String(format: "0x%04X", $0) }
        d["lastEvent"] = c.lastEventDescription

        guard let json = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? json.write(to: url, options: .atomic)
    }
}
