#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-19
#
# Installs, checks and removes the UFI003 device bundle (and optionally a relay .deb on top) inside
# a disposable Debian 11 arm64 root: a container or a chroot, never the device or the host.
#
# Usage, as root inside that root:
#   chroot-test.sh [--prepare] [--modules DIR] [--legacy RELAY_PACKAGE_DIR] [--relay RELAY_DEB] BUNDLE.tar.gz
#   --prepare  apt-get install the OpenStick base packages this test relies on (network needed)
#   --modules  a copy of the device's /lib/modules/5.15.0-handsomekernel+ (kernel/, modules.order,
#              modules.builtin*) so depmod/modinfo checks run against the real module tree
#   --legacy   first recreate the hand-installed state of the 2026-10 test device (Debian packages
#              installed with dpkg, files copied by hand, relay from its release tarball) to test the
#              upgrade path; RELAY_PACKAGE_DIR is an unpacked openxplay-relay-*-linux-aarch64
#   --relay    install, check, remove and purge this openxplay-relay .deb after the device stage
set -eu
krel=5.15.0-handsomekernel+
prepare=false; modules=; legacy=; relay=
while [ "$#" -gt 1 ]; do
    case "$1" in
    --prepare) prepare=true; shift ;;
    --modules) modules=$2; shift 2 ;;
    --legacy) legacy=$2; shift 2 ;;
    --relay) relay=$2; shift 2 ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
    esac
done
[ "$#" -eq 1 ] || { echo "Usage: $0 [options] BUNDLE.tar.gz" >&2; exit 2; }
bundle=$1
[ "$(id -u)" -eq 0 ] || { echo 'Run as root inside a disposable root' >&2; exit 2; }
grep -qx 'VERSION_ID="11"' /etc/os-release || { echo 'Needs Debian 11' >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
pass=0; failed=0
check() {
    if sh -c "$2" >/dev/null 2>&1; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; failed=$((failed + 1)); fi
}
section() { echo; echo "== $*"; }
owned_by() { dpkg-query -S "$1" 2>/dev/null | cut -d: -f1; }

if "$prepare"; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends network-manager dnsmasq kmod systemd systemd-timesyncd \
        udev dbus init-system-helpers procps python3 dnsmasq-base >/dev/null
fi
for p in network-manager dnsmasq kmod systemd init-system-helpers; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || { echo "Base package missing: $p" >&2; exit 2; }
done

python3 "$(dirname "$0")/profile-test.py"

section 'Fake OpenStick base'
mkdir -p "/lib/modules/$krel"
if [ -n "$modules" ]; then
    cp -R "$modules/." "/lib/modules/$krel/"
else
    mkdir -p "/lib/modules/$krel/kernel"
    : > "/lib/modules/$krel/modules.order"; : > "/lib/modules/$krel/modules.builtin"
fi
depmod -a "$krel"
# The image's USB network dnsmasq (enabled), as on the device.
printf 'listen-address=192.168.68.1\ndhcp-range=192.168.68.10,192.168.68.254,12h\n' > /etc/dnsmasq.conf
systemctl enable dnsmasq.service >/dev/null 2>&1
# install-device.sh checks the running kernel; the container runs the host's.
stub=$(mktemp -d)
printf '#!/bin/sh\n[ "$1" = -r ] && { echo %s; exit 0; }\nexec /bin/uname "$@"\n' "$krel" > "$stub/uname"
chmod 0755 "$stub/uname"
export OPENXPLAY_FORCE_MODEL=1
work=$(mktemp -d)
tar -xzf "$bundle" -C "$work"
set -- "$work"/openxplay-ufi003-device-*
dir=$1
# Accessory identity stand-ins (test bytes, not an identity) and settings: must never change.
mkdir -p /var/lib/openxplay/mfi
printf 'test-only-not-an-identity\n' > /var/lib/openxplay/mfi/identity.pk8
printf 'test-only-not-a-certificate\n' > /var/lib/openxplay/mfi/certificate.p7b
printf '{"output":"web"}\n' > /var/lib/openxplay/settings.json
chmod -R go-rwx /var/lib/openxplay
state_digest() { find /var/lib/openxplay -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1; }
state_before=$(state_digest)
same_state() {
    if [ "$(state_digest)" = "$state_before" ]; then echo "PASS state unchanged: $1"; pass=$((pass + 1));
    else echo "FAIL state changed: $1"; failed=$((failed + 1)); fi
}

if [ -n "$legacy" ]; then
    section 'Legacy state of the test device (hand-installed)'
    dpkg -i "$dir"/debs/lib*.deb "$dir"/debs/iw_*.deb "$dir"/debs/bluez_*.deb >/dev/null
    tmp=$(mktemp -d)
    dpkg-deb -x "$dir"/debs/openxplay-ufi003_*_arm64.deb "$tmp"
    install -D -m 0644 "$tmp/lib/modules/$krel/extra/rfcomm.ko" "/lib/modules/$krel/extra/rfcomm.ko"
    install -D -m 0644 "$tmp/lib/modules/$krel/updates/btqcomsmd.ko" "/lib/modules/$krel/updates/btqcomsmd.ko"
    depmod -a "$krel"
    install -D -m 0755 "$tmp/usr/lib/openxplay-ufi003/bt-guard" /usr/local/libexec/openxplay-bt-guard
    sed 's#^ExecStart=.*#ExecStart=/usr/local/libexec/openxplay-bt-guard#' \
        "$tmp/lib/systemd/system/openxplay-bt-guard.service" > /etc/systemd/system/openxplay-bt-guard.service
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/openxplay-bt-guard.service /etc/systemd/system/multi-user.target.wants/openxplay-bt-guard.service
    install -D -m 0644 "$(dirname "$0")/../../network/openxplay-wifi-powersave.conf" /etc/NetworkManager/conf.d/openxplay-wifi-powersave.conf
    install -D -m 0644 "$(dirname "$0")/../../network/openxplay-wifi-scan-mac.conf" /etc/NetworkManager/conf.d/openxplay-wifi-scan-mac.conf
    # These three were written by hand with mode 0666 on the device.
    install -D -m 0666 /dev/null /etc/modules-load.d/openxplay-rfcomm.conf; echo rfcomm > /etc/modules-load.d/openxplay-rfcomm.conf
    install -D -m 0666 /dev/null /etc/dnsmasq.d/openxplay-bind.conf; echo bind-interfaces > /etc/dnsmasq.d/openxplay-bind.conf
    install -D -m 0666 /dev/null /etc/systemd/system/openxplay-relay.service.d/utf8.conf
    printf '# Non-ASCII SSIDs: nmcli replaces non-ASCII bytes with ? under the C locale.\n[Service]\nEnvironment=LANG=C.UTF-8 LC_ALL=C.UTF-8\n' > /etc/systemd/system/openxplay-relay.service.d/utf8.conf
    # An owner's own drop-in, which no package may touch.
    printf '[Service]\nNice=-5\n' > /etc/systemd/system/openxplay-relay.service.d/zz-owner.conf
    # The relay from its release tarball, as installed on the device.
    printf '#!/bin/sh\ncase "$1" in daemon-reload|start|restart|stop) exit 0 ;; esac\nexec /bin/systemctl "$@"\n' > "$stub/systemctl"
    chmod 0755 "$stub/systemctl"
    (cd "$legacy" && PATH="$stub:$PATH" sh rust/packaging/install.sh bin/openxplay-relay bin/oxp-relay web admin >/dev/null)
    rm -f "$stub/systemctl"
    printf 'stale\n' > /opt/openxplay/share/web/assets/receiver-STALE000.js
    cp /opt/openxplay/bin/openxplay-relay /opt/openxplay/bin/openxplay-relay.prev
    check 'legacy relay enabled from /etc' "[ \"\$(readlink /etc/systemd/system/multi-user.target.wants/openxplay-relay.service)\" = /etc/systemd/system/openxplay-relay.service ]"
fi

section 'Stage device: preflight and install'
check 'preflight ok' "PATH='$stub:$PATH' sh '$dir/install-device.sh' --dry-run '$dir' | tail -n 1 | grep -q '^OXP-STAGE device preflight-ok'"
PATH="$stub:$PATH" sh "$dir/install-device.sh" "$dir" > "$work/install.log" 2>&1 || :
grep -E '^(openxplay-|Will install|Already installed|OXP-STAGE)' "$work/install.log" | sed 's/^/  | /'
check 'install ok' "tail -n 1 '$work/install.log' | grep -q '^OXP-STAGE device ok .*reboot=required'"
for p in bluez iw libasound2 libasound2-data libdw1 libelf1 libnl-3-200 libnl-genl-3-200 openxplay-ufi003; do
    check "installed: $p" "dpkg-query -W -f='\${Status}' $p | grep -qx 'install ok installed'"
done
check 'no modified package files' "[ -z \"\$(dpkg -V openxplay-ufi003)\" ]"
check 'dpkg audit clean' "[ -z \"\$(dpkg --audit)\" ]"
check 'rfcomm.ko owned by the package' "[ \"\$(dpkg-query -S /lib/modules/$krel/extra/rfcomm.ko | cut -d: -f1)\" = openxplay-ufi003 ]"
check 'modules.dep lists rfcomm' "grep -q '^extra/rfcomm.ko:' /lib/modules/$krel/modules.dep"
check 'modules.dep lists the fixed btqcomsmd' "grep -q '^updates/btqcomsmd.ko:' /lib/modules/$krel/modules.dep"
if [ -n "$modules" ]; then
    check 'modinfo selects updates/btqcomsmd.ko' "[ \"\$(modinfo -k $krel -n btqcomsmd)\" = /lib/modules/$krel/updates/btqcomsmd.ko ]"
    check 'fixed btqcomsmd srcversion' "[ \"\$(modinfo -k $krel -F srcversion btqcomsmd)\" = 9AB11C2ECBD034761F265A3 ]"
    check 'rfcomm resolves bluetooth.ko' "modprobe -S $krel --show-depends rfcomm | grep -q 'kernel/net/bluetooth/bluetooth.ko'"
    check 'btqcomsmd resolves btqca and wcnss_ctrl' "modprobe -S $krel --show-depends btqcomsmd | grep -q btqca.ko && modprobe -S $krel --show-depends btqcomsmd | grep -q wcnss_ctrl.ko"
    check 'rfcomm vermagic' "modinfo -k $krel -F vermagic rfcomm | grep -q '^$krel SMP preempt mod_unload aarch64'"
fi
check 'guard enabled from /lib' "[ \"\$(readlink /etc/systemd/system/multi-user.target.wants/openxplay-bt-guard.service)\" = /lib/systemd/system/openxplay-bt-guard.service ]"
check 'guard script executable' "[ -x /usr/lib/openxplay-ufi003/bt-guard ]"
check 'bluetooth enabled' "[ \"\$(systemctl is-enabled bluetooth.service)\" = enabled ]"
check 'system dnsmasq disabled' "[ \"\$(systemctl is-enabled dnsmasq.service)\" = disabled ]"
check 'dnsmasq marker' "[ -e /var/lib/openxplay-ufi003/dnsmasq-was-enabled ]"
check 'timesyncd enabled' "[ ! -e /lib/systemd/system/systemd-timesyncd.service ] || [ \"\$(systemctl is-enabled systemd-timesyncd.service)\" = enabled ]"
check 'rfcomm loaded at boot' "grep -qx rfcomm /etc/modules-load.d/openxplay-rfcomm.conf"
check 'device no longer ships clock guard or drop-in' "[ ! -e /usr/lib/openxplay-ufi003/clock-guard ] && [ ! -e /lib/systemd/system/openxplay-relay.service.d/ufi003-clock.conf ]"
check 'host profile is a conffile' "dpkg-query -W -f='\${Conffiles}' openxplay-ufi003 | grep -q /etc/openxplay/host.json"
check 'host profile values' "python3 -c 'import json; p=json.load(open(\"/etc/openxplay/host.json\")); assert p == {\"model\":\"UFI003\",\"wifiInterface\":\"wlan0\",\"bluetoothAdapter\":\"hci0\",\"hotspotDownGapSeconds\":15,\"secureConnections\":\"pairing-off\"}'"
check 'device no longer ships generic NM policies' "! dpkg-query -L openxplay-ufi003 | grep -q /etc/NetworkManager/conf.d/"
for f in /etc/modules-load.d/openxplay-rfcomm.conf /etc/dnsmasq.d/openxplay-bind.conf /etc/openxplay/host.json; do
    check "mode 0644: $f" "[ \"\$(stat -c %a $f)\" = 644 ]"
done
check 'no hand-installed guard left' "[ ! -e /usr/local/libexec/openxplay-bt-guard ] && [ ! -e /etc/systemd/system/openxplay-bt-guard.service ]"
same_state 'device stage'
check 'second run installs nothing' "PATH='$stub:$PATH' sh '$dir/install-device.sh' '$dir' | grep -c '^Will install' | grep -qx 0"

section 'Device 0.1.0 upgrade, modified conffiles, downgrade and purge'
# Reconstruct the retired payload using the unchanged legacy sources. Maintainer
# scripts stay out of this fixture: we are testing dpkg conffile transitions here.
old=$work/old-device
dpkg-deb -R "$dir"/debs/openxplay-ufi003_*_arm64.deb "$old"
sed -i 's/^Version: .*/Version: 0.1.0/' "$old/DEBIAN/control"
rm -f "$old/DEBIAN/preinst" "$old/DEBIAN/postinst" "$old/DEBIAN/prerm" "$old/DEBIAN/postrm" "$old/DEBIAN/md5sums" "$old/etc/openxplay/host.json"
mkdir -p "$old/etc/NetworkManager/conf.d" "$old/lib/systemd/system/openxplay-relay.service.d"
for policy in powersave scan-mac; do
    cp -f "$(dirname "$0")/../../network/openxplay-wifi-$policy.conf" "$old/etc/NetworkManager/conf.d/"
done
cp -f "$(dirname "$0")/../../install/clock-guard.sh" "$old/usr/lib/openxplay-ufi003/clock-guard"
chmod 0755 "$old/usr/lib/openxplay-ufi003/clock-guard"
printf '[Service]\nExecStartPre=-/usr/lib/openxplay-ufi003/clock-guard\n' > "$old/lib/systemd/system/openxplay-relay.service.d/ufi003-clock.conf"
(cd "$old" && find etc -type f | LC_ALL=C sort | sed 's#^#/#') > "$old/DEBIAN/conffiles"
dpkg-deb --root-owner-group -b "$old" "$work/device-0.1.0.deb" >/dev/null
# Run the upgrade twice: pristine policies disappear; local edits are backed up.
for modified in no yes; do
    dpkg --force-confdef --force-confold -i "$work/device-0.1.0.deb" >/dev/null
    check 'downgrade restores old policies and guard' "[ -f /etc/NetworkManager/conf.d/openxplay-wifi-powersave.conf ] && [ -x /usr/lib/openxplay-ufi003/clock-guard ]"
    if [ "$modified" = yes ]; then
        for policy in powersave scan-mac; do
            echo '# local edit' >> "/etc/NetworkManager/conf.d/openxplay-wifi-$policy.conf"
        done
    fi
    dpkg --force-confdef --force-confold -i "$dir"/debs/openxplay-ufi003_*_arm64.deb >/dev/null
    for policy in powersave scan-mac; do
        f=/etc/NetworkManager/conf.d/openxplay-wifi-$policy.conf
        check "obsolete policy removed ($modified): $policy" "[ ! -e $f ]"
        if [ "$modified" = yes ]; then
            check "local edit saved: $policy" "grep -qx '# local edit' $f.dpkg-bak"
        fi
    done
    check 'obsolete clock guard and drop-in removed on upgrade' "[ ! -e /usr/lib/openxplay-ufi003/clock-guard ] && [ ! -e /lib/systemd/system/openxplay-relay.service.d/ufi003-clock.conf ]"
    check 'host profile installed after upgrade' "[ -f /etc/openxplay/host.json ] && dpkg-query -W -f='\${Conffiles}' openxplay-ufi003 | grep -q /etc/openxplay/host.json"
done

if [ -n "$relay" ]; then
    section 'Stage relay: install, remove, purge'
    dpkg -i "$relay" > "$work/relay.log" 2>&1 || { cat "$work/relay.log"; }
    check 'relay installed' "dpkg-query -W -f='\${Status}' openxplay-relay | grep -qx 'install ok installed'"
    check 'relay files clean' "[ -z \"\$(dpkg -V openxplay-relay)\" ]"
    check 'relay enabled from /lib' "[ \"\$(readlink /etc/systemd/system/multi-user.target.wants/openxplay-relay.service)\" = /lib/systemd/system/openxplay-relay.service ]"
    check 'relay binaries' "[ -x /opt/openxplay/bin/openxplay-relay ] && [ -x /opt/openxplay/bin/oxp-relay ]"
    check 'receiver and admin pages' "[ -f /opt/openxplay/share/web/receiver/index.html ] && [ -f /opt/openxplay/share/admin/index.html ]"
    check 'updater installed' "[ -x /usr/sbin/openxplay-relay-update ]"
    check 'state dir 0700' "[ \"\$(stat -c %a /var/lib/openxplay)\" = 700 ]"
    if [ -n "$legacy" ]; then
        check 'tarball unit moved aside' "[ -f /etc/systemd/system/openxplay-relay.service.pre-deb ] && [ ! -e /etc/systemd/system/openxplay-relay.service ]"
        check 'stale tarball assets removed' "[ ! -e /opt/openxplay/share/web/assets/receiver-STALE000.js ]"
        check 'manual .prev copy kept' "[ -f /opt/openxplay/bin/openxplay-relay.prev ]"
        check 'obsolete utf8 drop-in removed' "[ ! -e /etc/systemd/system/openxplay-relay.service.d/utf8.conf ]"
        check "owner's drop-in kept" "[ -f /etc/systemd/system/openxplay-relay.service.d/zz-owner.conf ]"
    fi
    same_state 'relay install'
    echo; echo '-- OpenXPlay files with both stages installed:'
    { dpkg -L openxplay-ufi003 openxplay-relay | while read -r f; do [ -f "$f" ] && echo "$f"; done
      find /etc/systemd/system /usr/local /opt/openxplay -path '*openxplay*' -type f 2>/dev/null; } | sort -u
    dpkg -r openxplay-relay >/dev/null 2>&1
    check 'relay removed' "! dpkg-query -W -f='\${Status}' openxplay-relay 2>/dev/null | grep -q 'ok installed'"
    check 'relay files gone' "[ ! -e /opt/openxplay/bin/openxplay-relay ] && [ ! -e /lib/systemd/system/openxplay-relay.service ] && [ ! -e /usr/sbin/openxplay-relay-update ]"
    dpkg --purge openxplay-relay >/dev/null 2>&1
    check 'relay purged' "! dpkg-query -W openxplay-relay >/dev/null 2>&1 || [ -z \"\$(dpkg-query -W -f='\${Status}' openxplay-relay | grep -v 'not-installed')\" ]"
    check 'no relay enable link left' "[ ! -e /etc/systemd/system/multi-user.target.wants/openxplay-relay.service ] && [ ! -L /etc/systemd/system/openxplay-relay.service ]"
    same_state 'relay purge'
    echo '-- left under /opt/openxplay after purge:'; find /opt/openxplay 2>/dev/null | sort || :
fi

section 'Stage device: remove and purge'
dpkg -r openxplay-ufi003 >/dev/null 2>&1
check 'device package removed' "[ ! -e /lib/modules/$krel/extra/rfcomm.ko ] && [ ! -e /lib/modules/$krel/updates/btqcomsmd.ko ] && [ ! -e /usr/lib/openxplay-ufi003/bt-guard ]"
check 'modules.dep updated' "! grep -q 'rfcomm.ko' /lib/modules/$krel/modules.dep"
check 'conffiles kept on remove' "[ -f /etc/dnsmasq.d/openxplay-bind.conf ] && [ -f /etc/openxplay/host.json ]"
dpkg --purge openxplay-ufi003 >/dev/null 2>&1
check 'conffiles gone on purge' "[ ! -e /etc/dnsmasq.d/openxplay-bind.conf ] && [ ! -e /etc/NetworkManager/conf.d/openxplay-wifi-powersave.conf ] && [ ! -e /etc/openxplay/host.json ]"
for policy in powersave scan-mac; do
    check "obsolete conffile backup gone on purge: $policy" "[ ! -e /etc/NetworkManager/conf.d/openxplay-wifi-$policy.conf.dpkg-bak ]"
done
check 'system dnsmasq re-enabled on purge'  "[ \"\$(systemctl is-enabled dnsmasq.service)\" = enabled ]"
check 'guard enable link gone' "[ ! -e /etc/systemd/system/multi-user.target.wants/openxplay-bt-guard.service ]"
check 'BlueZ stays installed' "dpkg-query -W -f='\${Status}' bluez | grep -qx 'install ok installed'"
same_state 'device purge'

echo; echo "Result: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
