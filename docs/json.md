# JSON output

The query commands can print JSON instead of text, for scripts, editors and CI. Add `--json`:

| Command | JSON |
|---|---|
| `msl --list` (`-l`), with `--all`, `--running`, `--verbose`, `--quiet` | the installed distributions |
| `msl --list --online` | distributions available to install |
| `msl --status` | the default distribution and the VM's state and settings |
| `msl --version` | msl, kernel and macOS versions |

`--json` can go anywhere among these commands' options (`msl -l -v --json`), or first (`msl --json --status`). WSL has no JSON output: this is an msl extension, and without `--json` the output is exactly wsl.exe's.

Other commands, such as install, terminate and shutdown, don't take `--json`: their exit code says whether they worked, and they reject `--json` with an error. A `--json` in a Linux command line belongs to that program: `msl -e jq --json …`.

## Conventions

- **One object on stdout**, ending with a newline. It's pretty-printed on a terminal and compact when piped, with keys sorted.
- **`"schema": 1`** at the top level. It changes only for breaking changes. New fields can appear at any time, so ignore ones you don't know.
- **Field names are camelCase.** A field whose value is unknown is left out, never `null`: for example, `uptimeMs` is missing when the VM is stopped.
- **Numbers are raw:** sizes in bytes, times in milliseconds.
- **Exit codes are wsl.exe's.** JSON changes the format, never the exit code. For example, `msl --list --json` with nothing installed fails (exit code 255), as `wsl --list` does.
- **Errors go to stderr** as a JSON object, and stdout stays empty:

  ```json
  {"error": {"code": "Msl/Service/MSL_E_DEFAULT_DISTRO_NOT_FOUND", "message": "Modern Subsystem for Linux has no installed distributions.\n…"}, "schema": 1}
  ```

  The `code` is always included, whether or not `MSL_ERROR_CODES` is set.

## `msl --list --json`

```json
{
  "distributions": [
    {"default": true, "id": "0f2b9f9d-00b0-407f-8d90-6a6a7fa65dbc", "name": "Debian", "state": "Running", "version": 2}
  ],
  "schema": 1
}
```

- `state` is `Running` or `Stopped`, as in `msl -l -v`.
- `--running` and `--all` filter as usual. `--verbose` and `--quiet` make no difference.
- With nothing running, `--running --json` prints an empty list and exits 0. With nothing installed, `--list --json` is an error.

## `msl --list --online --json`

```json
{
  "distributions": [
    {"architectures": ["arm64", "x86_64"], "default": true, "emulated": false, "friendlyName": "Ubuntu", "name": "Ubuntu"},
    {"architectures": ["arm64", "x86_64"], "default": false, "emulated": false, "friendlyName": "Ubuntu 26.04 LTS", "name": "Ubuntu-26.04"}
  ],
  "schema": 1
}
```

- The list holds the distributions this Mac can install: every arm64 image, plus x86_64-only images when an emulator is available.
- `emulated` is true for an x86_64-only image.
- `default` marks the one `msl --install` picks when no name is given.

## `msl --status --json`

```json
{
  "defaultDistribution": "Debian",
  "defaultVersion": 2,
  "schema": 1,
  "vm": {
    "pendingChanges": [],
    "running": true,
    "settings": {
      "dnsTunneling": true,
      "instanceIdleTimeoutMs": 15000,
      "kernel": "6.18.15-msl (bundled)",
      "kernelCommandLine": "console=hvc0 ip=dhcp net.ifnames=0 loglevel=4",
      "localhostForwarding": true,
      "memoryBytes": 19327352832,
      "processors": 12,
      "vmIdleTimeoutMs": 60000
    },
    "settingsFile": "/Users/you/.mslconfig",
    "settingsFileExists": true,
    "uptimeMs": 2517
  },
  "warnings": []
}
```

- `vm.settings` holds what the running VM booted with. When the VM is stopped, it holds what the next start will use.
- `vm.pendingChanges` lists `.mslconfig` changes that apply after `msl --shutdown`, e.g. `{"setting": "memoryBytes", "from": "8589934592", "to": "4294967296"}`.
- A timeout of `-1` means "never".
- `warnings` holds the `.mslconfig` problems that text mode prints to stderr.

## `msl --version --json`

```json
{"kernel": "6.18.15-msl", "macOS": "27.0.0", "msl": "0.1.2", "prefix": "/Users/you/.local", "schema": 1}
```

`prefix` is where msl is installed. It's missing for a development build.
