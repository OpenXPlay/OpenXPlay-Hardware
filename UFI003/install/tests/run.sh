#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: AGPL-3.0-only
# Created by riko chen on 2026-10-16
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sh "$here/bt-guard.sh"
python3 - "$here" <<'PY'
import hashlib, os, pathlib, shutil, subprocess, sys, tempfile, time
source = pathlib.Path(sys.argv[1]).parent.parent
packaging = source.parents[1] / 'OpenXPlay-Relay/rust/packaging'
checks = 0
def check(condition, message):
    global checks
    assert condition, message
    checks += 1
with tempfile.TemporaryDirectory(prefix='ufi003 test ') as tmp:
    t = pathlib.Path(tmp)
    device = t / 'UFI003'
    shutil.copytree(source, device)
    inputs = t / 'inputs'
    inputs.mkdir()
    for name in ('relay', 'oxp', 'web/receiver/index.html', 'admin/index.html'):
        p = inputs / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('fixture ' + name)
    debs = inputs / 'debs'
    debs.mkdir()
    manifest = device / 'install/debs.txt'
    rows = []
    packages = []
    for line in manifest.read_text().splitlines():
        if not line or line.startswith('#'):
            rows.append(line); continue
        name, version, _ = line.split()
        arch = 'all' if name == 'libasound2-data' else 'arm64'
        filename = f'{name}_{version}_{arch}.deb'
        data = filename.encode()
        (debs / filename).write_bytes(data)
        rows.append(f'{name} {version} {hashlib.sha256(data).hexdigest()}')
        packages.append((name, version))
    stub = t / 'stubs'
    stub.mkdir()
    # All privileged device commands are stubs. Reject any accidental host runtime action.
    script = '''#!/bin/sh
set -eu
cmd=${0##*/}
printf '%s %s\\n' "$cmd" "$*" >> "$TEST_LOG"
case "$cmd" in
uname) echo "${TEST_KERNEL:-5.15.0-handsomekernel+}" ;;
dpkg)
  case "$1" in --root=*) shift ;; *) exit 99 ;; esac
  case "$1" in
    --show) name=$3; test -f "$TEST_STATE/$name"; printf 'install ok installed '; cat "$TEST_STATE/$name" ;;
    -i) file=${2##*/}; name=${file%%_*}; version=${file#*_}; version=${version%_*}; printf '%s' "$version" > "$TEST_STATE/$name" ;;
    *) exit 98 ;;
  esac ;;
systemctl)
  if [ "${TEST_GUARD:-no}" = yes ]; then
    if [ "${TEST_SYSTEMCTL_DELAY:-0}" != 0 ]; then sleep "$TEST_SYSTEMCTL_DELAY"; fi
    exit "${TEST_SYSTEMCTL_STATUS:-0}"
  fi
  case "$1" in --root=*) ;; *) echo 'Host systemctl forbidden' >&2; exit 97 ;; esac ;;
depmod) test "$1" = -b ;;
modprobe|nmcli) echo 'Host runtime action forbidden' >&2; exit 96 ;;
timedatectl) echo "${TEST_SYNC:-yes}"; exit "${TEST_SYNC_STATUS:-0}" ;;
date) echo 1800000000 ;;
stat)
  test "$1" = -c && test "$2" = %Y
  case "$3" in
    */admin-tls.json) echo "${TEST_ADMIN_MTIME:-1700000000}" ;;
    */cert.pem) echo "${TEST_CERT_MTIME:-1700000000}" ;;
    */key.pem) echo "${TEST_KEY_MTIME:-1700000000}" ;;
  esac ;;

esac
'''
    for cmd in ('dpkg', 'systemctl', 'depmod', 'modprobe', 'uname', 'nmcli', 'timedatectl', 'stat', 'date'):
        p = stub / cmd; p.write_text(script); p.chmod(0o755)
    # An allowlist PATH proves device scripts cannot find Python or OpenSSL.
    runtime = t / 'runtime'
    runtime.mkdir()
    for cmd in ('sh', 'awk', 'sha256sum', 'find', 'sort', 'dirname', 'id',
                'mkdir', 'install', 'cat', 'grep', 'cp', 'rm', 'rmdir', 'sleep'):
        executable = shutil.which(cmd)
        check(executable is not None, 'Host test dependency: ' + cmd)
        (runtime / cmd).symlink_to(executable)
    device_path = str(stub) + os.pathsep + str(runtime)
    check(shutil.which('python3', path=device_path) is None, 'No Python on device PATH')
    check(shutil.which('openssl', path=device_path) is None, 'No OpenSSL on device PATH')
    log = t / 'commands.log'
    state = t / 'dpkg-state'; state.mkdir()
    root = t / 'root'
    root.mkdir()
    env = dict(os.environ, PATH=str(stub) + os.pathsep + os.environ['PATH'],
               DESTDIR=str(root), TEST_LOG=str(log), TEST_STATE=str(state))
    def run(args, ok=True, extra=None):
        e = dict(env); e.update(extra or {})
        if pathlib.Path(args[0]).name != 'make-bundle.sh':
            e['PATH'] = device_path
        command = ['sh', *map(str, args)]
        result = subprocess.run(command, env=e, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        check((result.returncode == 0) == ok, 'Unexpected result: ' + result.stdout)
        return result.stdout
    make = device / 'install/make-bundle.sh'
    bundle = t / 'bundle'
    args = [make, bundle, inputs/'relay', inputs/'oxp', inputs/'web', inputs/'admin', debs, packaging]
    check('SHA256 mismatch' in run(args, False), 'Real digests reject fixture debs')
    check(not bundle.exists(), 'Invalid inputs must not create output')
    manifest.write_text('\n'.join(rows) + '\n')
    run([make, '--dry-run', *args[1:]])
    check(not bundle.exists(), 'Bundle dry-run writes nothing')
    # Asset identity rejection.
    identity = inputs/'admin/identity.pk8'; identity.write_text('NEVER SHIP')
    check('MFi' in run(args, False), 'Must reject MFi')
    identity.unlink()
    for bad_name in ('bad\nname', 'bad\rname', 'bad\\name'):
        bad = inputs/'admin'/bad_name; bad.write_text('bad filename')
        check('bundle filename' in run(args, False), 'Builder rejects ambiguous filenames')
        check(not bundle.exists(), 'Bad filename must not publish bundle')
        bad.unlink()
    run(args)
    check('already current' in run(args), 'Identical bundle build is idempotent')
    (bundle/'extra').write_text('unrecognized')
    run(args, False)  # Never overwrite a different existing bundle.
    (bundle/'extra').unlink()
    installer = bundle/'UFI003/install/install-ufi003.sh'
    for prefix in ('/', '//', 'relative'):
        run([installer, '--dry-run', bundle], False, {'DESTDIR': prefix})
    run([installer, '--dry-run', bundle])
    check(not any(root.iterdir()), 'Installer dry-run writes nothing')
    run([installer, bundle], False, {'TEST_KERNEL': 'wrong'})
    check(not any(root.iterdir()), 'Kernel mismatch writes nothing')
    binary = bundle/'bin/oxp-relay'; binary.write_text('corrupt')
    check('SHA256 mismatch' in run([installer, bundle], False), 'Reject bundle corruption')
    binary.write_text('fixture oxp')
    # Recreate manifest after fixture mutations, like make-bundle does.
    def sums():
        paths = sorted(p for p in bundle.rglob('*') if p.is_file() and p.name != 'SHA256SUMS')
        # Include the nested module SHA256SUMS files as well.
        paths.append(bundle/'UFI003/rfcomm/SHA256SUMS')
        paths.append(bundle/'UFI003/btqcomsmd/SHA256SUMS')
        (bundle/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() +
            '  ./' + p.relative_to(bundle).as_posix() + '\n' for p in sorted(paths)))
    sums()
    checksum_file = bundle/'SHA256SUMS'
    valid_sums = checksum_file.read_text()
    first = valid_sums.splitlines()[0]
    digest, name = first.split('  ', 1)
    invalid_rows = [first, 'g'*64 + '  ' + name, digest[:-1] + '  ' + name,
                    digest + ' *' + name, digest + '  /absolute',
                    digest + '  ./../escape', digest + '  ./x/../escape',
                    digest + '  .//absolute', digest + '  ./',
                    digest + '  ./x/./alias', digest + '  ./bad\\name',
                    digest + '  ./bad\rname', '', '# comment']
    for row in invalid_rows:
        checksum_file.write_text(valid_sums + row + '\n')
        check('manifest entry' in run([installer, bundle], False), 'Reject malformed/duplicate row: ' + repr(row))
    for content in ('', '\n'.join(valid_sums.splitlines()[1:]) + '\n',
                    valid_sums + digest + '  ./missing\n',
                    valid_sums + digest + '  ./SHA256SUMS\n'):
        checksum_file.write_text(content)
        check('cover exactly' in run([installer, bundle], False), 'Require exact manifest coverage')
    checksum_file.write_text(valid_sums)
    # Uppercase hex and spaces in a normal filename are accepted.
    spaced = bundle/'file with spaces'; spaced.write_text('spaces')
    sums()
    checksum_file.write_text(''.join(line[:64].upper() + line[64:] + '\n'
                                    for line in checksum_file.read_text().splitlines()))
    run([installer, '--dry-run', bundle])
    spaced.unlink(); sums()
    bundled_debs = bundle/'UFI003/install/debs.txt'
    valid_debs = bundled_debs.read_text()
    bundled_debs.write_text(valid_debs.replace(valid_debs.splitlines()[-1].split()[-1], 'FILL_SHA256'))
    sums()
    check('placeholder' in run([installer, bundle], False), 'Installer rejects placeholders')
    bundled_debs.write_text(valid_debs); sums()
    unlisted = bundle/'unlisted'; unlisted.write_text('unexpected')
    check('cover exactly' in run([installer, bundle], False), 'Require manifest coverage')
    unlisted.unlink()
    identity = bundle/'admin/certificate.p7b'; identity.write_text('private')
    check('MFi' in run([installer, bundle], False), 'Installer identity rejection')
    identity.unlink()
    module = bundle/'UFI003/rfcomm/rfcomm.ko'
    original = module.read_bytes(); module.write_bytes(b'bad module'); sums()
    check('SHA256 mismatch' in run([installer, bundle], False), 'Independent module digest')
    module.write_bytes(original); sums()
    driver = bundle/'UFI003/btqcomsmd/btqcomsmd.ko'
    driver_original = driver.read_bytes(); driver.write_bytes(b'bad driver'); sums()
    check('SHA256 mismatch' in run([installer, bundle], False), 'Independent btqcomsmd digest')
    check(not any(root.iterdir()), 'Driver digest mismatch writes nothing')
    driver.write_bytes(driver_original); sums()
    driver.unlink(); sums()
    check('btqcomsmd' in run([installer, bundle], False), 'Installer requires the fixed Bluetooth driver')
    driver.write_bytes(driver_original); sums()
    scan_policy = bundle/'UFI003/network/openxplay-wifi-scan-mac.conf'
    scan_policy_original = scan_policy.read_bytes(); scan_policy.unlink(); sums()
    check('openxplay-wifi-scan-mac.conf' in run([installer, bundle], False), 'Installer requires the scan MAC policy')
    check(not any(root.iterdir()), 'Missing scan MAC policy writes nothing')
    scan_policy.write_bytes(scan_policy_original); sums()
    (root/'etc').mkdir()
    (root/'etc/dnsmasq.conf').write_text('# bind-interfaces\nlisten-address=192.168.68.1\n')
    unit = root/'lib/systemd/system/systemd-timesyncd.service'
    unit.parent.mkdir(parents=True); unit.write_text('[Unit]\n')
    # Upgrade from a release that forced Secure Connections off at every BlueZ start.
    bluez_dropins = root/'etc/systemd/system/bluetooth.service.d'
    legacy = bluez_dropins/'openxplay-no-secure-connections.conf'
    bluez_dropins.mkdir(parents=True); legacy.write_text('[Service]\nExecStartPost=/bin/true\n')
    check(sorted(p.name for p in (bundle/'UFI003/bluetooth').iterdir()) == ['bt-guard.sh', 'openxplay-bt-guard.service'],
          'Bundle ships no Secure Connections drop-in')
    output = run([installer, bundle])
    check('Provide your own MFi' in output, 'Missing identity guidance')
    check((root/'opt/openxplay/bin/openxplay-relay').read_text() == 'fixture relay', 'Generic installer called')
    check((root/'opt/openxplay/share/web/receiver/index.html').exists(), 'Web assets installed')
    check((root/'etc/dnsmasq.d/openxplay-bind.conf').read_text() == 'bind-interfaces\n', 'dnsmasq binding')
    check('wifi.powersave = 2' in (root/'etc/NetworkManager/conf.d/openxplay-wifi-powersave.conf').read_text(), 'Wi-Fi policy')
    scan_mac = (root/'etc/NetworkManager/conf.d/openxplay-wifi-scan-mac.conf').read_text()
    check('\nmatch-device=interface-name:wlan0\nwifi.scan-rand-mac-address=no\n' in scan_mac, 'No scan MAC randomisation on wlan0')
    check(sorted(p.name for p in (bundle/'UFI003/network').iterdir()) ==
          ['openxplay-wifi-powersave.conf', 'openxplay-wifi-scan-mac.conf'], 'Bundle ships both NetworkManager policies')
    check((root/'lib/modules/5.15.0-handsomekernel+/extra/rfcomm.ko').read_bytes() == original, 'Module installed')
    check((root/'lib/modules/5.15.0-handsomekernel+/updates/btqcomsmd.ko').read_bytes() == driver_original,
          'Fixed Bluetooth driver installed where it overrides the in-tree module')
    check(not (root/'lib/modules/5.15.0-handsomekernel+/kernel').exists(), 'In-tree modules left untouched')
    check(not legacy.exists() and not bluez_dropins.exists(), 'Upgrade removes the Secure Connections drop-in and its empty directory')
    lines = output.splitlines()
    skipped = lambda action: lines.index('Fake root: skip runtime action: systemctl ' + action)
    check(skipped('daemon-reload') < skipped('restart openxplay-bt-guard.service') < skipped('restart bluetooth.service'),
          'Drop-in removal reloaded; guard replaced before BlueZ restarts')
    check((root/'usr/local/libexec/openxplay-bt-guard').stat().st_mode & 0o777 == 0o755, 'Bluetooth guard executable installed')
    bt_unit = (root/'etc/systemd/system/openxplay-bt-guard.service').read_text()
    check('After=bluetooth.service' in bt_unit and 'Restart=always' in bt_unit, 'Bluetooth guard ordering and restart')
    check('ExecStart=/usr/local/libexec/openxplay-bt-guard' in bt_unit, 'Bluetooth guard service command')
    clock_unit = (root/'etc/systemd/system/openxplay-relay.service.d/clock.conf').read_text()
    check('ExecStartPre=' in clock_unit, 'Clock hook')
    check('After=' not in clock_unit and 'Wants=' not in clock_unit, 'No time service ordering delay')
    calls = log.read_text()
    installed = [line.split('/')[-1] for line in calls.splitlines() if ' -i ' in line]
    check([x.split('_')[0] for x in installed] == [x[0] for x in packages], 'Dependency order')
    check('enable systemd-timesyncd.service' in calls, 'Time sync enabled')
    check(f'systemctl --root={root} enable openxplay-bt-guard.service' in calls, 'Bluetooth guard enabled under fake root')
    check('systemctl start openxplay-bt-guard.service' not in output, 'Bluetooth guard restarted, never only started')
    before = len(installed)
    # Other bluetooth.service drop-ins and their directory stay.
    bluez_dropins.mkdir(parents=True); legacy.write_text('legacy'); (bluez_dropins/'local.conf').write_text('[Service]\n')
    run([installer, bundle])
    check(not legacy.exists() and (bluez_dropins/'local.conf').exists(), 'Upgrade keeps unrelated BlueZ drop-ins')
    check(sum(' -i ' in line for line in log.read_text().splitlines()) == before, 'Exact installed versions skipped')
    # Even an already installed package must pass its committed checksum.
    deb = next((bundle/'debs').glob('iw_*.deb'))
    saved_deb = deb.read_bytes(); deb.write_text('corrupt deb'); sums()
    check('SHA256 mismatch' in run([installer, bundle], False), 'Independent deb digest, including installed packages')
    deb.write_bytes(saved_deb); sums()
    (state/'iw').write_text('old')
    run([installer, bundle])
    check(sum(' -i ' in line for line in log.read_text().splitlines()) == before + 1, 'Version mismatch installed')
    # Pre-bound configs need no extra drop-in, for either supported spelling.
    for directive in ('bind-dynamic', 'bind-interfaces'):
        (root/'etc/dnsmasq.d/openxplay-bind.conf').unlink(missing_ok=True)
        (root/'etc/dnsmasq.conf').write_text(directive + '\n')
        run([installer, bundle])
        check(not (root/'etc/dnsmasq.d/openxplay-bind.conf').exists(), 'Preserve existing binding')
    (root/'etc/dnsmasq.conf').unlink()
    run([installer, bundle])
    check(not (root/'etc/dnsmasq.d/openxplay-bind.conf').exists(), 'No system config: no drop-in')
    guard = root/'usr/local/libexec/openxplay-clock-guard'
    tls = root/'var/lib/openxplay/receiver-tls'; tls.mkdir()
    admin = tls.parent/'admin-tls.json'
    def guard_run(extra=None):
        return run([guard], extra=dict(TEST_GUARD='yes', **(extra or {})))
    def tls_present():
        return admin.exists() and (tls/'cert.pem').exists() and (tls/'key.pem').exists()
    admin.write_text('opaque admin data')
    (tls/'cert.pem').write_text('opaque certificate'); (tls/'key.pem').write_text('opaque key')
    future = '1900000000'
    guard_run({'TEST_SYNC': 'no', 'TEST_ADMIN_MTIME': future, 'TEST_CERT_MTIME': future})
    check(tls_present(), 'Unsynced: preserve even future TLS and allow startup')
    guard_run({'TEST_SYNC_STATUS': '1', 'TEST_ADMIN_MTIME': future})
    check(tls_present(), 'Failed sync query: preserve TLS')
    guard_run()
    check(tls_present(), 'Past mtime: preserve opaque TLS without parsing')
    guard_run({'TEST_ADMIN_MTIME': '1800000000', 'TEST_CERT_MTIME': '1800000000'})
    check(tls_present(), 'Equal mtime: preserve TLS')
    guard_run({'TEST_ADMIN_MTIME': future})
    check(not admin.exists() and (tls/'cert.pem').exists(), 'Future admin removed independently')
    admin.write_text('admin')
    guard_run({'TEST_CERT_MTIME': future})
    check(admin.exists() and not (tls/'cert.pem').exists() and not (tls/'key.pem').exists(), 'Future certificate removes pair')
    (tls/'cert.pem').write_text('cert'); (tls/'key.pem').write_text('key')
    guard_run({'TEST_KEY_MTIME': future})
    check(admin.exists() and not (tls/'cert.pem').exists() and not (tls/'key.pem').exists(), 'Future key removes pair')
    guard_run()  # Missing TLS is fine.
    for name, mtime_var in [('key.pem', 'TEST_KEY_MTIME'), ('cert.pem', 'TEST_CERT_MTIME')]:
        (tls/name).write_text('incomplete')
        guard_run()
        check((tls/name).exists(), 'Past incomplete pair preserved')
        guard_run({mtime_var: future})
        check(not (tls/name).exists(), 'Future incomplete pair removed')
    (tls/'cert.pem').write_text('cert'); (tls/'key.pem').write_text('key')
    guard_run({'TEST_SYSTEMCTL_STATUS': '1'})
    check(tls_present(), 'Time service failure never blocks startup')
    # A deliberately slow service command cannot delay the real guard return.
    start = time.monotonic()
    guard_run({'TEST_SYSTEMCTL_DELAY': '5', 'TEST_SYNC': 'no'})
    check(time.monotonic() - start < 3, 'Guard returns within 3 s despite slow time service')
    calls = log.read_text()
    check('systemctl --no-block start systemd-timesyncd.service' in calls, 'Guard kicks time sync')
    check(not (root/'var/lib/openxplay/mfi/identity.pk8').exists(), 'No identity installed')
    supplied = root/'var/lib/openxplay/mfi/identity.pk8'
    supplied.write_text('operator identity')
    supplied.chmod(0o600)
    (supplied.parent/'certificate.p7b').write_text('operator certificate')
    run([installer, bundle])
    check(supplied.read_text() == 'operator identity', 'Preserve separately supplied identity')
    check(supplied.stat().st_mode & 0o777 == 0o600, 'Preserve identity permissions')
    check((root/'var/lib/openxplay').stat().st_mode & 0o777 == 0o700, 'Private relay state directory')
    for shell in list(device.rglob('*.sh')) + [packaging/'install.sh']:
        subprocess.run(['sh', '-n', str(shell)], check=True)
print(f'PASS: {checks} assertions, fake-root scripts and clock guard; POSIX sh syntax checked')
PY

