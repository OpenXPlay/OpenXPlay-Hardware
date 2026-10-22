#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
root=${OPENXPLAY_N1_ROOT:-}
export LC_ALL=C
log() { printf 'openxplay-n1-phy-id: %s\n' "$*" >&2; }
fail() { log "$*"; exit 1; }
[ "$#" -eq 1 ] || fail "Usage: $0 apply|revert|status"
case "$1" in apply|revert|status) ;; *) fail "Usage: $0 apply|revert|status" ;; esac
node=/soc/bus@c8834000/mdio@558/mdio@0/ethernet-phy@0
id=ethernet-phy-id001c.c916
c22=ethernet-phy-ieee802.3-c22
expected="$id $c22"
expected_bytes=$(printf '%s\000%s\000' "$id" "$c22" | od -An -v -tu1 |
    awk '{ $1=$1; printf "%s%s", sep, $0; sep=" " }')
state=$root/var/lib/openxplay-phicomm-n1/dtb
tmp=; work=
cleanup() {
    [ -z "$tmp" ] || rm -f "$tmp"
    [ -z "$work" ] || rm -rf "$work"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
# Only the writers serialise; status is read-only and works for any user.
if [ "$1" != status ] && command -v flock >/dev/null 2>&1; then
    mkdir -p "$root/run/lock" || fail 'cannot create lock directory'
    exec 9>"$root/run/lock/openxplay-n1-phy-id.lock"
    flock 9 || fail 'cannot lock PHY fix'
fi
boot_dtb() {
    reason="missing $root/boot/uEnv.txt"
    [ -r "$root/boot/uEnv.txt" ] || return 1
    fdt=$(sed -n 's/^FDT=//p' "$root/boot/uEnv.txt" | tr -d '\r')
    case "$fdt" in
    /dtb/amlogic/meson-gxl-s905d-phicomm-n1.dtb|/dtb/amlogic/meson-gxl-s905d-phicomm-n1-thresh.dtb) ;;
    *) reason="FDT=${fdt:-missing}"; return 1 ;;
    esac
    dtb=$root/boot$fdt
    base=${fdt##*/}
    reason="missing $dtb"
    [ -f "$dtb" ]
}
compatible_is_ours() {
    compatible=$(fdtget -t s "$1" "$node" compatible 2>/dev/null) || return 1
    [ "$compatible" = "$expected" ] || return 1
    # The byte check distinguishes two strings from a single string containing a space.
    bytes=$(fdtget -t bu "$1" "$node" compatible 2>/dev/null) || return 1
    [ "$bytes" = "$expected_bytes" ]
}
apply() {
    if ! boot_dtb; then log "unsupported $reason"; return 0; fi
    properties=$(fdtget -p "$dtb" "$node" 2>/dev/null) || {
        log "PHY node missing in $dtb"; return 0;
    }
    if ! printf '%s\n' "$properties" | grep -qx reset-gpios; then
        log "PHY node has no reset-gpios in $dtb"; return 0
    fi
    reg=$(fdtget -t x "$dtb" "$node" reg 2>/dev/null) || reg=
    if [ "$reg" != 0 ]; then log "PHY node reg is not 0 in $dtb"; return 0; fi
    if printf '%s\n' "$properties" | grep -qx compatible; then
        if compatible_is_ours "$dtb"; then return 0; fi
        log "keeping the existing PHY compatible in $dtb"; return 0
    fi
    identified=false
    phy_id=
    # Find the PHY by its device-tree node: the bus number changes whenever the bus is rebound.
    for device in "$root"/sys/bus/mdio_bus/devices/*; do
        [ -r "$device/phy_id" ] || continue
        case "$(readlink -f "$device/of_node" 2>/dev/null)" in
        *"/devicetree/base$node")
            phy_id=$(tr '[:upper:]' '[:lower:]' < "$device/phy_id") || phy_id=
            break
            ;;
        esac
    done
    case "$phy_id" in
    0x001cc916) identified=true ;;
    '') ;;
    *) log "different phy_id $phy_id; leaving $dtb untouched"; return 0 ;;
    esac
    running=$root/proc/device-tree$node/compatible
    if ! "$identified" && [ -r "$running" ]; then
        first=$(tr '\000' '\n' < "$running" | sed -n '1p')
        if [ "$first" = "$id" ]; then identified=true; fi
    fi
    if ! "$identified"; then
        log 'PHY not identified on this boot; will retry at the next boot'; return 0
    fi
    mkdir -p "$state" || fail 'cannot create DTB state directory'
    cp -f "$dtb" "$state/$base" || fail "cannot back up $dtb"
    work=$(mktemp -d "$state/.verify.XXXXXX") || fail 'cannot create verification directory'
    tmp=$(dirname "$dtb")/.$base.openxplay-new
    cp -f "$dtb" "$tmp" || fail "cannot copy $dtb for patching"
    fdtput -t s "$tmp" "$node" compatible "$id" "$c22" || fail "fdtput failed for $dtb"
    compatible_is_ours "$tmp" || fail "compatible verification failed for $dtb"
    dtc -q -I dtb -O dts "$dtb" > "$work/stock.dts" || fail "dtc failed for stock $dtb"
    dtc -q -I dtb -O dts "$tmp" > "$work/patched.dts" || fail "dtc failed for patched $dtb"
    rc=0
    diff -U0 "$work/stock.dts" "$work/patched.dts" > "$work/change.diff" || rc=$?
    [ "$rc" -eq 1 ] || fail "unexpected DTB diff for $dtb"
    awk '
        /^--- / || /^\+\+\+ / || /^@@/ { next }
        /^\+/ { added++; if ($0 !~ /^\+[[:space:]]*compatible = /) bad=1 }
        /^-/ { removed++ }
        END { exit !(added == 1 && removed == 0 && !bad) }
    ' "$work/change.diff" || fail "DTB diff is not exactly one added compatible line for $dtb"
    sync "$tmp" || fail "cannot sync patched $dtb"
    mv -f "$tmp" "$dtb" || fail "cannot replace $dtb"
    sync || fail "cannot sync $dtb"
    hash=$(sha256sum "$dtb") || fail "cannot hash patched $dtb"
    printf '%s\n' "${hash%% *}" > "$state/$base.sha256" || fail "cannot record checksum for $dtb"
    log "patched $dtb; takes effect at the next boot"
}
revert() {
    for base in meson-gxl-s905d-phicomm-n1.dtb meson-gxl-s905d-phicomm-n1-thresh.dtb; do
        backup=$state/$base
        record=$state/$base.sha256
        [ -f "$backup" ] && [ -f "$record" ] || continue
        dtb=$root/boot/dtb/amlogic/$base
        recorded=$(cat "$record") || recorded=
        hash=$(sha256sum "$dtb" 2>/dev/null) || hash=
        if [ -n "$recorded" ] && [ "${hash%% *}" = "$recorded" ]; then
            tmp=$(dirname "$dtb")/.$base.openxplay-new
            cp -f "$backup" "$tmp" || fail "cannot copy backup for $dtb"
            sync "$tmp" || fail "cannot sync backup for $dtb"
            mv -f "$tmp" "$dtb" || fail "cannot restore $dtb"
            sync || fail "cannot sync restored $dtb"
            log "restored $dtb"
        else
            log "changed $dtb; discarding backup and checksum"
        fi
        rm -f "$backup" "$record" || log "cannot delete records for $dtb"
    done
}
case "$1" in
apply) apply ;;
revert) revert ;;
status)
    if ! boot_dtb; then
        printf 'unsupported %s\n' "$reason"
    elif compatible_is_ours "$dtb"; then
        printf 'patched %s\n' "$dtb"
    else
        printf 'unpatched %s\n' "$dtb"
    fi
    ;;
esac
exit 0
