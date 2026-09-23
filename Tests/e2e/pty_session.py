#!/usr/bin/env python3
"""Drive `msl` through a real PTY (interactive path): optional OOBE prompts,
shell, resize, exit code.

usage: [PTY_PROMPT='# '] pty_session.py <oobe-prompt-needle> <username> <password> -- <msl> [args...]
Exits 0 if the shell worked, resize reached it, and `exit 3` came back as 3."""
import fcntl, os, pty, select, signal, struct, sys, termios, time

sep = sys.argv.index("--")
needle_user, user, pw = sys.argv[1:4]
argv = sys.argv[sep + 1:]
out = b""
pos = 0  # matches only count in output after the previous match

def read_until(fd, needle, timeout=60):
    global out, pos
    end = time.time() + timeout
    while True:
        i = out.find(needle.encode(), pos)
        if i >= 0:
            pos = i + len(needle)
            return True
        if time.time() > end:
            return False
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return False
            if not chunk:
                return False
            out += chunk
            if b"\x1b[6n" in chunk:  # cursor-position query (BusyBox): answer like a terminal
                os.write(fd, b"\x1b[1;1R")
            sys.stdout.write(chunk.decode(errors="replace")); sys.stdout.flush()

def setsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

signal.signal(signal.SIGALRM, lambda *_: (print("\n[pty_session] timeout"), os._exit(2)))
signal.alarm(180)
pid, fd = pty.fork()
if pid == 0:
    os.execv(argv[0], argv)
setsize(fd, 30, 100)
checks = {}
if read_until(fd, needle_user, 60):
    os.write(fd, (user + "\r").encode())
    for _ in range(2):
        read_until(fd, "password:", 30); os.write(fd, (pw + "\r").encode())
PROMPT = os.environ.get("PTY_PROMPT", "$ ")
checks["prompt"] = read_until(fd, PROMPT, 120)
os.write(fd, b"echo TTY=$(tty) SIZE=$(stty size) ID=$(id -un)\r")
checks["tty+size"] = read_until(fd, "SIZE=30 100", 20)
setsize(fd, 50, 160)  # delivers SIGWINCH to msl
time.sleep(0.5)
os.write(fd, b"stty size\r")
checks["resize"] = read_until(fd, "50 160", 20)
os.write(fd, b"exit 3\r")
_, status = os.waitpid(pid, 0)
code = os.waitstatus_to_exitcode(status)
checks["exit=3"] = code == 3
print(f"\n[pty_session] {checks}")
sys.exit(0 if all(checks.values()) else 1)
