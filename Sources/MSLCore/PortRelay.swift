// SPDX-License-Identifier: Apache-2.0
import Foundation

/// msld <-> msl-portd, localhost forwarding's relay (WSL's wslrelay.exe).
/// msld starts msl-portd with one end of a socketpair as its fd 3 and talks
/// IPCConnection frames over it, with file descriptors via SCM_RIGHTS.
public enum PortRelayMessage: Codable, Sendable {
    /// msld: the listening sockets (attached) of a forwarded port, to accept on.
    case listen(port: UInt16)
    /// msld: stop accepting on `port`; its connections carry on.
    case unlisten(port: UInt16)
    /// msl-portd: a connection to `port` arrived. msld replies `.connected`
    /// with a framed vsock stream to the guest forwarder attached, or `.refused`.
    case connect(id: UInt64, port: UInt16)
    case connected(id: UInt64)
    case refused(id: UInt64)
    /// msl-portd: connection `id` has ended. msld keeps its own descriptor of
    /// the (host-initiated) vsock stream until then. Releasing it once
    /// msl-portd had received it (IPCConnection.sendRetaining) still lost about
    /// 0.4% of connections under load, which held to the end lost none; the
    /// cause is inside Virtualization.framework.
    case closed(id: UInt64)
}

/// The fd msl-portd finds its control socket on.
public let portRelayControlFD: Int32 = 3
