#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Write a gzipped newc cpio initramfs: /dev, /dev/console (c 5:1), /init.
Done in Python so no root/mknod is needed on macOS."""
import gzip, os, sys, time

def entry(name, mode, data=b"", rdev=(0, 0), ino=[0]):
    ino[0] += 1
    name_b = name.encode() + b"\0"
    hdr = "070701" + "".join("%08X" % v for v in (
        ino[0], mode, 0, 0, 1, int(time.time()), len(data), 0, 0, rdev[0], rdev[1], len(name_b), 0))
    out = hdr.encode() + name_b
    out += b"\0" * (-len(out) % 4)
    out += data + b"\0" * (-len(data) % 4)
    return out

init_path, out_path = sys.argv[1], sys.argv[2]
init = open(init_path, "rb").read()
blob = (entry("dev", 0o040755) + entry("dev/console", 0o020600, rdev=(5, 1))
        + entry("init", 0o100755, init) + entry("TRAILER!!!", 0))
with gzip.open(out_path, "wb", compresslevel=9) as f:
    f.write(blob)
print(f"initrd {out_path}: {os.path.getsize(out_path)} bytes (init {len(init)} bytes)")
