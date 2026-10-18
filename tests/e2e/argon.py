#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# /// script
# requires-python = ">=3.10"
# dependencies = ["grpcio>=1.60,<2"]
# ///
"""Clock regression in an isolated VM, using only the bundled BusyBox.

Usage: uv run tests/e2e/argon.py [path/to/msl]
Exercise SyncClock directly; native host tests cover event routing. macOS time
is never changed and the Mac is never put to sleep.
"""
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import time
import grpc


root = Path(__file__).resolve().parents[2]
msl = Path(sys.argv[1] if len(sys.argv) > 1 else root / "build/bin/msl").resolve()
home = Path(tempfile.mkdtemp(prefix="msl-argon-", dir="/tmp"))
env = dict(os.environ, MSL_HOME=str(home), MSL_CONFIG=str(home / "cfg"), MSL_VIEW_DIR=str(home / "view"))
(home / "cfg").write_text("[general]\ninstanceIdleTimeout=-1\n[msl2]\nmemory=512MB\nprocessors=2\nvmIdleTimeout=-1\nlocalhostForwarding=false\ndnsTunneling=false\n")


def run(*args, check=True):
    return subprocess.run([str(msl), *args], env=env, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, timeout=30, check=check).stdout.strip()


def guest(name, *args):
    return run("-d", name, "-u", "root", "--cd", "/", "-e", *args)


def sync_clock():
    # tonic rejects a Unix path as the HTTP/2 :authority (as in Guest.swift).
    with grpc.insecure_channel("unix:" + str(home / "run/vsock-1024.sock"),
                               options=[("grpc.default_authority", "msl-guest")]) as channel:
        channel.unary_unary("/msl.v1.MiniInit/SyncClock")(b"", timeout=5)


def debug(script):
    subprocess.run([str(msl), "--debug-shell"], env=env, input=script + "\n",
                   capture_output=True, text=True, timeout=15, check=True)


def offset(name):
    before = time.time()
    epoch = int(guest(name, "/bin/date", "+%s"))
    return epoch - (before + time.time()) / 2


def aligned(name):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        delta = offset(name)
        if abs(delta) < 2:
            print(f"PASS {name}: offset {delta:.3f} s")
            return
        time.sleep(0.05)
    raise AssertionError(f"{name}: offset {delta:.3f} s")


def corrections():
    return (home / "console.log").read_text().count("clock: corrected from")


def daemon_pid():
    # The test owns this socket, so lsof cannot select the user's real daemon.
    result = subprocess.run(["lsof", "-t", str(home / "msld.sock")], capture_output=True, text=True)
    return int(result.stdout.splitlines()[0])


print(f"MSL_HOME={home}", flush=True)
pid = None
try:
    image = home / "rootfs.tar"
    with tarfile.open(image, "w") as tar:
        for directory in ["bin", "etc", "root", "usr", "usr/bin", "run", "tmp"]:
            entry = tarfile.TarInfo(directory)
            entry.type, entry.mode = tarfile.DIRTYPE, 0o755
            tar.addfile(entry)
        tar.add(root / "guest/vendor/busybox", arcname="bin/busybox")
        for applet in ["sh", "date", "true", "sleep", "cat", "mount", "umount"]:
            entry = tarfile.TarInfo("bin/" + applet)
            entry.type, entry.linkname = tarfile.SYMTYPE, "busybox"
            tar.addfile(entry)
        for name, contents in {
            "passwd": "root:x:0:0:root:/root:/bin/sh\n",
            "group": "root:x:0:\n",
            "wsl.conf": "[boot]\nsystemd=false\n[automount]\nmountfstab=false\n",
        }.items():
            entry = tarfile.TarInfo("etc/" + name)
            entry.size, entry.mode = len(contents), 0o644
            tar.addfile(entry, io.BytesIO(contents.encode()))

    for name in ["ClockA", "ClockB"]:
        run("--import", name, str(home / name), str(image))
        guest(name, "/bin/true")
    pid = daemon_pid()
    aligned("ClockA")
    aligned("ClockB")
    boot_id = guest("ClockA", "/bin/cat", "/proc/sys/kernel/random/boot_id")
    guest("ClockA", "/bin/busybox", "ip", "link", "set", "eth0", "down")
    print("PASS guest network disabled before clock correction")

    for delta in [-88_468, 88_468]:
        guest("ClockA", "/bin/date", "-u", "-s", "@" + str(int(time.time()) + delta))
        assert abs(offset("ClockB")) > 88_460, "test failed to introduce shared skew"
        sync_clock()
        aligned("ClockA")
        aligned("ClockB")
        assert guest("ClockA", "/bin/cat", "/proc/sys/kernel/random/boot_id") == boot_id
        print(f"PASS corrected {delta:+d} s in both distros without a VM restart")

    count = corrections()
    for _ in range(3):
        sync_clock()
        time.sleep(0.1)
    assert corrections() == count, "clock stepped again despite RTC quantization tolerance"
    print("PASS repeated requests do not step an aligned clock")

    # Hide only this VM's RTC sysfs view to exercise RPC error propagation.
    debug("mount -t tmpfs tmpfs /sys/class/rtc")
    try:
        sync_clock()
    except grpc.RpcError as error:
        assert error.code() == grpc.StatusCode.INTERNAL, error
        assert "No such file" in error.details(), error
    else:
        raise AssertionError("missing RTC was not reported by SyncClock")
    debug("umount /sys/class/rtc")
    print("PASS missing RTC is reported by the control RPC without killing the service")

    run("--shutdown")
    assert not json.loads(run("--status", "--json"))["vm"]["running"]
    print("PASS shutdown stops the VM")
    aligned("ClockA")
    print("PASS VM can boot again after clock correction and RTC failure")
finally:
    run("--shutdown", check=False)
    if pid is None:
        try:
            pid = daemon_pid()
        except (ValueError, IndexError):
            pass
    if pid is not None:
        os.kill(pid, 15)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            raise AssertionError("isolated daemon did not exit after SIGTERM")
        print("PASS daemon exits cleanly after clock monitoring")
