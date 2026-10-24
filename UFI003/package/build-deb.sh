#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-19
#
# Builds openxplay-ufi003_<version>_arm64.deb, the UFI003 device-support package: RFCOMM and the
# fixed WCNSS Bluetooth driver for the OpenStick kernel, the Bluetooth guard, the host
# profile and the USB dnsmasq policy. It never contains an MFi identity or a relay.
#
# Usage: build-deb.sh [--version VERSION] OUTPUT_DIR
# Needs dpkg-deb; without it the build runs in a debian:bullseye container (Docker). The output is
# byte-identical for identical inputs and SOURCE_DATE_EPOCH (default: the repository's last commit).
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ufi=$(dirname "$here")
repo=$(dirname "$ufi")
krel=5.15.0-handsomekernel+
fail() { echo "Error: $*" >&2; exit 1; }
version=0.2.1
inside=false
while [ "$#" -gt 1 ]; do
    case "$1" in
    --version) version=$2; shift 2 ;;
    --inside) inside=true; shift ;;
    *) break ;;
    esac
done
[ "$#" -eq 1 ] || fail "Usage: $0 [--version VERSION] OUTPUT_DIR"
case "$version" in ''|*[!0-9A-Za-z.+~-]*|[!0-9]*) fail "Invalid Debian version: $version" ;; esac
out=$1
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH=$(git -C "$repo" log -1 --format=%ct 2>/dev/null || echo 1760832000)
fi
case "$SOURCE_DATE_EPOCH" in ''|*[!0-9]*) fail 'SOURCE_DATE_EPOCH must be an integer' ;; esac
export SOURCE_DATE_EPOCH

if ! command -v dpkg-deb >/dev/null 2>&1; then
    "$inside" && fail 'dpkg-deb missing inside the build container'
    command -v docker >/dev/null 2>&1 || fail 'Needs dpkg-deb or Docker'
    mkdir -p "$out"
    # Docker on macOS may not share this directory with its VM, so the inputs go in as a tar stream.
    COPYFILE_DISABLE=1 tar --no-xattrs -cf - -C "$repo" LICENSE LICENSE-GPL-2.0 UFI003 |
        docker run -i --rm --platform linux/arm64 -e SOURCE_DATE_EPOCH debian:bullseye sh -c \
            "mkdir -p /work /out && tar -xf - -C /work &&
             sh /work/UFI003/package/build-deb.sh --inside --version '$version' /out >&2 &&
             tar -cf - -C /out ." |
        tar -xf - -C "$out"
    exit 0
fi

sum() { sha256sum "$1" | cut -d' ' -f1; }
expect() {
    want=$(awk -v n="$2" '$2 == n {print $1}' "$1")
    [ -n "$want" ] && [ "$(sum "$3")" = "$want" ] || fail "Digest mismatch for $3"
}
expect "$ufi/rfcomm/SHA256SUMS" rfcomm.ko "$ufi/rfcomm/rfcomm.ko"
expect "$ufi/btqcomsmd/SHA256SUMS" btqcomsmd.ko "$ufi/btqcomsmd/btqcomsmd.ko"

work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
root=$work/root
umask 022
put() { install -D -m "$1" "$2" "$root$3"; }
put 0644 "$ufi/rfcomm/rfcomm.ko" "/lib/modules/$krel/extra/rfcomm.ko"
put 0644 "$ufi/btqcomsmd/btqcomsmd.ko" "/lib/modules/$krel/updates/btqcomsmd.ko"
put 0755 "$ufi/bluetooth/bt-guard.sh" /usr/lib/openxplay-ufi003/bt-guard
put 0644 "$ufi/host.json" /etc/openxplay/host.json
# Packaged units live in /lib/systemd/system; the guard moves from /usr/local/libexec.
install -d "$root/lib/systemd/system"
sed 's#^ExecStart=/usr/local/libexec/openxplay-bt-guard$#ExecStart=/usr/lib/openxplay-ufi003/bt-guard#' \
    "$ufi/bluetooth/openxplay-bt-guard.service" > "$root/lib/systemd/system/openxplay-bt-guard.service"
grep -qx 'ExecStart=/usr/lib/openxplay-ufi003/bt-guard' "$root/lib/systemd/system/openxplay-bt-guard.service" ||
    fail 'Unexpected ExecStart in openxplay-bt-guard.service'
header() {
    printf '%s\n' "# SPDX-FileCopyrightText: 2026 OpenXPlay.org" "# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0" \
        "# Created by riko chen on 2026-10-20" \
        "# Installed by openxplay-ufi003."
}
install -d "$root/etc/modules-load.d" "$root/etc/dnsmasq.d"
{ header; echo '# The OpenStick kernel has Bluetooth as a module without RFCOMM; iAP2 needs it.'; echo rfcomm; } \
    > "$root/etc/modules-load.d/openxplay-rfcomm.conf"
{
    header
    echo "# If the system dnsmasq is enabled again, bind only its own address so NetworkManager can run"
    echo "# the DHCP server of the relay's hotspot."
    echo bind-interfaces
} > "$root/etc/dnsmasq.d/openxplay-bind.conf"
doc=$root/usr/share/doc/openxplay-ufi003
install -d "$doc"
install -m 0644 "$repo/LICENSE" "$doc/LICENSE"
install -m 0644 "$repo/LICENSE-GPL-2.0" "$doc/LICENSE-GPL-2.0"
kernel_sha=$(awk '/^KERNEL_SHA256=/ {sub(/^KERNEL_SHA256=/, ""); print}' "$ufi/rfcomm/build.sh")
cat > "$doc/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: openxplay-ufi003
Source: https://github.com/OpenXPlay/OpenXPlay-Hardware (UFI003/)

Files: *
Copyright: 2026 OpenXPlay.org
License: LicenseRef-OpenXPlay-Hardware-1.0
 Device scripts, host profile, Bluetooth guard and USB network policy.
 See LICENSE: open source, no commercial use; distributors must publish the source.

Files: lib/modules/$krel/extra/rfcomm.ko lib/modules/$krel/updates/btqcomsmd.ko
Copyright: The Linux kernel authors
License: GPL-2.0-only
 See LICENSE-GPL-2.0. Corresponding source: linux-5.15.tar.xz from kernel.org
 (SHA-256 $kernel_sha) with the kernel config, Module.symvers, the btqcomsmd
 patch (upstream commit 5d44ab9e2042) and the build scripts in
 OpenXPlay-Hardware UFI003/rfcomm and UFI003/btqcomsmd.
EOF

ctl=$root/DEBIAN
install -d "$ctl"
for s in preinst postinst prerm postrm; do install -m 0755 "$here/debian/$s" "$ctl/$s"; done
(cd "$root" && find etc -type f | LC_ALL=C sort | sed 's#^#/#') > "$ctl/conffiles"
size=$(du -sk --exclude=DEBIAN "$root" | cut -f1)
cat > "$ctl/control" <<EOF
Package: openxplay-ufi003
Version: $version
Architecture: arm64
Maintainer: OpenXPlay.org <support@openxplay.org>
Installed-Size: $size
Depends: bluez (>= 5.55), iw, network-manager, kmod, init-system-helpers (>= 1.54)
Recommends: systemd-timesyncd
Section: misc
Priority: optional
Homepage: https://openxplay.org
Description: OpenXPlay device support for the UFI003 (OpenStick msm8916) dongle
 Makes the OpenStick Debian 11 image ($krel) ready for the OpenXPlay
 relay: RFCOMM and the fixed WCNSS Bluetooth driver (both GPL-2.0 kernel
 modules), the Bluetooth controller guard, the UFI003 host profile and the
 USB network dnsmasq fix. No relay, no
 accessory identity.
EOF
(cd "$root" && find . -type f ! -path './DEBIAN/*' | LC_ALL=C sort | sed 's#^\./##' |
    while IFS= read -r f; do md5sum "$f"; done) > "$ctl/md5sums"
chmod 0644 "$ctl/control" "$ctl/conffiles" "$ctl/md5sums"
find "$root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
mkdir -p "$out"
deb=$out/openxplay-ufi003_${version}_arm64.deb
dpkg-deb --root-owner-group -Zxz -b "$root" "$deb" >/dev/null
echo "Built $deb ($(sum "$deb"))"
