// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import SystemConfiguration

/// Host network values that MSL mirrors into new distro sessions.
public enum MacHostNetworkSettings {
    public static func proxyEnvironment() -> ProxyEnvironment {
        let values = (SCDynamicStoreCopyProxies(nil) as NSDictionary?) as? [String: Any] ?? [:]
        return ProxyEnvironment.make(from: values)
    }

    /// The unscoped DNS servers macOS publishes for the active network.
    public static func dnsServers() -> [String] {
        guard let store = SCDynamicStoreCreate(kCFAllocatorDefault, "msld" as CFString, nil, nil),
              let raw = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString),
              let values = raw as? [String: Any],
              let servers = values[kSCPropNetDNSServerAddresses as String] as? [String] else { return [] }
        return servers.filter(isIPAddress)
    }

    private static func isIPAddress(_ value: String) -> Bool {
        value.withCString { address in
            var v4 = in_addr()
            if inet_pton(AF_INET, address, &v4) == 1 { return true }
            var v6 = in6_addr()
            return inet_pton(AF_INET6, address, &v6) == 1
        }
    }
}

/// Environment variables synthesized from SCDynamicStoreCopyProxies.
public struct ProxyEnvironment: Equatable, Sendable {
    public var values: [String: String]
    public var warnings: [String]

    public static func make(from settings: [String: Any]) -> ProxyEnvironment {
        var values: [String: String] = [:]
        var warnings: [String] = []

        for (name, enabledKey, hostKey, portKey) in [
            ("HTTP", kSCPropNetProxiesHTTPEnable, kSCPropNetProxiesHTTPProxy, kSCPropNetProxiesHTTPPort),
            ("HTTPS", kSCPropNetProxiesHTTPSEnable, kSCPropNetProxiesHTTPSProxy, kSCPropNetProxiesHTTPSPort),
        ] {
            guard (settings[enabledKey as String] as? NSNumber)?.boolValue == true,
                  let host = settings[hostKey as String] as? String, !host.isEmpty,
                  let port = settings[portKey as String] as? NSNumber,
                  (1...65535).contains(port.intValue) else { continue }
            guard !isLoopback(host) else {
                warnings.append("Mac \(name) proxy at \(host) is on loopback and can't be reached from the distro; skipping it.")
                continue
            }
            let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            // Both System Configuration proxy entries describe HTTP proxy servers;
            // HTTPS selects the destination traffic, not TLS to the proxy itself.
            setPair("\(name.lowercased())_proxy", value: "http://\(authority):\(port.intValue)", in: &values)
        }

        if let exceptions = settings[kSCPropNetProxiesExceptionsList as String] as? [String] {
            let noProxy = exceptions.filter { !$0.isEmpty }.joined(separator: ",")
            if !noProxy.isEmpty { setPair("no_proxy", value: noProxy, in: &values) }
        }

        if (settings[kSCPropNetProxiesProxyAutoConfigEnable as String] as? NSNumber)?.boolValue == true,
           let pac = settings[kSCPropNetProxiesProxyAutoConfigURLString as String] as? String,
           let components = URLComponents(string: pac), let host = components.host, !host.isEmpty {
            if isLoopback(host) {
                warnings.append("Mac proxy auto-config URL at \(host) is on loopback and can't be reached from the distro; skipping it.")
            } else {
                values["MSL_PAC_URL"] = pac
                values["WSL_PAC_URL"] = pac
            }
        }

        return ProxyEnvironment(values: values, warnings: warnings)
    }

    private static func setPair(_ key: String, value: String, in env: inout [String: String]) {
        env[key] = value
        env[key.uppercased()] = value
    }

    private static func isLoopback(_ host: String) -> Bool {
        let unwrapped = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let normalized = unwrapped.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if normalized == "localhost" || normalized.hasSuffix(".localhost") { return true }
        return unwrapped.withCString { address in
            var v4 = in_addr()
            if inet_pton(AF_INET, address, &v4) == 1 {
                return UInt32(bigEndian: v4.s_addr) >> 24 == 127
            }
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
            return withUnsafeBytes(of: &v6) { bytes in
                bytes.count == 16 && bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
            }
        }
    }
}
