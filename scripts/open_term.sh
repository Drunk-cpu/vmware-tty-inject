#!/usr/bin/env bash
# Open an interactive terminal window inside the guest's graphical session.
set -u

UID_NUM=$(id -u)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID_NUM}"
[ -S "$XDG_RUNTIME_DIR/bus" ] && export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

# Prefer the Wayland compositor socket; fall back to X11 only when there is none.
WAY=""
for s in "$XDG_RUNTIME_DIR"/wayland-*; do
  case "$s" in *.lock) continue ;; esac
  if [ -S "$s" ]; then WAY=$(basename "$s"); break; fi
done

if [ -n "$WAY" ]; then
  export WAYLAND_DISPLAY="$WAY"
  export GDK_BACKEND=wayland
  unset DISPLAY
else
  for s in /tmp/.X11-unix/X*; do
    if [ -e "$s" ]; then export DISPLAY=":$(basename "$s" | tr -d X)"; export GDK_BACKEND=x11; break; fi
  done
fi

SHELL_BIN="${TTI_SHELL:-/bin/bash}"
LOG="${TTI_LOG:-/tmp/tti_term.log}"

start() {
  local exe="$1"; shift
  setsid "$exe" "$@" >>"$LOG" 2>&1 &
  sleep 3
  echo "started $exe"
}

for bin in ptyxis gnome-terminal konsole xfce4-terminal tilix mate-terminal lxterminal xterm; do
  command -v "$bin" >/dev/null 2>&1 || continue
  case "$bin" in
    ptyxis)         start "$bin" --maximize -- "$SHELL_BIN" -c "clear; exec $SHELL_BIN" ;;
    gnome-terminal) start "$bin" --maximize -- "$SHELL_BIN" -c "clear; exec $SHELL_BIN" ;;
    konsole)        start "$bin" --fullscreen -e "$SHELL_BIN" -c "clear; exec $SHELL_BIN" ;;
    xfce4-terminal|tilix|mate-terminal|lxterminal)
                    start "$bin" -e "$SHELL_BIN" -c "clear; exec $SHELL_BIN" ;;
    *)              start "$bin" -fa default -e "$SHELL_BIN" -c "clear; exec $SHELL_BIN" ;;
  esac
  exit 0
done

echo "no supported terminal emulator found" >&2
exit 1
