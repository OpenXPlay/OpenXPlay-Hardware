#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: GPL-2.0-only
# Created by riko chen on 2026-10-15
#
# Rebuilds rfcomm.ko for the UFI003 kernel "5.15.0-handsomekernel+", which ships Bluetooth as a module
# but no RFCOMM. Builds unmodified Linux v5.15 with the device's own config and Module.symvers inside an
# arm64 ubuntu:20.04 container (GCC 9.4, the compiler that built the device kernel).
#
# Usage: build.sh <path/to/linux-5.15.tar.xz> [output-dir]
#   linux-5.15.tar.xz: https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.15.tar.xz
# Requires Docker able to run linux/arm64 images. Inputs are streamed into the container, so the
# working directory need not be shared with the Docker VM.
set -eu

KERNEL_SHA256=57b2cf6991910e3b67a1b3490022e8a0674b6965c74c12da1e99d138d1991ee8
RELEASE=5.15.0-handsomekernel+

inside() {
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq >/dev/null
	apt-get install -y -qq --no-install-recommends \
		gcc-9 make libc6-dev bc flex bison libssl-dev libelf-dev xz-utils kmod >/dev/null
	ln -sf /usr/bin/gcc-9 /usr/local/bin/gcc
	tar xJf /work/linux-5.15.tar.xz -C /tmp
	cd /tmp/linux-5.15
	cp "/work/config-$RELEASE" .config
	# The device kernel came from a dirty tree, hence the "+" suffix supplied through LOCALVERSION.
	./scripts/config --disable LOCALVERSION_AUTO --module BT_RFCOMM --enable BT_RFCOMM_TTY
	make olddefconfig >/dev/null
	test "$(make -s LOCALVERSION=+ kernelrelease)" = "$RELEASE"
	make -s LOCALVERSION=+ -j"$(nproc)" modules_prepare
	# The device's symbol table lets modpost resolve exports and record the dependency on bluetooth.ko.
	cp /work/Module.symvers .
	make -s LOCALVERSION=+ -j"$(nproc)" M=net/bluetooth/rfcomm modules
	modinfo net/bluetooth/rfcomm/rfcomm.ko | grep -E '^(vermagic|depends|license):'
	mkdir -p /work/out
	cp net/bluetooth/rfcomm/rfcomm.ko /work/out/
}

if [ "${1:-}" = --inside ]; then
	inside
	exit 0
fi

[ $# -ge 1 ] || { echo "usage: $0 <linux-5.15.tar.xz> [output-dir]" >&2; exit 2; }
tarball=$1
here=$(cd "$(dirname "$0")" && pwd)
out=${2:-$here}
if command -v sha256sum >/dev/null; then
	sum=$(sha256sum "$tarball" | cut -d' ' -f1)
else
	sum=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
fi
[ "$sum" = "$KERNEL_SHA256" ] || { echo "unexpected checksum for $tarball: $sum" >&2; exit 1; }
mkdir -p "$out"

tar --no-xattrs -cf - -C "$(dirname "$tarball")" "$(basename "$tarball")" \
	-C "$here" build.sh "config-$RELEASE" Module.symvers |
	docker run -i --rm --platform linux/arm64 ubuntu:20.04 sh -c \
		'mkdir /work && tar -xf - -C /work && [ -f /work/linux-5.15.tar.xz ] ||
		 mv /work/*.tar.xz /work/linux-5.15.tar.xz; sh /work/build.sh --inside >&2 &&
		 tar -cf - -C /work/out rfcomm.ko' |
	tar -xf - -C "$out"
echo "built $out/rfcomm.ko"
