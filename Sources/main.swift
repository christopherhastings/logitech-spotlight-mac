//  main.swift — menu-bar-only app entry point.

import AppKit

guard SingleInstance.claim() else {
    // Another copy is already driving the remote — launchd and a manual open can
    // both fire. Second one out.
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)     // no Dock icon, no menu bar app menu
let delegate = AppDelegate()
app.delegate = delegate
app.run()
