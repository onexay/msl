// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import MSLCore

@Suite struct ArgumentsTests {
    func run(_ a: [String]) throws -> RunSpec {
        guard case .run(let s) = try Arguments.parse(a) else { Issue.record("not a run: \(a)"); return RunSpec() }
        return s
    }

    @Test func noArgsIsDefaultShell() throws {
        let s = try run([])
        #expect(s.commandLine == nil && s.argv.isEmpty && s.distribution == nil)
    }

    @Test func runOptionsThenCommand() throws {
        let s = try run(["-d", "Ubuntu", "-u", "root", "--cd", "/tmp", "ls", "-la"])
        #expect(s.distribution == "Ubuntu")
        #expect(s.user == "root")
        #expect(s.cd == "/tmp")
        #expect(s.commandLine == "ls -la")
        #expect(s.shellType == .standard)
    }

    @Test func tildeOnlyAsFirstArgument() throws {
        #expect(try run(["~"]).cd == "~")
        #expect(try run(["echo", "~"]).commandLine == "echo ~")
    }

    @Test func execTakesArgvVerbatim() throws {
        let s = try run(["-d", "D", "-e", "echo", "a b", "-d"])
        #expect(s.shellType == .none)
        #expect(s.argv == ["echo", "a b", "-d"])
        #expect(s.commandLine == nil)
    }

    @Test func doubleDashPassesRestAsCommand() throws {
        #expect(try run(["--", "-x", "y"]).commandLine == "-x y")
        #expect(try run(["--shell-type", "none", "--", "ls", "/"]).argv == ["ls", "/"])
        #expect(try run(["--shell-type", "login", "--", "env"]).shellType == .login)
    }

    @Test func commandLineQuotesWhitespaceOnly() {
        #expect(Arguments.joinCommandLine(["echo", "a b", "$HOME", "", "it's x"]) == "echo 'a b' $HOME '' 'it'\\''s x'")
    }

    @Test func errors() {
        #expect(throws: ArgumentError.missingValue("-d")) { try Arguments.parse(["-d"]) }
        #expect(throws: ArgumentError.invalid("--bogus")) { try Arguments.parse(["--bogus"]) }
        #expect(throws: ArgumentError.missingValue("-e")) { try Arguments.parse(["-e"]) }
        #expect(throws: ArgumentError.invalid("-x")) { try Arguments.parse(["--list", "-x"]) }
        #expect(throws: ArgumentError.invalid("extra")) { try Arguments.parse(["--terminate", "a", "extra"]) }
    }

    @Test func management() throws {
        #expect(try Arguments.parse(["-l", "-v"]) == .list({ var l = ListSpec(); l.verbose = true; return l }()))
        #expect(try Arguments.parse(["--list", "--running", "--quiet"]) == .list({ var l = ListSpec(); l.running = true; l.quiet = true; return l }()))
        #expect(try Arguments.parse(["-t", "Ubuntu"]) == .terminate("Ubuntu"))
        #expect(try Arguments.parse(["-s", "Ubuntu"]) == .setDefault("Ubuntu"))
        #expect(try Arguments.parse(["--shutdown", "--force"]) == .shutdown(force: true))
        #expect(try Arguments.parse(["--export", "U", "-", "--format", "tar.gz"]) == .export(distribution: "U", file: "-", format: "tar.gz"))
        #expect(try Arguments.parse(["--import", "U", "/loc", "f.tar", "--version", "2"])
            == .importTar(distribution: "U", location: "/loc", file: "f.tar", version: 2, vhd: false))
        #expect(try Arguments.parse(["-v"]) == .version)
        #expect(try Arguments.parse(["--system"]) == .unsupported("--system"))
        #expect(try Arguments.parse(["--debug-shell"]) == .debugShell)
        #expect(try Arguments.parse(["--unmount"]) == .unmount(nil))
        #expect(try Arguments.parse(["--update", "--pre-release"]) == .update(preRelease: true))
        #expect(try Arguments.parse(["--uninstall"]) == .uninstall)
        #expect(versionIsNewer("0.10.0", than: "0.9.3") && !versionIsNewer("0.1.0", than: "0.1.0") && versionIsNewer("1.0", than: "0.9.9"))
        guard case .mount(let m) = try Arguments.parse(["--mount", "d.img", "--vhd", "--name", "data", "-t", "xfs", "-o", "ro", "--partition", "2"]) else { Issue.record("mount"); return }
        #expect(m.disk == "d.img" && m.vhd && m.name == "data" && m.type == "xfs" && m.options == "ro" && m.partition == 2)
    }

    @Test func install() throws {
        guard case .install(let i) = try Arguments.parse(["--install", "--from-file", "u.wsl", "--name", "U2", "-n", "--location", "/x"]) else {
            Issue.record("not install"); return
        }
        #expect(i.fromFile == "u.wsl" && i.name == "U2" && i.noLaunch && i.location == "/x")
        guard case .install(let j) = try Arguments.parse(["--install", "Ubuntu"]) else { Issue.record("not install"); return }
        #expect(j.distribution == "Ubuntu")
    }
}

@Suite struct ListFormatTests {
    let d = [
        DistroSummary(name: "Ubuntu-24.04", id: "a", running: true, version: 2, isDefault: true),
        DistroSummary(name: "Debian", id: "b", running: false, version: 2, isDefault: false),
    ]

    @Test func plain() {
        #expect(ListFormat.render(d, ListSpec()).text == "Modern Subsystem for Linux Distributions:\nUbuntu-24.04 (Default)\nDebian")
    }

    @Test func verbose() {
        var s = ListSpec(); s.verbose = true
        #expect(ListFormat.render(d, s).text == """
              NAME            STATE           VERSION
            * Ubuntu-24.04    Running         2
              Debian          Stopped         2
            """)
    }

    @Test func runningAndEmpty() {
        var s = ListSpec(); s.running = true; s.quiet = true
        #expect(ListFormat.render(d, s).text == "Ubuntu-24.04")
        #expect(ListFormat.render([], s).text == Messages.noRunningDistro)
        #expect(ListFormat.render([], ListSpec()).isError)
    }
}

@Suite struct MessagesTests {
    @Test func errorCodeOnlyWhenRequested() {
        #expect(Messages.failure("Oops.", "Msl/X", environment: [:]) == "Oops.")
        #expect(Messages.failure("Oops.", "Msl/X", environment: ["MSL_ERROR_CODES": "1"]) == "Oops.\nError code: Msl/X")
    }
}

@Suite struct RegistryTests {
    @Test func namesAndDefault() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("msl-reg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = Registry(url: url)
        try r.mutate { $0.distros.append(DistroRecord(id: "1", name: "Ubuntu", location: "/x")) }
        #expect(r.find(name: "ubuntu")?.id == "1")
        #expect(r.defaultDistro?.name == "Ubuntu")
        #expect(Registry(url: url).all.count == 1)  // persisted
        #expect(Registry.isValidName("Ubuntu-24.04_x"))
        #expect(!Registry.isValidName("bad name") && !Registry.isValidName("a/b") && !Registry.isValidName(""))
    }
}

@Suite struct IPCTests {
    @Test func framesAndFdPassing() throws {
        var sv: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0)
        let a = IPCConnection(fd: sv[0]), b = IPCConnection(fd: sv[1])
        var p: [Int32] = [0, 0]
        #expect(pipe(&p) == 0)
        try a.send(Request.terminate(name: "U"), fds: [p[1]])
        let (req, fds) = try b.receive(Request.self)
        guard case .terminate(let n) = req else { Issue.record("wrong request"); return }
        #expect(n == "U" && fds.count == 1)
        // The passed fd is a working duplicate of the pipe's write end.
        #expect(write(fds[0], "hi", 2) == 2)
        var buf = [UInt8](repeating: 0, count: 2)
        #expect(read(p[0], &buf, 2) == 2 && buf == Array("hi".utf8))
        close(fds[0]); close(p[0]); close(p[1])
    }
}

@Suite struct ConfigTests {
    @Test func mslconfig() {
        let c = MSLConfig.parse("""
            [wsl2]
            memory=8GB
            processors = 4
            vmIdleTimeout=-1
            memory2 = x
            processors=abc
            [general]
            instanceIdleTimeout=5000
            """, path: "t")
        #expect(c.memoryBytes == 8 << 30)
        #expect(c.processors == 4)
        #expect(c.vmIdleTimeoutMs == -1)
        #expect(c.instanceIdleTimeoutMs == 5000)
        #expect(c.warnings == ["Invalid integer 'abc' for .mslconfig entry 'wsl2.processors' in t:6"])
        #expect(MSLConfig.parseSize("512MB") == 512 << 20 && MSLConfig.parseSize("1024") == 1024 && MSLConfig.parseSize("x") == nil)
    }

    @Test func manifest() throws {
        let json = """
            {"ModernDistributions": {
              "Ubuntu": [{"Name":"Ubuntu","FriendlyName":"Ubuntu","Default":true,"Arm64Url":{"Url":"u","Sha256":"h"}},
                         {"Name":"Ubuntu-24.04","FriendlyName":"Ubuntu 24.04 LTS","Arm64Url":{"Url":"u2","Sha256":"h2"}}],
              "archlinux": [{"Name":"archlinux","FriendlyName":"Arch Linux","Amd64Url":{"Url":"a","Sha256":"x"}}]},
             "Default": "Ubuntu"}
            """
        let m = try Manifest.parse(Data(json.utf8))
        #expect(m.resolve(nil)?.Name == "Ubuntu")
        #expect(m.resolve("ubuntu-24.04")?.Name == "Ubuntu-24.04")
        #expect(m.resolve("nope") == nil)
        #expect(m.installable.map(\.Name) == ["Ubuntu", "Ubuntu-24.04"])  // amd64-only arch is not listed
        #expect(m.onlineListing().contains("Ubuntu-24.04    Ubuntu 24.04 LTS"))
    }
}

@Suite struct StatusTests {
    let base = VMSettings(memoryBytes: 8 << 30, processors: 4, kernel: "6.18.15-msl (bundled)", kernelCommandLine: "console=hvc0",
                          localhostForwarding: true, dnsTunneling: true, vmIdleTimeoutMs: 60_000, instanceIdleTimeoutMs: -1)

    @Test func runningWithPendingChanges() {
        var next = base
        next.memoryBytes = 4 << 30
        next.dnsTunneling = false
        let s = VMStatus(running: true, uptimeSeconds: 125, effective: base, configured: next, configPath: "/Users/u/.mslconfig", configExists: true)
        let text = StatusFormat.render(defaultDistro: "Ubuntu", s, home: "/Users/u")
        #expect(text.hasPrefix("Default Distribution: Ubuntu\nDefault Version: 2\n"))
        #expect(text.contains("Virtual machine: Running (up 2m 5s)"))
        let row = { (k: String) in text.split(separator: "\n").first { $0.hasPrefix("  \(k):") }.map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) } }
        #expect(row("Memory") == "8 GB")
        #expect(row("Distribution idle timeout") == "never")
        #expect(text.contains("Pending changes in ~/.mslconfig (applied after 'msl --shutdown'):"))
        #expect(text.contains("Memory: 8 GB → 4 GB") && text.contains("DNS tunneling: on → off"))
    }

    @Test func stoppedShowsNextStart() {
        let s = VMStatus(running: false, uptimeSeconds: nil, effective: nil, configured: base, configPath: "/Users/u/.mslconfig", configExists: false)
        let text = StatusFormat.render(defaultDistro: "Debian", s, home: "/Users/u")
        #expect(text.contains("Virtual machine: Stopped"))
        #expect(text.contains("~/.mslconfig (not present; defaults)"))
        #expect(!text.contains("Pending"))
        #expect(StatusFormat.bytes(1536 << 20) == "1.5 GB" && StatusFormat.timeout(500) == "500 ms")
    }
}

@Suite struct JSONOutputTests {
    let distros = [DistroSummary(name: "Ubuntu", id: "u-1", running: true, version: 2, isDefault: true),
                   DistroSummary(name: "Debian", id: "d-1", running: false, version: 2, isDefault: false)]

    @Test func parsesJSONFlagOnlyForQueries() throws {
        #expect(try Arguments.parseInvocation(["--list", "-v", "--json"]) == Invocation(command: .list({ var s = ListSpec(); s.verbose = true; return s }()), json: true))
        #expect(try Arguments.parseInvocation(["--json", "--status"]) == Invocation(command: .status, json: true))
        #expect(try Arguments.parseInvocation(["-v", "--json"]).json)
        #expect(try Arguments.parseInvocation(["--list"]).json == false)
        // Other commands reject it, however it's placed.
        #expect(throws: ArgumentError.jsonUnsupported) { try Arguments.parseInvocation(["--terminate", "Ubuntu", "--json"]) }
        #expect(throws: ArgumentError.jsonUnsupported) { try Arguments.parseInvocation(["--json", "-e", "ls"]) }
        #expect(throws: ArgumentError.jsonUnsupported) { try Arguments.parseInvocation(["--json"]) }
        // Inside a Linux command line it belongs to the program.
        let run = try Arguments.parseInvocation(["-d", "Ubuntu", "-e", "jq", "--json"])
        #expect(run.json == false)
        if case .run(let spec) = run.command { #expect(spec.argv == ["jq", "--json"]) } else { Issue.record("expected run") }
    }

    @Test func listFollowsFiltersAndWSLErrors() throws {
        var spec = ListSpec()
        #expect(JSONOutput.list(distros, spec)?.distributions.map(\.name) == ["Ubuntu", "Debian"])
        spec.running = true
        let running = try #require(JSONOutput.list(distros, spec))
        #expect(running.distributions == [.init(name: "Ubuntu", id: "u-1", state: "Running", version: 2, default: true)])
        // Nothing installed is an error (as in wsl.exe); nothing running is an empty list.
        #expect(JSONOutput.list([], ListSpec()) == nil)
        #expect(JSONOutput.list([distros[1]], spec)?.distributions == [])
        let text = JSONOutput.encode(running, pretty: false)
        #expect(text == #"{"distributions":[{"default":true,"id":"u-1","name":"Ubuntu","state":"Running","version":2}],"schema":1}"#)
    }

    @Test func onlineMarksArchitectures() throws {
        let json = """
            {"ModernDistributions": {"Ubuntu": [
              {"Name": "Ubuntu", "FriendlyName": "Ubuntu", "Default": true, "Arm64Url": {"Url": "u", "Sha256": "s"}, "Amd64Url": {"Url": "u", "Sha256": "s"}}],
             "arch": [{"Name": "archlinux", "FriendlyName": "Arch Linux", "Amd64Url": {"Url": "u", "Sha256": "s"}}]},
             "Default": "Ubuntu"}
            """
        let m = try Manifest.parse(Data(json.utf8))
        #expect(JSONOutput.online(m, rosetta: false).distributions.map(\.name) == ["Ubuntu"])
        let all = JSONOutput.online(m, rosetta: true).distributions
        #expect(all[0] == .init(name: "Ubuntu", friendlyName: "Ubuntu", architectures: ["arm64", "x86_64"], emulated: false, default: true))
        #expect(all[1].emulated && all[1].architectures == ["x86_64"] && !all[1].default)
    }

    @Test func statusHasRawValuesAndPendingChanges() {
        let a = VMSettings(memoryBytes: 8 << 30, processors: 4, kernel: "k", kernelCommandLine: "c",
                           localhostForwarding: true, dnsTunneling: true, vmIdleTimeoutMs: 60_000, instanceIdleTimeoutMs: 15_000)
        var b = a
        b.memoryBytes = 4 << 30
        b.dnsTunneling = false
        let s = VMStatus(running: true, uptimeSeconds: 1.5, effective: a, configured: b, configPath: "/x/.mslconfig", configExists: true)
        let j = JSONOutput.status(defaultDistro: "Ubuntu", s, warnings: ["bad key"])
        #expect(j.vm.uptimeMs == 1500 && j.vm.settings == a && j.warnings == ["bad key"])
        #expect(j.vm.pendingChanges == [.init(setting: "dnsTunneling", from: "true", to: "false"),
                                        .init(setting: "memoryBytes", from: "\(8 << 30)", to: "\(4 << 30)")])
        // Stopped: no uptime field at all, no pending changes.
        let stopped = JSONOutput.status(defaultDistro: "Ubuntu", VMStatus(running: false, uptimeSeconds: nil, effective: nil, configured: b, configPath: "/x", configExists: false), warnings: [])
        let text = JSONOutput.encode(stopped, pretty: false)
        #expect(!text.contains("uptimeMs") && !text.contains("null") && text.contains(#""schema":1"#) && stopped.vm.pendingChanges.isEmpty)
    }

    @Test func errorShape() {
        let text = JSONOutput.encode(JSONOutput.Failure(error: .init(message: "No.", code: ErrorCode.noDistros)), pretty: false)
        #expect(text == #"{"error":{"code":"Msl/Service/MSL_E_DEFAULT_DISTRO_NOT_FOUND","message":"No."},"schema":1}"#)
    }
}
