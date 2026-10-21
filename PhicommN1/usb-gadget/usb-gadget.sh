#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
# Turns the OTG port (the USB port next to HDMI) into a USB device for management:
# CDC-NCM Ethernet (usb0, this side 192.168.201.1/24) and a CDC-ACM serial console (ttyGS0).
# NCM rather than ECM or RNDIS: Windows 10/11, macOS and Linux all ship a class driver for it.
# Usage: usb-gadget.sh start|stop
set -eu
export LC_ALL=C

gadget=/sys/kernel/config/usb_gadget/openxplay
role_switch=${OPENXPLAY_USB_ROLE_SWITCH:-/sys/class/usb_role/d0078080.usb-role-switch/role}
udc=${OPENXPLAY_USB_UDC:-c9100000.usb}
address=${OPENXPLAY_USB_ADDRESS:-192.168.201.1/24}

wait_for() {
    i=0
    while [ ! -e "$1" ]; do
        i=$((i + 1))
        [ "$i" -le 50 ] || { echo "usb-gadget: $1 did not appear" >&2; exit 1; }
        sleep 0.2
    done
}

# Locally administered MAC built from eth0's last five bytes, so it is stable and unique per box.
mac_from_eth0() {
    echo "$1:$(cut -d: -f2-6 /sys/class/net/eth0/address)"
}

start() {
    modprobe libcomposite
    wait_for /sys/kernel/config/usb_gadget
    wait_for "$role_switch"
    wait_for "/sys/class/udc/$udc"
    [ ! -d "$gadget" ] || stop
    echo device > "$role_switch"

    mkdir "$gadget"
    cd "$gadget"
    echo 0x1d6b > idVendor # Linux Foundation
    echo 0x0104 > idProduct # Multifunction Composite Gadget
    echo 0x0100 > bcdDevice
    echo 0x0200 > bcdUSB
    # Miscellaneous class with interface association, so hosts bind each function's class driver.
    echo 0xef > bDeviceClass
    echo 0x02 > bDeviceSubClass
    echo 0x01 > bDeviceProtocol
    mkdir strings/0x409
    tr -d : < /sys/class/net/eth0/address > strings/0x409/serialnumber
    echo OpenXPlay > strings/0x409/manufacturer
    echo "Phicomm N1" > strings/0x409/product

    mkdir functions/ncm.usb0
    mac_from_eth0 02 > functions/ncm.usb0/dev_addr
    mac_from_eth0 06 > functions/ncm.usb0/host_addr
    mkdir functions/acm.GS0

    mkdir -p configs/c.1/strings/0x409
    echo "NCM + ACM" > configs/c.1/strings/0x409/configuration
    echo 100 > configs/c.1/MaxPower
    ln -s "$gadget/functions/ncm.usb0" configs/c.1/
    ln -s "$gadget/functions/acm.GS0" configs/c.1/
    echo "$udc" > UDC

    # NetworkManager leaves USB gadget interfaces unmanaged, so the address is set here.
    ip address replace "$address" dev usb0
    ip link set usb0 up
}

tty_holders() {
    for fd in /proc/[0-9]*/fd/*; do
        [ "$(readlink "$fd" 2>/dev/null)" = /dev/ttyGS0 ] && echo "${fd#/proc/}"
    done | cut -d/ -f1 | grep -vx 1 | sort -u
}

# Removing the ACM function blocks uninterruptibly in the kernel until /dev/ttyGS0 is closed,
# so close it first and refuse to remove the function while anything still holds it.
release_tty() {
    for signal in HUP TERM KILL; do
        pids=$(tty_holders)
        [ -n "$pids" ] || return 0
        kill -s "$signal" $pids 2>/dev/null || true
        sleep 1
    done
    [ -z "$(tty_holders)" ]
}

# Removes whatever functions the gadget has, so a gadget left by an older version also goes.
stop() {
    if [ -d "$gadget" ]; then
        cd "$gadget"
        echo "" > UDC 2>/dev/null || true
        for link in configs/*/*; do
            [ ! -L "$link" ] || rm -f "$link"
        done
        for dir in configs/*/strings/0x409 configs/* strings/0x409; do
            [ ! -d "$dir" ] || rmdir "$dir"
        done
        for function in functions/*; do
            [ -d "$function" ] || continue
            case "$function" in
                functions/acm.*) release_tty || { echo "usb-gadget: /dev/ttyGS0 is still open, gadget left in place" >&2; exit 1; } ;;
            esac
            rmdir "$function"
        done
        cd /
        rmdir "$gadget"
    fi
    echo host > "$role_switch"
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
