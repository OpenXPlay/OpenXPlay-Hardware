<!--
SPDX-FileCopyrightText: 2026 OpenXPlay.org
SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
Created by riko chen on 2026-10-21
-->
<p align="center"><b>English</b> · <a href="README-zh.md">简体中文</a></p>

# PhicommN1

Support files for the Phicomm N1 TV box (Amlogic S905D) running ophub Armbian (Debian 13, kernel 6.12) from eMMC.

`package/` builds the device package (host profile and USB management gadget) and the offline SSH device bundle for the OpenXPlay Flasher:

```sh
sh package/build-deb.sh out
sh package/build-bundle.sh --version 0.1.0 /path/to/debs out
```

Builds need `dpkg-deb` on Linux, or a cached `debian:trixie` Docker image. Put the pinned Debian binaries from `install/debs.txt` in `/path/to/debs`; both `arm64` and `all` packages are accepted. The list holds what the device and relay packages need that a fresh ophub Debian 13 server image lacks, so the bundle installs offline. No build or installer downloads packages. `--sources DIR` includes local Debian source archives; `SOURCES.txt` records corresponding source locations.

## usb-gadget

Turns the USB port next to HDMI into a USB device, so a computer can manage the box over a USB A-to-A cable:

- CDC-NCM Ethernet: the box is `192.168.201.1`; the computer gets an address in `192.168.201.2`-`.9` by DHCP, without router or DNS server, so its own default route stays.
- CDC-ACM serial console: a login prompt on `ttyGS0` (`/dev/cu.usbmodem*` on macOS, a COM port on Windows).

Windows 10/11, macOS and Linux need no driver. While the service runs, that port no longer works as a USB host; the other port still does. The device tree has no switchable VBUS for this port, so assume the box puts 5 V on it: use an A-to-A cable with VBUS cut, or a VBUS-blocking adapter.

The device package installs and enables it. To install it by hand, as root (`dnsmasq-base` provides the DHCP server):

```sh
apt-get install --no-install-recommends dnsmasq-base
install -D -m 0755 usb-gadget.sh /usr/local/libexec/openxplay-usb-gadget
install -m 0644 openxplay-usb-gadget.service openxplay-usb-dhcp.service /etc/systemd/system/
install -D -m 0644 serial-getty-ttyGS0.conf /etc/systemd/system/serial-getty@ttyGS0.service.d/openxplay-usb-gadget.conf
systemctl daemon-reload
systemctl enable --now openxplay-usb-gadget.service
```

`systemctl disable --now openxplay-usb-gadget.service` returns the port to host mode.

## License

Everything here is under the [OpenXPlay-Hardware License](../LICENSE) like the rest of this repository.
