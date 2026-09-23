import Foundation

/// Where MSL keeps its state. Overridable with MSL_HOME (used by tests).
public struct Paths: Sendable {
    public let root: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let home = environment["MSL_HOME"], !home.isEmpty {
            root = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/msl", isDirectory: true)
        }
    }

    public var registry: URL { root.appendingPathComponent("registry.json") }
    public var dataDisk: URL { root.appendingPathComponent("data.img") }
    public var socket: URL { root.appendingPathComponent("msld.sock") }
    public var log: URL { root.appendingPathComponent("msld.log") }
    public var runDir: URL { root.appendingPathComponent("run", isDirectory: true) }
    public var consoleLog: URL { root.appendingPathComponent("console.log") }
}
