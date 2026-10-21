#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
# Usage: build-bundle.sh [--version VERSION] [--sources DIR] DEBS_DIR OUTPUT_DIR
# All inputs are local. debs/debs.txt preserves dependency order for the offline installer.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
n1=$(dirname "$here")
repo=$(dirname "$n1")
fail() { echo "Error: $*" >&2; exit 1; }
version=0.1.0
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
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$repo" log -1 --format=%ct 2>/dev/null || echo 1792540800)}
case "$SOURCE_DATE_EPOCH" in ''|*[!0-9]*) fail 'SOURCE_DATE_EPOCH must be an integer' ;; esac
export SOURCE_DATE_EPOCH LC_ALL=C
umask 022
sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
# macOS ar/bsdtar can read Debian control members without installing dpkg.
field() {
    if command -v dpkg-deb >/dev/null 2>&1; then dpkg-deb -f "$1" "$2"; return; fi
    member=$(ar t "$1" | sed 's#/$##' | grep '^control\.tar')
    ar p "$1" "$member" | tar -xOf - ./control | awk -v f="$2" '
        index($0, f ": ") == 1 { print substr($0, length(f) + 3); exit }'
}
name=openxplay-phicomm-n1-device-$version
stage=$(mktemp -d "$out/.$name.XXXXXX")
trap 'rm -rf "$stage"' 0
trap 'exit 1' HUP INT TERM
root=$stage/$name
mkdir -p "$root/debs"
cp -f "$n1/install/debs.txt" "$root/debs/debs.txt"
seen=' '
while read -r pkg ver digest extra || [ -n "$pkg" ]; do
    case "$pkg" in ''|'#'*) continue ;; esac
    [ -z "$extra" ] && printf '%s\n' "$pkg" | grep -Eq '^[a-z0-9][a-z0-9+.-]+$' &&
        printf '%s\n' "$ver" | grep -Eq '^[0-9][0-9A-Za-z.+:~-]*$' &&
        printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$' || fail "Invalid debs.txt row: $pkg"
    case "$seen" in *" $pkg "*) fail "Duplicate pinned package: $pkg" ;; esac
    [ "$pkg" != openxplay-phicomm-n1 ] || fail 'The device package must not be pinned in debs.txt'
    seen="$seen$pkg "
    found=
    # Debian filenames normally omit the version epoch. Architecture always comes from control.
    filever=${ver#*:}
    for f in "$debs/${pkg}_${filever}_arm64.deb" "$debs/${pkg}_${filever}_all.deb"; do
        [ -f "$f" ] || continue
        [ ! -L "$f" ] || fail "Symlink input: $f"
        [ -z "$found" ] || fail "Ambiguous package architectures: $pkg $ver"
        arch=$(field "$f" Architecture)
        case "$arch" in arm64|all) ;; *) fail "Unsupported architecture in $f: $arch" ;; esac
        [ "$(basename "$f")" = "${pkg}_${filever}_${arch}.deb" ] &&
            [ "$(field "$f" Package)" = "$pkg" ] && [ "$(field "$f" Version)" = "$ver" ] ||
            fail "Control metadata does not match filename/pin: $f"
        [ "$(sum "$f")" = "$digest" ] || fail "SHA-256 mismatch: $f"
        found=$f
    done
    [ -n "$found" ] || fail "Missing pinned .deb: $pkg $ver (arm64 or all)"
    cp -f "$found" "$root/debs/"
done < "$n1/install/debs.txt"
sh "$here/build-deb.sh" --version "$version" "$root/debs" >&2
device=$root/debs/openxplay-phicomm-n1_${version}_all.deb
# Keep the generated device package last, after all pinned dependencies (including an empty list).
printf '\nopenxplay-phicomm-n1 %s %s\n' "$version" "$(sum "$device")" >> "$root/debs/debs.txt"
cp -f "$here/install-device.sh" "$root/install-device.sh"
chmod 0755 "$root/install-device.sh"
if [ -n "$sources" ]; then
    mkdir -p "$root/sources"
    find "$sources" -maxdepth 1 -type f \( -name '*.dsc' -o -name '*.tar.*' -o -name '*.diff.gz' \) \
        -exec cp -f {} "$root/sources/" \;
fi
{
    echo 'Debian 13 packages in debs/ are unmodified Debian binaries. Their complete corresponding'
    echo "source (GPL/LGPL) is the Debian source package below, archived on snapshot.debian.org${sources:+ and included under sources/}."
    echo
    for f in "$root"/debs/*.deb; do
        b=$(field "$f" Package)
        [ "$b" != openxplay-phicomm-n1 ] || continue
        s=$(field "$f" Source); s=${s:-$b}
        sv=$(printf '%s' "$s" | sed -n 's/.*(\(.*\)).*/\1/p'); s=${s%% *}
        [ -n "$sv" ] || sv=$(field "$f" Version)
        echo "$b $(field "$f" Version): source $s $sv https://snapshot.debian.org/package/$s/$sv/"
    done
    echo
    echo 'openxplay-phicomm-n1: https://github.com/OpenXPlay/OpenXPlay-Hardware (PhicommN1/).'
} > "$root/SOURCES.txt"
json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
{
    cat <<EOF
{
  "schema": "org.openxplay.flash-stage/1",
  "stage": "device",
  "device": "phicomm-n1",
  "name": "$name",
  "version": "$version",
  "writes": "files",
  "transport": "ssh",
  "requires": {
    "stages": ["base"],
    "deviceTreeModel": "Phicomm N1",
    "debianVersion": "13",
    "dpkgArchitecture": "arm64",
    "freeKiB": 65536
  },
  "deviceDir": "/var/cache/openxplay/stages/device",
  "preflight": "sh install-device.sh --dry-run .",
  "install": "sh install-device.sh .",
  "reboot": "required",
  "verify": "sh install-device.sh --verify .",
  "success": {"preflight": "OXP-STAGE device preflight-ok", "install": "OXP-STAGE device ok", "verify": "OXP-STAGE device verified"},
  "rollback": "dpkg -r openxplay-phicomm-n1, or install-device.sh of the previous bundle",
  "packages": [
EOF
    sep=
    while read -r pkg ver digest extra || [ -n "$pkg" ]; do
        case "$pkg" in ''|'#'*) continue ;; esac
        # Resolve the validated filename from its control architecture, never its package name.
        for f in "$root/debs/${pkg}_${ver#*:}_"*.deb; do
            [ -f "$f" ] || fail "Missing staged package: $pkg"
            printf '%s    {"name": "%s", "version": "%s", "file": "debs/%s", "sha256": "%s"}' \
                "$sep" "$pkg" "$(json "$ver")" "$(basename "$f")" "$digest"
            sep=',
'
        done
    done < "$root/debs/debs.txt"
    printf '\n  ]\n}\n'
} > "$root/manifest.json"
newline='
'
carriage_return=$(printf '\r')
[ -z "$(find "$root" \( -type l -o -name "*$newline*" -o -name "*$carriage_return*" -o -name '*\\*' \
    -o -name 'offline-mfi*' -o -name mfi -o -name tls.password -o -name '*.pk8' -o -name '*.p7b' \
    -o -name '*.p12' -o -name '*.pfx' \) -print)" ] || fail 'Unsafe bundle path or identity material'
(cd "$root" && find . -type f ! -path ./SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sum "$f")" "$f"
done > SHA256SUMS)
find "$root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} + 2>/dev/null ||
    TZ=UTC0 find "$root" -exec touch -h -t "$(date -u -r "$SOURCE_DATE_EPOCH" +%Y%m%d%H%M.%S)" {} +
rm -rf "${out:?}/$name" "$out/$name.tar.gz"
mv -f "$root" "$out/$name"
if tar --version 2>/dev/null | grep -q 'GNU tar'; then owner='--owner=0 --group=0'; else owner='--uid 0 --gid 0'; fi
# shellcheck disable=SC2086
(cd "$out" && find "$name" | LC_ALL=C sort > "$stage/list" &&
    COPYFILE_DISABLE=1 tar --no-xattrs -cf "$stage/archive.tar" --no-recursion --numeric-owner $owner -T "$stage/list")
gzip -9n < "$stage/archive.tar" > "$out/$name.tar.gz"
echo "Bundle: $out/$name.tar.gz ($(sum "$out/$name.tar.gz"))"
