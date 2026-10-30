<!--
SPDX-FileCopyrightText: 2026 OpenXPlay.org
SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
Created by riko chen on 2026-10-21
-->
<p align="center"><b>English</b> · <a href="README-zh.md">简体中文</a></p>

# PhicommN1

Support files for the Phicomm N1 TV box (Amlogic S905D) running ophub Armbian (Debian 13, kernel 6.12) from eMMC.

## Install

The step-by-step guide, from writing Armbian to opening CarPlay, is at [openxplay.org/en/phicomm-n1](https://openxplay.org/en/phicomm-n1) (Chinese: [openxplay.org/phicomm-n1](https://openxplay.org/phicomm-n1)).

Releases are tagged `phicomm-n1-device-vX.Y.Z[-beta.N]` and carry the bundle `openxplay-phicomm-n1-device-<version>.tar.gz` with `SHA256SUMS`. On the N1, unpack the bundle and run its installer as root; it needs no network. The unpacked folder uses the Debian version, for example `0.1.1~beta.1`:

```sh
sudo sh openxplay-phicomm-n1-device-<version>/install-device.sh --dry-run   # checks only
sudo sh openxplay-phicomm-n1-device-<version>/install-device.sh
sudo reboot
sudo sh openxplay-phicomm-n1-device-<version>/install-device.sh --verify
```

The installer refuses anything but Debian 13 arm64 with the device-tree model `Phicomm N1` (exit 2), checks every file against `SHA256SUMS`, then installs the pinned Debian packages in order and `openxplay-phicomm-n1` last, skipping any package already at that version or newer. Its last line is `OXP-STAGE device preflight-ok`, `ok … reboot=required` or `verified`, with the version. Install the relay afterwards from its `.deb` (`OpenXPlay/OpenXPlay-Relay`, tags `linux-v…`); the bundle already holds its dependencies.

`apt-get remove openxplay-phicomm-n1` puts the stock device tree back, and the Wi-Fi and Bluetooth addresses return to the shared defaults at the next boot; `purge` also deletes `/var/lib/openxplay-phicomm-n1`.

## Build

`package/` builds the device package and the offline device bundle, which the installer above and the OpenXPlay Flasher (over SSH on the network) install. The package installs the host profile, writes the Ethernet PHY's ID into the boot device tree (again after kernel updates), and gives wlan0 and the Bluetooth controller addresses derived from the factory Ethernet MAC. It also installs newer Cypress Wi-Fi firmware for the onboard BCM43455 so wlan0 can use 5 GHz channels 36-48 under the CN regulatory domain.

```sh
sh package/build-deb.sh --firmware /path/to/firmware out
sh package/build-bundle.sh --version 0.1.0 --firmware /path/to/firmware /path/to/debs out
```

Builds need `dpkg-deb` on Linux, or a cached `debian:trixie` Docker image. Put the pinned Debian binaries from `install/debs.txt` in `/path/to/debs`; both `arm64` and `all` packages are accepted. Put the unmodified firmware and licence files pinned in `install/firmware.txt` in `/path/to/firmware`, using their upstream basenames. The Debian list holds what the device and relay packages need that a fresh ophub Debian 13 server image lacks, so the bundle installs offline. Builds verify all firmware hashes; no build or installer downloads files. `--sources DIR` includes local Debian source archives; `SOURCES.txt` records source locations and firmware provenance.

## License

Files here use the [OpenXPlay-Hardware License](../LICENSE). The packaged Cypress firmware uses LICENCE.cypress, included in the device package.
