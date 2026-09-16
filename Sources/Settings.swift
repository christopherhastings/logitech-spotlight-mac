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
    /// Re-centre the effect each time a hold starts, instead of resuming where it was.
    var recenterOnHold: Bool { get { bool("recenterOnHold", true) } set { d.set(newValue, forKey: "recenterOnHold") } }
    /// Off by default so a Zoom/Teams screen share shows the spotlight to remote viewers too.
    var hideFromScreenShare: Bool { get { bool("hideFromScreenShare", false) } set { d.set(newValue, forKey: "hideFromScreenShare") } }

    // Timing
    var doubleClickInterval: Double { get { dbl("doubleClickInterval", 0.30) } set { d.set(newValue, forKey: "doubleClickInterval") } }
    var holdThreshold: Double { get { dbl("holdThreshold", 0.25) } set { d.set(newValue, forKey: "holdThreshold") } }

    // Presentation timer
    var timerMinutes: Int { get { int("timerMinutes", 20) } set { d.set(newValue, forKey: "timerMinutes") } }
    var timerWarnMinutes: Int { get { int("timerWarnMinutes", 5) } set { d.set(newValue, forKey: "timerWarnMinutes") } }
    var timerVibrate: Bool { get { bool("timerVibrate", true) } set { d.set(newValue, forKey: "timerVibrate") } }

    // Button mappings, keyed by control ID.
    func mapping(for cid: UInt16) -> ButtonMapping {
        let k = String(format: "cid_%04X", cid)
        guard let arr = d.array(forKey: k) as? [String], arr.count == 3 else { return Settings.defaultMapping(cid) }
        return ButtonMapping(click: PresenterAction(raw: arr[0]),
                             doubleClick: PresenterAction(raw: arr[1]),
                             hold: PresenterAction(raw: arr[2]))
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
        case 0x0050:  // top button, quick press
            return ButtonMapping(click: PresenterAction(raw: "click"))
        case 0x00D8:  // top button, held — the spotlight
            return ButtonMapping(hold: .effect(.spotlight))
        case 0x00D9:  // big button, quick press
            return ButtonMapping(click: .key(PresenterAction.kRight))
        case 0x00DA:  // big button, held
            return ButtonMapping(hold: .effect(.magnify))
        case 0x00DB:  // back button, quick press
            return ButtonMapping(click: .key(PresenterAction.kLeft))
        case 0x00DC:  // back button, held
            return ButtonMapping(hold: PresenterAction(raw: "cursor"))
        default:
            return ButtonMapping()
        }
    }
}
