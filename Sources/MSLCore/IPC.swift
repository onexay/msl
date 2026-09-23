import CMSLSupport
import Foundation

// msl <-> msld protocol over a Unix stream socket.
// Frame: 4-byte big-endian length + JSON. File descriptors ride along with a
// frame via SCM_RIGHTS.

public struct RunRequest: Codable, Sendable {
    public var spec: RunSpec
    public var macCwd: String
    public var env: [String: String]
    public var stdinTTY: Bool
    public var stdoutTTY: Bool
    public var stderrTTY: Bool
    public var rows: UInt16
    public var cols: UInt16
    /// MSLENV and the macOS values of the variables it names (translated in the guest).
    public var mslenv: String = ""
    public var mslenvValues: [String: String] = [:]
    public var macHome: String = ""
    public init(spec: RunSpec, macCwd: String, env: [String: String], stdinTTY: Bool, stdoutTTY: Bool, stderrTTY: Bool, rows: UInt16, cols: UInt16) {
        self.spec = spec; self.macCwd = macCwd; self.env = env
        self.stdinTTY = stdinTTY; self.stdoutTTY = stdoutTTY; self.stderrTTY = stderrTTY
        self.rows = rows; self.cols = cols
    }
}

public enum Request: Codable, Sendable {
    case list
    case status
    case versionInfo
    case setDefault(name: String)
    case terminate(name: String)
    case shutdown(force: Bool)
    case unregister(name: String)
    /// fd[0] = output file (or stdout)
    case export(name: String, format: String)
    /// fd[0] = input file (or stdin)
    case importTar(name: String, location: String)
    /// fd[0] = input file
    case installFromFile(name: String?, location: String?, sourceDescription: String)
    case manage(name: String, op: ManageOp)
    /// fds = [stdin, stdout, stderr]
    case run(RunRequest)
    /// A root shell in the utility VM itself; fds = [stdin, stdout, stderr]
    case debugShell(RunRequest)
    case mount(MountSpec)
    case unmount(disk: String?)
}

/// Sent by msl while a `run` is in progress.
public enum ClientEvent: Codable, Sendable {
    case resize(rows: UInt16, cols: UInt16)
    case signal(Int32)
}

public struct DistroSummary: Codable, Sendable, Equatable {
    public var name: String
    public var id: String
    public var running: Bool
    public var version: Int
    public var isDefault: Bool
    public init(name: String, id: String, running: Bool, version: Int, isDefault: Bool) {
        self.name = name; self.id = id; self.running = running; self.version = version; self.isDefault = isDefault
    }
}

public enum Reply: Codable, Sendable {
    case ok
    case failure(message: String, code: String)
    case distros([DistroSummary])
    case status(distros: [DistroSummary], vm: VMStatus)
    case versionInfo(kernel: String)
    case installed(name: String)
    /// A run finished with this exit code.
    case exited(Int32)
    case mounted(device: String, mountPoint: String)
}

public enum IPCError: Error {
    case closed
    case io(Int32)
    case tooLarge
}

public final class IPCConnection: @unchecked Sendable {
    public let fd: Int32
    private let writeLock = NSLock()

    public init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }

    public static func connect(path: String) throws -> IPCConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.io(errno) }
        var addr = sockaddr_un.make(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw IPCError.io(e)
        }
        return IPCConnection(fd: fd)
    }

    public func send<T: Encodable>(_ value: T, fds: [Int32] = []) throws {
        let json = try JSONEncoder().encode(value)
        var frame = Data()
        var len = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(json)
        try writeLock.withLock {
            try frame.withUnsafeBytes { raw in
                var off = 0
                var first = true
                while off < raw.count {
                    let n: Int
                    if first && !fds.isEmpty {
                        n = fds.withUnsafeBufferPointer {
                            msl_send_with_fds(fd, raw.baseAddress! + off, raw.count - off, $0.baseAddress, Int32(fds.count))
                        }
                    } else {
                        n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                    }
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw IPCError.io(errno)
                    }
                    first = false
                    off += n
                }
            }
        }
    }

    /// Receive one frame; any fds attached to it are returned (caller owns them).
    public func receive<T: Decodable>(_ type: T.Type) throws -> (T, [Int32]) {
        var fds: [Int32] = []
        let header = try readExactly(4, fds: &fds)
        let len = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard len < 16 << 20 else { throw IPCError.tooLarge }
        let body = try readExactly(Int(len), fds: &fds)
        return (try JSONDecoder().decode(T.self, from: body), fds)
    }

    private func readExactly(_ count: Int, fds: inout [Int32]) throws -> Data {
        var out = Data(count: count)
        var got = 0
        while got < count {
            var buf = [Int32](repeating: -1, count: 8)
            var nfds: Int32 = 8
            let n = out.withUnsafeMutableBytes { raw in
                buf.withUnsafeMutableBufferPointer { msl_recv_with_fds(fd, raw.baseAddress! + got, count - got, $0.baseAddress, &nfds) }
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw IPCError.io(errno)
            }
            if n == 0 { throw IPCError.closed }
            fds.append(contentsOf: buf.prefix(Int(nfds)))
            got += n
        }
        return out
    }
}

extension sockaddr_un {
    public static func make(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        return addr
    }
}

/// Listen on a Unix socket path (removing a stale one).
public func listenUnix(_ path: String, backlog: Int32 = 64) throws -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw IPCError.io(errno) }
    var addr = sockaddr_un.make(path)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0, listen(fd, backlog) == 0 else {
        let e = errno
        close(fd)
        throw IPCError.io(e)
    }
    chmod(path, 0o600)
    return fd
}
