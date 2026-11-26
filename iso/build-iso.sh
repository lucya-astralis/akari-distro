#!/usr/bin/env bash
# The Akari OS installer ISO: Debian 13's own netinst, checked against Debian's
# signed checksums, with Akari's preseed, its archive key and a first boot
# entry "Akari OS installieren" (BIOS and UEFI). Debian's signed boot chain
# (shim, GRUB, kernel) is not touched, so Secure Boot keeps working.
#
#   iso/build-iso.sh OUT-DIR
#
# Needs: curl, xorriso, gpgv, debian-keyring (Debian's CD signing key),
# cpio, gzip. APT_URL: the Akari archive the installed system uses.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
APT_URL="${APT_URL:-https://lucya-astralis.github.io/akari-distro}"
MIRROR="${DEBIAN_CD:-https://cdimage.debian.org/debian-cd/current/amd64/iso-cd}"
VERSION="$(sed -n 's/^VERSION_ID="\(.*\)"/\1/p' "$ROOT/packages/akari-base/files/os-release")"
NAME="akari-os-$VERSION-amd64-netinst"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
say() { printf '\n▸ %s\n' "$*"; }

say "Debians Netinst und seine Prüfsummen"
curl -fsSL -o "$W/SHA256SUMS" "$MIRROR/SHA256SUMS"
curl -fsSL -o "$W/SHA256SUMS.sign" "$MIRROR/SHA256SUMS.sign"
gpgv --keyring /usr/share/keyrings/debian-role-keys.gpg "$W/SHA256SUMS.sign" "$W/SHA256SUMS" 2>&1 | grep -E "Good signature|Korrekte" \
  || { echo "SHA256SUMS ist nicht von Debian signiert" >&2; exit 1; }
DEB_ISO=$(awk '/-amd64-netinst\.iso$/ { print $2; exit }' "$W/SHA256SUMS")
mkdir -p "${CACHE:-$OUT/.cache}"
SRC="${CACHE:-$OUT/.cache}/$DEB_ISO"
want=$(awk -v f="$DEB_ISO" '$2 == f { print $1 }' "$W/SHA256SUMS")
if [[ ! -f "$SRC" ]] || [[ "$(sha256sum "$SRC" | cut -d' ' -f1)" != "$want" ]]; then
  curl -fSL --retry 5 -C - -o "$SRC" "$MIRROR/$DEB_ISO" || curl -fSL --retry 5 -o "$SRC" "$MIRROR/$DEB_ISO"
fi
[[ "$(sha256sum "$SRC" | cut -d' ' -f1)" == "$want" ]] || { echo "$DEB_ISO: Prüfsumme stimmt nicht" >&2; exit 1; }
say "Grundlage: $DEB_ISO (Signatur und Prüfsumme gut)"

say "Akaris Dateien"
X="$W/add"; mkdir -p "$X/preseed" "$X/akari" "$X/isolinux" "$X/boot/grub"
sed "s|@APT_URL@|$APT_URL|g" "$HERE/preseed/akari.cfg" > "$X/preseed/akari.cfg"
cp "$ROOT/keys/akari-archive.asc" "$X/akari/akari-archive-keyring.asc"
xorriso -osirrox on -indev "$SRC" -extract /isolinux/gtk.cfg "$W/gtk.cfg" -extract /boot/grub/grub.cfg "$W/grub.cfg" \
  -extract /md5sum.txt "$W/md5sum.txt" >/dev/null 2>&1
chmod u+w "$W"/*.cfg "$W/md5sum.txt"
PRESEED="preseed/file=/cdrom/preseed/akari.cfg"

# BIOS (isolinux): Akari first and the default; Debian's own entries stay below it
{
  printf 'default akari\nlabel akari\n\tmenu label ^Akari OS installieren\n\tmenu default\n\tkernel /install.amd/vmlinuz\n'
  printf '\tappend vga=788 initrd=/install.amd/gtk/initrd.gz %s --- quiet\n' "$PRESEED"
  sed -e '/^default /d' -e '/menu default/d' "$W/gtk.cfg"
} > "$X/isolinux/gtk.cfg"

# UEFI (GRUB): Akari as the first entry, so it is the default
awk -v p="$PRESEED" '
  !done && /^menuentry/ {
    print "menuentry --hotkey=a '\''Akari OS installieren'\'' {"
    print "    set background_color=black"
    print "    linux    /install.amd/vmlinuz vga=788 " p " --- quiet"
    print "    initrd   /install.amd/gtk/initrd.gz"
    print "}"
    done = 1
  }
  { print }' "$W/grub.cfg" > "$X/boot/grub/grub.cfg"
grep -q "Akari OS installieren" "$X/boot/grub/grub.cfg" || { echo "grub.cfg: kein menuentry gefunden" >&2; exit 1; }

# the ISO's own checksum list ("Datenträger prüfen") follows what changed
cp "$W/md5sum.txt" "$X/md5sum.txt"
for f in isolinux/gtk.cfg boot/grub/grub.cfg; do
  sum=$(md5sum "$X/$f" | cut -d' ' -f1)
  sed -i "s|^[0-9a-f]*  \./$f\$|$sum  ./$f|" "$X/md5sum.txt"
done
for f in preseed/akari.cfg akari/akari-archive-keyring.asc; do
  echo "$(md5sum "$X/$f" | cut -d' ' -f1)  ./$f" >> "$X/md5sum.txt"
done

say "ISO schreiben"
xorriso -indev "$SRC" -outdev "$OUT/$NAME.iso" \
  -map "$X/preseed" /preseed -map "$X/akari" /akari \
  -map "$X/isolinux/gtk.cfg" /isolinux/gtk.cfg -map "$X/boot/grub/grub.cfg" /boot/grub/grub.cfg \
  -map "$X/md5sum.txt" /md5sum.txt \
  -boot_image any replay >/dev/null 2>&1 \
  || { echo "xorriso ist gescheitert" >&2; exit 1; }
(cd "$OUT" && sha256sum "$NAME.iso" > "$NAME.iso.sha256")
echo "$DEB_ISO" > "$OUT/$NAME.base"
say "fertig: $OUT/$NAME.iso ($(du -h "$OUT/$NAME.iso" | cut -f1)), aus $DEB_ISO"
