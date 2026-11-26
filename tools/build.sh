#!/usr/bin/env bash
# The packages of this repo, built on a Debian 13 (the dev VM of akari):
#   tools/build.sh [OUT]          .debs, sources and lintian.txt into OUT (default: build/)
# AKARI_ARCHIVE_KEY=<public .asc> builds the keyring with that key (a dev archive).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mkdir -p "${1:-$ROOT/build}" && cd "${1:-$ROOT/build}" && pwd)"
export AKARI_ARCHIVE_KEY="${AKARI_ARCHIVE_KEY:-$ROOT/keys/akari-archive.asc}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
for p in "$ROOT"/packages/*/; do
  name=$(basename "$p")
  cp -a "$p" "$W/$name"
  (cd "$W/$name" && dpkg-buildpackage -us -uc -sa > "$W/$name.log" 2>&1) || { tail -30 "$W/$name.log"; exit 1; }
done
cp "$W"/*.deb "$W"/*.dsc "$W"/*.tar.xz "$W"/*.changes "$OUT/"
lintian --profile debian --info "$OUT"/*.changes > "$OUT/lintian.txt" 2>&1 || true
grep -E "^[EW]:" "$OUT/lintian.txt" | sort -u || true
ls "$OUT"/*.deb
