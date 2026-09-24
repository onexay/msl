// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A registered distribution (the equivalent of a key under HKCU\...\Lxss).
public struct DistroRecord: Codable, Equatable, Sendable {
    public var id: String              // lowercase GUID; also the on-disk directory name
    public var name: String
    public var version: Int = 2
    public var defaultUid: UInt32 = 0
    public var location: String        // --import/--install location (recorded; storage is the shared data disk)
    public var oobeCommand: String = ""
    public var oobeDefaultUid: UInt32?
    public var oobePending: Bool = false
    public var createdAt: Date = Date()

    public init(id: String, name: String, location: String) {
        self.id = id
        self.name = name
        self.location = location
    }
}

public struct RegistryData: Codable, Equatable, Sendable {
    public var defaultId: String?
    public var distros: [DistroRecord] = []
    public init() {}
}

/// JSON-file registry. Only msld writes it.
public final class Registry: @unchecked Sendable {
    public let url: URL
    public private(set) var data: RegistryData
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
        if let raw = try? Data(contentsOf: url), let d = try? Registry.decoder.decode(RegistryData.self, from: raw) {
            data = d
        } else {
            data = RegistryData()
        }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Distribution names are matched case-insensitively (as in WSL).
    public func find(name: String) -> DistroRecord? {
        lock.withLock { data.distros.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    }

    public func find(id: String) -> DistroRecord? {
        lock.withLock { data.distros.first { $0.id.caseInsensitiveCompare(id) == .orderedSame } }
    }

    public var defaultDistro: DistroRecord? {
        lock.withLock {
            data.distros.first { $0.id == data.defaultId } ?? data.distros.first
        }
    }

    public var all: [DistroRecord] { lock.withLock { data.distros } }

    public func mutate(_ body: (inout RegistryData) throws -> Void) throws {
        try lock.withLock {
            var copy = data
            try body(&copy)
            if copy.defaultId == nil || !copy.distros.contains(where: { $0.id == copy.defaultId }) {
                copy.defaultId = copy.distros.first?.id
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Registry.encoder.encode(copy).write(to: url, options: .atomic)
            data = copy
        }
    }

    public func update(id: String, _ body: (inout DistroRecord) -> Void) throws {
        try mutate { d in
            if let i = d.distros.firstIndex(where: { $0.id == id }) { body(&d.distros[i]) }
        }
    }

    /// WSL's rule for distribution names.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}
