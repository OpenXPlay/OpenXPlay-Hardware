#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: AGPL-3.0-only
# Created by riko chen on 2026-10-16
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/common.sh"
dry=false
if [ "${1:-}" = --dry-run ]; then dry=true; shift; fi
[ "$#" -eq 7 ] || fail "Usage: $0 [--dry-run] OUTPUT RELAY_BINARY OXP_BINARY WEB ADMIN DEBS RELAY_PACKAGING"
out=$1; relay=$2; oxp=$3; web=$4; admin=$5; debs=$6; packaging=$7
[ ! -e "$out" ] || [ -d "$out" ] || fail "Output is not a directory: $out"
[ ! -L "$out" ] || fail "Output must not be a symlink: $out"
for f in "$relay" "$oxp" "$web/receiver/index.html" "$admin/index.html" "$packaging/install.sh" "$packaging/openxplay-relay.service" "$packaging/../../LICENSE" "$packaging/../../LICENSE-GPL-3.0" "$packaging/../../NOTICE"; do
    [ -f "$f" ] || fail "Missing input: $f"
done
for input in "$relay" "$oxp" "$web" "$admin" "$debs" "$packaging"; do no_identity "$input"; done
# Verify before creating an output directory, including in dry-run mode.
while read -r name version digest extra; do
    case "$name" in ''|'#'*) continue ;; esac
    arch=arm64; [ "$name" != libasound2-data ] || arch=all
    verify "$digest" "$debs/${name}_${version}_${arch}.deb"
done < "$here/debs.txt"
module_digest=$(awk '$2 == "rfcomm.ko" {print $1}' "$here/../rfcomm/SHA256SUMS")
verify "$module_digest" "$here/../rfcomm/rfcomm.ko"
btqcomsmd_digest=$(awk '$2 == "btqcomsmd.ko" {print $1}' "$here/../btqcomsmd/SHA256SUMS")
verify "$btqcomsmd_digest" "$here/../btqcomsmd/btqcomsmd.ko"
if "$dry"; then echo "Would assemble verified UFI003 bundle at $out"; exit 0; fi
target=$out
out=$(mktemp -d "${target}.tmp.XXXXXX")
trap 'rm -rf "$out"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$out/bin" "$out/debs" "$out/packaging/licenses" "$out/UFI003/install" "$out/UFI003/rfcomm" "$out/UFI003/btqcomsmd" "$out/UFI003/bluetooth" "$out/UFI003/network"
cp -f "$relay" "$out/bin/openxplay-relay"
cp -f "$oxp" "$out/bin/oxp-relay"
cp -Rf "$web" "$out/web"
cp -Rf "$admin" "$out/admin"
cp -f "$packaging/install.sh" "$packaging/openxplay-relay.service" "$out/packaging/"
# The relay installer keeps the relay licenses and notices with the installed build.
cp -f "$packaging/../../LICENSE" "$packaging/../../LICENSE-GPL-3.0" "$packaging/../../NOTICE" "$out/packaging/licenses/"
cp -f "$here/"*.sh "$here/debs.txt" "$out/UFI003/install/"
cp -f "$here/../rfcomm/rfcomm.ko" "$here/../rfcomm/SHA256SUMS" "$out/UFI003/rfcomm/"
cp -f "$here/../btqcomsmd/btqcomsmd.ko" "$here/../btqcomsmd/SHA256SUMS" "$out/UFI003/btqcomsmd/"
cp -f "$here/../bluetooth/bt-guard.sh" "$here/../bluetooth/openxplay-bt-guard.service" "$out/UFI003/bluetooth/"
cp -f "$here/../network/openxplay-wifi-powersave.conf" "$here/../network/openxplay-wifi-scan-mac.conf" "$out/UFI003/network/"
while read -r name version digest extra; do
    case "$name" in ''|'#'*) continue ;; esac
    arch=arm64; [ "$name" != libasound2-data ] || arch=all
    cp -f "$debs/${name}_${version}_${arch}.deb" "$out/debs/"
done < "$here/debs.txt"
# Keep the line-oriented manifest unambiguous on macOS and Linux.
newline='
'
carriage_return=$(printf '\r')
[ -z "$(find "$out" \( -name "*$newline*" -o -name "*$carriage_return*" -o -name '*\\*' \) -print)" ] ||
    fail 'Newline, carriage return or backslash in bundle filename'
(cd "$out"; find . -type f ! -path ./SHA256SUMS | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(hash "$f")" "$f"
done > SHA256SUMS)
if [ -e "$target" ]; then
    no_identity "$target"
    if diff -qr "$out" "$target" >/dev/null; then
        echo "Bundle already current: $target"
        exit 0
    fi
    fail "Output differs: $target; choose a new output directory"
fi
mv -f "$out" "$target"
# macOS tar adds AppleDouble ._ files unless told not to; the installer rejects unlisted files.
COPYFILE_DISABLE=1 tar -czf "$target.tar.gz" -C "$target" .
echo "Bundle: $target.tar.gz (unpack on the device; no MFi identity included)"
