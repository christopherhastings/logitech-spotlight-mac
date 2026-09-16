//  Controller.swift — gestures, pointing, and the presentation timer.
//
//  Turns the raw stream (button CID down/up, gyro dx/dy) into click /
//  double-click / hold, and drives the overlay or the mouse cursor.

import AppKit

final class Controller: NSObject, SpotlightDelegate {
    let device = Spotlight()
    let overlay = OverlayController()
    private let settings = Settings.shared

    // Per-button gesture state. The remote decides press vs hold for us and sends
    // a different control ID for each, so there is no hold timer here.
    private var pendingClick: [UInt16: Timer] = [:]
    private var lastDown: [UInt16: Date] = [:]
    private var activeHoldCID: UInt16?

    // Pointing
    private var point: CGPoint = .zero
    private var smoothedDX: Double = 0
    private var smoothedDY: Double = 0
    private var activeMode: Mode = .idle
    private enum Mode { case idle, effect(OverlayEffect), cursor }

    // Observable bits for the UI
    @objc dynamic var statusText = "Starting…"
    var onStatusChange: (() -> Void)?
    private(set) var battery: BatteryState?
    /// CIDs seen since launch, so Settings can list real buttons even if the
    /// device's own control table is incomplete.
    private(set) var seenCIDs: [UInt16] = []
    var onButtonSeen: ((UInt16) -> Void)?

    /// True once we have taken the buttons over. We deliberately do not take them
    /// over until Accessibility is granted — diverted buttons stop sending their
    /// own keystrokes, so without it next/back would do nothing at all.
    private(set) var diverted = false

    // Timer
    private var timerEndsAt: Date?
    private var timerTicker: Timer?
    private var warnedAt: Set<Int> = []
    var timerText: String? {
        guard let end = timerEndsAt else { return nil }
        let left = Int(end.timeIntervalSinceNow.rounded())
        let sign = left < 0 ? "-" : ""
        let a = abs(left)
        return String(format: "%@%d:%02d", sign, a / 60, a % 60)
    }

    // MARK: start / stop

    func start() {
        device.delegate = self
        do {
            try device.start()
            battery = device.battery()
            takeOverIfAllowed()
        } catch {
            setStatus("\(error)")
        }
    }

    /// Take the buttons over only when we can act on them.
    private func takeOverIfAllowed() {
        guard device.connected else { return }
        if Actions.hasAccessibility {
            if !diverted { device.divertButtons(); diverted = true }
            setStatus("\(device.deviceName) ready" + (battery.map { " · \($0.percent)%" } ?? ""))
        } else {
            if diverted { device.restoreButtons(); diverted = false }
            setStatus("Grant Accessibility to enable the remote")
        }
    }

    func stop() { device.stop() }

    private var lastBatteryCheck = Date.distantPast

    /// Ticked every few seconds: reconnect if the remote was off, otherwise just
    /// refresh the battery reading now and then.
    func poll() {
        if !device.connected { reconnect(quiet: true); return }
        // Picks up the moment the user grants (or revokes) Accessibility.
        if Actions.hasAccessibility != diverted { takeOverIfAllowed() }
        if Date().timeIntervalSince(lastBatteryCheck) > 300 {
            lastBatteryCheck = Date()
            if let b = device.battery() { battery = b; onStatusChange?() }
        }
    }

    /// Called from the menu when the remote was off at launch.
    func reconnect(quiet: Bool = false) {
        do {
            try device.connect()
            diverted = false
            battery = device.battery()
            takeOverIfAllowed()
        } catch {
            // Background retries stay quiet so the menu does not flicker every few seconds.
            if !quiet { setStatus("\(error)") }
        }
    }

    private func setStatus(_ s: String) {
        statusText = s
        onStatusChange?()
    }

    // MARK: SpotlightDelegate

    func spotlight(statusChanged connected: Bool, message: String) { setStatus(message) }

    func spotlight(buttonDown cid: UInt16) {
        if !seenCIDs.contains(cid) { seenCIDs.append(cid); onButtonSeen?(cid) }
        let m = settings.mapping(for: cid)

        // Controls that stream gyro are the remote's own "held" variants.
        if device.streamsMotion(cid) || Spotlight.isHoldControl(cid) {
            beginHold(cid, m.hold)
            return
        }

        // A quick press. Fire immediately unless the user mapped a double-click,
        // in which case we have to wait out the window to tell them apart.
        if m.doubleClick != .none {
            if let last = lastDown[cid], Date().timeIntervalSince(last) < settings.doubleClickInterval {
                pendingClick[cid]?.invalidate(); pendingClick[cid] = nil
                lastDown[cid] = nil
                run(m.doubleClick, cid: cid)
                return
            }
            lastDown[cid] = Date()
            pendingClick[cid] = Timer.scheduledTimer(withTimeInterval: settings.doubleClickInterval,
                                                     repeats: false) { [weak self] _ in
                self?.run(m.click, cid: cid)
                self?.pendingClick[cid] = nil
            }
        } else {
            run(m.click, cid: cid)
        }
    }

    func spotlight(buttonUp cid: UInt16) {
        if activeHoldCID == cid { endHold() }
    }

    func spotlight(motionDX dx: Int, dy: Int) {
        if case .idle = activeMode { return }
        applyMotion(dx, dy)
    }

    /// Gyro deltas saturate at ±127 per sample at roughly 65 Hz, so they are
    /// smoothed before being scaled — raw values make the spot jitter.
    private func applyMotion(_ dx: Int, _ dy: Int) {
        let a = settings.smoothing
        smoothedDX = a * smoothedDX + (1 - a) * Double(dx)
        smoothedDY = a * smoothedDY + (1 - a) * Double(dy)

        let s = settings.sensitivity
        point.x += CGFloat(smoothedDX * s) * (settings.invertX ? -1 : 1)
        // Gyro Y grows downward; Cocoa Y grows upward.
        point.y -= CGFloat(smoothedDY * s) * (settings.invertY ? -1 : 1)
        clampPoint()

        switch activeMode {
        case .effect: overlay.move(to: point)
        case .cursor: Actions.moveCursor(to: point)
        case .idle: break
        }
    }

    // MARK: hold handling

    private func beginHold(_ cid: UInt16, _ action: PresenterAction) {
        activeHoldCID = cid
        smoothedDX = 0; smoothedDY = 0
        if settings.recenterOnHold || point == .zero { point = defaultPoint() }
        clampPoint()
        switch Actions.perform(action) {
        case .effect(let e):
            activeMode = .effect(e)
            overlay.show(effect: e, at: point)
        case .cursor:
            activeMode = .cursor
            Actions.moveCursor(to: point)
        case .timer:   toggleTimer()
        case .vibrate: device.vibrate()
        case .handled: break
        }
    }

    private func endHold() {
        if case .effect = activeMode { overlay.hide() }
        activeMode = .idle
        activeHoldCID = nil
    }

    private func run(_ action: PresenterAction, cid: UInt16) {
        switch Actions.perform(action) {
        case .effect(let e):
            // A click mapped to an effect toggles it on and off.
            if overlay.isVisible { overlay.hide(); activeMode = .idle }
            else {
                point = defaultPoint(); activeMode = .effect(e); overlay.show(effect: e, at: point)
            }
        case .cursor:  activeMode = .cursor
        case .timer:   toggleTimer()
        case .vibrate: device.vibrate()
        case .handled: break
        }
    }

    private func defaultPoint() -> CGPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let f = screen?.frame ?? .zero
        return CGPoint(x: f.midX, y: f.midY)
    }

    private func clampPoint() {
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.isEmpty ? $1.frame : $0.union($1.frame) }
        point.x = min(max(point.x, union.minX + 1), union.maxX - 1)
        point.y = min(max(point.y, union.minY + 1), union.maxY - 1)
    }

    // MARK: presentation timer

    func toggleTimer() {
        if timerEndsAt != nil { stopTimer() } else { startTimer() }
    }

    func startTimer() {
        timerEndsAt = Date().addingTimeInterval(Double(settings.timerMinutes) * 60)
        warnedAt = []
        timerTicker?.invalidate()
        timerTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if settings.timerVibrate { device.vibrate(duration: 0x02, intensity: 0x60) }
        onStatusChange?()
    }

    func stopTimer() {
        timerTicker?.invalidate(); timerTicker = nil
        timerEndsAt = nil
        onStatusChange?()
    }

    private func tick() {
        guard let end = timerEndsAt else { return }
        let left = Int(end.timeIntervalSinceNow.rounded())
        for mark in [settings.timerWarnMinutes * 60, 60, 0] where left == mark && !warnedAt.contains(mark) {
            warnedAt.insert(mark)
            if settings.timerVibrate {
                device.vibrate(duration: mark == 0 ? 0x0A : 0x04, intensity: mark == 0 ? 0xFF : 0x90)
            }
        }
        onStatusChange?()
    }
}
