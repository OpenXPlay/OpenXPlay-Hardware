#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
# Stage "device", run as root from an unpacked N1 bundle; no network access.
# Usage: install-device.sh [--dry-run | --verify] [BUNDLE_DIR]
# Exit 2 means wrong hardware/OS/architecture, exit 1 means a failed stage.
set -eu
export LC_ALL=C
reported=false
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "$reported" = false ]; then echo "OXP-STAGE device failed: unexpected installer error (exit $rc)" >&2; exit 1; fi' 0
fail() { reported=true; echo "OXP-STAGE device failed: $*" >&2; exit 1; }
wrong() { reported=true; echo "OXP-STAGE device wrong-device: $*" >&2; exit 2; }
mode=install
case "${1:-}" in
--dry-run) mode=dry; shift ;;
--verify) mode=verify; shift ;;
esac
[ "$#" -le 1 ] || fail "Usage: $0 [--dry-run | --verify] [BUNDLE_DIR]"
case "${1:-}" in -*) fail "Unknown option: $1" ;; esac
dir=$(CDPATH= cd -- "${1:-$(dirname -- "$0")}" && pwd) || fail 'bundle directory not found'
# A fixture root supplies the same files as a booted N1, without bypassing validation.
root=${OPENXPLAY_N1_ROOT:-}
case "$root" in ''|/*) ;; *) fail 'OPENXPLAY_N1_ROOT must be absolute' ;; esac
root=${root%/}

# Schema-specific parser, like UFI003's: retain whitespace inside strings, reject duplicates.
host_profile_ok() {
    awk '
    { text = text $0 "\n" }
    function ws() { sub(/^[ \t\r\n]*/, "", text) }
    function take(token) {
        ws()
        if (substr(text, 1, length(token)) != token) return 0
        text = substr(text, length(token) + 1)
        return 1
    }
    END {
        expected["model"] = "\"Phicomm N1\""
        expected["wifiInterface"] = "\"wlan0\""
        expected["bluetoothAdapter"] = "\"hci0\""
        expected["secureConnections"] = "\"pairing-off\""
        if (!take("{")) exit 1
        for (i = 0; i < 4; i++) {
            ws()
            if (!match(text, /^"[A-Za-z]+"/)) exit 1
            key = substr(text, 2, RLENGTH - 2)
            text = substr(text, RLENGTH + 1)
            if (!(key in expected) || seen[key]++) exit 1
            if (!take(":") || !take(expected[key])) exit 1
            if (i < 3 && !take(",")) exit 1
        }
        if (!take("}")) exit 1
        ws()
        if (text != "") exit 1
    }' "$1"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
for c in dpkg dpkg-deb dpkg-query sha256sum awk df find sort cmp tr grep sed; do
    command -v "$c" >/dev/null || fail "missing command: $c"
done
[ "$(dpkg --print-architecture)" = arm64 ] || wrong 'requires Debian arm64'
[ -r "$root/etc/os-release" ] || wrong 'requires Debian 13 (missing /etc/os-release)'
os=$( . "$root/etc/os-release"; printf '%s:%s' "${ID:-}" "${VERSION_ID:-}" )
[ "$os" = debian:13 ] || wrong "requires Debian 13; found $os"
model=$(tr -d '\000' < "$root/proc/device-tree/model" 2>/dev/null) || model=
[ "$model" = 'Phicomm N1' ] || wrong "device-tree model is ${model:-unknown}; expected Phicomm N1"

cd "$dir"
[ -f SHA256SUMS ] && [ -f manifest.json ] && [ -f debs/debs.txt ] || fail 'not a device bundle'
newline='
'
carriage_return=$(printf '\r')
[ -z "$(find . \( -type l -o -name "*$newline*" -o -name "*$carriage_return*" -o -name '*\\*' \
    -o -name 'offline-mfi*' -o -name mfi -o -name tls.password -o -name '*.pk8' -o -name '*.p7b' \
    -o -name '*.p12' -o -name '*.pfx' \) -print)" ] || fail 'bundle contains unsafe paths, symlinks or identity material'
awk '
    {
        digest = substr($0, 1, 64); name = substr($0, 67)
        if (length(digest) != 64 || digest ~ /[^0-9a-fA-F]/ || substr($0, 65, 2) != "  " ||
            name == "" || name ~ /[\\\r]/ || seen[name]++) exit 1
        n = split(name, parts, "/")
        for (i = 1; i <= n; i++)
            if (parts[i] == "" || parts[i] == "." || parts[i] == "..") exit 1
    }
' SHA256SUMS || fail 'unsafe, malformed or duplicate SHA256SUMS entry'
# Complete coverage, with no persistent files even during preflight.
find . -type f ! -path ./SHA256SUMS | sed 's#^\./##' | sort | awk '
    FILENAME != "-" { listed[substr($0, 67)] = 1; next }
    { if (!($0 in listed)) bad = 1; delete listed[$0] }
    END { for (name in listed) bad = 1; exit bad }
' SHA256SUMS - || fail 'SHA256SUMS does not cover exactly the bundle files'
sha256sum -c --quiet --strict SHA256SUMS || fail 'checksum mismatch'

# Validate every ordered entry before any dpkg action, including skipped/newer packages.
set --
seen=' '
device_version=
count=0
while read -r pkg version digest extra || [ -n "$pkg" ]; do
    case "$pkg" in ''|'#'*) continue ;; esac
    [ -z "$extra" ] && printf '%s\n' "$pkg" | grep -Eq '^[a-z0-9][a-z0-9+.-]+$' &&
        printf '%s\n' "$version" | grep -Eq '^[0-9][0-9A-Za-z.+:~-]*$' &&
        printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid debs.txt row: $pkg"
    case "$seen" in *" $pkg "*) fail "duplicate package: $pkg" ;; esac
    [ -z "$device_version" ] || fail 'device package must be last in debs.txt'
    seen="$seen$pkg "
    deb=
    for candidate in "debs/${pkg}_${version#*:}_arm64.deb" "debs/${pkg}_${version#*:}_all.deb"; do
        [ -f "$candidate" ] || continue
        [ -z "$deb" ] || fail "ambiguous package architectures: $pkg"
        deb=$candidate
    done
    [ -n "$deb" ] || fail "missing pinned package: $pkg $version"
    arch=$(dpkg-deb -f "$deb" Architecture)
    case "$arch" in arm64|all) ;; *) fail "unsupported package architecture: $pkg $arch" ;; esac
    [ "$deb" = "debs/${pkg}_${version#*:}_${arch}.deb" ] &&
        [ "$(dpkg-deb -f "$deb" Package)" = "$pkg" ] && [ "$(dpkg-deb -f "$deb" Version)" = "$version" ] ||
        fail "control metadata does not match pin/filename: $deb"
    printf '%s  %s\n' "$digest" "$deb" | sha256sum -c --quiet --strict - || fail "pinned checksum mismatch: $pkg"
    count=$((count + 1))
    if [ "$pkg" = openxplay-phicomm-n1 ]; then
        [ "$arch" = all ] || fail 'device package architecture must be all'
        device_version=$version
    fi
    current=$(dpkg-query -W -f='${Status} ${Version}' "$pkg" 2>/dev/null || :)
    case "$current" in
    'install ok installed '*)
        now=${current##* }
        if dpkg --compare-versions "$now" ge "$version"; then
            echo "Already installed: $pkg $now (bundle: $version)"
            continue
        fi
        ;;
    *' '*)
        # An interrupted upgrade can leave newer unpacked bytes on disk. Do not replace those
        # with an older pin either; dpkg's dependency/audit checks will request repair.
        now=${current##* }
        if dpkg --compare-versions "$now" gt "$version"; then
            echo "Keeping newer package: $pkg $now (bundle: $version; repair its dpkg state separately)"
            continue
        fi
        ;;
    esac
    echo "Will install: $pkg $version"
    set -- "$@" "$dir/$deb"
done < debs/debs.txt
[ -n "$device_version" ] || fail 'missing device package in debs.txt'
[ "$(find debs -name '*.deb' -type f | wc -l | tr -d ' ')" -eq "$count" ] || fail 'debs.txt does not cover exactly the .deb files'

if [ "$mode" = verify ]; then
    bad=0
    check() { if "$@"; then :; else bad=$((bad + 1)); fi; }
    package_ok() {
        [ "$(dpkg-query -W -f='${Status} ${Version}' openxplay-phicomm-n1 2>/dev/null)" = "install ok installed $device_version" ] || {
            echo "FAIL package version: expected openxplay-phicomm-n1 $device_version"; return 1;
        }
        echo "ok   package version $device_version"
    }
    profile_ok() {
        host_profile_ok "$root/etc/openxplay/host.json" || { echo 'FAIL Phicomm N1 host profile'; return 1; }
        echo 'ok   Phicomm N1 host profile'
    }
    gadget_ok() {
        [ "$(systemctl is-enabled openxplay-usb-gadget.service 2>/dev/null)" = enabled ] || {
            echo 'FAIL USB gadget service is not enabled'; return 1;
        }
        echo 'ok   USB gadget enabled'
    }
    bluetooth_ok() {
        systemctl is-active --quiet bluetooth.service || { echo 'FAIL bluetooth.service is not active'; return 1; }
        echo 'ok   bluetooth.service active'
    }
    rfcomm_ok() {
        modprobe -n rfcomm || { echo "FAIL kernel $(uname -r) lacks usable RFCOMM support (modprobe -n rfcomm)"; return 1; }
        echo 'ok   rfcomm module resolves'
    }
    for c in systemctl modprobe; do command -v "$c" >/dev/null || fail "missing command: $c"; done
    check package_ok
    check profile_ok
    check gadget_ok
    check bluetooth_ok
    check rfcomm_ok
    [ "$bad" -eq 0 ] || fail "$bad verification check(s) failed"
    echo "OXP-STAGE device verified version=$device_version"
    exit 0
fi

free=$(df -Pk "${root:-/}" | awk 'NR == 2 {print $4}')
[ "${free:-0}" -ge 65536 ] || fail "only ${free:-0} KiB free on /"
if [ "$mode" = dry ]; then
    if [ "$#" -gt 0 ]; then dpkg --no-act -i "$@" >/dev/null || fail 'dpkg dependency check failed (bundle must be complete offline)'; fi
    echo "OXP-STAGE device preflight-ok version=$device_version"
    exit 0
fi
if [ "$#" -gt 0 ]; then
    # One transaction unpacks dependencies first, then configures them and the device package.
    DEBIAN_FRONTEND=noninteractive dpkg --force-confdef --force-confold -i "$@" || fail 'dpkg failed (bundle must be complete offline)'
fi
audit=$(dpkg --audit) || fail 'dpkg audit failed'
[ -z "$audit" ] || fail "dpkg reports unconfigured packages: $audit"
echo "OXP-STAGE device ok version=$device_version reboot=required"
