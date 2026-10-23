#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
program=$here/../../wifi/wifi-mac.sh
fail() { echo "FAIL N1 Wi-Fi MAC: $*" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
pass=0
check() {
    title=$1; shift
    "$@" || fail "$title"
    echo "PASS $title"
    pass=$((pass + 1))
}
mkdir -p "$work/bin"
cat > "$work/bin/ip" <<'EOF'
#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
printf '%s\n' "$*" >> "$TEST_IP_LOG"
exit "${TEST_IP_EXIT:-0}"
EOF
cat > "$work/bin/logger" <<'EOF'
#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
printf '%s\n' "$*" >> "$TEST_LOGGER_LOG"
exit "${TEST_LOGGER_EXIT:-0}"
EOF
chmod 0755 "$work/bin/ip" "$work/bin/logger"
PATH=$work/bin:$PATH
export PATH
fixture() {
    root=$work/$1
    net=$root/sys/class/net/wlan0
    brcm=$root/lib/firmware/brcm
    factory=$root/proc/device-tree/soc/ethernet@c9410000/local-mac-address
    mkdir -p "$net" "$brcm" "$(dirname "$factory")"
    printf 'b8:27:eb:74:f2:6c\n' > "$net/address"
    printf '0x1002\n' > "$net/flags"
    printf 'macaddr=B8:27:EB:74:F2:6C\r\n' > "$brcm/brcmfmac43455-sdio.phicomm,n1.txt"
    printf 'macaddr=b8:27:eb:74:f2:6d\n' > "$brcm/brcmfmac43455-sdio.txt"
    printf '\374\174\002\207\001\206' > "$factory"
    OPENXPLAY_N1_ROOT=$root
    TEST_IP_LOG=$root/ip.log
    TEST_LOGGER_LOG=$root/logger.log
    export OPENXPLAY_N1_ROOT TEST_IP_LOG TEST_LOGGER_LOG
    : > "$TEST_IP_LOG"
    : > "$TEST_LOGGER_LOG"
}
run() { sh "$program" "$@" > "$root/stdout" 2> "$root/stderr"; }
no_ip() { test ! -s "$TEST_IP_LOG"; }
expected=$work/expected-ip
printf 'link set dev wlan0 address fe:7c:02:87:01:86\n' > "$expected"

fixture vendor-placeholder
printf 'B8:27:EB:74:F2:6C\n' > "$net/address"
check 'vendor NVRAM placeholder replaced' run wlan0
check 'vendor placeholder uses the derived unicast address' cmp "$expected" "$TEST_IP_LOG"
message='wlan0: replaced the shared NVRAM address b8:27:eb:74:f2:6c with fe:7c:02:87:01:86 (derived from the factory Ethernet address)'
check 'replacement logged to stderr' grep -Fxq "openxplay-n1-wifi-mac: $message" "$root/stderr"
check 'replacement logged with the Wi-Fi tag' grep -Fxq -- "-t openxplay-n1-wifi-mac $message" "$TEST_LOGGER_LOG"
check 'no messages on stdout' test ! -s "$root/stdout"

fixture generic-placeholder
printf 'b8:27:eb:74:f2:6d\n' > "$net/address"
check 'generic NVRAM placeholder replaced' run wlan0
check 'generic placeholder uses the derived address' cmp "$expected" "$TEST_IP_LOG"

fixture real-address
printf '02:11:22:33:44:55\n' > "$net/address"
check 'real address accepted' run wlan0
check 'real address kept' no_ip
check 'own address logged' grep -q 'wlan0 keeps its own address' "$root/stderr"

for kind in missing short long zero ff multicast; do
    fixture "factory-$kind"
    case "$kind" in
    missing) rm -f "$factory" ;;
    short) printf '\374\174\002\207\001' > "$factory" ;;
    long) printf '\374\174\002\207\001\206\000' > "$factory" ;;
    zero) printf '\000\000\000\000\000\000' > "$factory" ;;
    ff) printf '\377\377\377\377\377\377' > "$factory" ;;
    multicast) printf '\375\174\002\207\001\206' > "$factory" ;;
    esac
    check "$kind factory address skipped" run wlan0
    check "$kind factory address makes no ip call" no_ip
done

fixture interface-up
printf '0x1003\n' > "$net/flags"
check 'running interface skipped' run wlan0
check 'running interface makes no ip call' no_ip
check 'running interface skip logged' grep -q 'interface is up' "$root/stderr"

for kind in missing invalid; do
    fixture "flags-$kind"
    case "$kind" in missing) rm -f "$net/flags" ;; invalid) printf 'unknown\n' > "$net/flags" ;; esac
    check "$kind flags skipped" run wlan0
    check "$kind flags make no ip call" no_ip
done

for name in wlan wlan0extra wlan-1 eth0 'wlan0/../eth0'; do
    fixture "bad-name-$pass"
    if run "$name"; then fail "accepted interface $name"; fi
    check "invalid interface $name makes no ip call" no_ip
done
fixture missing-argument
if run; then fail 'accepted missing interface'; fi
check 'missing interface makes no ip call' no_ip

fixture ip-failure
if env TEST_IP_EXIT=1 sh "$program" wlan0 > "$root/stdout" 2> "$root/stderr"; then fail 'ip failure ignored'; fi
check 'ip failure still used the expected arguments' cmp "$expected" "$TEST_IP_LOG"
check 'ip failure logged' grep -q 'failed to set address' "$root/stderr"

fixture logger-failure
check 'logger failure does not prevent replacement' env TEST_LOGGER_EXIT=1 sh "$program" wlan0
check 'logger failure still called ip' cmp "$expected" "$TEST_IP_LOG"
echo "PASS $pass N1 Wi-Fi MAC checks"
