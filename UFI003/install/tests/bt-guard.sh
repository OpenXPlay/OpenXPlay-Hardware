#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-16
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 - "$here/../../bluetooth/bt-guard.sh" <<'PY'
import datetime, itertools, json, os, pathlib, re, subprocess, sys, tempfile

guard = pathlib.Path(sys.argv[1]).resolve()
checks = 0

def check(condition, message):
    global checks
    assert condition, message
    checks += 1

with tempfile.TemporaryDirectory(prefix='bt guard ') as tmp:
    root = pathlib.Path(tmp)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    stub = '''#!/bin/sh
set -eu
cmd=${0##*/}
printf '%s %s\\n' "$cmd" "$*" >> "$TEST_LOG"
read -r tick rest < "$OPENXPLAY_BT_GUARD_UPTIME_FILE"
case "$cmd" in
    timeout) test "$1" = 5; shift; exec "$@" ;;
    sleep)
        tick=$((tick + $1))
        printf '%s 0\\n' "$tick" > "$OPENXPLAY_BT_GUARD_UPTIME_FILE"
        # Rearm heals only after the budget is spent; backoff heals during the first backoff.
        if [ "$TEST_MODE" = rearm ] && [ "$tick" -ge 450 ]; then echo healthy > "$TEST_STATE"; fi
        if [ "$TEST_MODE" = backoff ] && [ "$tick" -ge 40 ]; then echo healthy > "$TEST_STATE"; fi
        # Setup completes late, during the short boot backoff.
        if [ "$TEST_MODE" = bootheal ] && [ "$tick" -ge 13 ]; then echo healthy > "$TEST_STATE"; fi
        # Something turns Secure Connections on again, once, at 30 s.
        if [ "$TEST_MODE" = sc ] && [ "$tick" -ge 30 ] && [ ! -e "$TEST_STATE.again" ]; then
            : > "$TEST_STATE.again"; : > "$TEST_STATE.sc"
        fi
        ;;
    systemctl)
        if [ "$1" = show ]; then
            if [ "$TEST_MODE" = restart ] && [ "$tick" -ge 40 ]; then echo 2; else echo "$TEST_ACTIVE"; fi
        fi
        if [ "$1" = stop ]; then echo "$tick" >> "$TEST_STATE.stops"; fi
        if [ "$TEST_MODE" = stopfail ] && [ "$1" = stop ]; then exit 1; fi
        case "$TEST_MODE:$1" in
            late:start|slow:start) echo "$tick" > "$TEST_STATE.start" ;;
        esac
        ;;
    hciconfig)
        mode=$(cat "$TEST_STATE")
        [ "$mode" != noindex ] || exit 1
        case "$mode" in zero|fail|rearm|stopfail|restart|grace|backoff|boot*) address=00:00:00:00:00:00 ;; *) address=AA:BB:CC:DD:EE:FF ;; esac
        printf 'hci0: Type: Primary\\n    BD Address: %s ACL MTU: 1024\\n' "$address"
        up=true
        case "$mode" in
            down|power|boot*) up=false ;;
            late|slow)
                # BlueZ powers the adapter 3 s (late) or 20 s (slow) after it starts.
                delay=3; [ "$mode" = late ] || delay=20
                started=$(cat "$TEST_STATE.start" 2>/dev/null) || started=
                [ -n "$started" ] && [ "$tick" -ge $((started + delay)) ] || up=false ;;
        esac
        if "$up"; then echo '    UP RUNNING '; else echo '    DOWN'; fi
        ;;
    btmgmt)
        # Like BlueZ 5.55 btmgmt: with stdin closed or not a pipe (systemd gives /dev/null) it quits
        # before the controller answers, printing and changing nothing, and still exits 0.
        [ -p /dev/stdin ] || exit 0
        mode=$(cat "$TEST_STATE")
        if [ "$*" = '--index 0 power on' ]; then
            [ "$mode" != power ] || echo healthy > "$TEST_STATE"
        elif [ "$mode" = hang ]; then exit 124
        elif [ "$*" = info ]; then
            if [ "$mode" = noindex ] || [ ! -e "$OPENXPLAY_BT_GUARD_SYSFS_ROOT/class/bluetooth/hci0" ]; then
                echo 'Index list with 0 items'
            else printf 'Index list with 1 item\\nhci0:\\tPrimary controller\\n'; fi
        elif [ "$*" = '--index 0 info' ]; then
            current='powered ssp br/edr le'
            [ ! -e "$TEST_STATE.sc" ] || current="$current secure-conn"
            printf 'hci0:\\tPrimary controller\\n\\tsupported settings: powered ssp br/edr le secure-conn\\n'
            printf '\\tcurrent settings: %s\\n' "$current"
        fi
        ;;
    modprobe)
        case "$TEST_MODE" in
            fail|rearm|stopfail|bootfail) exit 1 ;;
            power) echo power > "$TEST_STATE" ;;
            late|slow) ;;
            # The reloaded controller comes back with Secure Connections on.
            boot) echo healthy > "$TEST_STATE"; : > "$TEST_STATE.sc" ;;
            *) echo healthy > "$TEST_STATE" ;;
        esac
        ;;
esac
'''
    for name in ('timeout', 'sleep', 'systemctl', 'hciconfig', 'btmgmt', 'rmmod', 'modprobe'):
        p = bin_dir / name
        p.write_text(stub)
        p.chmod(0o755)

    serial = itertools.count()
    last = {}

    def run(mode, count, grace=0, active=1, start=0, sc=False):
        # active: bluetooth.service ActiveEnterTimestampMonotonic (us); start: uptime at guard start.
        case = root / (mode + str(next(serial)))
        case.mkdir()
        last['case'] = case
        sysfs = case / 'sys'
        if mode != 'missing':
            (sysfs / 'class/bluetooth/hci0').mkdir(parents=True)
        uptime = case / 'uptime'
        uptime.write_text(f'{start} 0\n')
        state = case / 'controller'
        state.write_text(mode)
        if sc:
            (case / 'controller.sc').touch()
        log = case / 'commands'
        status = case / 'run/bluetooth-guard.json'
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                   TEST_LOG=str(log), TEST_STATE=str(state), TEST_MODE=mode, TEST_ACTIVE=str(active),
                   OPENXPLAY_BT_GUARD_INTERVAL='100' if mode == 'rearm' else '10', OPENXPLAY_BT_GUARD_ONCE=str(count),
                   OPENXPLAY_BT_GUARD_STATUS_PATH=str(status),
                   OPENXPLAY_BT_GUARD_SYSFS_ROOT=str(sysfs),
                   OPENXPLAY_BT_GUARD_UPTIME_FILE=str(uptime),
                   OPENXPLAY_BT_GUARD_GRACE=str(grace))
        # systemd starts the guard with stdin on /dev/null.
        result = subprocess.run(['sh', str(guard)], env=env, text=True, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        check(result.returncode == 0, result.stdout)
        data = json.loads(status.read_text())
        check(set(data) == {'state', 'attempts', 'lastRecovery', 'lastError', 'address'}, 'JSON fields')
        check(data['state'] in ('ok', 'recovering', 'failed'), 'JSON state')
        check(type(data['attempts']) is int, 'JSON attempts')
        check(data['lastError'] is None or isinstance(data['lastError'], str), 'JSON error')
        check(data['address'] in (None, 'AA:BB:CC:DD:EE:FF'), 'JSON address')
        if data['lastRecovery'] is not None:
            datetime.datetime.strptime(data['lastRecovery'], '%Y-%m-%dT%H:%M:%SZ')
        check(not list(status.parent.glob('*.tmp.*')), 'Atomic temporary file removed')
        calls = log.read_text().splitlines()
        # Every controller/service command must immediately follow its deadline wrapper.
        for i, call in enumerate(calls):
            if call.split()[0] in ('hciconfig', 'btmgmt', 'systemctl', 'rmmod', 'modprobe'):
                check(i > 0 and calls[i - 1] == 'timeout 5 ' + call, 'Command deadline: ' + call)
        actions = [c for c in calls if c.startswith(('rmmod ', 'modprobe ', 'systemctl stop ', 'systemctl start '))]
        check(not any('wcn36xx' in c or 'relay' in c for c in calls), 'Bluetooth only')
        return data, actions, calls, result.stdout

    def waits(calls):
        # Fake seconds slept in 1 s steps after each driver load and each BlueZ start.
        found = {'modprobe btqcomsmd': [], 'systemctl start bluetooth.service': []}
        current = None
        for call in calls:
            if call in found:
                current = found[call]
                current.append(0)
            elif call == 'sleep 1' and current is not None:
                current[-1] += 1
            elif call.startswith('sleep '):
                current = None
        return found['modprobe btqcomsmd'], found['systemctl start bluetooth.service']

    def stops():
        # Fake uptime at each bluetooth.service stop, the first step of a reload.
        path = last['case'] / 'controller.stops'
        return [int(t) for t in path.read_text().split()] if path.exists() else []

    def backoffs(calls):
        return [c for c in calls if c.startswith('sleep ') and c != 'sleep 1']

    def secure_connections(calls):
        # Any btmgmt Secure Connections command (`sc on`, `sc off`).
        return [c for c in calls if c.startswith('btmgmt') and ' sc ' in c + ' ']

    data, actions, calls, _ = run('healthy', 5)
    check(not actions and data['state'] == 'ok' and data['attempts'] == 0, 'Healthy: no recovery')
    check(not secure_connections(calls), 'Secure Connections supported but off: left alone')
    check(data['lastRecovery'] is None and data['lastError'] is None, 'Initial null metadata')
    data, actions, _, _ = run('zero', 2)
    check(not actions, 'Two bad checks do not recover')
    data, actions, calls, output = run('zero', 3)
    expected = ['systemctl stop bluetooth.service', 'rmmod btqcomsmd btqca',
                'modprobe btqcomsmd', 'systemctl start bluetooth.service']
    check(actions == expected, 'Exactly one recovery, correct order')
    check(data['state'] == 'ok' and data['attempts'] == 1, 'Recovery restored health')
    check('state=recovering' in output and 'state=ok' in output, 'State changes logged')
    check('sleep 30' in calls, 'First backoff')
    for mode in ('down', 'hang', 'missing', 'power'):
        data, actions, calls, _ = run(mode, 3)
        check(actions == expected * (3 if mode == 'missing' else 1), mode + ': detects unhealthy controller')
        check('sleep 30' in calls and 'sleep 3' not in calls, mode + ': not a boot failure, normal first backoff')
        if mode == 'missing':
            check(data['state'] == 'failed', 'Missing hci0 exhausts budget')
            address, health = waits(calls)
            check(len(address) == 3 and all(0 < n <= 20 for n in address), 'Each address wait is bounded to twenty seconds')
            check(len(health) == 3 and all(0 < n <= 15 for n in health), 'Each health wait is bounded to fifteen seconds')
            check(calls.count('btmgmt --index 0 power on') == 3, 'One power command per attempt')
        if mode == 'power':
            check('btmgmt --index 0 power on' in calls and data['state'] == 'ok', 'Power restored')
            check(calls.count('btmgmt --index 0 power on') == 1 and 'sleep 60' not in calls, 'Power command sent once')
    # BlueZ powers the adapter a few seconds after it starts: the same attempt succeeds.
    data, actions, calls, _ = run('late', 3)
    check(actions == expected and data['state'] == 'ok' and data['attempts'] == 1, 'Late power-up: attempt succeeds')
    check(waits(calls)[1] == [3] and data['lastError'] is None, 'Late power-up: health polled until up')
    check('btmgmt --index 0 power on' not in calls and 'sleep 60' not in calls, 'Late power-up: no further action')
    # Up only after the health wait: the next backoff ends healthy and keeps the driver.
    data, actions, calls, output = run('slow', 3)
    check(actions == expected and data['state'] == 'ok' and data['attempts'] == 2, 'Slow recovery: no second reload')
    check('sleep 60' in calls and 'sleep 120' not in calls, 'Slow recovery: budget not spent')
    check(data['lastError'] is None and data['address'] == 'AA:BB:CC:DD:EE:FF', 'Slow recovery: status ok')
    check('attempt 2: controller healthy after backoff' in output, 'Slow recovery logged')
    # Healthy again by itself when the first backoff ends: the driver is never touched.
    data, actions, calls, output = run('backoff', 3)
    check(not actions and data['state'] == 'ok' and data['attempts'] == 1, 'Recovered during backoff: no reload')
    check('sleep 30' in calls and data['lastError'] is None, 'Recovered during backoff: status ok')
    check('state=recovering' in output and 'state=ok' in output, 'Recovered during backoff: states logged')
    data, actions, calls, output = run('fail', 6)
    check(actions == expected * 3, 'Failing controller limited to three attempts')
    check(data['state'] == 'failed' and data['attempts'] == 3, 'Exhausted status')
    check([c for c in calls if c in ('sleep 30', 'sleep 60', 'sleep 120')] ==
          ['sleep 30', 'sleep 60', 'sleep 120'], 'Bounded exponential backoff')
    data, actions, _, _ = run('stopfail', 5)
    check(not any(c.startswith(('rmmod', 'modprobe')) for c in actions), 'Do not unload if stop fails')
    check(data['state'] == 'failed', 'Stop failure exhausts budget safely')
    data, actions, _, _ = run('grace', 5, grace=30)
    check(not actions, 'Startup grace before three unhealthy checks')
    data, actions, _, _ = run('restart', 9, grace=30)
    check(not actions, 'Bluetooth restart renews grace and consecutive count')
    data, actions, _, _ = run('rearm', 9)
    check(data['state'] == 'failed' and data['attempts'] == 3, 'Healthy less than ten minutes stays failed')
    data, actions, _, _ = run('rearm', 10)
    check(data['state'] == 'ok' and data['attempts'] == 0, 'Ten continuous healthy minutes re-arm')

    # Secure Connections belongs to the relay (on, off only while pairing): the guard leaves it
    # alone when it is on from the start and when something turns it on again at 30 s.
    data, actions, calls, output = run('sc', 6, sc=True)
    check(not actions and data['state'] == 'ok' and data['attempts'] == 0, 'Secure Connections on: no recovery')
    check(not secure_connections(calls), 'Secure Connections on: never switched by the guard')
    check('Secure Connections' not in output, 'Secure Connections on: nothing logged')
    check(calls.count('btmgmt --index 0 info') == 6, 'Secure Connections on: management interface still checked')
    check(not re.search(r'btmgmt[^\n]*\ssc\s', guard.read_text()), 'The guard script has no btmgmt sc command')

    # Boot failure: BlueZ starts at 0 s; bluetooth.service becomes active at 3 s, when the guard
    # starts. Production grace.
    boot = dict(grace=30, active=3000000, start=3)
    data, actions, calls, _ = run('boot', 1, **boot)
    check(not actions and data['attempts'] == 0, 'Boot failure: no recovery before BlueZ has run 8 s')
    data, actions, calls, output = run('boot', 2, **boot)
    check(actions == expected and data['state'] == 'ok' and data['attempts'] == 1, 'Boot failure: one reload restores health')
    check(backoffs(calls) == ['sleep 8', 'sleep 3'], 'Boot failure: check again at 8 s, then a 3 s backoff')
    check(stops() == [14], 'Boot failure: reload starts 14 s after BlueZ start')
    check('hci0 failed setup 8s after bluetooth.service started' in output, 'Boot failure fast path logged')
    check(not secure_connections(calls), 'Reloaded controller: Secure Connections left alone')
    check(data['lastError'] is None and data['address'] == 'AA:BB:CC:DD:EE:FF', 'Boot failure: status ok')
    # A guard started late, BlueZ already up 17 s: recover on the first check.
    data, actions, calls, _ = run('boot', 1, grace=30, active=3000000, start=20)
    check(actions == expected and backoffs(calls) == ['sleep 3'] and stops() == [23], 'Boot failure seen late: immediate recovery')
    # hciconfig unusable, but btmgmt completes and lists no controller.
    data, actions, calls, _ = run('noindex', 2, **boot)
    check(actions == expected and data['state'] == 'ok' and data['attempts'] == 1, 'No management index: one reload')
    check(backoffs(calls) == ['sleep 8', 'sleep 3'] and stops() == [14], 'No management index: boot timing')
    # Setup completes during the short backoff: the driver is never touched.
    data, actions, calls, output = run('bootheal', 2, **boot)
    check(not actions and data['state'] == 'ok' and data['attempts'] == 1, 'Boot failure healed during backoff: no reload')
    check('attempt 1: controller healthy after backoff' in output, 'Boot failure healed during backoff: logged')
    # Later attempts keep the long backoffs and the budget.
    data, actions, calls, _ = run('bootfail', 2, **boot)
    check(actions == expected * 3 and data['state'] == 'failed' and data['attempts'] == 3, 'Boot failure: three attempts at most')
    check(backoffs(calls) == ['sleep 8', 'sleep 3', 'sleep 60', 'sleep 120'], 'Boot failure: later attempts back off 60 s and 120 s')
    check(data['lastError'] == 'Recovery budget exhausted', 'Boot failure: budget exhausted')
    # Other unhealthy states keep the full grace, three checks and the 30 s first backoff.
    data, actions, calls, _ = run('down', 5, **boot)
    check(not actions and 'sleep 8' not in calls, 'Valid address, DOWN: normal grace and confirmation')
    data, actions, calls, _ = run('down', 6, **boot)
    check(actions == expected and backoffs(calls)[-1] == 'sleep 30', 'Valid address, DOWN: normal first backoff')
    check(stops() == [83], 'Valid address, DOWN: reload after grace, three checks and 30 s')
    data, actions, calls, _ = run('missing', 3, **boot)
    check(not actions, 'No hci0 at all: not a boot failure, normal grace')
print(f'PASS: {checks} Bluetooth guard assertions with fake commands and monotonic time')
PY
