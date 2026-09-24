// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Byte copying between file descriptors on dedicated threads.
enum Pump {
    /// Copy `from` -> `to` until EOF/error; then `onDone`. With `stop`, polls so
    /// the copy can be abandoned (used for a client stdin that may never EOF).
    @discardableResult
    static func copy(from: Int32, to: Int32, stop: StopFlag? = nil, shutdownWrite: Bool = true, onDone: (() -> Void)? = nil) -> Thread {
        let t = Thread {
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            outer: while true {
                if let stop {
                    var p = pollfd(fd: from, events: Int16(POLLIN), revents: 0)
                    let r = poll(&p, 1, 100)
                    if stop.isSet { break }
                    if r == 0 || (r < 0 && errno == EINTR) { continue }
                }
                let n = read(from, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                var off = 0
                while off < n {
                    let w = buf.withUnsafeBytes { write(to, $0.baseAddress! + off, n - off) }
                    if w < 0 && errno == EINTR { continue }
                    if w <= 0 { break outer }
                    off += w
                }
            }
            if shutdownWrite { shutdown(to, SHUT_WR) }
            onDone?()
        }
        t.start()
        return t
    }

    /// Bridge two sockets both ways, closing both when both directions end.
    static func bidirectional(_ a: Int32, _ b: Int32) {
        let group = DispatchGroup()
        group.enter(); group.enter()
        copy(from: a, to: b) { group.leave() }
        copy(from: b, to: a) { group.leave() }
        group.notify(queue: .global()) {
            close(a)
            close(b)
        }
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Run async work from a (non-cooperative) thread and wait for it.
func blocking<T>(_ op: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        do { box.result = .success(try await op()) } catch { box.result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try box.result!.get()
}

final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// A one-shot signal that can be awaited from async code (set from any thread).
final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var isSignaled: Bool { lock.withLock { done } }
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let w = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            done = true
            defer { waiters.removeAll() }
            return waiters
        }
        w.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if done { return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }
}

/// File descriptors collected across threads, closed together.
final class FdSet: @unchecked Sendable {
    private let lock = NSLock()
    private var fds: [Int32] = []
    func add(_ fd: Int32) { lock.withLock { fds.append(fd) } }
    func closeAll() { lock.withLock { fds.forEach { close($0) }; fds.removeAll() } }
}
