//  Settings.swift — everything the user can change, persisted in UserDefaults.

import AppKit

/// Actions are stored as short strings so they survive version changes and are
/// easy to show in a menu. Format:
///   none | key:<keycode>:<flagbits> | effect:<name> | cursor | click
///   volume:up | volume:down | playpause | timer | vibrate
struct PresenterAction: Equatable {
    var raw: String

    static let none = PresenterAction(raw: "none")

    var label: String {
        if let p = PresenterAction.presets.first(where: { $0.action.raw == raw }) { return p.name }
        return raw
    }

    struct Preset { let name: String; let action: PresenterAction }

    static func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) -> PresenterAction {
        PresenterAction(raw: "key:\(code):\(flags.rawValue)")
    }
    static func effect(_ e: OverlayEffect) -> PresenterAction {
        PresenterAction(raw: "effect:\(e.rawValue)")
    }

    // Virtual key codes (ANSI layout, from Carbon Events.h).
    static let kRight: CGKeyCode = 124, kLeft: CGKeyCode = 123, kDown: CGKeyCode = 125, kUp: CGKeyCode = 126
    static let kPageDown: CGKeyCode = 121, kPageUp: CGKeyCode = 116
    static let kEsc: CGKeyCode = 53, kSpace: CGKeyCode = 49, kReturn: CGKeyCode = 36
    static let kB: CGKeyCode = 11, kW: CGKeyCode = 13, kF5: CGKeyCode = 96, kPeriod: CGKeyCode = 47

    static let presets: [Preset] = [
        Preset(name: "Nothing",               action: .none),
        Preset(name: "Next slide (→)",        action: .key(kRight)),
        Preset(name: "Previous slide (←)",    action: .key(kLeft)),
        Preset(name: "Page Down",             action: .key(kPageDown)),
        Preset(name: "Page Up",               action: .key(kPageUp)),
        Preset(name: "Start slideshow (⌘⇧↵)", action: .key(kReturn, [.maskCommand, .maskShift])),
        Preset(name: "End slideshow (Esc)",   action: .key(kEsc)),
        Preset(name: "Black screen (B)",      action: .key(kB)),
        Preset(name: "White screen (W)",      action: .key(kW)),
        Preset(name: "Spotlight while held",  action: .effect(.spotlight)),
        Preset(name: "Circle while held",     action: .effect(.circle)),
        Preset(name: "Magnify while held",    action: .effect(.magnify)),
        Preset(name: "Laser dot while held",  action: .effect(.laser)),
        Preset(name: "Move the mouse cursor", action: PresenterAction(raw: "cursor")),
        Preset(name: "Left click",            action: PresenterAction(raw: "click")),
        Preset(name: "Volume up",             action: PresenterAction(raw: "volume:up")),
        Preset(name: "Volume down",           action: PresenterAction(raw: "volume:down")),
        Preset(name: "Play / Pause",          action: PresenterAction(raw: "playpause")),
        Preset(name: "Start / stop timer",    action: PresenterAction(raw: "timer")),
        Preset(name: "Buzz the remote",       action: PresenterAction(raw: "vibrate")),
        Preset(name: "Switch effect",         action: PresenterAction(raw: "cycle")),
        Preset(name: "Scroll (move hand up/down)", action: PresenterAction(raw: "gesture:scroll")),
        Preset(name: "Volume (move hand up/down)", action: PresenterAction(raw: "gesture:volume")),
    ]
}

/// The three things a button can do.
struct ButtonMapping: Equatable {
    var click = PresenterAction.none
    var doubleClick = PresenterAction.none
    var hold = PresenterAction.none
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
    private func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
    private func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }

    // Effect appearance
    var radius: Double { get { dbl("radius", 150) } set { d.set(newValue, forKey: "radius") } }
    /// Tint applied to the dimmed area. 0 = plain black, which is the default.
    var highlightTint: Double { get { dbl("highlightTint", 0) } set { d.set(newValue, forKey: "highlightTint") } }
    var highlightTintStrength: Double {
        get { dbl("highlightTintStrength", 0) } set { d.set(newValue, forKey: "highlightTintStrength") }
    }
    /// The laser dot is sized independently of the highlight circle.
    var laserSize: Double { get { dbl("laserSize", 26) } set { d.set(newValue, forKey: "laserSize") } }
    var dimOpacity: Double { get { dbl("dimOpacity", 0.55) } set { d.set(newValue, forKey: "dimOpacity") } }
    var zoom: Double { get { dbl("zoom", 2.2) } set { d.set(newValue, forKey: "zoom") } }
    var borderWidth: Double { get { dbl("borderWidth", 0) } set { d.set(newValue, forKey: "borderWidth") } }
    var borderColorValue: NSColor { .white }
    var laserColorValue: NSColor {
        NSColor(calibratedHue: CGFloat(dbl("laserHue", 0.0)), saturation: 0.95, brightness: 1.0, alpha: 0.95)
    }
    var laserHue: Double { get { dbl("laserHue", 0.0) } set { d.set(newValue, forKey: "laserHue") } }

    // Pointing
    var sensitivity: Double { get { dbl("sensitivity", 0.30) } set { d.set(newValue, forKey: "sensitivity") } }
    var invertX: Bool { get { bool("invertX", false) } set { d.set(newValue, forKey: "invertX") } }
    /// 0 = raw and jittery, 0.9 = very smooth but laggy.
    var smoothing: Double { get { dbl("smoothing", 0.45) } set { d.set(newValue, forKey: "smoothing") } }
    var invertY: Bool { get { bool("invertY", false) } set { d.set(newValue, forKey: "invertY") } }
    /// Release the button and the effect stays where you left it, until the button
    /// is pressed again. Logi Options+ calls this "freeze the effect".
    var freezeEffect: Bool { get { bool("freezeEffect", false) } set { d.set(newValue, forKey: "freezeEffect") } }
    /// Move the real mouse cursor along with the effect, so links stay clickable
    /// while highlighting. This is what the remote does with Logitech's software.
    var cursorFollowsEffect: Bool {
        get { bool("cursorFollowsEffect", true) } set { d.set(newValue, forKey: "cursorFollowsEffect") }
    }
    /// Effects that "Switch effect" cycles through.
    var effectCycle: [OverlayEffect] {
        get {
            let raw = (d.array(forKey: "effectCycle") as? [String])
                ?? [OverlayEffect.spotlight.rawValue, OverlayEffect.magnify.rawValue, OverlayEffect.laser.rawValue]
            let out = raw.compactMap { OverlayEffect(rawValue: $0) }.filter { $0 != .none }
            return out.isEmpty ? [.spotlight] : out
        }
        set { d.set(newValue.map { $0.rawValue }, forKey: "effectCycle") }
    }

    /// Re-centre the effect each time a hold starts, instead of resuming where it was.
    var recenterOnHold: Bool { get { bool("recenterOnHold", true) } set { d.set(newValue, forKey: "recenterOnHold") } }
    /// Off by default so a Zoom/Teams screen share shows the spotlight to remote viewers too.
    var hideFromScreenShare: Bool { get { bool("hideFromScreenShare", false) } set { d.set(newValue, forKey: "hideFromScreenShare") } }

    // Timing
    var doubleClickInterval: Double { get { dbl("doubleClickInterval", 0.30) } set { d.set(newValue, forKey: "doubleClickInterval") } }

    // Presentation timer. Logi Options+ offers a countdown or an alert at a clock
    // time; both are here.
    var timerUsesClockTime: Bool {
        get { bool("timerUsesClockTime", false) } set { d.set(newValue, forKey: "timerUsesClockTime") }
    }
    /// Minutes past midnight for the clock-time finish, e.g. 15:00 is 900.
    var timerFinishMinuteOfDay: Int {
        get { int("timerFinishMinuteOfDay", 15 * 60) } set { d.set(newValue, forKey: "timerFinishMinuteOfDay") }
    }
    var timerMinutes: Int { get { int("timerMinutes", 20) } set { d.set(newValue, forKey: "timerMinutes") } }

    /// Wait for the first move off the title slide before the clock starts, so the
    /// count matches the talk rather than the time you spent setting up.
    var timerAutoStart: Bool { get { bool("timerAutoStart", true) } set { d.set(newValue, forKey: "timerAutoStart") } }

    /// When to buzz, as a list. "half" is the halfway point of the talk; a number
    /// is that many minutes left. Zero is always added, so the end always buzzes.
    var timerMarks: [String] {
        get { (d.array(forKey: "timerMarks") as? [String]) ?? ["half", "5"] }
        set { d.set(newValue, forKey: "timerMarks") }
    }
    var timerVibrate: Bool { get { bool("timerVibrate", true) } set { d.set(newValue, forKey: "timerVibrate") } }

    // Button mappings, keyed by control ID.
    func mapping(for cid: UInt16) -> ButtonMapping {
        let k = String(format: "cid_%04X", cid)
        guard let arr = d.array(forKey: k) as? [String], arr.count == 3 else { return Settings.defaultMapping(cid) }
        return ButtonMapping(click: PresenterAction(raw: arr[0]),
                             doubleClick: PresenterAction(raw: arr[1]),
                             hold: PresenterAction(raw: arr[2]))
    }
    /// True if the user has saved anything for this control.
    func hasCustomMapping(_ cid: UInt16) -> Bool {
        d.array(forKey: String(format: "cid_%04X", cid)) != nil
    }

    func setMapping(_ m: ButtonMapping, for cid: UInt16) {
        d.set([m.click.raw, m.doubleClick.raw, m.hold.raw], forKey: String(format: "cid_%04X", cid))
    }
    func resetMappings(cids: [UInt16]) {
        for c in cids { d.removeObject(forKey: String(format: "cid_%04X", c)) }
    }

    /// Measured defaults for this remote. The device emits a different control ID
    /// for a press than for a hold, so each row is one physical gesture.
    static func defaultMapping(_ cid: UInt16) -> ButtonMapping {
        switch cid {
        case 0x0050:  // top button: click, and a double press switches effect
            return ButtonMapping(click: PresenterAction(raw: "click"),
                                 doubleClick: PresenterAction(raw: "cycle"))
        case 0x00D8:  // top button, held — the spotlight
            return ButtonMapping(hold: .effect(.spotlight))
        case 0x00D9:  // big button, quick press
            return ButtonMapping(click: .key(PresenterAction.kRight))
        case 0x00DA:  // big button, held — Logitech's default is Start presentation
            return ButtonMapping(hold: .key(PresenterAction.kReturn, [.maskCommand, .maskShift]))
        case 0x00DB:  // back button, quick press
            return ButtonMapping(click: .key(PresenterAction.kLeft))
        case 0x00DC:  // back button, held — Logitech's default is Blank screen
            return ButtonMapping(hold: .key(PresenterAction.kB))
        default:
            return ButtonMapping()
        }
    }
}
