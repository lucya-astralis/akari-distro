#!/usr/bin/env bash
# Pictures of the ISO as a person sees it (CI artifact): the boot menu with
# BIOS and with UEFI, and the graphical installer's first screen.
#   iso/test/screens.sh ISO OUT-DIR
set -euo pipefail
ISO="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT="$(mkdir -p "$2" && cd "$2" && pwd)"
ACCEL=$([[ -w /dev/kvm ]] && echo "-accel kvm -cpu host" || echo "-accel tcg")
W="$(mktemp -d)"

mon() {  # mon SOCKET COMMAND: one command to QEMU's monitor
  python3 - "$1" "$2" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(.3); s.recv(4096)
s.sendall((sys.argv[2] + "\n").encode()); time.sleep(.8); s.close()
PY
}
shot() { mon "$1" "screendump $W/$2.ppm"; sleep 1; convert "$W/$2.ppm" "$OUT/$2.png"; echo "  $2.png"; }

run() {  # run NAME FIRMWARE-ARGS…: boot the ISO, photograph the menu, then the installer
  local name=$1; shift
  # shellcheck disable=SC2086
  qemu-system-x86_64 $ACCEL -m 2048 -smp 2 "$@" -cdrom "$ISO" -display none -vga std \
    -monitor unix:"$W/$name.mon",server,nowait -daemonize -pidfile "$W/$name.pid"
  sleep 12; shot "$W/$name.mon" "$name-1-bootmenu"
  mon "$W/$name.mon" "sendkey ret"
  sleep 45; shot "$W/$name.mon" "$name-2-installer"
  kill "$(cat "$W/$name.pid")" 2>/dev/null || true
}

echo "BIOS"; run bios
OVMF=$(ls /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd 2>/dev/null | head -1)
if [[ -n "$OVMF" ]]; then
  cp "$(dirname "$OVMF")/OVMF_VARS_4M.fd" "$W/vars.fd" 2>/dev/null || cp "$(dirname "$OVMF")/OVMF_VARS.fd" "$W/vars.fd"
  echo "UEFI"; run uefi -machine q35 -drive if=pflash,format=raw,readonly=on,file="$OVMF" -drive if=pflash,format=raw,file="$W/vars.fd"
fi
rm -rf "$W"
