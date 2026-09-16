//  Actions.swift — turning a mapped action into something macOS actually does.

import AppKit

enum Actions {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func tapKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Media keys travel as NSSystemDefined events, not virtual key codes.
    static func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let data1 = Int((key << 16) | ((down ? 0x0A : 0x0B) << 8))
            guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                              timestamp: 0, windowNumber: 0, context: nil,
                                              subtype: 8, data1: data1, data2: -1),
                  let cg = ev.cgEvent else { continue }
            cg.post(tap: .cghidEventTap)
        }
    }
    static let NX_KEYTYPE_SOUND_UP: Int32 = 0
    static let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
    static let NX_KEYTYPE_PLAY: Int32 = 16

    static func moveCursor(to p: CGPoint) {
        // Cocoa's origin is bottom-left, CoreGraphics' is top-left.
        guard let primary = NSScreen.screens.first else { return }
        let flipped = CGPoint(x: p.x, y: primary.frame.maxY - p.y)
        CGWarpMouseCursorPosition(flipped)
        CGAssociateMouseAndMouseCursorPosition(1)
        if let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                            mouseCursorPosition: flipped, mouseButton: .left) {
            ev.post(tap: .cghidEventTap)
        }
    }

    static func leftClick(at p: CGPoint? = nil) {
        let loc = p ?? CGEvent(source: nil)?.location ?? .zero
        for t in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: loc, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    /// Parse and run one action string. Effects and the timer are handled by the
    /// caller, which owns the overlay — this returns what it could not do itself.
    enum Outcome { case handled, effect(OverlayEffect), cursor, timer, vibrate }

    @discardableResult
    static func perform(_ action: PresenterAction) -> Outcome {
        let parts = action.raw.split(separator: ":").map(String.init)
        switch parts.first ?? "none" {
        case "key":
            guard parts.count >= 2, let code = UInt16(parts[1]) else { return .handled }
            let flags = parts.count > 2 ? CGEventFlags(rawValue: UInt64(parts[2]) ?? 0) : []
            tapKey(CGKeyCode(code), flags: flags)
        case "effect":
            return .effect(OverlayEffect(rawValue: parts.count > 1 ? parts[1] : "none") ?? .none)
        case "cursor":   return .cursor
        case "timer":    return .timer
        case "vibrate":  return .vibrate
        case "click":    leftClick()
        case "volume":
            mediaKey(parts.count > 1 && parts[1] == "down" ? NX_KEYTYPE_SOUND_DOWN : NX_KEYTYPE_SOUND_UP)
        case "playpause": mediaKey(NX_KEYTYPE_PLAY)
        default: break
        }
        return .handled
    }
}
