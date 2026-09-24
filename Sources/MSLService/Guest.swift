// SPDX-License-Identifier: Apache-2.0
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import MSLCore
import MSLProtocol

typealias Transport = HTTP2ClientTransport.Posix

/// gRPC clients for guest vsock ports, reached through VMHost's Unix-socket bridges.
final class GuestClients: @unchecked Sendable {
    private let vm: VMHost
    private var clients: [UInt32: (GRPCClient<Transport>, Task<Void, Never>)] = [:]
    private let lock = NSLock()

    init(vm: VMHost) {
        self.vm = vm
    }

    func client(port: UInt32) throws -> GRPCClient<Transport> {
        let path = try vm.bridgePath(port: port)
        return try lock.withLock {
            if let (c, _) = clients[port] { return c }
            // The default :authority would be the socket path, which hyper (tonic) rejects.
            let transport = try Transport(target: .unixDomainSocket(path: path, authority: "msl-guest"), transportSecurity: .plaintext)
            let c = GRPCClient(transport: transport)
            let task = Task { do { try await c.runConnections() } catch {} }
            clients[port] = (c, task)
            return c
        }
    }

    var miniInit: Msl_V1_MiniInit.Client<Transport> {
        get throws { Msl_V1_MiniInit.Client(wrapping: try client(port: VMHost.controlPort)) }
    }

    func agent(port: UInt32) throws -> Msl_V1_Agent.Client<Transport> {
        Msl_V1_Agent.Client(wrapping: try client(port: port))
    }

    /// Forget all clients (VM stopped).
    func reset() {
        let old = lock.withLock { () -> [(GRPCClient<Transport>, Task<Void, Never>)] in
            defer { clients.removeAll() }
            return Array(clients.values)
        }
        for (c, t) in old {
            c.beginGracefulShutdown()
            t.cancel()
        }
    }

    /// Wait until MiniInit answers (after boot).
    func waitForMiniInit(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Error?
        while Date() < deadline {
            do {
                let mini = try miniInit
                _ = try blocking {
                    try await mini.ping(Msl_V1_Empty(), options: {
                        var o = CallOptions.defaults
                        o.timeout = .milliseconds(500)
                        return o
                    }())
                }
                return
            } catch {
                last = error
                usleep(50_000)
            }
        }
        throw ServiceError("The utility VM did not start: \(last.map { "\($0)" } ?? "timeout")", code: ErrorCode.vm)
    }
}
