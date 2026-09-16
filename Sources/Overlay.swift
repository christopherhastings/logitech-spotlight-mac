//  Overlay.swift — the on-screen effects: spotlight, circle, magnifier, laser dot.
//
//  One borderless window stretched over every display, above the shielding level so
//  it survives Keynote/PowerPoint presentation mode and full-screen apps.
//  Drawing is CALayer based with implicit animation off, so it tracks the gyro
//  without lag or smearing.

import AppKit
import ScreenCaptureKit

enum OverlayEffect: String, CaseIterable, Codable {
    case spotlight   // dim the screen, cut a clear circle
    case circle      // just an outlined circle, no dimming
    case magnify     // circular zoom of what is underneath
    case laser       // small glowing dot
    case none

    var label: String {
        switch self {
        case .spotlight: return "Spotlight (dim + circle)"
        case .circle:    return "Circle outline"
        case .magnify:   return "Magnifier"
        case .laser:     return "Laser dot"
        case .none:      return "Nothing"
        }
    }
}

final class OverlayView: NSView {
    var effect: OverlayEffect = .none
    /// Centre of the effect, in this view's coordinates.
    var center: CGPoint = .zero
    var radius: CGFloat = 140
    var dimOpacity: CGFloat = 0.55
    var zoom: CGFloat = 2.0
    var laserColor: NSColor = .systemRed
    var borderWidth: CGFloat = 0
    var borderColor: NSColor = .white

    private let dimLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let magLayer = CALayer()
    private let magMask = CAShapeLayer()
    private let dotLayer = CALayer()

    /// Screen snapshot used by the magnifier, plus the rect it covers in view coordinates.
    var snapshot: CGImage?
    var snapshotRect: NSRect = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.cgColor
        ringLayer.fillColor = nil
        magLayer.mask = magMask
        magLayer.contentsGravity = .resize
        dotLayer.masksToBounds = true
        for l in [dimLayer, magLayer, ringLayer, dotLayer] { layer?.addSublayer(l) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    func refresh() {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for l in [dimLayer, magLayer, ringLayer, dotLayer] {
            l.frame = root.bounds
            l.isHidden = true
        }
        let hole = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2), transform: nil)

        switch effect {
        case .none:
            break

        case .spotlight:
            let p = CGMutablePath()
            p.addRect(root.bounds)
            p.addPath(hole)
            dimLayer.path = p
            dimLayer.opacity = Float(dimOpacity)
            dimLayer.isHidden = false
            drawRing(hole)

        case .circle:
            ringLayer.path = hole
            ringLayer.strokeColor = borderColor.cgColor
            ringLayer.lineWidth = max(borderWidth, 3)
            ringLayer.isHidden = false

        case .magnify:
            if let img = snapshot, snapshotRect.width > 0 {
                // Region under the circle, blown up by `zoom`.
                let src = CGRect(x: center.x - radius / zoom, y: center.y - radius / zoom,
                                 width: 2 * radius / zoom, height: 2 * radius / zoom)
                let scale = CGFloat(img.width) / snapshotRect.width
                // CGImage origin is top-left; the view is bottom-left.
                let crop = CGRect(x: (src.minX - snapshotRect.minX) * scale,
                                  y: (snapshotRect.maxY - src.maxY) * scale,
                                  width: src.width * scale, height: src.height * scale)
                    .intersection(CGRect(x: 0, y: 0, width: CGFloat(img.width), height: CGFloat(img.height)))
                if !crop.isEmpty, let sub = img.cropping(to: crop.integral) {
                    magLayer.frame = CGRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2)
                    magLayer.contents = sub
                    magMask.frame = magLayer.bounds
                    magMask.path = CGPath(ellipseIn: magLayer.bounds, transform: nil)
                    magMask.fillColor = NSColor.black.cgColor
                    magLayer.isHidden = false
                }
            }
            if magLayer.isHidden {   // no screen-recording permission yet
                ringLayer.path = hole
                ringLayer.strokeColor = NSColor.systemYellow.cgColor
                ringLayer.lineWidth = 4
                ringLayer.isHidden = false
            } else {
                drawRing(hole)
            }

        case .laser:
            let d = max(radius * 0.18, 10)
            dotLayer.frame = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
            dotLayer.cornerRadius = d / 2
            dotLayer.backgroundColor = laserColor.cgColor
            dotLayer.shadowColor = laserColor.cgColor
            dotLayer.shadowOpacity = 0.9
            dotLayer.shadowRadius = d * 0.8
            dotLayer.shadowOffset = .zero
            dotLayer.isHidden = false
        }
    }

    private func drawRing(_ hole: CGPath) {
        guard borderWidth > 0 else { return }
        ringLayer.path = hole
        ringLayer.strokeColor = borderColor.cgColor
        ringLayer.lineWidth = borderWidth
        ringLayer.isHidden = false
    }
}

final class OverlayController {
    private var window: NSWindow?
    private var view: OverlayView?
    private var snapshotTimer: Timer?

    private(set) var isVisible = false
    var settings: Settings = .shared

    /// Union of every screen, in Cocoa global coordinates.
    private var unionFrame: NSRect {
        NSScreen.screens.reduce(NSRect.zero) { $0.isEmpty ? $1.frame : $0.union($1.frame) }
    }

    private func ensureWindow() -> OverlayView {
        if let v = view, let w = window {
            let f = unionFrame
            if w.frame != f { w.setFrame(f, display: false); v.frame = NSRect(origin: .zero, size: f.size) }
            return v
        }
        let f = unionFrame
        let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.sharingType = settings.hideFromScreenShare ? .none : .readOnly
        let v = OverlayView(frame: NSRect(origin: .zero, size: f.size))
        w.contentView = v
        window = w; view = v
        return v
    }

    /// View coordinates for a point given in Cocoa global screen coordinates.
    func toViewPoint(_ global: CGPoint) -> CGPoint {
        let f = unionFrame
        return CGPoint(x: global.x - f.minX, y: global.y - f.minY)
    }

    func show(effect: OverlayEffect, at global: CGPoint) {
        let v = ensureWindow()
        window?.sharingType = settings.hideFromScreenShare ? .none : .readOnly
        v.effect = effect
        v.center = toViewPoint(global)
        applySettings(to: v)
        v.refresh()
        window?.orderFrontRegardless()
        isVisible = true
        if effect == .magnify { startSnapshots() }
    }

    func move(to global: CGPoint) {
        guard isVisible, let v = view else { return }
        v.center = toViewPoint(global)
        v.refresh()
    }

    func setRadius(_ r: CGFloat) {
        guard let v = view else { return }
        v.radius = max(30, min(r, 900))
        v.refresh()
    }

    func hide() {
        snapshotTimer?.invalidate(); snapshotTimer = nil
        view?.effect = .none
        view?.refresh()
        window?.orderOut(nil)
        isVisible = false
    }

    private func applySettings(to v: OverlayView) {
        v.radius = CGFloat(settings.radius)
        v.dimOpacity = CGFloat(settings.dimOpacity)
        v.zoom = CGFloat(settings.zoom)
        v.borderWidth = CGFloat(settings.borderWidth)
        v.borderColor = settings.borderColorValue
        v.laserColor = settings.laserColorValue
    }

    // MARK: magnifier source image

    private func startSnapshots() {
        capture()
        snapshotTimer?.invalidate()
        // Slides are mostly static; re-grabbing twice a second is plenty and cheap.
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.capture()
        }
    }

    private func capture() {
        guard let v = view else { return }
        let bounds = unionFrame
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false,
                                                                                      onScreenWindowsOnly: true)
            else { return }
            // Capture the display the effect is currently on.
            let globalCenter = CGPoint(x: v.center.x + bounds.minX, y: v.center.y + bounds.minY)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(globalCenter) })
                    ?? NSScreen.main,
                  let sid = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == sid })
            else { return }

            let cfg = SCStreamConfiguration()
            cfg.width = Int(screen.frame.width * screen.backingScaleFactor)
            cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
            cfg.showsCursor = false
            // Exclude our own overlay so the magnifier does not photograph itself.
            let ourWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingWindows: ourWindows)
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                    configuration: cfg) {
                v.snapshot = img
                v.snapshotRect = NSRect(x: screen.frame.minX - bounds.minX,
                                        y: screen.frame.minY - bounds.minY,
                                        width: screen.frame.width, height: screen.frame.height)
                v.refresh()
            }
        }
    }
}
