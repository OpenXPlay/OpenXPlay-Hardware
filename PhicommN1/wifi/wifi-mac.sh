#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
root=${OPENXPLAY_N1_ROOT:-}
export LC_ALL=C
log() {
    printf 'openxplay-n1-wifi-mac: %s\n' "$*" >&2
    if command -v logger >/dev/null 2>&1; then logger -t openxplay-n1-wifi-mac "$*" || :; fi
}
fail() { log "$*"; exit 1; }
[ "$#" -eq 1 ] || fail "Usage: $0 wlanN"
iface=$1
case "$iface" in
wlan*) number=${iface#wlan}; case "$number" in ''|*[!0-9]*) fail "invalid interface: $iface" ;; esac ;;
*) fail "invalid interface: $iface" ;;
esac
net=$root/sys/class/net/$iface
if [ ! -r "$net/address" ]; then log "$iface: current address is unavailable"; exit 0; fi
current=$(tr '[:upper:]' '[:lower:]' < "$net/address") || {
    log "$iface: cannot read the current address"; exit 0;
}
placeholder=false
for name in brcmfmac43455-sdio.phicomm,n1.txt brcmfmac43455-sdio.txt; do
    nvram=$root/lib/firmware/brcm/$name
    [ -r "$nvram" ] || continue
    if tr -d '\r' < "$nvram" | awk -v address="$current" '
        /^macaddr=/ { if (tolower(substr($0, 9)) == address) found=1 }
        END { exit !found }
    '; then placeholder=true; break; fi
done
if ! "$placeholder"; then log "$iface keeps its own address $current"; exit 0; fi
factory=$root/proc/device-tree/soc/ethernet@c9410000/local-mac-address
if [ ! -r "$factory" ]; then log "$iface: factory Ethernet address is unavailable"; exit 0; fi
octets=$(od -An -v -tu1 "$factory") || { log "$iface: cannot read the factory Ethernet address"; exit 0; }
set -- $octets
if [ "$#" -ne 6 ]; then log "$iface: factory Ethernet address is not 6 bytes"; exit 0; fi
case "$1:$2:$3:$4:$5:$6" in
0:0:0:0:0:0|255:255:255:255:255:255) log "$iface: invalid factory Ethernet address"; exit 0 ;;
esac
first=$1
if [ $((first & 1)) -ne 0 ]; then log "$iface: multicast factory Ethernet address"; exit 0; fi
derived=$(printf '%02x:%02x:%02x:%02x:%02x:%02x' "$(((first | 2) & 254))" "$2" "$3" "$4" "$5" "$6")
flags=$(cat "$net/flags" 2>/dev/null) || flags=
case "$flags" in
0x*) digits=${flags#0x} ;;
*) digits= ;;
esac
case "$digits" in
''|*[!0-9a-fA-F]*) log "$iface: interface flags are unavailable"; exit 0 ;;
esac
if [ $((flags & 1)) -ne 0 ]; then log "$iface: interface is up; keeping $current"; exit 0; fi
ip link set dev "$iface" address "$derived" || fail "$iface: failed to set address $derived"
log "$iface: replaced the shared NVRAM address $current with $derived (derived from the factory Ethernet address)"
exit 0
