#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-19
#
# Stage "device" installer, run as root on the UFI003 from an unpacked device bundle.
# Usage: install-device.sh [--dry-run | --verify] [BUNDLE_DIR]
#   (none)     verify the bundle and the device, install the packages; a reboot follows
#   --dry-run  verify the bundle and the device and check package dependencies; change nothing
#   --verify   check an installed device after its reboot
# The last line is machine-readable for the flasher: "OXP-STAGE device <ok|preflight-ok|verified>
# ..." on success, "OXP-STAGE device failed: <reason>" (exit 1) or "... wrong-device: ..." (exit 2).
set -eu
krel=5.15.0-handsomekernel+
mode=install
case "${1:-}" in
--dry-run) mode=dry; shift ;;
--verify) mode=verify; shift ;;
esac
dir=$(CDPATH= cd -- "${1:-$(dirname -- "$0")}" && pwd)
fail() { echo "OXP-STAGE device failed: $*" >&2; exit 1; }
wrong() { echo "OXP-STAGE device wrong-device: $*" >&2; exit 2; }
export LC_ALL=C

# Validate the exact device profile with a small schema-specific JSON parser. Only
# the five literal keys/values below are accepted, in any order, with JSON whitespace.
# Keep whitespace inside strings intact; stripping it would accept incorrect values.
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
        expected["model"] = "\"UFI003\""
        expected["wifiInterface"] = "\"wlan0\""
        expected["bluetoothAdapter"] = "\"hci0\""
        expected["hotspotDownGapSeconds"] = "15"
        expected["secureConnections"] = "\"pairing-off\""
        if (!take("{")) exit 1
        for (i = 0; i < 5; i++) {
            ws()
            if (!match(text, /^"[A-Za-z]+"/)) exit 1
            key = substr(text, 2, RLENGTH - 2)
            text = substr(text, RLENGTH + 1)
            if (!(key in expected) || seen[key]++) exit 1
            if (!take(":") || !take(expected[key])) exit 1
            if (i < 4 && !take(",")) exit 1
        }
        if (!take("}")) exit 1
        ws()
        if (text != "") exit 1
    }' "$1"
}

if [ "$mode" = verify ]; then
    bad=0
    check() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; bad=$((bad + 1)); fi; }
    check 'package installed' "dpkg-query -W -f='\${Status}' openxplay-ufi003 | grep -qx 'install ok installed'"
    check 'fixed btqcomsmd selected' "[ \"\$(modinfo -n btqcomsmd)\" = /lib/modules/$krel/updates/btqcomsmd.ko ]"
    check 'fixed btqcomsmd loaded' "[ \"\$(cat /sys/module/btqcomsmd/srcversion)\" = 9AB11C2ECBD034761F265A3 ]"
    check 'rfcomm loaded' "[ -d /sys/module/rfcomm ]"
    check 'bluetooth active' 'systemctl is-active bluetooth.service'
    check 'bluetooth guard active' 'systemctl is-active openxplay-bt-guard.service'
    check 'hci0 up with an address' "hciconfig hci0 | grep -q 'UP RUNNING' && ! hciconfig hci0 | grep -q '00:00:00:00:00:00'"
    check 'guard state ok' "grep -q '\"state\":\"ok\"' /run/openxplay/bluetooth-guard.json"
    check 'UFI003 host profile' 'host_profile_ok /etc/openxplay/host.json'
    check 'system dnsmasq not failed' '! systemctl is-failed dnsmasq.service'
    [ "$bad" -eq 0 ] || fail "$bad check(s) failed"
    echo "OXP-STAGE device verified version=$(dpkg-query -W -f='${Version}' openxplay-ufi003)"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || fail 'run as root'
for c in dpkg dpkg-deb dpkg-query sha256sum awk df find sort; do command -v "$c" >/dev/null || fail "missing command: $c"; done
[ "$(uname -r)" = "$krel" ] || wrong "kernel $(uname -r), expected $krel"
[ "$(dpkg --print-architecture)" = arm64 ] || wrong 'not an arm64 Debian'
grep -qx 'VERSION_ID="11"' /etc/os-release || wrong 'not Debian 11'
if [ "${OPENXPLAY_FORCE_MODEL:-}" != 1 ]; then
    tr -d '\000' < /proc/device-tree/model 2>/dev/null | grep -qi openstick || wrong 'device tree model is not an OpenStick'
fi
free=$(df -Pk / | awk 'NR == 2 {print $4}')
[ "$free" -ge 65536 ] || fail "only ${free} KiB free on /"

cd "$dir"
[ -f SHA256SUMS ] && [ -f manifest.json ] || fail 'not a device bundle'
[ -z "$(find . \( -type l -o -name identity.pk8 -o -name certificate.p7b -o -name mfi \) -print)" ] ||
    fail 'bundle contains symlinks or identity material'
# Every file except SHA256SUMS must be listed exactly once, and every listed file must match.
find . -type f ! -path ./SHA256SUMS | sed 's#^\./##' | sort > /tmp/oxp-device-files.$$
awk '{ name = substr($0, 67); sub(/^\.\//, "", name); print name }' SHA256SUMS | sort > /tmp/oxp-device-listed.$$
if ! cmp -s /tmp/oxp-device-files.$$ /tmp/oxp-device-listed.$$; then
    rm -f /tmp/oxp-device-files.$$ /tmp/oxp-device-listed.$$
    fail 'SHA256SUMS does not cover exactly the bundle files'
fi
rm -f /tmp/oxp-device-files.$$ /tmp/oxp-device-listed.$$
sha256sum -c --quiet --strict SHA256SUMS || fail 'checksum mismatch'

list=
for deb in debs/*.deb; do
    name=$(dpkg-deb -f "$deb" Package)
    version=$(dpkg-deb -f "$deb" Version)
    current=$(dpkg-query -W -f='${Status} ${Version}' "$name" 2>/dev/null || :)
    if [ "$current" = "install ok installed $version" ]; then
        echo "Already installed: $name $version"
    else
        case "$current" in "install ok installed "*) now=" (now: ${current##* })" ;; *) now= ;; esac
        echo "Will install: $name $version$now"
        list="$list $dir/$deb"
    fi
done
device_version=$(dpkg-deb -f debs/openxplay-ufi003_*_arm64.deb Version)
if [ "$mode" = dry ]; then
    if [ -n "$list" ]; then
        # shellcheck disable=SC2086
        dpkg --no-act -i $list >/dev/null || fail 'dpkg dependency check failed'
    fi
    echo "OXP-STAGE device preflight-ok version=$device_version"
    exit 0
fi
if [ -n "$list" ]; then
    # One dpkg call: unpack everything, then configure in dependency order. Configuration files the
    # owner changed are kept.
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive dpkg --force-confdef --force-confold -i $list || fail 'dpkg failed'
fi
[ -z "$(dpkg --audit)" ] || fail 'dpkg reports unconfigured packages'
echo "OXP-STAGE device ok version=$device_version reboot=required"
