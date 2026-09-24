#!/usr/bin/env python3
"""Spike client.
  mslctl.py <port> '<json request>'     guest control (1024) or a distro agent (2000+)
  mslctl.py ctl '<command>'             host control socket (usb-attach, balloon, state, stop)
"""
import json, os, socket, sys

RUN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "run")

def call(port, req, timeout=600):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(os.path.join(RUN, f"vsock-{port}.sock"))
    s.sendall((json.dumps(req) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf)

def ctl(cmd):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(os.path.join(RUN, "control.sock"))
    s.sendall((cmd + "\n").encode())
    out = s.recv(65536).decode().strip()
    s.close()
    return out

if __name__ == "__main__":
    if sys.argv[1] == "ctl":
        print(ctl(" ".join(sys.argv[2:])))
    else:
        r = call(int(sys.argv[1]), json.loads(sys.argv[2]))
        if "stdout" in r:
            sys.stdout.write(r["stdout"]); sys.stderr.write(r["stderr"])
            sys.exit(r.get("exit", 0))
        print(json.dumps(r, indent=1))
