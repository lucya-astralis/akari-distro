#!/usr/bin/env bash
# A signed apt archive from .debs (reprepro), as apt.lucya.systems will serve it:
#   tools/archive.sh DIR KEY-ID [SUITE] DEB…
#     DIR      the archive (made if missing)
#     KEY-ID   the signing key in GNUPGHOME
#     SUITE    stable (default) or testing
set -euo pipefail
DIR=$1 KEY=$2; shift 2
SUITE=stable; [[ ${1:-} == stable || ${1:-} == testing ]] && { SUITE=$1; shift; }
mkdir -p "$DIR/conf"
cat > "$DIR/conf/distributions" <<EOT
Origin: Akari OS
Label: Akari OS
Suite: stable
Codename: stable
Architectures: amd64 arm64 source
Components: main
Description: Akari OS packages for Debian 13 (trixie)
SignWith: $KEY

Origin: Akari OS
Label: Akari OS
Suite: testing
Codename: testing
Architectures: amd64 arm64 source
Components: main
Description: Akari OS packages for Debian 13 (trixie), to try first
SignWith: $KEY
EOT
for deb in "$@"; do
  reprepro -b "$DIR" --silent includedeb "$SUITE" "$deb"
done
reprepro -b "$DIR" list "$SUITE"
