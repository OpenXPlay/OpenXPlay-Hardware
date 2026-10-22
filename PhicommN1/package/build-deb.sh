#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
# Builds openxplay-phicomm-n1_<version>_all.deb. No relay or kernel binaries.
# Usage: build-deb.sh [--version VERSION] OUTPUT_DIR
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
n1=$(dirname "$here")
repo=$(dirname "$n1")
fail() { echo "Error: $*" >&2; exit 1; }
version=0.1.0
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
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$repo" log -1 --format=%ct 2>/dev/null || echo 1792540800)}
case "$SOURCE_DATE_EPOCH" in ''|*[!0-9]*) fail 'SOURCE_DATE_EPOCH must be an integer' ;; esac
export SOURCE_DATE_EPOCH
if ! command -v dpkg-deb >/dev/null 2>&1; then
    "$inside" && fail 'dpkg-deb missing inside the build container'
    command -v docker >/dev/null 2>&1 || fail 'Needs dpkg-deb or a cached debian:trixie Docker image'
    mkdir -p "$out"
    # Tar streams also work when Docker cannot mount the worktree (for example on macOS).
    stream=$(mktemp -d)
    trap 'rm -rf "$stream"' 0
    trap 'exit 1' HUP INT TERM
    COPYFILE_DISABLE=1 tar --no-xattrs -cf "$stream/input.tar" -C "$repo" LICENSE PhicommN1
    if ! docker run -i --rm --pull=never --network=none --platform linux/arm64 -e SOURCE_DATE_EPOCH \
            debian:trixie sh -c \
            "mkdir -p /work /out && tar -xf - -C /work &&
             sh /work/PhicommN1/package/build-deb.sh --inside --version '$version' /out >&2 &&
             tar -cf - -C /out ." < "$stream/input.tar" > "$stream/output.tar"; then
        fail 'Container build failed'
    fi
    tar -xf "$stream/output.tar" -C "$out"
    [ -f "$out/openxplay-phicomm-n1_${version}_all.deb" ] || fail 'Container build failed'
    exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
root=$work/root
umask 022
put() { install -D -m "$1" "$2" "$root$3"; }
put 0644 "$n1/host.json" /etc/openxplay/host.json
put 0755 "$n1/ethernet/phy-id.sh" /usr/lib/openxplay-phicomm-n1/phy-id
put 0755 "$n1/wifi/wifi-mac.sh" /usr/lib/openxplay-phicomm-n1/wifi-mac
for unit in openxplay-n1-phy-id.service openxplay-n1-phy-id.path; do
    put 0644 "$n1/ethernet/$unit" "/lib/systemd/system/$unit"
done
put 0644 "$n1/wifi/70-openxplay-n1-wifi-mac.rules" /lib/udev/rules.d/70-openxplay-n1-wifi-mac.rules
doc=$root/usr/share/doc/openxplay-phicomm-n1
install -d "$doc" "$root/DEBIAN"
install -m 0644 "$repo/LICENSE" "$doc/LICENSE"
cat > "$doc/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: openxplay-phicomm-n1
Source: https://github.com/OpenXPlay/OpenXPlay-Hardware (PhicommN1/)

Files: *
Copyright: 2026 OpenXPlay.org
License: LicenseRef-OpenXPlay-Hardware-1.0
 See LICENSE: no commercial use; distributors must publish the complete source.
EOF
ctl=$root/DEBIAN
for s in preinst postinst prerm postrm; do install -m 0755 "$here/debian/$s" "$ctl/$s"; done
echo /etc/openxplay/host.json > "$ctl/conffiles"
size=$(du -sk --exclude=DEBIAN "$root" | cut -f1)
cat > "$ctl/control" <<EOF
Package: openxplay-phicomm-n1
Version: $version
Architecture: all
Maintainer: OpenXPlay.org <support@openxplay.org>
Installed-Size: $size
Depends: bluez, iw, network-manager, dnsmasq-base, kmod, init-system-helpers (>= 1.54), device-tree-compiler, iproute2
Section: misc
Priority: optional
Homepage: https://openxplay.org
Description: OpenXPlay device support for the Phicomm N1 TV box
 Phicomm N1 host profile, Ethernet PHY and Wi-Fi address fixes, and offline
 dependencies for ophub Armbian, Debian 13 arm64. No relay or accessory identity.
EOF
(cd "$root" && find . -type f ! -path './DEBIAN/*' | LC_ALL=C sort | sed 's#^\./##' |
    while IFS= read -r f; do md5sum "$f"; done) > "$ctl/md5sums"
chmod 0644 "$ctl/control" "$ctl/conffiles" "$ctl/md5sums"
find "$root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
mkdir -p "$out"
deb=$out/openxplay-phicomm-n1_${version}_all.deb
dpkg-deb --root-owner-group -Zxz -b "$root" "$deb" >/dev/null
echo "Built $deb ($(sha256sum "$deb" | cut -d' ' -f1))"
