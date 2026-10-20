#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-16
set -u
export LC_ALL=C
interval=${OPENXPLAY_BT_GUARD_INTERVAL:-10}
status=${OPENXPLAY_BT_GUARD_STATUS_PATH:-/run/openxplay/bluetooth-guard.json}
sysfs=${OPENXPLAY_BT_GUARD_SYSFS_ROOT:-/sys}
uptime_file=${OPENXPLAY_BT_GUARD_UPTIME_FILE:-/proc/uptime}
grace=${OPENXPLAY_BT_GUARD_GRACE:-30}
rearm=${OPENXPLAY_BT_GUARD_REARM:-600}
# A controller showing the boot failure signature this long after bluetooth.service became
# active is recovered without further checks, after a short first backoff.
boot_grace=8
boot_backoff=3
# ONCE=1 runs one check; larger values bound a test run without changing logic.
checks=${OPENXPLAY_BT_GUARD_ONCE:-0}
mkdir -p "$(dirname "$status")" || exit 1
trap 'rm -f "$status.tmp.$$"' 0
trap 'exit 0' HUP INT TERM
now() {
    read -r seconds rest < "$uptime_file" || exit 1
    seconds=${seconds%%.*}
}
log() { printf 'Bluetooth guard: %s\n' "$*"; }
# BlueZ 5.55 btmgmt quits as soon as its stdin is closed, before the controller answers, so with
# systemd's /dev/null stdin it prints and changes nothing yet exits 0. Every call therefore runs in
# a command substitution with that substitution's pipe as stdin (`<&1`): open, never readable.
state=ok; attempts=0; last_recovery=null; last_error=null; address=null
published_state=; failures=0; healthy_since=; activation=
info=; mgmt=; age=0; first_backoff=30
now
grace_until=$((seconds + grace))
publish() {
    if [ "$state" != "$published_state" ]; then
        log "state=$state attempts=$attempts error=$last_error"
        published_state=$state
    fi
    # All strings are fixed messages, validated addresses, or a UTC date.
    printf '{"state":"%s","attempts":%s,"lastRecovery":%s,"lastError":%s,"address":%s}\n' \
        "$state" "$attempts" "$last_recovery" "$last_error" "$address" > "$status.tmp.$$" &&
        mv -f "$status.tmp.$$" "$status" || exit 1
}
controller() {
    address=null; info=
    [ -e "$sysfs/class/bluetooth/hci0" ] || return 1
    info=$(timeout 5 hciconfig hci0 2>/dev/null) || { info=; return 1; }
    bd=$(printf '%s\n' "$info" | awk '
        { for (i=1; i<NF; i++) if ($i == "Address:") {
            a=$(i+1); n=split(a, p, ":"); valid=(n==6)
            for (j=1; j<=n; j++) if (length(p[j])!=2 || p[j] ~ /[^0-9A-Fa-f]/) valid=0
            if (valid && a!="00:00:00:00:00:00") { print toupper(a); exit }
        }}')
    [ -n "$bd" ] || return 1
    address="\"$bd\""
}
healthy() {
    controller || return 1
    printf '%s\n' "$info" | awk '
        { for (i=1; i<NF; i++) if ($i == "UP" && $(i+1) == "RUNNING") found=1 }
        END { exit !found }' || return 1
    # Query the management interface too: a stale UP flag alone can hide a hang. Secure
    # Connections is left alone: the relay keeps it on, which bonded iPhones need to reconnect,
    # and turns it off only while a pairing window is open.
    mgmt=$(timeout 5 btmgmt --index 0 info <&1 2>/dev/null) || return 1
}
# hci0 registered but never finished setup: zero address and DOWN, or no management index.
boot_failure() {
    [ -e "$sysfs/class/bluetooth/hci0" ] || return 1
    printf '%s\n' "$info" | awk '
        { for (i=1; i<=NF; i++) {
            if ($i == "Address:" && $(i+1) == "00:00:00:00:00:00") zero=1
            if ($i == "DOWN") down=1
        }}
        END { exit !(zero && down) }' && return 0
    # Only a completed listing counts; a hung or failed btmgmt is not evidence.
    list=$(timeout 5 btmgmt info <&1 2>/dev/null) || return 1
    ! printf '%s\n' "$list" | grep -q '^hci0:'
}
# Whole seconds since bluetooth.service last became active, in $age; fails if unknown.
active_for() {
    case $activation in ''|0|*[!0-9]*) return 1 ;; esac
    now
    age=$((seconds - activation / 1000000))
}
step() {
    log "$*"
    timeout 5 "$@"
}
recovered() {
    state=ok; last_error=null; failures=0
    now
    healthy_since=$seconds
    grace_until=$((seconds + grace))
    publish
}
recover() {
    attempts=$((attempts + 1))
    state=recovering
    last_error='"Controller unhealthy"'
    stamp=$(timeout 5 date -u +%Y-%m-%dT%H:%M:%SZ) || stamp=
    last_recovery=null
    [ -z "$stamp" ] || last_recovery="\"$stamp\""
    publish
    case "$attempts" in 1) delay=$first_backoff ;; 2) delay=60 ;; 3) delay=120 ;; esac
    log "attempt $attempts: backoff ${delay}s"
    sleep "$delay"
    # A slow earlier attempt, or the controller itself, may have recovered meanwhile.
    if healthy; then
        log "attempt $attempts: controller healthy after backoff, skipping reload"
        recovered
        return 0
    fi
    loaded=false
    if step systemctl stop bluetooth.service; then
        # Reload, never `hciconfig hci0 up`: that powers a controller whose first setup failed but
        # the kernel then never lists it on the management interface, so BlueZ cannot use it.
        if step rmmod btqcomsmd btqca && step modprobe btqcomsmd; then
            loaded=true
            now
            deadline=$((seconds + 20))
            log 'Waiting up to 20s for hci0 with a non-zero address'
            while :; do
                now
                # Reserve the full command timeout inside the twenty-second window.
                [ $((seconds + 5)) -le "$deadline" ] || break
                controller && break
                now
                [ "$seconds" -lt "$deadline" ] || break
                sleep 1
            done
        fi
    fi
    # Always try to restore BlueZ, even after an unload/load failure.
    step systemctl start bluetooth.service || loaded=false
    if "$loaded"; then
        # BlueZ powers the adapter a few seconds after it starts; judge only after that.
        now
        deadline=$((seconds + 15))
        power_at=$((seconds + 5))
        log 'Waiting up to 15s for BlueZ to power hci0'
        while :; do
            if healthy; then
                recovered
                return 0
            fi
            # Command timeouts bound each probe; the clock, not a probe count, ends the wait.
            now
            [ "$seconds" -lt "$deadline" ] || break
            if [ -n "$power_at" ] && [ "$seconds" -ge "$power_at" ]; then
                power_at=
                log 'btmgmt --index 0 power on'
                reply=$(timeout 5 btmgmt --index 0 power on <&1 2>/dev/null) || :
            fi
            sleep 1
        done
    fi
    last_error='"Recovery did not restore controller"'
    [ "$attempts" -lt 3 ] || state=failed
    publish
    return 1
}
publish
while :; do
    now
    pause=$interval
    # ActiveEnterTimestampMonotonic changes whenever bluetooth.service starts.
    started=$(timeout 5 systemctl show bluetooth.service -p ActiveEnterTimestampMonotonic --value 2>/dev/null) || started=
    if [ -n "$started" ] && [ "$started" != "$activation" ]; then
        activation=$started
        grace_until=$((seconds + grace))
        failures=0
        healthy_since=
    fi
    if healthy; then
        failures=0
        [ -n "$healthy_since" ] || healthy_since=$seconds
        if [ $((seconds - healthy_since)) -ge "$rearm" ]; then
            attempts=0; state=ok; last_error=null
        fi
    else
        healthy_since=
        if [ "$state" != failed ]; then
            quick=false
            if boot_failure && active_for; then
                if [ "$age" -ge "$boot_grace" ]; then
                    quick=true
                elif [ $((boot_grace - age)) -lt "$pause" ]; then
                    pause=$((boot_grace - age))
                fi
            fi
            if "$quick"; then
                # Unambiguous: skip the rest of the grace, the confirming checks and the long backoff.
                log "hci0 failed setup ${age}s after bluetooth.service started: recovering now"
                failures=3; first_backoff=$boot_backoff
            elif [ "$seconds" -ge "$grace_until" ]; then
                failures=$((failures + 1)); first_backoff=30
            fi
            if [ "$failures" -ge 3 ]; then
                while [ "$attempts" -lt 3 ]; do
                    recover && break
                done
                # A previously successful attempt may have consumed the budget.
                if [ "$failures" -ge 3 ]; then
                    state=failed
                    last_error='"Recovery budget exhausted"'
                fi
            fi
        fi
    fi
    publish
    if [ "$checks" -gt 0 ]; then
        checks=$((checks - 1))
        [ "$checks" -gt 0 ] || break
    fi
    sleep "$pause"
done
