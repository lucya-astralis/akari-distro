#!/usr/bin/env bash
# The whole Akari OS archive, built from scratch, for GitHub Pages (CI, in a
# debian:trixie container). Two suites:
#
#   stable    akari from its newest release tag (v*), if it has one
#   testing   akari from its main branch, as <version>+git<date>.<commit>
#
# akari-base and akari-archive-keyring come from this repo in both. Signed with
# the key in $APT_SIGNING_KEY (armored secret key); the result goes to public/.
#
#   tools/ci-archive.sh AKARI-CHECKOUT OUT
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AKARI="$(cd "$1" && pwd)"; OUT="$2"
W="$(mktemp -d)"
say() { printf '\n▸ %s\n' "$*"; }

say "Signierschlüssel"
export GNUPGHOME="$W/gnupg"; mkdir -m 700 "$GNUPGHOME"
[[ -n "${APT_SIGNING_KEY:-}" ]] || { echo "APT_SIGNING_KEY fehlt" >&2; exit 1; }
gpg --batch -q --import <<<"$APT_SIGNING_KEY"
FPR=$(cat "$ROOT/keys/akari-archive.fingerprint")
gpg --batch --with-colons -K "$FPR" | grep -q '^sec' || { echo "der Schlüssel im Secret ist nicht $FPR" >&2; exit 1; }

build_akari() {  # build_akari REF SUITE → .debs in $W/SUITE
  local ref=$1 suite=$2 src="$W/src-$2"
  git -C "$AKARI" worktree add -q --detach "$src" "$ref"
  if [[ $suite == testing ]]; then
    local v; v="$(dpkg-parsechangelog -l "$src/debian/changelog" -S Version)+git$(git -C "$src" log -1 --format=%cd --date=format:%Y%m%d).$(git -C "$src" rev-parse --short=7 HEAD)"
    sed -i "1s/(.*)/($v)/" "$src/debian/changelog"
  fi
  (cd "$src" && VENDOR_STRICT=1 tools/vendor.sh >/dev/null)
  (cd "$src" && dpkg-buildpackage -us -uc -b > "$W/build-$suite.log" 2>&1) || { tail -40 "$W/build-$suite.log"; exit 1; }
  # dpkg-buildpackage leaves its results next to the tree, in $W
  mkdir -p "$W/$suite" && mv "$W"/*.deb "$W/$suite/" && rm -f "$W"/*.changes "$W"/*.buildinfo
  say "akari für $suite: $(dpkg-parsechangelog -l "$src/debian/changelog" -S Version)"
}

say "akari-base, akari-archive-keyring"
AKARI_ARCHIVE_KEY="$ROOT/keys/akari-archive.asc" "$ROOT/tools/build.sh" "$W/distro"
if grep -E "^E:" "$W/distro/lintian.txt"; then echo "lintian: Fehler (oben)" >&2; exit 1; fi

say "akari testing (main)"
build_akari "$(git -C "$AKARI" rev-parse origin/main 2>/dev/null || git -C "$AKARI" rev-parse HEAD)" testing
TAG=$(git -C "$AKARI" tag -l 'v*' --sort=-v:refname | head -1)
if [[ -n "$TAG" ]]; then
  say "akari stable ($TAG)"
  build_akari "$TAG" stable
else
  say "akari hat noch keinen Release-Tag: stable bekommt nur akari-base und den Keyring"
fi

say "Paketquelle"
for suite in stable testing; do
  debs=("$W"/distro/*.deb)
  [[ -d "$W/$suite" ]] && debs+=("$W/$suite"/*.deb)
  "$ROOT/tools/archive.sh" "$W/apt" "$FPR" "$suite" "${debs[@]}" >/dev/null
  reprepro -b "$W/apt" list "$suite" | sed "s/^/  /"
done

mkdir -p "$OUT"
cp -r "$W/apt/dists" "$W/apt/pool" "$OUT/"
cp "$ROOT/keys/akari-archive.asc" "$OUT/akari-archive-keyring.asc"
gpg --dearmor < "$ROOT/keys/akari-archive.asc" > "$OUT/akari-archive-keyring.gpg"
printf 'Types: deb\nURIs: %s\nSuites: stable\nComponents: main\nSigned-By: /usr/share/keyrings/akari-archive-keyring.gpg\n' \
  "${APT_URL:-https://apt.lucya.systems}" > "$OUT/akari.sources"
sed -e "s|@URL@|${APT_URL:-https://apt.lucya.systems}|g" -e "s|@FPR@|$FPR|g" -e "s|@DATE@|$(date -u +%Y-%m-%dT%H:%MZ)|" \
  "$ROOT/site/index.html" > "$OUT/index.html"
touch "$OUT/.nojekyll"
gpgconf --kill all 2>/dev/null || true
rm -rf "$W"
say "fertig: $(du -sh "$OUT" | cut -f1) in $OUT"
