#!/usr/bin/env python3
"""Inject keystrokes into a terminal running inside a Linux guest.

Instead of synthesizing keyboard events on the host (which VMware / RDP /
hypervisors usually filter), this pushes bytes straight into the terminal's
TTY input queue with the TIOCSTI ioctl.  To the shell it looks exactly like
someone typed the characters; the kernel does the echo, so the screen shows
a real prompt + command + output.

Standard library only.  Requires CAP_SYS_ADMIN (i.e. root / sudo).
"""

import argparse
import os
import sys
import subprocess
import time

DEFAULT_PW_FILE = "/tmp/.tti_pw"
PW_ENV = "TTI_SUDO_PASS"


def read_password():
    pw = os.environ.get(PW_ENV)
    if pw:
        return pw
    if os.path.exists(DEFAULT_PW_FILE):
        try:
            with open(DEFAULT_PW_FILE, "r", encoding="utf-8") as f:
                return f.read().strip()
        except OSError:
            return None
    return None


def ensure_root(argv):
    """TIOCSTI needs CAP_SYS_ADMIN; re-exec ourselves through sudo."""
    if os.geteuid() == 0:
        return
    pw = read_password()
    if not pw:
        sys.exit("not root and no sudo password available "
                 "(set $TTI_SUDO_PASS or write %s)" % DEFAULT_PW_FILE)
    cmd = ["sudo", "-S", "-p", "", sys.executable, os.path.abspath(__file__)] + argv
    proc = subprocess.run(cmd, input=(pw + "\n").encode(), text=False)
    sys.exit(proc.returncode)


SHELLS = {"bash", "sh", "dash", "zsh", "fish", "ksh", "tcsh", "mksh"}


def find_terminal_pts():
    """Return a /dev/pts/N that belongs to an interactive shell."""
    candidates = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/comm" % pid, "r") as f:
                name = f.read().strip()
        except OSError:
            continue
        if name not in SHELLS:
            continue
        try:
            target = os.readlink("/proc/%s/fd/0" % pid)
        except OSError:
            continue
        if target.startswith("/dev/pts/"):
            candidates.append((int(pid), target))
    if not candidates:
        return None
    # newest shell is usually the one the user is looking at
    candidates.sort()
    return candidates[-1][1]


def inject(pts, data, delay):
    fd = os.open(pts, os.O_RDWR | os.O_NOCTTY)
    try:
        for b in data:
            os_ioctl(fd, b)
            if delay:
                time.sleep(delay)
    finally:
        os.close(fd)


def os_ioctl(fd, byte):
    import fcntl
    import termios
    fcntl.ioctl(fd, termios.TIOCSTI, bytes([byte]))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--file", "-f", help="command file; every line is typed followed by Enter")
    ap.add_argument("--text", "-t", help="literal text to type (Enter appended)")
    ap.add_argument("--pts", help="target tty, e.g. /dev/pts/0 (auto-detected by default)")
    ap.add_argument("--find", action="store_true", help="only print the detected tty and exit")
    ap.add_argument("--delay", type=float, default=0.008, help="seconds between bytes")
    ap.add_argument("--no-enter", action="store_true", help="do not append a newline")
    args = ap.parse_args()

    pts = args.pts or find_terminal_pts()

    if args.find:
        print(pts or "")
        sys.exit(0 if pts else 1)
    if not pts:
        sys.exit("no interactive terminal found (open one in the GUI session first)")
    if not os.path.exists(pts):
        sys.exit("tty does not exist: %s" % pts)

    ensure_root(sys.argv[1:])

    if args.file:
        with open(args.file, "rb") as f:
            payload = f.read()
    elif args.text is not None:
        payload = args.text.encode()
    else:
        sys.exit("need --file or --text")

    payload = payload.rstrip(b"\r\n")
    if not args.no_enter:
        payload += b"\n"

    inject(pts, payload, args.delay)
    print("typed %d bytes into %s" % (len(payload), pts))


if __name__ == "__main__":
    main()
