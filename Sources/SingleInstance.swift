//  SingleInstance.swift — only one copy may talk to the remote.
//
//  launchd's plug-in trigger and a manual `open` can fire within milliseconds of
//  each other, so checking the running-application list is racy. A file lock is not.

import Foundation

enum SingleInstance {
    private static var fd: Int32 = -1

    /// Returns false if another copy already holds the lock.
    static func claim() -> Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Presenter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("instance.lock").path

        fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }          // cannot lock; better to run than not
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd); fd = -1
            return false
        }
        return true                                  // held until the process exits
    }
}
