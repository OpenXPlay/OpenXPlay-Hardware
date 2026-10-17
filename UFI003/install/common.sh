#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: AGPL-3.0-only
# Created by riko chen on 2026-10-16
fail() { echo "Error: $*" >&2; exit 1; }
hash() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1";
    else shasum -a 256 "$1"; fi | awk '{print $1}'
}
verify() {
    case "$1" in *[!0-9a-f]*|'') fail "SHA256 placeholder or invalid digest for $2; fill debs.txt first" ;; esac
    [ "${#1}" -eq 64 ] || fail "SHA256 placeholder or invalid digest for $2; fill debs.txt first"
    [ -f "$2" ] || fail "Missing file: $2"
    [ "$(hash "$2")" = "$1" ] || fail "SHA256 mismatch: $2"
}
# Whitelist package filenames from the ordered manifest, verifying even installed packages.
verify_debs() {
    while read -r name version digest extra; do
        case "$name" in ''|'#'*) continue ;; esac
        [ -z "$extra" ] || fail "Invalid debs.txt row: $name"
        case "$name:$version" in *[!a-zA-Z0-9.+:~_-]*) fail "Invalid package: $name" ;; esac
        arch=arm64
        [ "$name" != libasound2-data ] || arch=all
        verify "$digest" "$1/debs/${name}_${version}_${arch}.deb"
    done < "$1/UFI003/install/debs.txt"
}
no_identity() {
    [ -z "$(find "$1" \( -type l -o -name identity.pk8 -o -name certificate.p7b -o -name mfi \) -print)" ] ||
        fail "Refusing symlinks or MFi identity material in $1"
}
