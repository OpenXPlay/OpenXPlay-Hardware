#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
# Builds openxplay-phicomm-n1_<version>_all.deb. No relay or kernel binaries.
# Usage: build-deb.sh [--version VERSION] --firmware DIR OUTPUT_DIR
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
n1=$(dirname "$here")
repo=$(dirname "$n1")
fail() { echo "Error: $*" >&2; exit 1; }
version=0.1.0
firmware=
inside=false
while [ "$#" -gt 1 ]; do
    case "$1" in
    --version) version=$2; shift 2 ;;
    --firmware) firmware=$2; shift 2 ;;
    --inside) inside=true; shift ;;
    *) break ;;
    esac
done
[ "$#" -eq 1 ] && [ -n "$firmware" ] || fail "Usage: $0 [--version VERSION] --firmware DIR OUTPUT_DIR"
case "$version" in ''|*[!0-9A-Za-z.+~-]*|[!0-9]*) fail "Invalid Debian version: $version" ;; esac
out=$1
firmware=$(CDPATH= cd -- "$firmware" && pwd) || fail 'Missing firmware directory'
sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
# Test-only fixture pins replace the inputs, never the checks. Production uses the committed list.
firmware_pins=${OPENXPLAY_N1_TEST_FIRMWARE_PINS:-$n1/install/firmware.txt}
seen=' '
while read -r commit path digest extra || [ -n "$commit" ]; do
    case "$commit" in ''|'#'*) continue ;; esac
    [ -z "$extra" ] && printf '%s\n' "$commit" | LC_ALL=C grep -Eq '^[0-9a-fA-F]{40}$' &&
        printf '%s\n' "$path" | LC_ALL=C grep -Eq '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' &&
        printf '%s\n' "$digest" | LC_ALL=C grep -Eq '^[0-9a-fA-F]{64}$' || fail "Invalid firmware.txt row: $commit"
    case "/$path/" in *..*|*/./*) fail "Invalid firmware path: $path" ;; esac
    base=${path##*/}
    case "$base" in cyfmac43455-sdio.bin|cyfmac43455-sdio.clm_blob|LICENCE.cypress) ;;
        *) fail "Unexpected pinned firmware file: $base" ;;
    esac
    case "$seen" in *" $base "*) fail "Duplicate firmware basename: $base" ;; esac
    seen="$seen$base "
    [ ! -L "$firmware/$base" ] || fail "Symlink firmware input: $base"
    [ -f "$firmware/$base" ] || fail "Missing regular firmware file: $base"
    [ "$(sum "$firmware/$base")" = "$(printf '%s' "$digest" | tr 'A-F' 'a-f')" ] || fail "SHA-256 mismatch: $base"
done < "$firmware_pins"
for base in cyfmac43455-sdio.bin cyfmac43455-sdio.clm_blob LICENCE.cypress; do
    case "$seen" in *" $base "*) ;; *) fail "Missing firmware pin: $base" ;; esac
done
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
    mkdir "$stream/firmware"
    for base in cyfmac43455-sdio.bin cyfmac43455-sdio.clm_blob LICENCE.cypress; do
        cp -f "$firmware/$base" "$stream/firmware/$base"
    done
    if [ -n "${OPENXPLAY_N1_TEST_FIRMWARE_PINS:-}" ]; then
        cp -f "$firmware_pins" "$stream/firmware/test-pins.txt"
        export OPENXPLAY_N1_TEST_FIRMWARE_PINS=/work/firmware/test-pins.txt
    fi
    COPYFILE_DISABLE=1 tar --no-xattrs -cf "$stream/input.tar" -C "$repo" LICENSE PhicommN1
    COPYFILE_DISABLE=1 tar --no-xattrs -rf "$stream/input.tar" -C "$stream" firmware
    if ! docker run -i --rm --pull=never --network=none --platform linux/arm64 -e SOURCE_DATE_EPOCH \
            -e OPENXPLAY_N1_TEST_FIRMWARE_PINS \
            debian:trixie sh -c \
            "mkdir -p /work /out && tar -xf - -C /work &&
             sh /work/PhicommN1/package/build-deb.sh --inside --version '$version' --firmware /work/firmware /out >&2 &&
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
put 0755 "$n1/bluetooth/bt-addr.sh" /usr/lib/openxplay-phicomm-n1/bt-addr
put 0644 "$n1/bluetooth/openxplay-n1-bt-addr.service" /lib/systemd/system/openxplay-n1-bt-addr.service
for unit in openxplay-n1-phy-id.service openxplay-n1-phy-id.path; do
    put 0644 "$n1/ethernet/$unit" "/lib/systemd/system/$unit"
done
put 0644 "$n1/wifi/70-openxplay-n1-wifi-mac.rules" /lib/udev/rules.d/70-openxplay-n1-wifi-mac.rules
doc=$root/usr/share/doc/openxplay-phicomm-n1
install -d "$doc" "$root/DEBIAN"
install -m 0644 "$repo/LICENSE" "$doc/LICENSE"
put 0644 "$firmware/cyfmac43455-sdio.bin" /usr/lib/firmware/updates/brcm/brcmfmac43455-sdio.phicomm,n1.bin
put 0644 "$firmware/cyfmac43455-sdio.clm_blob" /usr/lib/firmware/updates/brcm/brcmfmac43455-sdio.phicomm,n1.clm_blob
install -m 0644 "$firmware/LICENCE.cypress" "$doc/LICENCE.cypress"
cat > "$doc/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: openxplay-phicomm-n1
Source: https://github.com/OpenXPlay/OpenXPlay-Hardware (PhicommN1/)

Files: *
Copyright: 2026 OpenXPlay.org
License: LicenseRef-OpenXPlay-Hardware-1.0
 See LICENSE: no commercial use; distributors must publish the complete source.

Files: usr/lib/firmware/updates/brcm/*
Copyright: Cypress Semiconductor Corporation, an Infineon Technologies company
License: LicenseRef-LICENCE.cypress
Comment: Unmodified linux-firmware cypress/cyfmac43455-sdio.bin and
 cypress/cyfmac43455-sdio.clm_blob, version 7.45.286, from commit
 a137a09be163c5e3fc6e96ba3bfb9eb328394c34. See LICENCE.cypress for the full text.
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
 Phicomm N1 host profile, Ethernet PHY and Wi-Fi address fixes, newer Cypress
 Wi-Fi firmware, and offline dependencies for ophub Armbian, Debian 13 arm64.
 No relay or accessory identity.
EOF
(cd "$root" && find . -type f ! -path './DEBIAN/*' | LC_ALL=C sort | sed 's#^\./##' |
    while IFS= read -r f; do md5sum "$f"; done) > "$ctl/md5sums"
chmod 0644 "$ctl/control" "$ctl/conffiles" "$ctl/md5sums"
find "$root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
mkdir -p "$out"
deb=$out/openxplay-phicomm-n1_${version}_all.deb
dpkg-deb --root-owner-group -Zxz -b "$root" "$deb" >/dev/null
echo "Built $deb ($(sha256sum "$deb" | cut -d' ' -f1))"
