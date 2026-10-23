<!--
SPDX-FileCopyrightText: 2026 OpenXPlay.org
SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
Created by riko chen on 2026-10-21
-->
<p align="center"><b>English</b> · <a href="README-zh.md">简体中文</a></p>

# PhicommN1

Support files for the Phicomm N1 TV box (Amlogic S905D) running ophub Armbian (Debian 13, kernel 6.12) from eMMC.

`package/` builds the device package and the offline device bundle that the OpenXPlay Flasher installs over SSH on the network. The package installs the host profile and fixes two board problems: it writes the Ethernet PHY's ID into the boot device tree (again after kernel updates), so the PHY is found on every boot, and it gives wlan0 and the Bluetooth controller addresses derived from the factory Ethernet MAC instead of the ones every N1 shares:

```sh
sh package/build-deb.sh out
sh package/build-bundle.sh --version 0.1.0 /path/to/debs out
```

Builds need `dpkg-deb` on Linux, or a cached `debian:trixie` Docker image. Put the pinned Debian binaries from `install/debs.txt` in `/path/to/debs`; both `arm64` and `all` packages are accepted. The list holds what the device and relay packages need that a fresh ophub Debian 13 server image lacks, so the bundle installs offline. No build or installer downloads packages. `--sources DIR` includes local Debian source archives; `SOURCES.txt` records corresponding source locations.

## License

Everything here is under the [OpenXPlay-Hardware License](../LICENSE) like the rest of this repository.
