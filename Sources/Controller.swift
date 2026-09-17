//  Controller.swift — gestures, pointing, and the presentation timer.
//
//  Turns the raw stream (button CID down/up, gyro dx/dy) into click /
//  double-click / hold, and drives the overlay or the mouse cursor.

import AppKit

final class Controller: NSObject, SpotlightDelegate {
    let device = Spotlight()
    let overlay = OverlayController()
    private let settings = Settings.shared

    /// Every HID++ exchange blocks until the remote answers or the timeout expires.
    /// On the main thread that freezes the menu bar, so all device work runs here.
    /// Button and motion events already arrive on the main queue.
    private let deviceQueue = DispatchQueue(label: "presenter.device", qos: .userInitiated)

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
    private enum Mode { case idle, effect(OverlayEffect), cursor, gesture(Actions.Gesture) }

    /// An effect left on screen after the button was released, when Freeze is on.
    private var frozen = false
    /// Which effect the "Switch effect" action has selected, overriding the one
    /// the button is mapped to.
    private var effectOverride: OverlayEffect?
    /// Accumulated vertical movement for the scroll and volume gestures.
    private var gestureAccumulator: Double = 0
    private var lastVolumeStep = Date.distantPast

    // Observable bits for the UI
    @objc dynamic var statusText = "Starting…"
    var onStatusChange: (() -> Void)?
    private(set) var battery: BatteryState?
    /// CIDs seen since launch, so Settings can list real buttons even if the
    /// device's own control table is incomplete.
    private(set) var seenCIDs: [UInt16] = []
    /// Last thing the remote did, for the status file and for support questions.
    private(set) var lastEventDescription = "nothing yet"
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
        deviceQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.device.start()
                let b = self.device.battery()
                DispatchQueue.main.async { self.battery = b; self.takeOverIfAllowed() }
            } catch {
                DispatchQueue.main.async { self.setStatus("\(error)") }
            }
        }
    }

    /// Take the buttons over only when we can act on them.
    private func takeOverIfAllowed() {
        guard device.connected else { return }
        let allowed = Actions.hasAccessibility
        if allowed != diverted {
            diverted = allowed
            deviceQueue.async { [weak self] in
                guard let self else { return }
                if allowed { self.device.divertButtons() } else { self.device.restoreButtons() }
            }
        }
        setStatus(allowed
                  ? "\(device.deviceName) ready" + (battery.map { " · \($0.percent)%" } ?? "")
                  : "Grant Accessibility to enable the remote")
    }

    /// Runs as the app quits, so it must finish promptly. Diversion is handed back
    /// with unacknowledged writes, which takes about fifteen milliseconds.
    func stop() { deviceQueue.sync { device.stop() } }

    private var lastBatteryCheck = Date.distantPast

    /// Ticked every few seconds: reconnect if the remote was off, otherwise just
    /// refresh the battery reading now and then.
    func poll() {
        if !device.connected { reconnect(quiet: true); return }
        // Picks up the moment the user grants (or revokes) Accessibility.
        if Actions.hasAccessibility != diverted { takeOverIfAllowed() }
        if Date().timeIntervalSince(lastBatteryCheck) > 300 {
            lastBatteryCheck = Date()
            deviceQueue.async { [weak self] in
                guard let self, let b = self.device.battery() else { return }
                DispatchQueue.main.async { self.battery = b; self.onStatusChange?() }
            }
        }
        StatusFile.write(self)
    }

    /// Called from the menu when the remote was off at launch.
    func reconnect(quiet: Bool = false) {
        deviceQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.device.connect()
                let b = self.device.battery()
                DispatchQueue.main.async {
                    self.diverted = false
                    self.battery = b
                    self.takeOverIfAllowed()
                }
            } catch {
                // Background retries stay quiet so the menu does not flicker.
                if !quiet { DispatchQueue.main.async { self.setStatus("\(error)") } }
            }
        }
    }

    private func setStatus(_ s: String) {
        statusText = s
        StatusFile.write(self)
        onStatusChange?()
    }

    // MARK: SpotlightDelegate

    func spotlight(statusChanged connected: Bool, message: String) { setStatus(message) }

    func spotlight(buttonDown cid: UInt16) {
        if !seenCIDs.contains(cid) { seenCIDs.append(cid); onButtonSeen?(cid) }
        let m = settings.mapping(for: cid)
        let which = Spotlight.isHoldControl(cid) || device.streamsMotion(cid) ? m.hold : m.click
        lastEventDescription = String(format: "%@ (0x%04X) -> %@ at %@",
                                      Spotlight.controlName(cid), cid, which.label,
                                      DateFormatter.localizedString(from: Date(), dateStyle: .none,
                                                                    timeStyle: .medium))
        StatusFile.write(self)

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

        // Scrolling and volume care only about vertical movement, and work on
        // accumulated travel rather than pointer position.
        if case .gesture(let g) = activeMode {
            gestureAccumulator += smoothedDY * settings.sensitivity
            switch g {
            case .scroll:
                let lines = Int(gestureAccumulator / 12)
                if lines != 0 {
                    gestureAccumulator -= Double(lines) * 12
                    Actions.scroll(by: -lines)
                }
            case .volume:
                // Volume keys are coarse, so step them slowly and not too often.
                if abs(gestureAccumulator) > 60, Date().timeIntervalSince(lastVolumeStep) > 0.12 {
                    Actions.mediaKey(gestureAccumulator < 0 ? Actions.NX_KEYTYPE_SOUND_UP
                                                            : Actions.NX_KEYTYPE_SOUND_DOWN)
                    gestureAccumulator = 0
                    lastVolumeStep = Date()
                }
            }
            return
        }

        let s = settings.sensitivity
        point.x += CGFloat(smoothedDX * s) * (settings.invertX ? -1 : 1)
        // Gyro Y grows downward; Cocoa Y grows upward.
        point.y -= CGFloat(smoothedDY * s) * (settings.invertY ? -1 : 1)
        clampPoint()

        switch activeMode {
        case .effect:
            overlay.move(to: point)
            // Keeping the real cursor under the effect is what makes links
            // clickable while you are highlighting them.
            if settings.cursorFollowsEffect { Actions.moveCursor(to: point) }
        case .cursor: Actions.moveCursor(to: point)
        case .idle, .gesture: break
        }
    }

    // MARK: hold handling

    private func beginHold(_ cid: UInt16, _ action: PresenterAction) {
        // A frozen effect is dismissed by the next press, not replaced by it.
        if frozen {
            overlay.hide()
            frozen = false
            activeHoldCID = cid          // so the release is swallowed
            activeMode = .idle
            return
        }

        activeHoldCID = cid
        smoothedDX = 0; smoothedDY = 0
        gestureAccumulator = 0
        if settings.recenterOnHold || point == .zero { point = defaultPoint() }
        clampPoint()

        switch Actions.perform(action) {
        case .effect(let mapped):
            let e = effectOverride ?? mapped
            activeMode = .effect(e)
            overlay.show(effect: e, at: point)
            if settings.cursorFollowsEffect { Actions.moveCursor(to: point) }
        case .cursor:
            activeMode = .cursor
            Actions.moveCursor(to: point)
        case .gesture(let g):
            activeMode = .gesture(g)
        case .cycleEffect: cycleEffect()
        case .timer:       toggleTimer()
        case .vibrate:     device.vibrate()
        case .handled:     break
        }
    }

    private func endHold() {
        if case .effect = activeMode {
            // Freeze leaves the effect where you put it, until the next press.
            if settings.freezeEffect { frozen = true } else { overlay.hide() }
        }
        activeMode = .idle
        activeHoldCID = nil
    }

    /// Step through the effects the user has enabled. Confirmed with a short buzz
    /// rather than anything on screen, so the audience sees nothing.
    private func cycleEffect() {
        let cycle = settings.effectCycle
        guard !cycle.isEmpty else { return }
        let current = effectOverride ?? cycle.first!
        let next = cycle[((cycle.firstIndex(of: current) ?? 0) + 1) % cycle.count]
        effectOverride = next
        lastEventDescription = "switched effect to \(next.label)"
        device.vibrate(duration: 0x02, intensity: 0x70)
        StatusFile.write(self)
    }

    private func run(_ action: PresenterAction, cid: UInt16) {
        switch Actions.perform(action) {
        case .effect(let mapped):
            // A click mapped to an effect toggles it on and off.
            if overlay.isVisible { overlay.hide(); frozen = false; activeMode = .idle }
            else {
                let e = effectOverride ?? mapped
                point = defaultPoint(); activeMode = .effect(e); overlay.show(effect: e, at: point)
            }
        case .cursor:      activeMode = .cursor
        case .cycleEffect: cycleEffect()
        case .timer:       toggleTimer()
        case .vibrate:     device.vibrate()
        case .gesture:     break      // meaningless without a button held down
        case .handled:     break
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
        timerEndsAt = Controller.timerEnd(usesClockTime: settings.timerUsesClockTime,
                                          minutes: settings.timerMinutes,
                                          finishMinuteOfDay: settings.timerFinishMinuteOfDay,
                                          now: Date())
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

    /// A countdown from now, or the next occurrence of a clock time.
    static func timerEnd(usesClockTime: Bool, minutes: Int, finishMinuteOfDay: Int,
                         now: Date, calendar: Calendar = .current) -> Date {
        guard usesClockTime else {
            return now.addingTimeInterval(Double(minutes) * 60)
        }
        let cal = calendar
        let target = finishMinuteOfDay
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = target / 60
        comps.minute = target % 60
        let today = cal.date(from: comps) ?? now
        // If that time has already passed, mean tomorrow.
        return today > now ? today : cal.date(byAdding: .day, value: 1, to: today) ?? today
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
