//  SettingsView.swift — the preferences window.

import SwiftUI

final class SettingsModel: ObservableObject {
    let s = Settings.shared
    let controller: Controller

    @Published var radius: Double
    @Published var dim: Double
    @Published var zoom: Double
    @Published var laserHue: Double
    @Published var sensitivity: Double
    @Published var invertX: Bool
    @Published var invertY: Bool
    @Published var recenter: Bool
    @Published var hideFromShare: Bool
    @Published var smoothing: Double
    @Published var doubleClickInterval: Double
    @Published var timerMinutes: Double
    @Published var timerMarks: String
    @Published var timerAutoStart: Bool
    @Published var timerVibrate: Bool
    @Published var timerUsesClock: Bool
    @Published var timerFinishMinute: Double
    @Published var freeze: Bool
    @Published var cursorFollows: Bool
    @Published var laserSize: Double
    @Published var tint: Double
    @Published var tintStrength: Double
    @Published var cycle: [OverlayEffect]
    @Published var buttons: [UInt16] = []
    @Published var mappings: [UInt16: ButtonMapping] = [:]
    @Published var lastPressed: UInt16? = nil

    init(controller: Controller) {
        self.controller = controller
        radius = s.radius; dim = s.dimOpacity; zoom = s.zoom; laserHue = s.laserHue
        sensitivity = s.sensitivity; invertX = s.invertX; invertY = s.invertY
        recenter = s.recenterOnHold; hideFromShare = s.hideFromScreenShare
        smoothing = s.smoothing; doubleClickInterval = s.doubleClickInterval
        timerMinutes = Double(s.timerMinutes)
        timerMarks = s.timerMarks.joined(separator: ", ")
        timerAutoStart = s.timerAutoStart
        timerVibrate = s.timerVibrate
        timerUsesClock = s.timerUsesClockTime
        timerFinishMinute = Double(s.timerFinishMinuteOfDay)
        freeze = s.freezeEffect
        cursorFollows = s.cursorFollowsEffect
        laserSize = s.laserSize
        tint = s.highlightTint
        tintStrength = s.highlightTintStrength
        cycle = s.effectCycle
        reloadButtons()
        controller.onButtonSeen = { [weak self] cid in
            DispatchQueue.main.async { self?.lastPressed = cid; self?.reloadButtons() }
        }
    }

    func reloadButtons() {
        // The three physical buttons, each as its press and its hold.
        let known: [UInt16] = [0x0050, 0x00D8, 0x00D9, 0x00DA, 0x00DB, 0x00DC]
        // The device also lists controls no physical button produces. Hide those
        // until one actually fires, rather than showing dead rows.
        var cids = controller.device.controls
            .filter { $0.isDivertable }
            .map { $0.cid }
            .filter { known.contains($0) || controller.seenCIDs.contains($0) || s.hasCustomMapping($0) }
        for c in controller.seenCIDs where !cids.contains(c) { cids.append(c) }
        if cids.isEmpty { cids = known }
        cids.sort { (known.firstIndex(of: $0) ?? 99) < (known.firstIndex(of: $1) ?? 99) }
        buttons = cids
        mappings = Dictionary(uniqueKeysWithValues: cids.map { ($0, s.mapping(for: $0)) })
    }

    func save() {
        s.radius = radius; s.dimOpacity = dim; s.zoom = zoom; s.laserHue = laserHue
        s.sensitivity = sensitivity; s.invertX = invertX; s.invertY = invertY
        s.recenterOnHold = recenter; s.hideFromScreenShare = hideFromShare
        s.smoothing = smoothing; s.doubleClickInterval = doubleClickInterval
        s.timerMinutes = Int(timerMinutes)
        s.timerMarks = timerMarks.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0 == "half" || Int($0) != nil }
        s.timerAutoStart = timerAutoStart
        s.timerVibrate = timerVibrate
        s.timerUsesClockTime = timerUsesClock
        s.timerFinishMinuteOfDay = Int(timerFinishMinute)
        s.freezeEffect = freeze
        s.cursorFollowsEffect = cursorFollows
        s.laserSize = laserSize
        s.highlightTint = tint
        s.highlightTintStrength = tintStrength
        s.effectCycle = cycle
        for (cid, m) in mappings { s.setMapping(m, for: cid) }
    }

    func resetButtons() {
        s.resetMappings(cids: buttons)
        reloadButtons()
    }

    /// Plain-English preview of the buzz points, counted from the start of the talk.
    var markPreview: String {
        let total = max(1, Int(timerMinutes) * 60)
        let list = timerMarks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let marks = Controller.timerMarks(list, totalSeconds: total)
        guard !marks.isEmpty else { return "" }
        let parts = marks.map { "\($0.label) at \((total - $0.seconds) / 60) min in" }
        return "Buzzes: " + parts.joined(separator: ", ")
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            buttonsTab.tabItem { Label("Buttons", systemImage: "hand.tap") }
            effectsTab.tabItem { Label("Effects", systemImage: "circle.dashed") }
            pointingTab.tabItem { Label("Pointing", systemImage: "scope") }
            timerTab.tabItem { Label("Timer", systemImage: "timer") }
            permissionsTab.tabItem { Label("Permissions", systemImage: "lock") }
        }
        .frame(width: 560, height: 430)
        .onDisappear { model.save() }
    }

    // MARK: buttons

    private var buttonsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Press a button on the remote to highlight it here. The remote sends a different signal for a quick press than for a held press, so each appears as its own row.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(model.buttons, id: \.self) { cid in
                        buttonRow(cid)
                    }
                }.padding(.vertical, 4)
            }
            HStack {
                Button("Reset to defaults") { model.resetButtons() }
                Spacer()
                Button("Apply") { model.save() }.keyboardShortcut(.defaultAction)
            }
        }.padding()
    }

    private func buttonRow(_ cid: UInt16) -> some View {
        let active = model.lastPressed == cid
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: active ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                Text(Spotlight.controlName(cid)).font(.headline)
                Text(String(format: "CID 0x%04X", cid)).font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                if Spotlight.isHoldControl(cid) {
                    row("While held", cid, \ButtonMapping.hold)
                } else {
                    row("Press", cid, \ButtonMapping.click)
                    row("Double press", cid, \ButtonMapping.doubleClick)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(active ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
    }

    private func row(_ title: String, _ cid: UInt16,
                     _ path: WritableKeyPath<ButtonMapping, PresenterAction>) -> some View {
        GridRow {
            Text(title).frame(width: 90, alignment: .leading)
            Picker("", selection: Binding(
                get: { model.mappings[cid]?[keyPath: path].raw ?? "none" },
                set: { raw in
                    var m = model.mappings[cid] ?? ButtonMapping()
                    m[keyPath: path] = PresenterAction(raw: raw)
                    model.mappings[cid] = m
                })) {
                ForEach(PresenterAction.presets, id: \.action.raw) { p in
                    Text(p.name).tag(p.action.raw)
                }
            }
            .labelsHidden()
            .frame(width: 260)
        }
    }

    // MARK: effects

    private var effectsTab: some View {
        Form {
            Slider(value: $model.radius, in: 40...600) {
                Text("Circle size: \(Int(model.radius)) px")
            }
            Slider(value: $model.dim, in: 0...0.95) {
                Text("Dim the rest of the screen: \(Int(model.dim * 100))%")
            }
            Slider(value: $model.zoom, in: 1.2...6) {
                Text(String(format: "Magnifier zoom: %.1f×", model.zoom))
            }
            Slider(value: $model.laserHue, in: 0...1) { Text("Laser dot colour") }
            Slider(value: $model.laserSize, in: 8...80) {
                Text("Laser dot size: \(Int(model.laserSize)) px")
            }
            Divider()
            Slider(value: $model.tintStrength, in: 0...0.8) {
                Text(model.tintStrength < 0.02
                     ? "Tint the dimmed area: off"
                     : "Tint the dimmed area: \(Int(model.tintStrength * 100))%")
            }
            if model.tintStrength >= 0.02 {
                Slider(value: $model.tint, in: 0...1) { Text("Tint colour") }
            }
            Divider()
            Text("Switch effect cycles through:").font(.headline)
            HStack {
                ForEach([OverlayEffect.spotlight, .circle, .magnify, .laser], id: \.rawValue) { e in
                    Toggle(e.label, isOn: Binding(
                        get: { model.cycle.contains(e) },
                        set: { on in
                            var c = model.cycle
                            if on { if !c.contains(e) { c.append(e) } }
                            else { c.removeAll { $0 == e } }
                            model.cycle = c.isEmpty ? [e] : c
                        }))
                    .toggleStyle(.checkbox)
                }
            }
            Divider()
            Toggle("Hide the overlay from screen recordings and shares", isOn: $model.hideFromShare)
            Text("Leave this off if you present over Zoom or Teams — remote viewers need to see the spotlight. Turn it on if you are recording and want a clean capture.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }

    // MARK: pointing

    private var pointingTab: some View {
        Form {
            Slider(value: $model.sensitivity, in: 0.1...5) {
                Text(String(format: "Pointer speed: %.2f", model.sensitivity))
            }
            Toggle("Invert left / right", isOn: $model.invertX)
            Toggle("Invert up / down", isOn: $model.invertY)
            Toggle("Start from the middle of the screen each time", isOn: $model.recenter)
            Divider()
            Toggle("Freeze the effect when you let go", isOn: $model.freeze)
            Text("Point at what you want, release the button, and the effect stays put. Press the button again to clear it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Move the mouse cursor with the effect", isOn: $model.cursorFollows)
            Text("Keeps links and video controls clickable while you are highlighting them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Slider(value: $model.smoothing, in: 0...0.9) {
                Text(String(format: "Smoothing: %.2f", model.smoothing))
            }
            Text("The remote decides press vs hold by itself, so there is no hold delay to tune.")
                .font(.caption).foregroundStyle(.secondary)
            Slider(value: $model.doubleClickInterval, in: 0.15...0.7) {
                Text(String(format: "Double-click window: %.2f s", model.doubleClickInterval))
            }
            Text("Buttons with no double-click action fire immediately, so next/back stay snappy.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }

    // MARK: timer

    private var timerTab: some View {
        Form {
            Picker("", selection: $model.timerUsesClock) {
                Text("Count down from now").tag(false)
                Text("Finish at a set time").tag(true)
            }
            .pickerStyle(.radioGroup).labelsHidden()

            if model.timerUsesClock {
                Slider(value: $model.timerFinishMinute, in: 0...(24 * 60 - 1), step: 5) {
                    Text("Finish at \(String(format: "%02d:%02d", Int(model.timerFinishMinute) / 60, Int(model.timerFinishMinute) % 60))")
                }
                Text("If that time has already gone by today, it means tomorrow.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Slider(value: $model.timerMinutes, in: 1...120, step: 1) {
                    Text("Talk length: \(Int(model.timerMinutes)) min")
                }
            }
            if !model.timerUsesClock {
                Toggle("Start the timer when I move off the title slide", isOn: $model.timerAutoStart)
                Text("The timer waits until your first forward press, so setup time is not counted.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            TextField("Buzz at", text: $model.timerMarks)
            Text("Comma separated. \"half\" is the halfway point, a number is that many minutes left. The end always buzzes.")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.markPreview).font(.caption).foregroundStyle(.secondary)

            Toggle("Buzz the remote at each of these", isOn: $model.timerVibrate)
            Divider()
            HStack {
                Button(model.controller.timerText == nil ? "Start timer now" : "Stop timer") {
                    model.controller.toggleTimer()
                }
                Button("Wait for slide 2") { model.controller.armTimer() }
                Button("Test buzz") { model.controller.device.vibrate() }
            }
        }.padding()
    }

    // MARK: permissions

    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            perm("Accessibility",
                 "Lets the app send arrow keys to Keynote, PowerPoint and Google Slides, and move the cursor.",
                 Actions.hasAccessibility) { Actions.requestAccessibility() }
            perm("Screen Recording",
                 "Only used by the Magnifier, which needs to read the pixels it is blowing up.",
                 CGPreflightScreenCaptureAccess()) { CGRequestScreenCaptureAccess() }
            Divider()
            Text("Reading the remote itself needs no permission — the app talks to the receiver's vendor channel directly.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding()
    }

    private func perm(_ title: String, _ why: String, _ granted: Bool,
                      _ request: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant…", action: request) }
        }
    }
}
