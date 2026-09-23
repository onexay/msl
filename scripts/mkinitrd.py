#!/usr/bin/env python3
"""Write a gzipped newc cpio initramfs: /dev, /dev/console (c 5:1), /init, and
optionally /bin/busybox (for `msl --debug-shell`).
Done in Python so no root/mknod is needed on macOS.
usage: mkinitrd.py <init> <out.gz> [busybox]"""
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
blob = entry("dev", 0o040755) + entry("dev/console", 0o020600, rdev=(5, 1)) + entry("init", 0o100755, init)
if len(sys.argv) > 3:
    blob += entry("bin", 0o040755) + entry("bin/busybox", 0o100755, open(sys.argv[3], "rb").read())
blob += entry("TRAILER!!!", 0)
with gzip.open(out_path, "wb", compresslevel=9) as f:
    f.write(blob)
print(f"initrd {out_path}: {os.path.getsize(out_path)} bytes (init {len(init)} bytes)")
