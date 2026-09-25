// SPDX-License-Identifier: Apache-2.0

/// The header line on msld's connect socket (MSLService/Connect.swift):
/// `CONNECT distro=<name> unix=<absolute path>` or `CONNECT distro=<name> tcp=<port>`.
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

    public init?(line: String) {
        let prefix = "CONNECT distro="
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        guard let sp = rest.firstIndex(of: " "), sp > rest.startIndex else { return nil }
        let arg = rest[rest.index(after: sp)...]
        if arg.hasPrefix("unix="), arg.dropFirst(5).hasPrefix("/") {
            target = .unix(String(arg.dropFirst(5)))
        } else if arg.hasPrefix("tcp="), let port = UInt16(arg.dropFirst(4)), port > 0 {
            target = .tcp(port)
        } else {
            return nil
        }
        distro = String(rest[..<sp])
    }
}
