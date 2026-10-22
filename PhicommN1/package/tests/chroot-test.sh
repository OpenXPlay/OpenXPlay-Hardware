#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
# Real dpkg lifecycle in a disposable cached Debian trixie arm64 container. No pulls or network.
# Missing runtime dependencies use empty test packages; this tests packaging, not their behavior.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fail() { echo "FAIL N1 chroot: $*" >&2; exit 1; }
if [ "${1:-}" != --inside ]; then
    [ "$#" -eq 0 ] || { echo "Usage: $0" >&2; exit 2; }
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo 'SKIP N1 chroot: Docker is unavailable'
        exit 0
    fi
    if ! docker image inspect debian:trixie >/dev/null 2>&1; then
        echo 'SKIP N1 chroot: debian:trixie is not cached (offline test never pulls)'
        exit 0
    fi
    if ! docker run --rm --pull=never --network=none --platform linux/arm64 debian:trixie \
        sh -c '[ "$(dpkg --print-architecture)" = arm64 ]' >/dev/null 2>&1; then
        echo 'SKIP N1 chroot: cached trixie image cannot run as arm64'
        exit 0
    fi
    repo=$(CDPATH= cd -- "$here/../../.." && pwd)
    work=$(mktemp -d)
    trap 'rm -rf "$work"' 0
    trap 'exit 1' HUP INT TERM
    sh "$here/../build-deb.sh" "$work/debs"
    COPYFILE_DISABLE=1 tar --no-xattrs -cf "$work/test.tar" -C "$repo" LICENSE PhicommN1
    tar -rf "$work/test.tar" -C "$work" debs
    docker run -i --rm --pull=never --network=none --platform linux/arm64 \
        -e OPENXPLAY_N1_CHROOT_TEST=1 debian:trixie \
        sh -c 'mkdir /work && tar -xf - -C /work && sh /work/PhicommN1/package/tests/chroot-test.sh --inside' < "$work/test.tar"
    exit 0
fi
[ "${OPENXPLAY_N1_CHROOT_TEST:-}" = 1 ] && [ -d /work/debs ] || {
    echo '--inside is only for the disposable test container' >&2; exit 2;
}
[ "$(id -u)" -eq 0 ] && [ "$(dpkg --print-architecture)" = arm64 ] || exit 2
os=$( . /etc/os-release; printf '%s:%s' "$ID" "$VERSION_ID" )
[ "$os" = debian:13 ] || { echo 'Needs Debian trixie arm64' >&2; exit 2; }
export LC_ALL=C DEBIAN_FRONTEND=noninteractive DPKG_MAINTSCRIPT_PACKAGE=openxplay-phicomm-n1
pass=0
check() {
    title=$1; shift
    "$@" || { echo "FAIL $title" >&2; exit 1; }
    echo "PASS $title"
    pass=$((pass + 1))
}
fixture=/work/device
mkdir -p "$fixture/etc" "$fixture/proc/device-tree"
cp -f /etc/os-release "$fixture/etc/os-release"
printf 'Phicomm N1\000' > "$fixture/proc/device-tree/model"
export OPENXPLAY_N1_ROOT=$fixture
preinst=$here/../debian/preinst
printf 'Other Board\000' > "$fixture/proc/device-tree/model"
if sh "$preinst" install >/work/wrong.log 2>&1; then echo 'FAIL wrong model accepted'; exit 1; fi
check 'package rejects wrong model' grep -q 'requires device-tree model Phicomm N1' /work/wrong.log
printf 'Phicomm N1\000' > "$fixture/proc/device-tree/model"
printf 'ID=debian\nVERSION_ID=12\n' > "$fixture/etc/os-release"
if sh "$preinst" install >/work/wrong.log 2>&1; then echo 'FAIL wrong OS accepted'; exit 1; fi
check 'package rejects wrong Debian version' grep -q 'requires Debian 13' /work/wrong.log
cp -f /etc/os-release "$fixture/etc/os-release"

# A plain Debian image lacks the N1's runtime packages. Resolve only absent direct dependencies
# with explicit fixtures, preserving real init-system-helpers to detect service state changes.
for pkg in bluez iw network-manager dnsmasq-base kmod device-tree-compiler iproute2; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -qx 'install ok installed'; then continue; fi
    echo "Fixture dependency (no runtime payload): $pkg"
    ctl=/work/dependency-$pkg/DEBIAN
    mkdir -p "$ctl"
    cat > "$ctl/control" <<EOF
Package: $pkg
Version: 999:1.0
Architecture: all
Maintainer: Test <test@example.invalid>
Description: Empty dependency fixture for offline N1 packaging tests
EOF
    dpkg-deb --root-owner-group -b "/work/dependency-$pkg" "/work/$pkg.deb" >/dev/null
    dpkg -i "/work/$pkg.deb" >/dev/null
done

# An incomplete pinned runtime must fail in apt before dpkg can unpack either package.
source=/work/missing-dependency-source
inputs=/work/missing-dependency-debs
mkdir -p "$source" "$inputs" /work/pinned-runtime/DEBIAN
cp -rf /work/PhicommN1 "$source/"
cp -f /work/LICENSE "$source/LICENSE"
cat > /work/pinned-runtime/DEBIAN/control <<'EOF'
Package: oxp-test-pinned-runtime
Version: 1.0
Architecture: all
Depends: oxp-test-missing-dependency
Maintainer: Test <test@example.invalid>
Description: Pinned fixture with a dependency absent from the offline bundle
EOF
deb=$inputs/oxp-test-pinned-runtime_1.0_all.deb
dpkg-deb --root-owner-group -b /work/pinned-runtime "$deb" >/dev/null
printf 'oxp-test-pinned-runtime 1.0 %s\n' "$(sha256sum "$deb" | cut -d' ' -f1)" > "$source/PhicommN1/install/debs.txt"
sh "$source/PhicommN1/package/build-bundle.sh" "$inputs" /work/bundles >/work/bundle.log 2>&1 || {
    cat /work/bundle.log; exit 1;
}
bundle=/work/bundles/openxplay-phicomm-n1-device-0.1.0
check 'missing dependency is not installed' sh -c '! dpkg-query -W -f="\${Status}" oxp-test-missing-dependency 2>/dev/null | grep -qx "install ok installed"'
check 'missing dependency is not bundled' sh -c '! find "$1/debs" -name "oxp-test-missing-dependency_*.deb" | grep .' sh "$bundle"
status_before=$(sha256sum /var/lib/dpkg/status)
for mode in dry install; do
    set -- "$bundle"
    if [ "$mode" = dry ]; then set -- --dry-run "$@"; fi
    rc=0
    sh "$bundle/install-device.sh" "$@" > "/work/$mode-preflight.log" 2>&1 || rc=$?
    check "$mode exits with dependency failure" test "$rc" -eq 1
    check "$mode reports the missing dependency" grep -qx \
        'OXP-STAGE device failed: missing dependencies: oxp-test-missing-dependency' "/work/$mode-preflight.log"
    check "$mode changes no dpkg state" test "$(sha256sum /var/lib/dpkg/status)" = "$status_before"
    check "$mode leaves no iU packages" sh -c '! dpkg-query -W -f="\${db:Status-Abbrev}\n" | grep -q "^iU"'
    check "$mode leaves dpkg audit clean" sh -c '[ -z "$(dpkg --audit)" ]'
done

# Only the device units may change enablement links.
mkdir -p /etc/systemd /run/systemd /var/lib/systemd
unit_links() {
    find /etc/systemd /run/systemd /var/lib/systemd -type l ! -name 'openxplay-n1-phy-id.*' ! -name 'openxplay-n1-bt-addr.service' -printf '%p %l\n' | sort
}
helper_state() { find /var/lib/systemd -path '*deb-systemd-helper*' \( -name 'openxplay-n1-phy-id.*' -o -name 'openxplay-n1-bt-addr.service*' \) -print; }
units='openxplay-n1-phy-id.service openxplay-n1-phy-id.path openxplay-n1-bt-addr.service'
check 'container is not booted with systemd' test ! -d /run/systemd/system
unit_links > /work/units-before
dpkg -i /work/debs/openxplay-phicomm-n1_*_all.deb >/work/install.log 2>&1 || { cat /work/install.log; exit 1; }
check 'package installed' sh -c '[ "$(dpkg-query -W -f="\${Status} \${Version}" openxplay-phicomm-n1)" = "install ok installed 0.1.0" ]'
check 'package files unmodified' sh -c '[ -z "$(dpkg -V openxplay-phicomm-n1)" ]'
check 'dpkg audit clean' sh -c '[ -z "$(dpkg --audit)" ]'
check 'host profile conffile' sh -c 'dpkg-query -W -f="\${Conffiles}" openxplay-phicomm-n1 | grep -q /etc/openxplay/host.json'
check 'host profile bytes' cmp /etc/openxplay/host.json "$here/../../host.json"
check 'package ships no openxplay-usb-* units' sh -c '! dpkg-query -L openxplay-phicomm-n1 | grep -E "/openxplay-usb-[^/]+$"'
check 'package ships no serial-getty@ttyGS0 drop-in' sh -c '! dpkg-query -L openxplay-phicomm-n1 | grep -F "/serial-getty@ttyGS0.service.d"'
for program in phy-id wifi-mac bt-addr; do
    check "mode 0755: $program" test "$(stat -c %a "/usr/lib/openxplay-phicomm-n1/$program")" = 755
done
check 'PHY program bytes' cmp /usr/lib/openxplay-phicomm-n1/phy-id "$here/../../ethernet/phy-id.sh"
check 'Bluetooth program bytes' cmp /usr/lib/openxplay-phicomm-n1/bt-addr "$here/../../bluetooth/bt-addr.sh"
check 'Wi-Fi program bytes' cmp /usr/lib/openxplay-phicomm-n1/wifi-mac "$here/../../wifi/wifi-mac.sh"
for unit in $units; do
    source=ethernet
    target=multi-user.target
    if [ "$unit" = openxplay-n1-bt-addr.service ]; then source=bluetooth; target=bluetooth.target; fi
    check "mode 0644: $unit" test "$(stat -c %a "/lib/systemd/system/$unit")" = 644
    check "unit bytes: $unit" cmp "/lib/systemd/system/$unit" "$here/../../$source/$unit"
    check "helper enables $unit" deb-systemd-helper --quiet is-enabled "$unit"
    check "helper remembers $unit" deb-systemd-helper --quiet was-enabled "$unit"
    check "unit enablement link: $unit" test \
        "$(readlink -f "/etc/systemd/system/$target.wants/$unit")" = "$(readlink -f "/lib/systemd/system/$unit")"
done
rule=/lib/udev/rules.d/70-openxplay-n1-wifi-mac.rules
check 'mode 0644: Wi-Fi udev rule' test "$(stat -c %a "$rule")" = 644
check 'Wi-Fi udev rule bytes' cmp "$rule" "$here/../../wifi/70-openxplay-n1-wifi-mac.rules"
check 'image install does not run PHY apply' test ! -e "$fixture/run/lock/openxplay-n1-phy-id.lock"
check 'configure message printed once' test "$(grep -cFx \
    'openxplay-phicomm-n1: the Ethernet PHY fix and the per-device Wi-Fi and Bluetooth addresses take effect at the next boot.' /work/install.log)" -eq 1
/usr/lib/openxplay-phicomm-n1/phy-id status > /work/phy-status || fail 'PHY status failed in container'
check 'container PHY status is unsupported' grep -qx 'unsupported .*' /work/phy-status
helper_state > /work/helper-state
check 'helper state recorded' test -s /work/helper-state
unit_links > /work/units-after
check 'install preserves unrelated unit links' cmp /work/units-before /work/units-after

# Runtime commands are shims; deb-systemd-helper remains real for the whole lifecycle.
mkdir -p /work/bin
for cmd in systemctl deb-systemd-invoke udevadm ip; do
    cat > "/work/bin/$cmd" <<'EOF'
#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
echo "$(basename "$0") $*" >> /work/runtime.log
exit "${TEST_SERVICE_EXIT:-0}"
EOF
done
cat > /work/bin/flock <<'EOF'
#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
exit "${TEST_PHY_LOCK_EXIT:-0}"
EOF
chmod 0755 /work/bin/*
: > /work/runtime.log
postinst() {
    env PATH="/work/bin:$PATH" "$@" sh "$here/../debian/postinst" configure 0.1.0 > /work/postinst.log 2>&1
}
check 'image postinst succeeds' postinst
check 'image postinst runs no runtime commands' test ! -s /work/runtime.log
mkdir -p /run/systemd/system
cat > /work/runtime-expected <<'EOF'
systemctl --system daemon-reload
deb-systemd-invoke start openxplay-n1-phy-id.path
udevadm control --reload
deb-systemd-invoke start bluetooth.service
EOF
check 'live postinst succeeds' postinst
check 'live postinst starts the watcher and Bluetooth and reloads udev' cmp /work/runtime-expected /work/runtime.log
check 'live postinst applies PHY fix once' test "$(grep -c 'openxplay-n1-phy-id: unsupported' /work/postinst.log)" -eq 1
: > /work/runtime.log
check 'postinst tolerates runtime and PHY failures' postinst TEST_SERVICE_EXIT=1 TEST_PHY_LOCK_EXIT=1
check 'failed commands do not skip later runtime actions' cmp /work/runtime-expected /work/runtime.log
check 'PHY failure warning printed' grep -q 'warning: Ethernet PHY fix failed' /work/postinst.log
for action in abort-upgrade abort-deconfigure abort-remove; do
    : > /work/runtime.log
    check "$action succeeds" env PATH="/work/bin:$PATH" sh "$here/../debian/postinst" "$action" 0.1.0
    check "$action runs the guarded runtime actions" cmp /work/runtime-expected /work/runtime.log
done
echo '# owner edit' >> /etc/openxplay/host.json
PATH="/work/bin:$PATH" dpkg --force-confdef --force-confold -i /work/debs/openxplay-phicomm-n1_*_all.deb >/dev/null 2>&1
check 'local conffile edit preserved' grep -qx '# owner edit' /etc/openxplay/host.json
for unit in $units; do check "reinstall retains helper state: $unit" deb-systemd-helper --quiet is-enabled "$unit"; done
unit_links > /work/units-after
check 'live configure and reinstall preserve unrelated links' cmp /work/units-before /work/units-after
mkdir -p /var/lib/openxplay-phicomm-n1
printf 'purge me\n' > /var/lib/openxplay-phicomm-n1/purge-marker
: > /work/runtime.log
PATH="/work/bin:$PATH" dpkg -r openxplay-phicomm-n1 > /work/remove.log 2>&1 || { cat /work/remove.log; fail 'remove failed'; }
printf 'deb-systemd-invoke stop openxplay-n1-phy-id.path\nsystemctl --system daemon-reload\n' > /work/remove-expected
# The real deb-systemd-helper reloads systemd itself on a live system after mask, purge and
# unmask; only those reloads may follow the package's own commands.
runtime_is() {
    lines=$(wc -l < "$1")
    head -n "$lines" /work/runtime.log | cmp "$1" - &&
        ! tail -n +"$((lines + 1))" /work/runtime.log | grep -vqx 'systemctl daemon-reload'
}
check 'remove stops watcher and reloads systemd' runtime_is /work/remove-expected
check 'package license removed' test ! -e /usr/share/doc/openxplay-phicomm-n1/LICENSE
check 'conffile kept on remove' test -f /etc/openxplay/host.json
check 'state kept until purge' test -f /var/lib/openxplay-phicomm-n1/purge-marker
for unit in $units; do check "helper masks removed unit: $unit" test "$(readlink "/etc/systemd/system/$unit")" = /dev/null; done
check 'PHY program removed' test ! -e /usr/lib/openxplay-phicomm-n1/phy-id
check 'Bluetooth program removed' test ! -e /usr/lib/openxplay-phicomm-n1/bt-addr
check 'Wi-Fi program removed' test ! -e /usr/lib/openxplay-phicomm-n1/wifi-mac
check 'Wi-Fi rule removed' test ! -e "$rule"
: > /work/runtime.log
PATH="/work/bin:$PATH" dpkg --purge openxplay-phicomm-n1 > /work/purge.log 2>&1 || { cat /work/purge.log; fail 'purge failed'; }
printf 'systemctl --system daemon-reload\n' > /work/purge-expected
check 'purge reloads systemd' runtime_is /work/purge-expected
check 'conffile removed on purge' test ! -e /etc/openxplay/host.json
check 'package state removed on purge' test ! -e /var/lib/openxplay-phicomm-n1
helper_state > /work/helper-state
check 'helper state removed on purge' test ! -s /work/helper-state
for unit in $units; do
    target=multi-user.target
    if [ "$unit" = openxplay-n1-bt-addr.service ]; then target=bluetooth.target; fi
    check "purge removes enablement link: $unit" test ! -L "/etc/systemd/system/$target.wants/$unit"
    check "purge unmasks unit: $unit" test ! -L "/etc/systemd/system/$unit"
done
unit_links > /work/units-after
check 'remove and purge preserve unrelated unit links' cmp /work/units-before /work/units-after
echo "PASS $pass N1 trixie arm64 package lifecycle checks (offline dependency fixtures)"
