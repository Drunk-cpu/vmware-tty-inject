---
name: vmware-tty-inject
description: Type commands into a terminal inside a running VMware guest and capture the resulting screen, without synthesizing host keyboard events. Use when you must run commands in a VM's GUI terminal (hypervisor filters injected keystrokes, so SendKeys/pyautogui/clipboard paste all fail), or when you need repeatable screenshot evidence of a command sequence executed inside the guest.
---

# vmware-tty-inject

Drive a VMware guest's terminal from the host: each command line is pushed into the shell's TTY input
queue with `TIOCSTI` (so it looks typed), then `vmrun captureScreen` records the guest's real screen.

## When to use

- Commands must run **inside a VM's terminal window**, not as a headless background process.
- Host-side key synthesis (`SendKeys`, `pyautogui`, `computer_use` type, clipboard paste) is silently
  swallowed by the hypervisor.
- A repeatable sequence of commands plus screenshots is needed (labs, demos, verification records).

Do not use it for: guest machines where you have SSH already (plain SSH is simpler and gives you real
stdout), or any machine you do not own.

## Preconditions to confirm first

1. The VM is **powered on** (`vmrun -T ws list`). A powered-off VM makes every vmrun call fail with
   `The virtual machine is not powered on`.
2. The guest is **logged into a graphical desktop**. At a login prompt there is no tty to inject into, and
   the password box cannot take synthetic keys — enable autologin (`/etc/gdm3/custom.conf`,
   `AutomaticLoginEnable = true`) or ask the owner to log in once.
3. `config.local.json` exists with `vmx`, `vmrun`, `guest_user`, `guest_pass`.
4. Guest has `python3`, a terminal emulator, and working `sudo`.

## Workflow

1. Write the sequence file: one command per line, `#SHOT` alone for a screenshot, `#` starts a comment.
2. Run the orchestrator:
   - Windows: `pwsh scripts/vmrun_seq.ps1 -Seq <seq> -OutDir <dir> [-WaitMs 3200]`
   - Linux/macOS: `scripts/vmrun_seq.sh -s <seq> -o <dir> -w 3.2`
3. The script opens a maximized terminal in the guest, types each line, sleeps `WaitMs` between lines,
   and writes `shot_NN.png` into the output directory.
4. Verify results by reading the screenshots; raise `WaitMs` for slow commands (`apt`, `mongosh` startup).
5. Cleanup is automatic (`/tmp/.tti_pw` and the command file are removed).

## Guest-side entry points

- `scripts/tty_inject.py` — `--text`, `--file`, `--pts`, `--find`; re-execs itself through `sudo`
  (password from `$TTI_SUDO_PASS` or `/tmp/.tti_pw`).
- `scripts/open_term.sh` — discovers Wayland/X11 session, starts the first available terminal emulator.

## Failure modes

| Symptom | Cause | Fix |
| --- | --- | --- |
| `no interactive terminal found` | no terminal window, or guest not logged in | run `open_term.sh`, check the desktop |
| `EPERM` / `ENOTTY` from ioctl | kernel built without `CONFIG_LEGACY_TIOCSTI` | fall back to `tmux send-keys` inside that terminal |
| typed text appears but nothing executes | Enter not injected (`--no-enter` set) | drop the flag |
| screenshot shows a covered window | terminal not in front | keep `--maximize`, do not open other windows |
| `vmrun failed: runProgramInGuest` | wrong guest password / Tools not running | verify password, `vmrun checkToolsState` |

## Housekeeping

- Screenshots and sequence files are run artifacts; keep them out of version control (`out/`, `*.png`
  are already in `.gitignore`).
- Never commit `config.local.json` — it contains the guest password.
