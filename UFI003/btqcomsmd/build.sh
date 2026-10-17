#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: GPL-2.0-only
# Created by riko chen on 2026-10-16
#
# Rebuilds btqcomsmd.ko (WCNSS Bluetooth over SMD) for the UFI003 kernel "5.15.0-handsomekernel+" with
# Linux commit 5d44ab9e2042 ("Bluetooth: btqcomsmd: Fix command timeout after setting BD address", v6.3),
# which the device kernel lacks. Without it the controller often fails to come up at boot.
# First builds the unmodified v5.15 driver and requires its srcversion to equal the device's own module,
# proving the device runs unmodified v5.15 btqcomsmd source; then applies the patch and builds it.
# Uses the device's config and Module.symvers from ../rfcomm and the same arm64 ubuntu:20.04 container
# (GCC 9.4, the compiler that built the device kernel).
#
# Usage: build.sh <path/to/linux-5.15.tar.xz> [output-dir]
#   linux-5.15.tar.xz: https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.15.tar.xz
# Requires Docker able to run linux/arm64 images. Inputs are streamed into the container, so the
# working directory need not be shared with the Docker VM.
set -eu

KERNEL_SHA256=57b2cf6991910e3b67a1b3490022e8a0674b6965c74c12da1e99d138d1991ee8
RELEASE=5.15.0-handsomekernel+
# srcversion of /lib/modules/5.15.0-handsomekernel+/kernel/drivers/bluetooth/btqcomsmd.ko on the device.
DEVICE_SRCVERSION=AA930C3888ABD368BA2CE81
PATCH=btqcomsmd-fix-command-timeout-after-setting-bd-address.patch

inside() {
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq >/dev/null
	apt-get install -y -qq --no-install-recommends \
		gcc-9 make libc6-dev bc flex bison libssl-dev libelf-dev xz-utils kmod patch >/dev/null
	ln -sf /usr/bin/gcc-9 /usr/local/bin/gcc
	tar xJf /work/linux-5.15.tar.xz -C /tmp
	cd /tmp/linux-5.15
	# src/btqcomsmd.c in this repository is the unmodified v5.15 driver source.
	cmp drivers/bluetooth/btqcomsmd.c /work/src/btqcomsmd.c
	cp "/work/config-$RELEASE" .config
	# The device kernel came from a dirty tree, hence the "+" suffix supplied through LOCALVERSION.
	./scripts/config --disable LOCALVERSION_AUTO
	make olddefconfig >/dev/null
	test "$(make -s LOCALVERSION=+ kernelrelease)" = "$RELEASE"
	grep -qx 'CONFIG_BT_QCOMSMD=m' .config
	make -s LOCALVERSION=+ -j"$(nproc)" modules_prepare
	# The device's symbol table lets modpost resolve exports and record the module dependencies.
	cp /work/Module.symvers .
	make -s LOCALVERSION=+ -j"$(nproc)" M=drivers/bluetooth modules
	stock=$(modinfo -F srcversion drivers/bluetooth/btqcomsmd.ko)
	echo "unmodified v5.15 btqcomsmd srcversion: $stock"
	test "$stock" = "$DEVICE_SRCVERSION"
	patch -p1 < "/work/$PATCH"
	make -s LOCALVERSION=+ -j"$(nproc)" M=drivers/bluetooth modules
	modinfo drivers/bluetooth/btqcomsmd.ko | grep -E '^(vermagic|depends|license|srcversion):'
	mkdir -p /work/out
	cp drivers/bluetooth/btqcomsmd.ko /work/out/
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
	-C "$here" build.sh "$PATCH" src/btqcomsmd.c -C "$here/../rfcomm" "config-$RELEASE" Module.symvers |
	docker run -i --rm --platform linux/arm64 ubuntu:20.04 sh -c \
		'mkdir /work && tar -xf - -C /work && [ -f /work/linux-5.15.tar.xz ] ||
		 mv /work/*.tar.xz /work/linux-5.15.tar.xz; sh /work/build.sh --inside >&2 &&
		 tar -cf - -C /work/out btqcomsmd.ko' |
	tar -xf - -C "$out"
echo "built $out/btqcomsmd.ko"
