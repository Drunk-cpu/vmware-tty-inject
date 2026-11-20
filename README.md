# vmware-tty-inject

Type commands into a **terminal window inside a running VMware guest**, and capture the result — without
synthesizing a single keyboard event on the host.

Most hypervisors (VMware, RDP, VNC) drop keyboard input that carries an injected-event flag, so the usual
`SendKeys` / `pyautogui.typewrite` / clipboard-paste tricks silently do nothing on the guest console.
This tool sidesteps that entirely: the characters are pushed into the terminal's **TTY input queue** from
inside the guest, using the `TIOCSTI` ioctl. The kernel echoes them, so the screen shows a real
prompt + command + output, exactly as if someone had typed.

```
Windows host                         Linux guest
─────────────                        ───────────
run sequence file
      │
      ├─ vmrun copyFileFromHostToGuest ──►  /tmp/tti/cmd.txt
      ├─ vmrun runProgramInGuest ────────►  python3 tty_inject.py --file cmd.txt
      │                                          │
      │                                          ├─ find /dev/pts/N of the GUI shell
      │                                          └─ ioctl(fd, TIOCSTI, byte)  ← kernel echoes it
      │                                                ▼
      │                                          terminal shows:  $ <command>
      │                                                          <output>
      └─ vmrun captureScreen ────────────►  shot_01.png
```

## Requirements

- VMware Workstation / Fusion / Player with `vmrun` and VMware Tools running in the guest
- A Linux guest with a **graphical, logged-in desktop session** and a terminal emulator
  (`ptyxis`, `gnome-terminal`, `konsole`, `xfce4-terminal`, `tilix`, `xterm`, …)
- Python 3 in the guest (standard library only — nothing to install)
- `sudo` rights in the guest, because `TIOCSTI` requires `CAP_SYS_ADMIN` (Linux ≥ 4.5)

## Setup

```bash
git clone https://github.com/<you>/vmware-tty-inject.git
cd vmware-tty-inject
cp config.example.json config.local.json   # then edit it
```

`config.local.json` is git-ignored on purpose — it holds your guest password.
Alternatively omit `guest_pass` in the file and export `TTI_GUEST_PASS` before running, and adapt the scripts
to read it from the environment.

## Usage

Windows (PowerShell 7):

```powershell
.\scripts\vmrun_seq.ps1 -Seq .\examples\demo.txt -OutDir .\out
```

The script refuses to run when the VM is powered off or VMware Tools are down. Add `-Start` to power the
VM on (GUI) and wait for Tools plus the desktop session automatically:

```powershell
.\scripts\vmrun_seq.ps1 -Seq .\examples\demo.txt -OutDir .\out -Start
```

Linux / macOS:

```bash
./scripts/vmrun_seq.sh -s examples/demo.txt -o out -w 3.2
```

### Sequence file format

```
# comments and blank lines are ignored
date
#SHOT                 <- take a screenshot right here
ls -la /opt
mongosh --quiet --eval "db.runCommand({ping:1})"
```

- one command per line; each line is typed and Enter is pressed
- `#SHOT` on its own line captures the guest screen at that moment
- screenshots land in `-OutDir` as `shot_01.png`, `shot_02.png`, …

Typing speed is 8 ms per byte by default; the `-WaitMs` / `-w` option is the pause **between lines** —
raise it for slow commands (`apt install`, `mongosh` startup).

### Single command, no sequence

Inside the guest:

```bash
python3 /tmp/tti/tty_inject.py --text "echo hello"      # auto-detects the tty
python3 /tmp/tti/tty_inject.py --find                    # just print the detected tty
python3 /tmp/tti/tty_inject.py --file cmds.txt --pts /dev/pts/2
```

`tty_inject.py` re-execs itself through `sudo` automatically, reading the password from `$TTI_SUDO_PASS`
or from `/tmp/.tti_pw` (mode 600, written and deleted by the host script).

## Limitations

- **Needs a terminal already open in a GUI session.** With no window there is no tty to inject into.
  `open_term.sh` starts one; it tries `ptyxis`, `gnome-terminal`, `konsole`, `xfce4-terminal`, `tilix`,
  `mate-terminal`, `lxterminal`, `xterm` in that order.
- **`TIOCSTI` must be enabled in the kernel.** Some hardened distributions build with
  `CONFIG_LEGACY_TIOCSTI=n`, where the ioctl returns `EPERM`/`ENOTTY` even for root.
  Fallback that needs no privileges at all: run the commands inside `tmux` in that terminal and use
  `tmux send-keys -t <pane> '<command>' Enter` from another guest process — the pane's pty gets the
  characters the same way.
- **One line at a time.** Interactive REPLs (`mongosh`, `python`, `mysql`) keep their state across lines
  because they read the same tty, but multi-line pastes must be fed line by line.
- **Screenshots are full-screen frames.** Maximize the terminal (`open_term.sh` does) so the picture is
  readable; a window covered by another window is captured covered.
- **The guest must be logged in.** A GDM/KDE login prompt has no terminal to inject into and its password
  box cannot receive synthetic keys either — enable autologin if you want unattended runs.
- Wayland or X11 both work; only the guest-side environment discovery differs.

## Security notes

- Guest password: only used for `vmrun -gu/-gp` and for `sudo`. It is copied to `/tmp/.tti_pw` with mode
  600 for the duration of a run and deleted afterwards; it never sits in the repo.
- Injecting into a tty is a privileged, powerful primitive: anything that can write to your shell's input
  queue can run commands as you. Keep the sudo password out of shared machines and never expose this
  over a network.
- Nothing here touches the host keyboard, so it cannot be blocked by an injected-input filter — which is
  precisely why it works, and also why it is worth thinking twice before pointing it at someone else's
  machine.

## License

MIT — see [LICENSE](LICENSE).
