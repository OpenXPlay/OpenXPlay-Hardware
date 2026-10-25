<!--
SPDX-FileCopyrightText: 2026 OpenXPlay.org
SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
Created by riko chen on 2026-10-21
-->
<p align="center"><b>English</b> · <a href="README-zh.md">简体中文</a></p>

# PhicommN1

Support files for the Phicomm N1 TV box (Amlogic S905D) running ophub Armbian (Debian 13, kernel 6.12) from eMMC.

`package/` builds the device package and the offline device bundle that the OpenXPlay Flasher installs over SSH on the network. The package installs the host profile, writes the Ethernet PHY's ID into the boot device tree (again after kernel updates), and gives wlan0 and the Bluetooth controller addresses derived from the factory Ethernet MAC. It also installs newer Cypress Wi-Fi firmware for the onboard BCM43455 so wlan0 can use 5 GHz channels 36-48 under the CN regulatory domain.

```sh
sh package/build-deb.sh --firmware /path/to/firmware out
sh package/build-bundle.sh --version 0.1.0 --firmware /path/to/firmware /path/to/debs out
```

Builds need `dpkg-deb` on Linux, or a cached `debian:trixie` Docker image. Put the pinned Debian binaries from `install/debs.txt` in `/path/to/debs`; both `arm64` and `all` packages are accepted. Put the unmodified firmware and licence files pinned in `install/firmware.txt` in `/path/to/firmware`, using their upstream basenames. The Debian list holds what the device and relay packages need that a fresh ophub Debian 13 server image lacks, so the bundle installs offline. Builds verify all firmware hashes; no build or installer downloads files. `--sources DIR` includes local Debian source archives; `SOURCES.txt` records source locations and firmware provenance.

## License

Files here use the [OpenXPlay-Hardware License](../LICENSE). The packaged Cypress firmware uses LICENCE.cypress, included in the device package.
