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
    /// Waiting for the first move off the title slide. Cleared once the timer has
    /// started, so stopping it mid-talk does not let the next press restart it.
    private(set) var timerArmed = true
    var timerText: String? {
        guard let end = timerEndsAt else { return nil }
        let left = Int(end.timeIntervalSinceNow.rounded())
        let sign = left < 0 ? "-" : ""
        let a = abs(left)
        return String(format: "%@%d:%02d", sign, a / 60, a % 60)
    }
    /// True when the timer is set up but has not begun, because it is waiting for
    /// the presentation to actually start.
    var timerWaiting: Bool {
        timerEndsAt == nil && timerArmed && settings.timerAutoStart && !settings.timerUsesClockTime
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
        maybeAutoStartTimer(action)
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

    /// The talk begins when you leave the title slide, not when you pick up the
    /// remote, so a waiting timer starts on the first forward press.
    private func maybeAutoStartTimer(_ action: PresenterAction) {
        guard timerWaiting, Controller.isSlideAdvance(action) else { return }
        startTimer()
        lastEventDescription = "timer started on first slide advance"
    }

    private func run(_ action: PresenterAction, cid: UInt16) {
        maybeAutoStartTimer(action)
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

    /// A buzz point during the talk. `seconds` is how much time is left when it
    /// fires; `buzzes` is how many pulses, so you can tell them apart by feel.
    struct TimerMark: Equatable {
        let seconds: Int
        let buzzes: Int
        let label: String
    }

    func toggleTimer() {
        if timerEndsAt != nil { stopTimer() } else { startTimer() }
    }

    /// Set the timer up but leave it waiting for the first slide advance.
    func armTimer() {
        timerTicker?.invalidate(); timerTicker = nil
        timerEndsAt = nil
        timerStart = nil
        timerArmed = true
        onStatusChange?()
    }

    func startTimer() {
        timerEndsAt = Controller.timerEnd(usesClockTime: settings.timerUsesClockTime,
                                          minutes: settings.timerMinutes,
                                          finishMinuteOfDay: settings.timerFinishMinuteOfDay,
                                          now: Date())
        timerStart = Date()
        warnedAt = []
        timerArmed = false
        timerTicker?.invalidate()
        timerTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if settings.timerVibrate { device.vibrate(duration: 0x02, intensity: 0x60) }
        onStatusChange?()
    }

    func stopTimer() {
        timerTicker?.invalidate(); timerTicker = nil
        timerEndsAt = nil
        timerStart = nil
        timerArmed = false
        onStatusChange?()
    }

    /// Does this action move the talk forward? Used to decide when a waiting timer
    /// should start. A modified Return is "Start slideshow", which puts the title
    /// slide up — that is not the start of the talk, so it does not count.
    static func isSlideAdvance(_ action: PresenterAction) -> Bool {
        let p = action.raw.split(separator: ":").map(String.init)
        guard p.count >= 2, p[0] == "key", let code = Int(p[1]) else { return false }
        let flags = p.count > 2 ? (UInt64(p[2]) ?? 0) : 0
        guard flags == 0 else { return false }
        return [Int(PresenterAction.kRight), Int(PresenterAction.kDown),
                Int(PresenterAction.kPageDown), Int(PresenterAction.kSpace)].contains(code)
    }

    /// Turn the saved list into buzz points, biggest gap first. Marks that do not
    /// fit inside the talk are dropped, and zero is always present.
    static func timerMarks(_ raw: [String], totalSeconds: Int) -> [TimerMark] {
        var out: [TimerMark] = []
        var seen: Set<Int> = []
        func add(_ m: TimerMark) {
            guard m.seconds >= 0, m.seconds < totalSeconds || m.seconds == 0 else { return }
            guard !seen.contains(m.seconds) else { return }
            seen.insert(m.seconds); out.append(m)
        }
        for entry in raw {
            let t = entry.trimmingCharacters(in: .whitespaces).lowercased()
            if t == "half" {
                add(TimerMark(seconds: totalSeconds / 2, buzzes: 1, label: "halfway"))
            } else if let m = Int(t), m > 0 {
                add(TimerMark(seconds: m * 60, buzzes: 2, label: "\(m) min left"))
            }
        }
        add(TimerMark(seconds: 0, buzzes: 3, label: "time is up"))
        return out.sorted { $0.seconds > $1.seconds }
    }

    private func currentMarks() -> [TimerMark] {
        guard let end = timerEndsAt else { return [] }
        let total = max(1, Int(end.timeIntervalSince(timerStart ?? Date()).rounded()))
        return Controller.timerMarks(settings.timerMarks, totalSeconds: total)
    }
    private var timerStart: Date?

    /// Pulse the remote. Several short pulses, or a few long ones at the end.
    private func buzz(times: Int, long: Bool = false) {
        guard settings.timerVibrate, times > 0 else { return }
        deviceQueue.async { [weak self] in
            guard let self else { return }
            for i in 0..<times {
                self.device.vibrate(duration: long ? 0x0A : 0x03, intensity: long ? 0xFF : 0x90)
                if i < times - 1 { usleep(long ? 600_000 : 280_000) }
            }
        }
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
        for mark in currentMarks() where left == mark.seconds && !warnedAt.contains(mark.seconds) {
            warnedAt.insert(mark.seconds)
            lastEventDescription = "timer: \(mark.label)"
            buzz(times: mark.buzzes, long: mark.seconds == 0)
        }
        onStatusChange?()
    }
}
