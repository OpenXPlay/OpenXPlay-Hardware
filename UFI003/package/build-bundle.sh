#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-19
#
# Builds the flash stage "device" for the UFI003: openxplay-ufi003-device-<version>.tar.gz with the
# pinned Debian 11 packages from install/debs.txt, the openxplay-ufi003 package, a manifest for the
# flasher, the on-device installer and SHA256SUMS. Files only: it writes no partition.
#
# Usage: build-bundle.sh [--version VERSION] [--sources DIR] DEBS_DIR OUTPUT_DIR
#   DEBS_DIR  the Debian .deb files named in install/debs.txt (verified against its digests)
#   --sources Debian source packages (.dsc, .tar.*, .diff.gz) to ship under sources/ for the
#             GPL/LGPL packages; without it SOURCES.txt names them on snapshot.debian.org
# Runs on Linux or macOS; the package itself is built by build-deb.sh (Docker when needed).
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ufi=$(dirname "$here")
repo=$(dirname "$ufi")
fail() { echo "Error: $*" >&2; exit 1; }
version=0.2.1
sources=
while [ "$#" -gt 2 ]; do
    case "$1" in
    --version) version=$2; shift 2 ;;
    --sources) sources=$(CDPATH= cd -- "$2" && pwd); shift 2 ;;
    *) fail "Unknown option: $1" ;;
    esac
done
[ "$#" -eq 2 ] || fail "Usage: $0 [--version VERSION] [--sources DIR] DEBS_DIR OUTPUT_DIR"
case "$version" in ''|*[!0-9A-Za-z.+~-]*|[!0-9]*) fail "Invalid Debian version: $version" ;; esac
debs=$(CDPATH= cd -- "$1" && pwd)
mkdir -p "$2"
out=$(CDPATH= cd -- "$2" && pwd)
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH=$(git -C "$repo" log -1 --format=%ct 2>/dev/null || echo 1760832000)
fi
export SOURCE_DATE_EPOCH
sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
# Prefer the Debian parser on Linux. Without dpkg (macOS), give tar a named archive so it can
# detect compression: GNU tar cannot auto-decompress a control.tar.xz arriving on stdin. Keep
# every extraction step separate, since a trailing awk would otherwise hide a failed tar.
field() (
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -f "$1" "$2" || fail "Cannot read Debian control metadata: $1"
        exit
    fi
    control_work=$(mktemp -d)
    trap 'rm -rf "$control_work"' 0
    trap 'exit 1' HUP INT TERM
    ar t "$1" > "$control_work/members" || fail "Cannot list Debian archive: $1"
    member=$(sed 's#/$##' "$control_work/members" | grep '^control\.tar\(\.[a-z0-9]*\)\?$') ||
        fail "Missing Debian control archive: $1"
    [ "$(printf '%s\n' "$member" | wc -l)" -eq 1 ] || fail "Ambiguous Debian control archive: $1"
    ar p "$1" "$member" > "$control_work/$member" || fail "Cannot read Debian control archive: $1"
    tar -xOf "$control_work/$member" ./control > "$control_work/control" ||
        fail "Cannot extract Debian control metadata: $1"
    awk -v f="$2" 'index($0, f ": ") == 1 { print substr($0, length(f) + 3); exit }' "$control_work/control"
)
name=openxplay-ufi003-device-$version
stage=$(mktemp -d "$out/.$name.XXXXXX")
trap 'rm -rf "$stage"' 0
trap 'exit 1' HUP INT TERM
root=$stage/$name
mkdir -p "$root/debs"

while read -r pkg ver digest extra; do
    case "$pkg" in ''|'#'*) continue ;; esac
    [ -z "$extra" ] || fail "Invalid debs.txt row: $pkg"
    arch=arm64; [ "$pkg" != libasound2-data ] || arch=all
    f=$debs/${pkg}_${ver}_${arch}.deb
    [ -f "$f" ] || fail "Missing $f"
    [ "$(sum "$f")" = "$digest" ] || fail "SHA-256 mismatch: $f"
    [ "$(field "$f" Package)" = "$pkg" ] && [ "$(field "$f" Version)" = "$ver" ] &&
        [ "$(field "$f" Architecture)" = "$arch" ] || fail "Control metadata does not match pin: $f"
    cp "$f" "$root/debs/"
done < "$ufi/install/debs.txt"
sh "$here/build-deb.sh" --version "$version" "$root/debs" >&2
device=$root/debs/openxplay-ufi003_${version}_arm64.deb
[ -f "$device" ] && [ "$(field "$device" Package)" = openxplay-ufi003 ] &&
    [ "$(field "$device" Version)" = "$version" ] && [ "$(field "$device" Architecture)" = arm64 ] ||
    fail 'Invalid generated device package control metadata'
cp "$here/install-device.sh" "$root/install-device.sh"
chmod 0755 "$root/install-device.sh"

if [ -n "$sources" ]; then
    mkdir -p "$root/sources"
    find "$sources" -maxdepth 1 -type f \( -name '*.dsc' -o -name '*.tar.*' -o -name '*.diff.gz' \) \
        -exec cp {} "$root/sources/" \;
fi
{
    echo "Debian 11 packages in debs/ are unmodified binaries from deb.debian.org. Their complete"
    echo "corresponding source (GPL/LGPL) is the Debian source package below, archived on"
    echo "snapshot.debian.org${sources:+ and included under sources/}."
    echo
    for f in "$root"/debs/*.deb; do
        b=$(field "$f" Package)
        [ "$b" != openxplay-ufi003 ] || continue
        s=$(field "$f" Source); s=${s:-$b}
        sv=$(printf '%s' "$s" | sed -n 's/.*(\(.*\)).*/\1/p'); s=${s%% *}
        [ -n "$sv" ] || sv=$(field "$f" Version)
        echo "$b $(field "$f" Version): source $s $sv https://snapshot.debian.org/package/$s/$sv/"
    done
    echo
    echo "openxplay-ufi003: https://github.com/OpenXPlay/OpenXPlay-Hardware (UFI003/), kernel module"
    echo "sources and build scripts under UFI003/rfcomm and UFI003/btqcomsmd."
} > "$root/SOURCES.txt"

json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
{
    printf '{\n'
    printf '  "schema": "org.openxplay.flash-stage/1",\n'
    printf '  "stage": "device",\n'
    printf '  "device": "ufi003",\n'
    printf '  "name": "%s",\n' "$name"
    printf '  "version": "%s",\n' "$(json "$version")"
    printf '  "writes": "files",\n'
    printf '  "transport": "adb",\n'
    printf '  "requires": {\n'
    printf '    "stages": ["base"],\n'
    printf '    "kernelRelease": "5.15.0-handsomekernel+",\n'
    printf '    "deviceTreeModel": "Handsome Openstick",\n'
    printf '    "debianVersion": "11",\n'
    printf '    "dpkgArchitecture": "arm64",\n'
    printf '    "freeKiB": 65536\n'
    printf '  },\n'
    printf '  "deviceDir": "/var/cache/openxplay/stages/device",\n'
    printf '  "preflight": "sh install-device.sh --dry-run .",\n'
    printf '  "install": "sh install-device.sh .",\n'
    printf '  "reboot": "required",\n'
    printf '  "verify": "sh install-device.sh --verify .",\n'
    printf '  "success": {"preflight": "OXP-STAGE device preflight-ok", "install": "OXP-STAGE device ok", "verify": "OXP-STAGE device verified"},\n'
    printf '  "rollback": "dpkg -r openxplay-ufi003, or install-device.sh of the previous bundle",\n'
    printf '  "packages": [\n'
    sep=
    for f in "$root"/debs/*.deb; do
        pkg=$(field "$f" Package) || fail "Cannot read package name: $f"
        ver=$(field "$f" Version) || fail "Cannot read package version: $f"
        printf '%s\n' "$pkg" | grep -Eq '^[a-z0-9][a-z0-9+.-]+$' &&
            printf '%s\n' "$ver" | grep -Eq '^[0-9][0-9A-Za-z.+:~_-]*$' ||
            fail "Invalid Debian package entry: $f"
        printf '%s    {"name": "%s", "version": "%s", "file": "debs/%s", "sha256": "%s"}' \
            "$sep" "$(json "$pkg")" "$(json "$ver")" \
            "$(basename "$f")" "$(sum "$f")"
        sep=',
'
    done
    printf '\n  ]\n}\n'
} > "$root/manifest.json"

(cd "$root" && find . -type f ! -name SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sum "$f")" "$f"
done > SHA256SUMS)
find "$root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} + 2>/dev/null ||
    TZ=UTC0 find "$root" -exec touch -h -t "$(date -u -r "$SOURCE_DATE_EPOCH" +%Y%m%d%H%M.%S)" {} +
rm -rf "${out:?}/$name" "$out/$name.tar.gz"
mv "$root" "$out/$name"
# Deterministic archive: sorted names, fixed owner and times, no gzip timestamp.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then owner='--owner=0 --group=0'; else owner='--uid 0 --gid 0'; fi
# shellcheck disable=SC2086
(cd "$out" && find "$name" | LC_ALL=C sort > "$stage/list" &&
    COPYFILE_DISABLE=1 tar --no-xattrs -cf - --no-recursion --numeric-owner $owner -T "$stage/list") |
    gzip -9n > "$out/$name.tar.gz"
echo "Bundle: $out/$name.tar.gz ($(sum "$out/$name.tar.gz"))"
