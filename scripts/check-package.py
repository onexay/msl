#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Install and start an existing distributable without a VM or user state changes."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def check_package(archive, version, source):
    archive = Path(archive).resolve()
    with tarfile.open(archive, 'r:gz') as tar:
        prefix = f'msl-{version}'
        for member in tar.getmembers():
            parts = Path(member.name).parts
            if not parts or parts[0] != prefix or '..' in parts or not (member.isfile() or member.isdir()):
                raise ValueError(f'unexpected package entry: {member.name}')
    with tempfile.TemporaryDirectory(prefix='msl-pkg-', dir='/tmp') as scratch:
        scratch = Path(scratch)
        prefix = scratch / 'prefix'
        state = scratch / 'state'
        env = {key: value for key, value in os.environ.items() if not key.startswith('MSL_')}
        env.update(MSL_HOME=str(state), MSL_CONFIG='/dev/null', MSL_VIEW_DIR=str(scratch / 'view'), MSL_LAUNCHD='0')
        executable = prefix / 'bin/msl'
        try:
            subprocess.run(['sh', str(ROOT / 'scripts/install.sh'), '--from', str(archive), '--prefix', str(prefix),
                            '--yes', '--no-path', '--no-ide'], env=env, check=True, timeout=60)
            for binary in [executable, *(prefix / 'libexec/msl').iterdir()]:
                subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
            metadata = json.loads(subprocess.check_output([str(executable), '--version', '--json'], env=env, text=True, timeout=15))
            if metadata['msl'] != version or metadata['commit'] != source:
                raise ValueError(f'embedded version/revision mismatch: {metadata}')
            # --status requires a default distro. A fresh install has none;
            # --version already exercises the installed CLI-to-daemon RPC.
            if (state / 'data.img').exists():
                raise ValueError('package smoke test unexpectedly started a VM')
            print(f'Installed and started package {version} ({source}); VM remains stopped')
        finally:
            if executable.exists():
                subprocess.run([str(executable), '--shutdown'], env=env, timeout=15, check=False)
            # Select this test's daemon by its private socket, never by a global name.
            socket = state / 'msld.sock'
            if socket.exists():
                result = subprocess.run(['lsof', '-t', str(socket)], capture_output=True, text=True)
                for value in set(result.stdout.split()):
                    pid = int(value)
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        continue
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        try:
                            os.kill(pid, 0)
                        except ProcessLookupError:
                            break
                        time.sleep(0.05)
                    else:
                        raise RuntimeError(f'isolated package daemon {pid} did not exit')


if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit('usage: check-package.py <tarball> <version> <source-sha>')
    check_package(*sys.argv[1:])
