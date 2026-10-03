// SPDX-License-Identifier: Apache-2.0

/// `msl --connect <distro> unix=<absolute path>|tcp=<port>`: a byte stream to a
/// Unix socket or a localhost TCP port in a distro (VS Code's managed pipes).
public struct ConnectRequest: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case unix(String)
        case tcp(UInt16)
    }

    public let distro: String
    public let target: Target

    public init(distro: String, target: Target) {
        self.distro = distro
        self.target = target
    }

    /// `target` is `unix=<absolute path>` or `tcp=<port>`.
    public init?(distro: String, target arg: String) {
        guard !distro.isEmpty else { return nil }
        if arg.hasPrefix("unix="), arg.dropFirst(5).hasPrefix("/") {
            target = .unix(String(arg.dropFirst(5)))
        } else if arg.hasPrefix("tcp="), let port = UInt16(arg.dropFirst(4)), port > 0 {
            target = .tcp(port)
        } else {
            return nil
        }
        self.distro = distro
    }
}
