// SPDX-License-Identifier: Apache-2.0
import Foundation

/// msld <-> its relay helpers, which copy bytes between macOS sockets and the
/// guest so that msld doesn't: msl-portd (localhost forwarding, like WSL's
/// wslrelay.exe) and msl-fileviewd (the ~/.msl/distros NFS view). msld starts a
/// helper with one end of a socketpair as its fd 3 (`relayControlFD`) and talks
/// IPCConnection frames over it, with file descriptors via SCM_RIGHTS.
public enum RelayMessage: Codable, Sendable {
    /// msld: listening sockets (attached), whose connections go to the guest's
    /// localhost:`port`.
    case listen(port: UInt16)
    /// msld: stop accepting on `port`; its connections carry on.
    case unlisten(port: UInt16)
    /// helper: a connection to `port` arrived. msld replies `.connected` with a
    /// framed vsock stream to the guest forwarder attached, or `.refused`.
    case connect(id: UInt64, port: UInt16)
    case connected(id: UInt64)
    case refused(id: UInt64)
    /// helper: connection `id` has ended. msld keeps its own descriptor of the
    /// (host-initiated) vsock stream until then. Releasing it once the helper
    /// had received it (IPCConnection.sendRetaining) still lost about 0.4% of
    /// connections under load, which held to the end lost none; the cause is
    /// inside Virtualization.framework.
    case closed(id: UInt64)
    /// msld -> msl-fileviewd: accept NFS MOUNT calls, only while msld runs
    /// mount_nfs (RPCFilter). msl-fileviewd answers `.mountWindowSet` once
    /// applied, so the mount's first call already sees it.
    case mountWindow(open: Bool)
    case mountWindowSet(open: Bool)
}

/// The fd a relay helper finds its control socket on.
public let relayControlFD: Int32 = 3
