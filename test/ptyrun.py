#!/usr/bin/env python3
# Tiny PTY launcher for the loopback test: runs a command with a real controlling terminal
# so we can deliver a genuine Ctrl-C (the \x03 INTR byte → line discipline → SIGINT to the
# child's foreground group), exactly as a user pressing Ctrl-C would. A plain `cmd &` can't
# test this: bash ignores SIGINT for async-backgrounded scripts and the trap can't re-enable it.
#
# env: PTYRUN_LOG (output file), PTYRUN_PIDFILE (child pid).  argv[1:] = command to run.
# Send this process SIGTERM to forward a Ctrl-C to the child.
import os, pty, sys, signal, select

log = open(os.environ["PTYRUN_LOG"], "wb", buffering=0)
pid, master = pty.fork()
if pid == 0:
    # A real terminal hands the child DEFAULT signal dispositions. ptyrun may have been
    # backgrounded (SIGINT ignored), and bash can't trap a signal that was ignored on entry —
    # so reset to default here, or Ctrl-C would be silently uncatchable in the child.
    for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP, signal.SIGPIPE):
        try: signal.signal(s, signal.SIG_DFL)
        except (OSError, ValueError): pass
    os.execvp(sys.argv[1], sys.argv[1:])  # child: becomes session leader w/ the pty as ctty
    os._exit(127)

with open(os.environ["PTYRUN_PIDFILE"], "w") as f:
    f.write(str(pid))

def send_ctrl_c(_signum, _frame):
    try: os.write(master, b"\x03")
    except OSError: pass
signal.signal(signal.SIGTERM, send_ctrl_c)
signal.signal(signal.SIGINT, send_ctrl_c)

while True:
    try:
        r, _, _ = select.select([master], [], [], 1)
    except (InterruptedError, OSError):
        continue
    if master in r:
        try:
            data = os.read(master, 65536)
        except OSError:
            break
        if not data:
            break
        log.write(data)
    try:
        wpid, _ = os.waitpid(pid, os.WNOHANG)
        if wpid == pid:
            break
    except ChildProcessError:
        break
