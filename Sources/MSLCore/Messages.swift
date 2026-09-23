import Foundation

// User-facing text. Wording follows wsl.exe (localization/strings/en-US/Resources.resw)
// with product names adapted: "Windows Subsystem for Linux" -> "macOS Subsystem for Linux",
// "wsl.exe" -> "msl".

public enum Messages {
    public static let product = "macOS Subsystem for Linux"
    public static let exe = "msl"

    public static let registeredDistrosHeader = "\(product) Distributions:"
    public static func printDistroDefault(_ name: String) -> String { "\(name) (Default)" }
    public static let noRunningDistro = "There are no running distributions."
    public static let noDefaultDistro = """
        \(product) has no installed distributions.
        You can resolve this by installing a distribution with the instructions below:

        Use '\(exe) --list --online' to list available distributions
        and '\(exe) --install <Distro>' to install.
        """
    public static let distroNotFound = "There is no distribution with the supplied name."
    public static let distroNameAlreadyExists = "A distribution with the supplied name already exists. Use --name to choose a different name."
    public static let distributionNameNeeded = "This distribution doesn't contain a default name. Use --name to choose the distribution name."
    public static let userNotFound = "User not found."
    public static let operationCompleted = "The operation completed successfully."
    public static let exportProgress = "Export in progress, this may take a few minutes."
    public static let importProgress = "Import in progress, this may take a few minutes."
    public static let importFailed = "Importing the distribution failed."
    public static let unregistering = "Unregistering."
    public static func installing(_ what: String) -> String { "Installing: \(what)" }
    public static func distributionInstalled(_ name: String) -> String {
        "Distribution successfully installed. It can be launched via '\(exe) -d \(name)'"
    }
    public static func launching(_ name: String) -> String { "Launching \(name)..." }
    public static func statusDefaultDistro(_ name: String) -> String { "Default Distribution: \(name)" }
    public static func statusDefaultVersion(_ v: Int) -> String { "Default Version: \(v)" }
    public static func invalidCommandLine(_ arg: String) -> String {
        "Invalid command line argument: \(arg)\nPlease use '\(exe) --help' to get a list of supported arguments."
    }
    public static func missingArgument(_ arg: String) -> String {
        "Command line argument \(arg) requires a value.\nPlease use '\(exe) --help' to get a list of supported arguments."
    }
    public static func invalidDistributionName(_ name: String) -> String { "Invalid distribution name: \"\(name)\"." }
    public static func unsupportedOnMacOS(_ arg: String) -> String { "'\(arg)' is not supported on macOS." }
    public static func notImplemented(_ arg: String) -> String { "'\(arg)' is not implemented yet in this version of \(exe)." }
    public static let wsl1NotSupported = "WSL1-style distributions are not supported on macOS; only version 2 is available."

    /// How msl reports a failure: the message, plus wsl.exe's `Error code: …` line
    /// only when asked for (MSL_ERROR_CODES=1), e.g. for bug reports or scripts.
    public static func failure(_ message: String, _ code: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let show = ["1", "true", "yes"].contains((environment["MSL_ERROR_CODES"] ?? "").lowercased())
        return show ? "\(message)\nError code: \(code)" : message
    }

    public static func versions(msl: String, kernel: String, macOS: String) -> String {
        "MSL version: \(msl)\nKernel version: \(kernel)\nmacOS version: \(macOS)"
    }

    public static let usage = """
        Usage: \(exe) [Argument] [Options...] [CommandLine]

        Arguments for running Linux binaries:

            If no command line is provided, \(exe) launches the default shell.

            --exec, -e <CommandLine>
                Execute the specified command without using the default Linux shell.

            --shell-type <standard|login|none>
                Execute the specified command with the provided shell type.

            --
                Pass the remaining command line as-is.

        Options:
            --cd <Directory>
                Sets the specified directory as the current working directory.
                If ~ is used the Linux user's home path will be used. The path is
                interpreted as an absolute Linux path; macOS paths are under /mnt/mac.

            --distribution, -d <DistroName>
                Run the specified distribution.

            --distribution-id <DistroGuid>
                Run the specified distribution ID.

            --user, -u <UserName>
                Run as the specified user.

        Arguments for managing \(product):

            --help
                Display usage information.

            --install [Distro] [Options...]
                Install a \(product) distribution.

                Options:
                    --from-file <Path>
                        Install a distribution from a local file.

                    --location <Location>
                        Set the install path for the distribution.

                    --name <Name>
                        Set the name of the distribution.

                    --no-launch, -n
                        Do not launch the distribution after install.

                    --version <Version>
                        Specifies the version to use for the new distribution.

            --shutdown
                Immediately terminates all running distributions and the
                lightweight utility virtual machine.

                Options:
                    --force
                        Terminate the virtual machine even if an operation is in progress. Can cause data loss.

            --status
                Show the status of \(product).

            --version, -v
                Display version information.

        Arguments for managing distributions in \(product):

            --export <Distro> <FileName> [Options]
                Exports the distribution to a tar file.
                The filename can be - for stdout.

                Options:
                    --format <Format>
                        Specifies the export format. Supported values: tar, tar.gz, tar.xz.

            --import <Distro> <InstallLocation> <FileName> [Options]
                Imports the specified tar file as a new distribution.
                The filename can be - for stdin.

                Options:
                    --version <Version>
                        Specifies the version to use for the new distribution.

            --list, -l [Options]
                Lists distributions.

                Options:
                    --all
                        List all distributions, including distributions that are
                        currently being installed or uninstalled.

                    --running
                        List only distributions that are currently running.

                    --quiet, -q
                        Only show distribution names.

                    --verbose, -v
                        Show detailed information about all distributions.

            --set-default, -s <Distro>
                Sets the distribution as the default.

            --terminate, -t <Distro>
                Terminates the specified distribution.

            --unregister <Distro>
                Unregisters the distribution and deletes the root filesystem.
        """
}

/// Error codes, formatted like wsl.exe's `Wsl/<Component>/<Name>`.
public enum ErrorCode {
    public static let distroNotFound = "Msl/Service/MSL_E_DISTRO_NOT_FOUND"
    public static let alreadyExists = "Msl/Service/RegisterDistro/ERROR_ALREADY_EXISTS"
    public static let nameNeeded = "Msl/Service/RegisterDistro/MSL_E_DISTRO_NAME_NEEDED"
    public static let invalidName = "Msl/Service/RegisterDistro/MSL_E_INVALID_DISTRO_NAME"
    public static let userNotFound = "Msl/Service/CreateInstance/MSL_E_USER_NOT_FOUND"
    public static let noDistros = "Msl/Service/MSL_E_DEFAULT_DISTRO_NOT_FOUND"
    public static let importFailed = "Msl/Service/RegisterDistro/MSL_E_IMPORT_FAILED"
    public static let unsupported = "Msl/MSL_E_NOT_SUPPORTED"
    public static let invalidArgument = "Msl/E_INVALIDARG"
    public static let vm = "Msl/Service/CreateInstance/MSL_E_VM_START_FAILED"
    public static let service = "Msl/Service/E_UNEXPECTED"
    public static let fileNotFound = "Msl/ERROR_FILE_NOT_FOUND"
}
