// SPDX-License-Identifier: Apache-2.0
/// `msl --list` output, laid out like wsl.exe.
public enum ListFormat {
    public static func render(_ distros: [DistroSummary], _ spec: ListSpec) -> (text: String, isError: Bool) {
        var rows = distros
        if spec.running { rows = rows.filter(\.running) }

        if rows.isEmpty {
            if spec.running { return (Messages.noRunningDistro, false) }
            return (Messages.noDefaultDistro, true)
        }
        if spec.quiet {
            return (rows.map(\.name).joined(separator: "\n"), false)
        }
        if spec.verbose {
            // "  NAME<pad>STATE<pad>VERSION" with NAME column = longest name + 4.
            let nameWidth = max(rows.map(\.name.count).max() ?? 0, 4) + 4
            let stateWidth = 16
            func pad(_ s: String, _ w: Int) -> String { s + String(repeating: " ", count: max(w - s.count, 1)) }
            var lines = ["  " + pad("NAME", nameWidth) + pad("STATE", stateWidth) + "VERSION"]
            for d in rows {
                let mark = d.isDefault ? "* " : "  "
                lines.append(mark + pad(d.name, nameWidth) + pad(d.running ? "Running" : "Stopped", stateWidth) + String(d.version))
            }
            return (lines.joined(separator: "\n"), false)
        }
        var lines = [Messages.registeredDistrosHeader]
        for d in rows {
            lines.append(d.isDefault ? Messages.printDistroDefault(d.name) : d.name)
        }
        return (lines.joined(separator: "\n"), false)
    }
}
