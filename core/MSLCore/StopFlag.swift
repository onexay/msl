// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A one-way flag that blocked readers wake up for: setting it closes the write
/// end of a pipe, so its read end polls readable for good.
public final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var fds: [Int32] = [-1, -1]

    public init() {
        if pipe(&fds) == 0 {
            fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        }
    }

    deinit {
        fds.filter { $0 >= 0 }.forEach { close($0) }
    }

    public var isSet: Bool { lock.withLock { value } }

    public func set() {
        lock.withLock {
            guard !value else { return }
            value = true
            if fds[1] >= 0 { close(fds[1]); fds[1] = -1 }
        }
    }

    /// Block until `fd` is readable (true) or the flag is set (false), without a timeout.
    public func waitReadable(_ fd: Int32) -> Bool {
        var p = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)]
        while true {
            let r = poll(&p, 2, -1)
            if isSet { return false }
            if r > 0 || errno != EINTR { return true }  // an error: the caller's read or accept reports it
        }
    }
}
