//  LaunchEvents.swift — consume the launchd event that started us.
//
//  The LaunchAgent starts this app when the receiver is plugged in, via
//  LaunchEvents -> com.apple.iokit.matching. launchd holds that event as pending
//  until the process takes delivery of it. An app that never does gets relaunched
//  the instant it exits, because from launchd's point of view the event is still
//  outstanding and unhandled — quitting simply hands you another launch.
//
//  Installing a handler marks the events delivered, so Quit means quit and the
//  next launch comes from actually re-plugging the receiver.

import Foundation
import XPC

enum LaunchEvents {
    /// Called when the receiver appears while the app is already running.
    nonisolated(unsafe) static var onDeviceEvent: (() -> Void)?

    static func consume() {
        xpc_set_event_stream_handler("com.apple.iokit.matching", DispatchQueue.main) { _ in
            // Taking delivery is the point. If the receiver was re-plugged while
            // we were running, pick it up again.
            onDeviceEvent?()
        }
    }
}
