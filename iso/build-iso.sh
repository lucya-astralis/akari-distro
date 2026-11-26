#!/usr/bin/env bash
# The Akari OS installer ISO: Debian 13's own netinst, checked against Debian's
# signed checksums, with Akari's preseed, its archive key and a first boot
# entry "Akari OS installieren" (BIOS and UEFI). Debian's signed boot chain
# (shim, GRUB, kernel) is not touched, so Secure Boot keeps working.
#
#   iso/build-iso.sh OUT-DIR
#
# Needs: curl, xorriso, gpgv, debian-keyring (Debian's CD signing key),
# cpio, gzip, librsvg2-bin, imagemagick. APT_URL: the Akari archive the installed system uses.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
APT_URL="${APT_URL:-https://apt.lucya.systems}"
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
X="$W/add"; mkdir -p "$X/preseed" "$X/akari" "$X/isolinux" "$X/boot/grub/theme" "$X/install.amd/gtk"
sed "s|@APT_URL@|$APT_URL|g" "$HERE/preseed/akari.cfg" > "$X/preseed/akari.cfg"
cp "$ROOT/keys/akari-archive.asc" "$X/akari/akari-archive-keyring.asc"
E="$W/orig"; mkdir -p "$E"
xorriso -osirrox on -indev "$SRC" \
  -extract /isolinux/gtk.cfg "$E/gtk.cfg" -extract /isolinux/menu.cfg "$E/menu.cfg" -extract /isolinux/stdmenu.cfg "$E/stdmenu.cfg" \
  -extract /boot/grub/grub.cfg "$E/grub.cfg" -extract /boot/grub/theme/1 "$E/theme-1" \
  -extract /install.amd/gtk/initrd.gz "$E/gtk-initrd.gz" -extract /md5sum.txt "$E/md5sum.txt" >/dev/null 2>&1
chmod -R u+w "$E"
PRESEED="preseed/file=/cdrom/preseed/akari.cfg"

say "Akari-Look: Banner, Boot-Hintergrund, Farben"
A="$W/art"; mkdir -p "$A"; cp "$HERE"/art/*.svg "$A/"
rsvg-convert "$A/banner.svg" -o "$A/banner-a.png" && convert "$A/banner-a.png" -alpha off "$A/banner.png"
rsvg-convert "$A/splash.svg" -o "$A/splash-a.png" && convert "$A/splash-a.png" -alpha off "$X/isolinux/splash.png"
convert -size 8x8 xc:'#5865f2' "$X/boot/grub/theme/hl_c.png"      # GRUB's highlight behind the chosen entry
# the installer's banner: a second cpio archive after Debian's initrd; the kernel
# unpacks both, and its files replace Debian's logo (light and dark theme)
G="$W/initrd-add"; mkdir -p "$G/usr/share/graphics"
cp "$A/banner.png" "$G/usr/share/graphics/logo_debian.png"
cp "$A/banner.png" "$G/usr/share/graphics/logo_debian_dark.png"
(cd "$G" && find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --quiet | gzip -9n) > "$W/initrd-add.gz"
cat "$E/gtk-initrd.gz" "$W/initrd-add.gz" > "$X/install.amd/gtk/initrd.gz"

# BIOS (isolinux): Akari first and the default; Debian's own entries stay below it
{
  printf 'default akari\nlabel akari\n\tmenu label ^Akari OS installieren\n\tmenu default\n\tkernel /install.amd/vmlinuz\n'
  printf '\tappend vga=788 initrd=/install.amd/gtk/initrd.gz %s --- quiet\n' "$PRESEED"
  sed -e '/^default /d' -e '/menu default/d' "$E/gtk.cfg"
} > "$X/isolinux/gtk.cfg"
sed 's|^menu title .*Debian GNU/Linux installer menu (BIOS mode)|menu title Akari OS - Installation (BIOS)|' "$E/menu.cfg" > "$X/isolinux/menu.cfg"
# vesamenu colours are #AARRGGBB: the chosen entry on Akari's violet
sed -e 's|#76a1d0ff|#c05865f2|g' "$E/stdmenu.cfg" > "$X/isolinux/stdmenu.cfg"
grep -q "Akari OS - Installation" "$X/isolinux/menu.cfg" || { echo "menu.cfg: Titel nicht gefunden" >&2; exit 1; }

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
  { print }' "$E/grub.cfg" > "$X/boot/grub/grub.cfg"
grep -q "Akari OS installieren" "$X/boot/grub/grub.cfg" || { echo "grub.cfg: kein menuentry gefunden" >&2; exit 1; }
# the theme: no Debian title over the lockup, Akari's label, white on violet when chosen
sed -e 's|^title-text: .*|title-text: ""|' \
    -e 's|Debian GNU/Linux UEFI Installer menu|Akari OS · Installation (UEFI)|' \
    -e 's|selected_item_color = "black"|selected_item_color = "white"|' "$E/theme-1" > "$X/boot/grub/theme/1"
grep -q "Akari OS · Installation (UEFI)" "$X/boot/grub/theme/1" || { echo "theme/1: Titel nicht gefunden" >&2; exit 1; }

# the ISO's own checksum list ("Datenträger prüfen") follows what changed
CHANGED=(isolinux/gtk.cfg isolinux/menu.cfg isolinux/stdmenu.cfg isolinux/splash.png boot/grub/grub.cfg
         boot/grub/theme/1 boot/grub/theme/hl_c.png install.amd/gtk/initrd.gz)
cp "$E/md5sum.txt" "$X/md5sum.txt"
for f in "${CHANGED[@]}"; do
  sum=$(md5sum "$X/$f" | cut -d' ' -f1)
  sed -i "s|^[0-9a-f]*  \./$f\$|$sum  ./$f|" "$X/md5sum.txt"
done
for f in preseed/akari.cfg akari/akari-archive-keyring.asc; do
  echo "$(md5sum "$X/$f" | cut -d' ' -f1)  ./$f" >> "$X/md5sum.txt"
done

say "ISO schreiben"
MAPS=(-map "$X/preseed" /preseed -map "$X/akari" /akari -map "$X/md5sum.txt" /md5sum.txt)
for f in "${CHANGED[@]}"; do MAPS+=(-map "$X/$f" "/$f"); done
xorriso -indev "$SRC" -outdev "$OUT/$NAME.iso" "${MAPS[@]}" -boot_image any replay >/dev/null 2>&1 \
  || { echo "xorriso ist gescheitert" >&2; exit 1; }
(cd "$OUT" && sha256sum "$NAME.iso" > "$NAME.iso.sha256")
echo "$DEB_ISO" > "$OUT/$NAME.base"
say "fertig: $OUT/$NAME.iso ($(du -h "$OUT/$NAME.iso" | cut -f1)), aus $DEB_ISO"
