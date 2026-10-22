#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
root=${OPENXPLAY_N1_ROOT:-}
export LC_ALL=C
log() {
    printf 'openxplay-n1-bt-addr: %s\n' "$*" >&2
    if command -v logger >/dev/null 2>&1; then logger -t openxplay-n1-bt-addr "$*" || :; fi
}
fail() { log "$*"; exit 1; }
# btmgmt polls stdin and hangs with /dev/null, as supplied by systemd.
# An empty pipe works.
mgmt() { : | btmgmt -i hci0 "$@"; }
[ "$#" -eq 0 ] || fail "Usage: $0"
wait=${OPENXPLAY_N1_BT_WAIT:-30}
case "$wait" in ''|*[!0-9]*) fail 'OPENXPLAY_N1_BT_WAIT must be an integer' ;; esac
read_info() {
    info=$(mgmt info 2>/dev/null) || return 1
    current=$(printf '%s\n' "$info" | awk '$1 == "addr" { print tolower($2); exit }')
    [ -n "$current" ]
}
elapsed=0
until read_info; do
    if [ "$elapsed" -ge "$wait" ]; then log 'hci0: controller address is unavailable'; exit 0; fi
    sleep 1
    elapsed=$((elapsed + 1))
done
if [ "$current" != 43:45:c0:00:1f:ac ]; then log "hci0 keeps its own address $current"; exit 0; fi
old=$current
factory=$root/proc/device-tree/soc/ethernet@c9410000/local-mac-address
if [ ! -r "$factory" ]; then log 'hci0: factory Ethernet address is unavailable'; exit 0; fi
octets=$(od -An -v -tu1 "$factory") || { log 'hci0: cannot read the factory Ethernet address'; exit 0; }
set -- $octets
if [ "$#" -ne 6 ]; then log 'hci0: factory Ethernet address is not 6 bytes'; exit 0; fi
case "$1:$2:$3:$4:$5:$6" in
0:0:0:0:0:0|255:255:255:255:255:255) log 'hci0: invalid factory Ethernet address'; exit 0 ;;
esac
first=$1
if [ $((first & 1)) -ne 0 ]; then log 'hci0: multicast factory Ethernet address'; exit 0; fi
derived=$(printf '%02x:%02x:%02x:%02x:%02x:%02x' "$((((first | 2) & 254) ^ 4))" "$2" "$3" "$4" "$5" "$6")
powered=false
if printf '%s\n' "$info" | awk '
    $1 == "current" && $2 == "settings:" {
        for (i=3; i<=NF; i++) if ($i == "powered") found=1
    }
    END { exit !found }
'; then powered=true; fi
restore_power() {
    if "$powered"; then
        mgmt power on >/dev/null || log 'hci0: failed to restore controller power'
    fi
}
# The kernel writes the address only when opening hci0 after Set Public Address.
# This is lost if hci0 is still up (the 2 s after setup) or another power-on is
# in progress. Run before bluetoothd, power hci0 on and off first, then wait
# for the address before touching power again.
for attempt in 1 2 3; do
    if [ "$attempt" -gt 1 ]; then sleep 1; fi
    mgmt power on >/dev/null || {
        restore_power
        fail 'hci0: failed to power on the controller'
    }
    mgmt power off >/dev/null || {
        restore_power
        fail 'hci0: failed to power off the controller'
    }
    if mgmt public-addr "$derived" >/dev/null; then break; fi
    if [ "$attempt" -lt 3 ]; then continue; fi
    restore_power
    fail "hci0: failed to set public address $derived"
done
elapsed=0
while :; do
    if read_info && [ "$current" = "$derived" ]; then break; fi
    if [ "$elapsed" -ge 10 ]; then
        restore_power
        fail "hci0: public address verification failed; expected $derived, got ${current:-unavailable}"
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done
if "$powered"; then
    mgmt power on >/dev/null || fail 'hci0: failed to restore controller power'
fi
log "hci0: replaced the default controller address $old with $derived (derived from the factory Ethernet address)"
exit 0
