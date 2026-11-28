#!/usr/bin/env bash
# Smoke test of the Akari OS ISO in QEMU (KVM), as CI runs it:
#   1. install, unattended: the ISO's kernel and installer, Akari's preseed from
#      the ISO plus the answers a person gives (test/answers.cfg, over HTTP from
#      this machine), until the installer powers off
#   2. boot the installed disk, wait for https://…/api/login/state
#   3. the account from the installer is an Akari account: sign in, ask the agent
#
#   iso/test/smoke.sh ISO [WORK-DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ISO="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
W="${2:-$(mktemp -d)}"; mkdir -p "$W"
say() { printf '\n▸ %s\n' "$*"; }
ACCEL=$([[ -w /dev/kvm ]] && echo "-accel kvm -cpu host" || echo "-accel tcg")
PW=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')

say "Kernel und Installer aus dem ISO"
xorriso -osirrox on -indev "$ISO" -extract /install.amd/vmlinuz "$W/vmlinuz" -extract /install.amd/initrd.gz "$W/initrd.gz" \
  -extract /preseed/akari.cfg "$W/akari.cfg" >/dev/null 2>&1
mkdir -p "$W/www"
{ cat "$W/akari.cfg"; sed "s|@PASSWORD@|$PW|g" "$HERE/answers.cfg"; } > "$W/www/test.cfg"
(cd "$W/www" && exec python3 -m http.server 8000 --bind 127.0.0.1 >/dev/null 2>&1) &
HTTP=$!
trap 'kill $HTTP 2>/dev/null || true; [[ -n "${VM:-}" ]] && kill $VM 2>/dev/null || true' EXIT
rm -f "$W/disk.qcow2"; qemu-img create -q -f qcow2 "$W/disk.qcow2" 20G

say "Installieren (unbeaufsichtigt)"
start=$(date +%s)
: > "$W/install.log"
# a question on the screen ([!!]) means the answers miss one: stop at once and show it,
# instead of waiting for the time limit
( while sleep 10; do
    if grep -aq '\[!!\]' "$W/install.log"; then
      sleep 5
      echo "Der Installer stellt eine Frage, die der Test nicht beantwortet:"
      tr -d '\r' < "$W/install.log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][0-9A-B]//g' | tr -s ' ' \
        | grep -ao '\[!!\][^<]*' | tail -1 | cut -c1-600
      pkill -f "disk.qcow2,if=virtio -cdrom" || true
      exit 0
    fi
  done ) &
WATCH=$!
# shellcheck disable=SC2086
timeout 2700 qemu-system-x86_64 $ACCEL -m 3072 -smp 2 -no-reboot -display none \
  -drive file="$W/disk.qcow2",if=virtio -cdrom "$ISO" \
  -kernel "$W/vmlinuz" -initrd "$W/initrd.gz" \
  -append "auto=true priority=critical preseed/url=http://10.0.2.2:8000/test.cfg locale=en_US.UTF-8 keymap=de hostname=akari domain= interface=auto console=ttyS0,115200n8 --- console=ttyS0,115200n8" \
  -nic user,model=virtio-net-pci -serial file:"$W/install.log" \
  || { kill $WATCH 2>/dev/null; echo "Die Installation ist nicht durchgelaufen (Zeit oder Fehler)."; exit 1; }
kill $WATCH 2>/dev/null || true
grep -aq '\[!!\]' "$W/install.log" && { echo "Abgebrochen: der Installer hat gefragt (oben)."; exit 1; }
say "installiert in $(( ($(date +%s) - start) / 60 )) Minuten"

say "Von der Platte starten"
# shellcheck disable=SC2086
qemu-system-x86_64 $ACCEL -m 3072 -smp 2 -display none -vga std -drive file="$W/disk.qcow2",if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:18443-:443 -serial file:"$W/boot.log" \
  -monitor unix:"$W/mon",server,nowait &
VM=$!
# a picture of GRUB on the installed system (it waits 5 s)
if [[ -n "${SCREENS:-}" ]]; then
  mkdir -p "$SCREENS"; sleep 3
  python3 - "$W/mon" "screendump $W/grub.ppm" <<'PY' || true
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(.3); s.recv(4096)
s.sendall((sys.argv[2] + "\n").encode()); time.sleep(.8)
PY
  sleep 1; convert "$W/grub.ppm" "$SCREENS/installed-grub.png" 2>/dev/null || true
fi
U=https://127.0.0.1:18443
for i in $(seq 1 120); do
  curl -sfk --max-time 5 "$U/api/login/state" -o "$W/state.json" && break
  kill -0 $VM 2>/dev/null || { echo "QEMU ist beendet"; tail -40 "$W/boot.log"; exit 1; }
  sleep 5
done
[[ -s "$W/state.json" ]] || { echo "akarid antwortet nicht"; tail -60 "$W/boot.log"; exit 1; }

fails=0
check() { if eval "$2" >/dev/null 2>&1; then printf '  ✓ %s\n' "$1"; else printf '  ✗ %s\n' "$1"; fails=$((fails + 1)); fi; }
say "Prüfen"
j() { python3 -c "import json,sys; d=json.load(open('$W/state.json')); print($1)"; }
check "das System heißt Akari OS"                      '[[ "$(j "d[\"os\"]")" == "Akari OS"* ]]'
check "es ist eingerichtet (das Konto kam vom Installer)" '[[ "$(j "d[\"setup\"]")" == False ]]'
check "die Anmeldeseite zeigt akari-test"              '[[ "$(j "[a[\"name\"] for a in d[\"accounts\"]]")" == *akari-test* ]]'
check "die Konsole zeigt die Adresse"                  'grep -a -q -E "(In a browser|Im Browser):" "$W/boot.log"'
C="$W/cookies"
code=$(curl -sk -o /dev/null -w '%{http_code}' -c "$C" -H "Origin: $U" -H 'Content-Type: application/json' \
  --data "{\"name\":\"akari-test\",\"password\":\"$PW\"}" "$U/api/login")
check "Anmelden mit dem Passwort aus dem Installer"   '[[ $code == 200 ]]'
check "die Sitzung antwortet (/api/stats)"            '[[ $(curl -sk -o /dev/null -w "%{http_code}" -b "$C" "$U/api/stats") == 200 ]]'
check "das Konto verwaltet (sudo)"                     '[[ $(curl -sk -b "$C" "$U/api/session" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"admin\"])") == True ]]'

echo
[[ $fails == 0 ]] && { echo "Rauchtest bestanden"; exit 0; } || { echo "$fails Fehler"; tail -30 "$W/boot.log"; exit 1; }
