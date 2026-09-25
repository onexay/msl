// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Access control for the `~/.msl/distros` NFS view (#1), applied by msld to
/// every ONC RPC call (RFC 5531) before it reaches the guest's NFS server.
///
/// macOS's NFS client connects from the kernel as root, so neither the
/// socket's permissions nor the MOUNT call (always uid 0) say whose mount it
/// is. What does: the AUTH_SYS credential on each call is the user doing the
/// file access, or 0 for the kernel's own calls (mount setup, read-ahead).
/// So only the owner and root get through, and MOUNT only while msld itself
/// is mounting. A new mount by anyone else fails at MOUNT; another user's
/// access through the owner's mounts fails per call.
public enum RPCFilter {
    public static let mountProgram: UInt32 = 100_005
    public static let mountProcMNT: UInt32 = 1
    static let authNone: UInt32 = 0
    static let authSys: UInt32 = 1

    public enum Verdict: Equatable {
        case allow
        case deny(xid: UInt32, why: String)
    }

    /// Decide on one call, given the first fragment of its record.
    public static func check(_ call: [UInt8], owner: UInt32, mountAllowed: Bool) -> Verdict {
        func u32(_ o: Int) -> UInt32? {
            guard o + 4 <= call.count else { return nil }
            return UInt32(call[o]) << 24 | UInt32(call[o + 1]) << 16 | UInt32(call[o + 2]) << 8 | UInt32(call[o + 3])
        }
        guard let xid = u32(0) else { return .deny(xid: 0, why: "short record") }
        guard u32(4) == 0, u32(8) == 2, let prog = u32(12), let proc = u32(20), let flavor = u32(24), let credLen = u32(28) else {
            return .deny(xid: xid, why: "not an RPC v2 call")
        }
        if prog == mountProgram, proc == mountProcMNT, !mountAllowed {
            return .deny(xid: xid, why: "MOUNT outside msld's own mount")
        }
        switch flavor {
        case authNone:
            return proc == 0 ? .allow : .deny(xid: xid, why: "AUTH_NONE for procedure \(proc)")  // NULL pings only
        case authSys:
            // stamp, machinename<255>, uid, …
            guard let nameLen = u32(36), nameLen <= 255 else { return .deny(xid: xid, why: "bad AUTH_SYS") }
            let uidAt = 40 + Int((nameLen + 3) & ~3)
            guard uidAt + 4 <= 32 + Int(credLen), let uid = u32(uidAt) else { return .deny(xid: xid, why: "bad AUTH_SYS") }
            return uid == owner || uid == 0 ? .allow : .deny(xid: xid, why: "uid \(uid)")
        default:
            return .deny(xid: xid, why: "auth flavor \(flavor)")
        }
    }

    /// A complete record (with its record mark) rejecting call `xid`:
    /// MSG_DENIED, AUTH_ERROR, AUTH_TOOWEAK. The client reports EAUTH/EACCES.
    public static func denial(xid: UInt32) -> [UInt8] {
        let body: [UInt32] = [xid, 1 /* REPLY */, 1 /* MSG_DENIED */, 1 /* AUTH_ERROR */, 5 /* AUTH_TOOWEAK */]
        let mark: UInt32 = 0x8000_0000 | UInt32(body.count * 4)
        return ([mark] + body).flatMap { v in [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    }
}
