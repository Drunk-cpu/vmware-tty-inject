#!/usr/bin/env bash
# Host side orchestrator for Linux / macOS.
# Replays a command sequence inside a VMware guest's GUI terminal.
#
#   ./vmrun_seq.sh -s examples/demo.txt [-c ../config.local.json] [-o ../out] [-w 3.2]
#
# Sequence format: one command per line, "#SHOT" alone takes a screenshot.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SEQ=""
CONFIG="$(cd "$HERE/.." && pwd)/config.local.json"
OUTDIR="$(cd "$HERE/.." && pwd)/out"
WAIT=3.2
NO_TERM=0

while getopts "s:c:o:w:n" opt; do
  case $opt in
    s) SEQ=$OPTARG ;;
    c) CONFIG=$OPTARG ;;
    o) OUTDIR=$OPTARG ;;
    w) WAIT=$OPTARG ;;
    n) NO_TERM=1 ;;
    *) echo "usage: $0 -s <seq> [-c config] [-o outdir] [-w wait] [-n]" >&2; exit 2 ;;
  esac
done
[ -n "$SEQ" ] || { echo "missing -s <seq>" >&2; exit 2; }
[ -f "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 2; }

cfg() { python3 -c "import json,sys;print(json.load(open('$CONFIG')).get('$1',''))"; }

VMRUN=$(cfg vmrun)
VMX=$(cfg vmx)
GU=$(cfg guest_user)
GP=$(cfg guest_pass)
GD=$(cfg guest_dir); GD=${GD:-/tmp/tti}
[ -n "$VMRUN" ] && [ -n "$VMX" ] && [ -n "$GU" ] || { echo "config incomplete" >&2; exit 2; }

mkdir -p "$OUTDIR"

vm() { "$VMRUN" -T ws -gu "$GU" -gp "$GP" "$@" || echo "warn: vmrun $1 failed" >&2; }

vm runProgramInGuest "$VMX" /bin/sh -c "mkdir -p '$GD' && chmod 700 '$GD'"
for f in tty_inject.py open_term.sh; do
  vm copyFileFromHostToGuest "$VMX" "$HERE/scripts/$f" "$GD/$f"
done
vm runProgramInGuest "$VMX" /bin/sh -c "chmod +x '$GD/tty_inject.py' '$GD/open_term.sh'"

printf '%s' "$GP" > /tmp/tti_pw_local
vm copyFileFromHostToGuest "$VMX" /tmp/tti_pw_local /tmp/.tti_pw
rm -f /tmp/tti_pw_local
vm runProgramInGuest "$VMX" /bin/sh -c "chmod 600 /tmp/.tti_pw"

if [ "$NO_TERM" -eq 0 ]; then
  echo "opening terminal in guest..."
  vm runProgramInGuest "$VMX" /bin/bash "$GD/open_term.sh"
  sleep 1.5
fi

idx=0; shot=0
capture() { shot=$((shot+1)); local p; p=$(printf '%s/shot_%02d.png' "$OUTDIR" "$shot"); vm captureScreen "$VMX" "$p"; echo "screenshot -> $p"; }

while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in
    "") continue ;;
    "#SHOT") capture; continue ;;
    "#"*) continue ;;
  esac
  idx=$((idx+1))
  printf '%s' "$line" > /tmp/tti_cmd_local
  vm copyFileFromHostToGuest "$VMX" /tmp/tti_cmd_local "$GD/cmd.txt"
  rm -f /tmp/tti_cmd_local
  vm runProgramInGuest "$VMX" /bin/python3 "$GD/tty_inject.py" --file "$GD/cmd.txt" >/dev/null
  echo "[$idx] $line"
  sleep "$WAIT"
done < "$SEQ"

capture
echo "done: $idx commands, $shot screenshots -> $OUTDIR"
vm runProgramInGuest "$VMX" /bin/sh -c "rm -f /tmp/.tti_pw '$GD/cmd.txt'"
