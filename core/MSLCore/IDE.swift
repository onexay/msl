// SPDX-License-Identifier: Apache-2.0

/// IDEs that can run the MSL extension (`msl --manage-ide`): VS Code and the
/// editors built from it, which share its extension and `argv.json` formats.
public struct IDE: Equatable, Sendable {
    /// `--ide` value.
    public let id: String
    public let aliases: [String]
    public let name: String
    /// Per-user data under ~ (extensions/, argv.json).
    public let configDir: String
    /// App bundle names, looked up in /Applications and ~/Applications.
    public let apps: [String]
    /// CLI inside the app bundle.
    public let bundleCLI: String
    /// CLI names on PATH.
    public let commands: [String]

    public static let extensionID = "onexay.msl"

    public static let all: [IDE] = [
        IDE(id: "vscode", aliases: ["code"], name: "Visual Studio Code", configDir: ".vscode",
            apps: ["Visual Studio Code.app"], bundleCLI: "Contents/Resources/app/bin/code", commands: ["code"]),
        IDE(id: "vscode-insiders", aliases: ["insiders"], name: "Visual Studio Code - Insiders", configDir: ".vscode-insiders",
            apps: ["Visual Studio Code - Insiders.app"], bundleCLI: "Contents/Resources/app/bin/code", commands: ["code-insiders"]),
        IDE(id: "vscode-oss", aliases: ["vscodium", "codium"], name: "VSCodium", configDir: ".vscode-oss",
            apps: ["VSCodium.app"], bundleCLI: "Contents/Resources/app/bin/codium", commands: ["codium"]),
        IDE(id: "cursor", aliases: [], name: "Cursor", configDir: ".cursor",
            apps: ["Cursor.app"], bundleCLI: "Contents/Resources/app/bin/cursor", commands: ["cursor"]),
    ]

    /// The IDE for an `--ide` value (id or alias, any case); nil if unknown.
    public static func named(_ s: String) -> IDE? {
        let s = s.lowercased()
        return all.first { $0.id == s || $0.aliases.contains(s) }
    }
}

/// `--manage-ide [--ide <ide>|all] [--install|--uninstall]`.
public struct ManageIDESpec: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case install, uninstall }
    /// An IDE id, "all", or nil (choose interactively).
    public var ide: String?
    public var action: Action?
    public init(ide: String? = nil, action: Action? = nil) {
        self.ide = ide
        self.action = action
    }
}
