//  AppDelegate.swift — menu bar item, settings window, lifecycle.

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = Controller()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingModel: OnboardingModel?
    private var settingsModel: SettingsModel?
    private var batteryTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dot.circle.and.hand.point.up.left.fill",
                                           accessibilityDescription: "Presenter")
        statusItem.button?.image?.isTemplate = true

        controller.onStatusChange = { [weak self] in DispatchQueue.main.async { self?.rebuildMenu() } }
        controller.start()
        rebuildMenu()

        // First run, or any launch where we still cannot act on the remote.
        if !UserDefaults.standard.bool(forKey: "onboarded") || !Actions.hasAccessibility {
            showOnboarding()
        }

        // Poll often while disconnected so the app picks the remote up the moment
        // it is switched on; back off to a battery refresh once it is talking.
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.controller.poll()
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.controller.overlay.hide()
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        controller.stop()
    }

    // MARK: menu

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: controller.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if let t = controller.timerText {
            statusItem.button?.title = " \(t)"
            menu.addItem(withTitle: "Timer: \(t) left", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Stop timer", action: #selector(toggleTimer), keyEquivalent: "")
                .target = self
        } else {
            statusItem.button?.title = ""
            menu.addItem(withTitle: "Start \(Settings.shared.timerMinutes)-minute timer",
                         action: #selector(toggleTimer), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        for e in [OverlayEffect.spotlight, .circle, .magnify, .laser] {
            let item = NSMenuItem(title: "Test: \(e.label)", action: #selector(testEffect(_:)), keyEquivalent: "")
            item.representedObject = e.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(withTitle: "Hide overlay", action: #selector(hideOverlay), keyEquivalent: "").target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Setup guide…", action: #selector(showOnboarding), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reconnect remote", action: #selector(reconnect), keyEquivalent: "r").target = self
        if !Actions.hasAccessibility {
            menu.addItem(withTitle: "Grant Accessibility…", action: #selector(grantAccessibility),
                         keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
    }

    @objc private func toggleTimer() { controller.toggleTimer() }
    @objc private func hideOverlay() { controller.overlay.hide() }
    @objc private func reconnect() { controller.reconnect() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showOnboarding() {
        if onboardingWindow == nil {
            let model = OnboardingModel(controller: controller)
            onboardingModel = model
            let host = NSHostingController(rootView: OnboardingView(model: model) { [weak self] in
                UserDefaults.standard.set(true, forKey: "onboarded")
                self?.onboardingWindow?.close()
            })
            let w = NSWindow(contentViewController: host)
            w.title = "Set up Presenter"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            onboardingWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.center()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func grantAccessibility() {
        Actions.requestAccessibility()
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func testEffect(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let e = OverlayEffect(rawValue: raw) else { return }
        let screen = NSScreen.main?.frame ?? .zero
        controller.overlay.show(effect: e, at: CGPoint(x: screen.midX, y: screen.midY))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.controller.overlay.hide() }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(controller: controller)
            settingsModel = model
            let host = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Presenter"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        settingsModel?.reloadButtons()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension Controller {
    /// Cheap keep-alive: if the remote was asleep or off, pick it up again.
    func reconnectIfNeeded() {
        if !device.connected { reconnect() }
    }
}
