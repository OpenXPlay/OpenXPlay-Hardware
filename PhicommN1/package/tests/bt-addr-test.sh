#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
program=$here/../../bluetooth/bt-addr.sh
fail() { echo "FAIL N1 Bluetooth address: $*" >&2; exit 1; }
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
cat > "$work/bin/btmgmt" <<'SHIM'
#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
if [ ! -p /dev/stdin ]; then
    printf 'stdin-not-pipe\n' >> "$TEST_BT_STATE/stdin"
    exit 1
fi
printf '%s\n' "$*" >> "$TEST_BT_LOG"
[ "$1" = -i ] && [ "$2" = hci0 ] || exit 2
shift 2
case "$1" in
info)
    [ ! -f "$TEST_BT_STATE/absent" ] || exit 1
    if [ -f "$TEST_BT_STATE/removed" ]; then
        rm -f "$TEST_BT_STATE/removed"
        exit 1
    fi
    if [ -f "$TEST_BT_STATE/pending" ]; then
        mv -f "$TEST_BT_STATE/pending" "$TEST_BT_STATE/address"
    fi
    printf 'hci0:\tPrimary controller\n'
    printf '\taddr %s version 9 manufacturer 305 class 0x400000\n' "$(cat "$TEST_BT_STATE/address")"
    powered=
    if [ "$(cat "$TEST_BT_STATE/powered")" = on ]; then powered='powered '; fi
    printf '\tcurrent settings: %sssp br/edr le secure-conn\n' "$powered"
    ;;
power)
    if [ -f "$TEST_BT_STATE/power-$2-failure" ]; then
        rm -f "$TEST_BT_STATE/power-$2-failure"
        exit 1
    fi
    if [ "$2" = on ]; then
        : > "$TEST_BT_STATE/up"
        rm -f "$TEST_BT_STATE/pending"
    else
        rm -f "$TEST_BT_STATE/up"
    fi
    printf '%s\n' "$2" > "$TEST_BT_STATE/powered"
    ;;
public-addr)
    if [ -f "$TEST_BT_STATE/race" ]; then
        printf 'on\n' > "$TEST_BT_STATE/powered"
        : > "$TEST_BT_STATE/up"
        rm -f "$TEST_BT_STATE/race"
        exit 1
    fi
    [ ! -f "$TEST_BT_STATE/fail" ] || exit 1
    [ "$(cat "$TEST_BT_STATE/powered")" != on ] || exit 1
    if [ ! -f "$TEST_BT_STATE/up" ] && [ ! -f "$TEST_BT_STATE/unchanged" ]; then
        printf '%s\n' "$2" | tr '[:lower:]' '[:upper:]' > "$TEST_BT_STATE/pending"
    fi
    : > "$TEST_BT_STATE/removed"
    printf 'hci0 Set Public Address complete, options:\n'
    ;;
*) exit 2 ;;
esac
SHIM
cat > "$work/bin/logger" <<'SHIM'
#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
printf '%s\n' "$*" >> "$TEST_LOGGER_LOG"
exit "${TEST_LOGGER_EXIT:-0}"
SHIM
cat > "$work/bin/sleep" <<'SHIM'
#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
[ "$*" = 1 ] || exit 2
printf '%s\n' "$*" >> "$TEST_BT_STATE/sleeps"
SHIM
chmod 0755 "$work/bin/btmgmt" "$work/bin/logger" "$work/bin/sleep"
PATH=$work/bin:$PATH
export PATH
fixture() {
    root=$work/$1
    factory=$root/proc/device-tree/soc/ethernet@c9410000/local-mac-address
    mkdir -p "$(dirname "$factory")" "$root/state"
    printf '\374\174\002\207\001\206' > "$factory"
    printf '43:45:C0:00:1F:AC\n' > "$root/state/address"
    printf 'off\n' > "$root/state/powered"
    : > "$root/state/up"
    OPENXPLAY_N1_ROOT=$root
    OPENXPLAY_N1_BT_WAIT=2
    TEST_BT_STATE=$root/state
    TEST_BT_LOG=$root/btmgmt.log
    TEST_LOGGER_LOG=$root/logger.log
    export OPENXPLAY_N1_ROOT OPENXPLAY_N1_BT_WAIT TEST_BT_STATE TEST_BT_LOG TEST_LOGGER_LOG
    : > "$TEST_BT_LOG"
    : > "$TEST_LOGGER_LOG"
}
run() { sh "$program" < /dev/null > "$root/stdout" 2> "$root/stderr"; }
no_changes() { ! grep -Eq ' power | public-addr ' "$TEST_BT_LOG"; }
expected=$work/expected-btmgmt
cat > "$expected" <<'CALLS'
-i hci0 info
-i hci0 power on
-i hci0 power off
-i hci0 public-addr fa:7c:02:87:01:86
-i hci0 info
-i hci0 info
CALLS
message='hci0: replaced the default controller address 43:45:c0:00:1f:ac with fa:7c:02:87:01:86 (derived from the factory Ethernet address)'
for start in boot powered closed; do
    fixture "$start"
    case "$start" in
    powered) printf 'on\n' > "$TEST_BT_STATE/powered" ;;
    closed) rm -f "$TEST_BT_STATE/up" ;;
    esac
    cp -f "$expected" "$work/expected-start"
    if [ "$start" = powered ]; then printf '%s\n' '-i hci0 power on' >> "$work/expected-start"; fi
    check "$start placeholder replaced" run
    check "$start controller changed in order and verified" cmp "$work/expected-start" "$TEST_BT_LOG"
    check "$start derived address stored" grep -qx 'FA:7C:02:87:01:86' "$TEST_BT_STATE/address"
    if [ "$start" = powered ]; then final=on; else final=off; fi
    check "$start controller power restored" grep -qx "$final" "$TEST_BT_STATE/powered"
    check "$start replacement logged to stderr" grep -Fxq "openxplay-n1-bt-addr: $message" "$root/stderr"
    check "$start replacement logged with the Bluetooth tag" grep -Fxq -- "-t openxplay-n1-bt-addr $message" "$TEST_LOGGER_LOG"
    check "$start no messages on stdout" test ! -s "$root/stdout"
done

fixture old-ordering
: | btmgmt -i hci0 public-addr fa:7c:02:87:01:86 > /dev/null
if : | btmgmt -i hci0 info > "$root/info"; then fail 'shim kept index during removal'; fi
: | btmgmt -i hci0 info > "$root/info"
check 'old ordering leaves default address stored while hci0 is up' grep -qx '43:45:C0:00:1F:AC' "$TEST_BT_STATE/address"
check 'old ordering still reports default address after two info calls' grep -q 'addr 43:45:C0:00:1F:AC ' "$root/info"
check 'old ordering queues no address write' test ! -f "$TEST_BT_STATE/pending"

fixture early-power-on
: | btmgmt -i hci0 power off
: | btmgmt -i hci0 public-addr fa:7c:02:87:01:86 > /dev/null
: | btmgmt -i hci0 power on
if : | btmgmt -i hci0 info > "$root/info"; then fail 'shim kept index during removal'; fi
check 'shim loses pending address when powered on too early' grep -qx '43:45:C0:00:1F:AC' "$TEST_BT_STATE/address"
: | btmgmt -i hci0 info > "$root/info"
check 'shim still reports default address after early power on' grep -q 'addr 43:45:C0:00:1F:AC ' "$root/info"

fixture powered-rejection
printf 'on\n' > "$TEST_BT_STATE/powered"
if : | btmgmt -i hci0 public-addr fa:7c:02:87:01:86; then fail 'shim accepted powered public-addr'; fi
check 'shim rejects address change while powered' test ! -f "$TEST_BT_STATE/pending"

fixture real-address
printf '02:11:22:33:44:55\n' > "$TEST_BT_STATE/address"
check 'real address accepted' run
check 'real address kept' no_changes
check 'own address logged' grep -q 'hci0 keeps its own address' "$root/stderr"

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
    check "$kind factory address skipped" run
    check "$kind factory address makes no change calls" no_changes
done

fixture no-controller
: > "$TEST_BT_STATE/absent"
check 'absent controller skipped' run
check 'absent controller makes no change calls' no_changes
check 'absent controller waited in one second steps' test "$(wc -l < "$TEST_BT_STATE/sleeps" | tr -d ' ')" -eq 2
check 'absent controller retried info' test "$(wc -l < "$TEST_BT_LOG" | tr -d ' ')" -eq 3
check 'absent controller logged' grep -q 'controller address is unavailable' "$root/stderr"

for start in boot powered; do
    fixture "public-addr-failure-$start"
    if [ "$start" = powered ]; then printf 'on\n' > "$TEST_BT_STATE/powered"; fi
    : > "$TEST_BT_STATE/fail"
    if run; then fail 'public-addr failure ignored'; fi
    {
        printf '%s\n' '-i hci0 info'
        for attempt in 1 2 3; do
            printf '%s\n' '-i hci0 power on' '-i hci0 power off' '-i hci0 public-addr fa:7c:02:87:01:86'
        done
        if [ "$start" = powered ]; then printf '%s\n' '-i hci0 power on'; fi
    } > "$work/expected-failure"
    check "$start public-addr failure returns nonzero" test "$(cat "$TEST_BT_STATE/address")" = '43:45:C0:00:1F:AC'
    check "$start public-addr failure restores starting power in order" cmp "$work/expected-failure" "$TEST_BT_LOG"
    check "$start public-addr failure waits between attempts" test "$(wc -l < "$TEST_BT_STATE/sleeps" | tr -d ' ')" -eq 2
    if [ "$start" = powered ]; then final=on; else final=off; fi
    check "$start public-addr failure preserves power" grep -qx "$final" "$TEST_BT_STATE/powered"
    check "$start public-addr failure logged" grep -q 'failed to set public address' "$root/stderr"

    fixture "power-race-$start"
    if [ "$start" = powered ]; then printf 'on\n' > "$TEST_BT_STATE/powered"; fi
    : > "$TEST_BT_STATE/race"
    check "$start public-addr power race recovered" run
    {
        printf '%s\n' '-i hci0 info'
        for attempt in 1 2; do
            printf '%s\n' '-i hci0 power on' '-i hci0 power off' '-i hci0 public-addr fa:7c:02:87:01:86'
        done
        printf '%s\n' '-i hci0 info' '-i hci0 info'
        if [ "$start" = powered ]; then printf '%s\n' '-i hci0 power on'; fi
    } > "$work/expected-race"
    check "$start power race retries without re-reading starting power" cmp "$work/expected-race" "$TEST_BT_LOG"
    check "$start power race waits before retrying and for the address" test "$(wc -l < "$TEST_BT_STATE/sleeps" | tr -d ' ')" -eq 2
    check "$start power race stores derived address" grep -qx 'FA:7C:02:87:01:86' "$TEST_BT_STATE/address"
    check "$start power race restores starting power" grep -qx "$final" "$TEST_BT_STATE/powered"

    fixture "unchanged-address-$start"
    if [ "$start" = powered ]; then printf 'on\n' > "$TEST_BT_STATE/powered"; fi
    : > "$TEST_BT_STATE/unchanged"
    if run; then fail 'unchanged address accepted'; fi
    check "$start unchanged address verification failure logged" grep -q 'public address verification failed; expected fa:7c:02:87:01:86, got 43:45:c0:00:1f:ac' "$root/stderr"
    check "$start verification retries for ten seconds" test "$(wc -l < "$TEST_BT_STATE/sleeps" | tr -d ' ')" -eq 10
    {
        printf '%s\n' '-i hci0 info' '-i hci0 power on' '-i hci0 power off' '-i hci0 public-addr fa:7c:02:87:01:86'
        for poll in 0 1 2 3 4 5 6 7 8 9 10; do printf '%s\n' '-i hci0 info'; done
        if [ "$start" = powered ]; then printf '%s\n' '-i hci0 power on'; fi
    } > "$work/expected-unchanged"
    check "$start verification timeout waits before restoring starting power" cmp "$work/expected-unchanged" "$TEST_BT_LOG"
    check "$start verification failure preserves power" grep -qx "$final" "$TEST_BT_STATE/powered"
done

for start in boot powered; do
    for power in on off; do
        fixture "power-$power-failure-$start"
        if [ "$start" = powered ]; then printf 'on\n' > "$TEST_BT_STATE/powered"; fi
        : > "$TEST_BT_STATE/power-$power-failure"
        if run; then fail "power $power failure ignored"; fi
        check "$start power $power failure logged" grep -q "failed to power $power the controller" "$root/stderr"
        {
            printf '%s\n' '-i hci0 info' '-i hci0 power on'
            if [ "$power" = off ]; then printf '%s\n' '-i hci0 power off'; fi
            if [ "$start" = powered ]; then printf '%s\n' '-i hci0 power on'; fi
        } > "$work/expected-power-failure"
        check "$start power $power failure restores power only for powered start" cmp "$work/expected-power-failure" "$TEST_BT_LOG"
    done
done

fixture logger-failure
check 'logger failure does not prevent replacement' env TEST_LOGGER_EXIT=1 sh "$program" < /dev/null
check 'logger failure still changed and verified the address' cmp "$expected" "$TEST_BT_LOG"
check 'all program cases give btmgmt a pipe on stdin' test -z "$(find "$work" -name stdin -print)"

fixture stdin-not-pipe
if btmgmt -i hci0 info < /dev/null; then fail 'shim accepted non-pipe stdin'; fi
check 'shim reports non-pipe stdin' grep -qx stdin-not-pipe "$TEST_BT_STATE/stdin"
check 'shim records no calls with non-pipe stdin' test ! -s "$TEST_BT_LOG"
echo "PASS $pass N1 Bluetooth address checks"
