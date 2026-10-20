#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-16
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/common.sh"
dry=false
if [ "${1:-}" = --dry-run ]; then dry=true; shift; fi
[ "$#" -eq 1 ] || fail "Usage: DESTDIR=/optional/fake/root $0 [--dry-run] BUNDLE"
bundle=$(CDPATH= cd -- "$1" && pwd)
root=${DESTDIR:-}
case "$root" in ''|/*) ;; *) fail 'DESTDIR must be absolute' ;; esac
# Reject / as a misleading fake root; an empty prefix is the live-device mode.
case "$root" in ''|*[!/]*) ;; *) fail 'Use an empty DESTDIR for live installation' ;; esac
root=${root%/}
export DESTDIR="$root"
[ -n "$root" ] || "$dry" || [ "$(id -u)" -eq 0 ] || fail 'Run as root on the device'
[ "$(uname -r)" = '5.15.0-handsomekernel+' ] || fail 'Unsupported kernel; expected 5.15.0-handsomekernel+'
for cmd in awk sha256sum find sort stat date dpkg systemctl depmod modprobe nmcli timedatectl; do command -v "$cmd" >/dev/null || fail "Required command: $cmd"; done
no_identity "$bundle"
# The bundle manifest is an integrity check, not a signature. Require complete coverage.
(
    cd "$bundle"
    LC_ALL=C awk '
        {
            digest = substr($0, 1, 64)
            name = substr($0, 67)
            if (length(digest) != 64 || digest ~ /[^0-9a-fA-F]/ ||
                substr($0, 65, 2) != "  " || length(name) <= 2 || substr(name, 1, 2) != "./" ||
                name ~ /[\\\\\r]/ || seen[name]++) exit 1
            n = split(substr(name, 3), parts, "/")
            for (i = 1; i <= n; i++)
                if (parts[i] == "" || parts[i] == "." || parts[i] == "..") exit 1
        }
    ' SHA256SUMS || fail 'Unsafe, malformed or duplicate bundle manifest entry'
    find . -type f ! -path ./SHA256SUMS -print | LC_ALL=C sort | LC_ALL=C awk '
        FILENAME != "-" { listed[substr($0, 67)] = 1; next }
        { if (!($0 in listed)) bad = 1; delete listed[$0] }
        END { for (name in listed) bad = 1; exit bad }
    ' SHA256SUMS - || fail 'Bundle SHA256SUMS does not cover exactly the bundle files'
    sha256sum -c SHA256SUMS || fail 'Bundle SHA256 mismatch'
)

verify_debs "$bundle"
module_digest=$(awk '$2 == "rfcomm.ko" {print $1}' "$bundle/UFI003/rfcomm/SHA256SUMS")
verify "$module_digest" "$bundle/UFI003/rfcomm/rfcomm.ko"
btqcomsmd_digest=$(awk '$2 == "btqcomsmd.ko" {print $1}' "$bundle/UFI003/btqcomsmd/SHA256SUMS")
verify "$btqcomsmd_digest" "$bundle/UFI003/btqcomsmd/btqcomsmd.ko"
for f in bin/openxplay-relay bin/oxp-relay web/receiver/index.html admin/index.html packaging/install.sh packaging/openxplay-relay.service UFI003/btqcomsmd/btqcomsmd.ko UFI003/install/clock-guard.sh UFI003/bluetooth/bt-guard.sh UFI003/bluetooth/openxplay-bt-guard.service UFI003/network/openxplay-wifi-powersave.conf UFI003/network/openxplay-wifi-scan-mac.conf; do
    [ -f "$bundle/$f" ] || fail "Missing bundle file: $f"
done
if "$dry"; then
    echo "Verified bundle. Would install ordered debs, RFCOMM, the fixed WCNSS Bluetooth driver, Bluetooth, dnsmasq binding (if needed), Wi-Fi power-save and scan MAC policy, time guard, Bluetooth guard and relay under ${root:-/}."
    echo 'Live mode enables Bluetooth/time sync; relay starts with a supplied MFi identity, including offline without synchronized time.'
    exit 0
fi
# Runtime actions are deliberately suppressed for fake roots, never sent to the host.
live() { if [ -z "$root" ]; then "$@"; else echo "Fake root: skip runtime action: $*"; fi; }
enable() {
    if [ -n "$root" ]; then systemctl --root="$root" enable "$1";
    else systemctl enable "$1"; fi
}
if [ -f "$root/etc/systemd/system/openxplay-relay.service" ]; then
    live systemctl stop openxplay-relay.service
fi
while read -r name version digest extra; do
    case "$name" in ''|'#'*) continue ;; esac
    arch=arm64; [ "$name" != libasound2-data ] || arch=all
    if [ -n "$root" ]; then
        installed=$(dpkg --root="$root" --show --showformat='${Status} ${Version}' "$name" 2>/dev/null || :)
    else
        installed=$(dpkg --show --showformat='${Status} ${Version}' "$name" 2>/dev/null || :)
    fi
    if [ "$installed" = "install ok installed $version" ]; then echo "Already installed: $name $version"; continue; fi
    if [ -n "$root" ]; then dpkg --root="$root" -i "$bundle/debs/${name}_${version}_${arch}.deb";
    else dpkg -i "$bundle/debs/${name}_${version}_${arch}.deb"; fi
done < "$bundle/UFI003/install/debs.txt"
put() { mkdir -p "$(dirname "$root$2")"; install -m 0644 "$1" "$root$2"; }
put "$bundle/UFI003/rfcomm/rfcomm.ko" /lib/modules/5.15.0-handsomekernel+/extra/rfcomm.ko
# Fixed WCNSS Bluetooth driver; updates/ takes precedence over the in-tree module. It is loaded at
# the next boot: replacing it live would drop working Bluetooth connections.
put "$bundle/UFI003/btqcomsmd/btqcomsmd.ko" /lib/modules/5.15.0-handsomekernel+/updates/btqcomsmd.ko
if [ -n "$root" ]; then depmod -b "$root" -a 5.15.0-handsomekernel+; else depmod -a 5.15.0-handsomekernel+; fi
mkdir -p "$root/etc/modules-load.d"
printf 'rfcomm\n' > "$root/etc/modules-load.d/openxplay-rfcomm.conf"
live modprobe rfcomm
# Earlier releases forced Secure Connections off at every BlueZ start, but bonded iPhones then drop
# the link right after encryption. The relay now owns the setting (off only while pairing), so
# remove that drop-in on upgrade; the daemon-reload and BlueZ restart below apply the removal.
rm -f "$root/etc/systemd/system/bluetooth.service.d/openxplay-no-secure-connections.conf"
rmdir "$root/etc/systemd/system/bluetooth.service.d" 2>/dev/null || :
mkdir -p "$root/usr/local/libexec"
install -m 0755 "$bundle/UFI003/bluetooth/bt-guard.sh" "$root/usr/local/libexec/openxplay-bt-guard"
put "$bundle/UFI003/bluetooth/openxplay-bt-guard.service" /etc/systemd/system/openxplay-bt-guard.service
live systemctl daemon-reload
enable openxplay-bt-guard.service
enable bluetooth.service
# Restart, not start: an upgrade must replace a running older guard (which switched Secure
# Connections off) before BlueZ restarts and turns the setting back on.
live systemctl restart openxplay-bt-guard.service
live systemctl restart bluetooth.service
# Ignore commented directives. Scan the image's main config and standard conf-dir.
configured=false; bound=false
for config in "$root/etc/dnsmasq.conf" "$root/etc/dnsmasq.d/"*.conf; do
    [ -f "$config" ] || continue
    configured=true
    if LC_ALL=C grep -Eq '^[[:space:]]*bind-(interfaces|dynamic)([[:space:]#]|$)' "$config"; then bound=true; fi
done
if "$configured" && ! "$bound"; then
    mkdir -p "$root/etc/dnsmasq.d"
    printf 'bind-interfaces\n' > "$root/etc/dnsmasq.d/openxplay-bind.conf"
    live systemctl restart dnsmasq.service
fi
put "$bundle/UFI003/network/openxplay-wifi-powersave.conf" /etc/NetworkManager/conf.d/openxplay-wifi-powersave.conf
# wlan0 keeps its own MAC address while scanning, so the boot needs no address changes before the AP.
put "$bundle/UFI003/network/openxplay-wifi-scan-mac.conf" /etc/NetworkManager/conf.d/openxplay-wifi-scan-mac.conf
# Reload configuration without disconnecting the installation network; use live setting too.
live nmcli general reload
if ! live nmcli device modify wlan0 802-11-wireless.powersave 2; then
    echo 'Wi-Fi is inactive; power-save policy will apply on its next activation.'
fi
for unit in /lib/systemd/system/systemd-timesyncd.service /usr/lib/systemd/system/systemd-timesyncd.service /etc/systemd/system/systemd-timesyncd.service; do
    if [ -f "$root$unit" ]; then enable systemd-timesyncd.service; live systemctl start systemd-timesyncd.service; break; fi
done
mkdir -p "$root/usr/local/libexec" "$root/etc/systemd/system/openxplay-relay.service.d"
install -m 0755 "$bundle/UFI003/install/clock-guard.sh" "$root/usr/local/libexec/openxplay-clock-guard"
cat > "$root/etc/systemd/system/openxplay-relay.service.d/clock.conf" <<'UNIT'
[Service]
ExecStartPre=/usr/local/libexec/openxplay-clock-guard
UNIT
# Generic GPL installer remains the single owner of relay deployment.
# In fake-root mode it also suppresses live systemctl actions.
sh "$bundle/packaging/install.sh" "$bundle/bin/openxplay-relay" "$bundle/bin/oxp-relay" "$bundle/web" "$bundle/admin"
live systemctl daemon-reload
if [ ! -s "$root/var/lib/openxplay/mfi/identity.pk8" ] || [ ! -s "$root/var/lib/openxplay/mfi/certificate.p7b" ]; then
    echo 'Provide your own MFi identity separately as /var/lib/openxplay/mfi/identity.pk8 and certificate.p7b (chmod 0600). No identity is bundled. Then: systemctl start openxplay-relay.service'
else
    live systemctl restart openxplay-relay.service
fi
echo 'UFI003 installation finished. Wi-Fi power-save policy also applies on subsequent connections; the fixed Bluetooth driver loads from the next boot.'
