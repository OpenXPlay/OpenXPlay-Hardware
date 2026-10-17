<p align="center"><b>English</b> · <a href="README-zh.md">简体中文</a></p>

# UFI003

Support files for the UFI003 msm8916 4G USB dongle running the OpenStick Debian 11 image (kernel `5.15.0-handsomekernel+`, aarch64) as an OpenXPlay relay.

## rfcomm

The image's kernel has Bluetooth as a module but lacks RFCOMM, so BlueZ cannot serve the iAP2 profile that wireless CarPlay needs (`RFCOMM server failed … Protocol not supported`). `rfcomm/rfcomm.ko` is RFCOMM from unmodified Linux v5.15, built with the device's kernel config and symbol table.

Install on the device:

```sh
install -D -m 0644 rfcomm.ko /lib/modules/5.15.0-handsomekernel+/extra/rfcomm.ko
depmod -a
echo rfcomm > /etc/modules-load.d/openxplay-rfcomm.conf
modprobe rfcomm
systemctl restart bluetooth
```

Rebuild with `rfcomm/build.sh <linux-5.15.tar.xz>` (needs Docker running linux/arm64 images). `SHA256SUMS` lists the module and the build inputs.

## btqcomsmd

The image's WCNSS Bluetooth driver often leaves `hci0` DOWN with address 00:00:00:00:00:00 after boot: a race in the 5.15 Bluetooth core loses the controller's command credit right after the driver sets the BD address, so the first HCI Reset is never sent. `btqcomsmd/btqcomsmd.ko` is the unmodified v5.15 driver plus upstream commit 5d44ab9e2042 ("Bluetooth: btqcomsmd: Fix command timeout after setting BD address"), built like `rfcomm`. The installer puts it in `updates/`, where it replaces the in-tree module from the next boot:

```sh
install -D -m 0644 btqcomsmd.ko /lib/modules/5.15.0-handsomekernel+/updates/btqcomsmd.ko
depmod -a
```

`btqcomsmd/src/btqcomsmd.c` is the unmodified v5.15 driver source. Rebuild with `btqcomsmd/build.sh <linux-5.15.tar.xz>`; it checks that this source matches the tarball and that the unmodified driver matches the device's (srcversion). `SHA256SUMS` lists the module, the source and the patch.

## bluetooth

`bluetooth/bt-guard.sh`, run by `openxplay-bt-guard.service`, watches the controller, reloads the driver when it fails and writes its state to `/run/openxplay/bluetooth-guard.json`.

On this controller an iPhone pairs only with Secure Connections off (`Simple Pairing Complete: Authentication Failure` otherwise), but a bonded iPhone reconnects only with it on. The relay owns the setting: on, and off only while its pairing window is open. The guard leaves it alone. Earlier releases forced it off with `/etc/systemd/system/bluetooth.service.d/openxplay-no-secure-connections.conf`; the installer removes that drop-in.

## One-step installer

Use the exact bullseye package versions and SHA-256 values already recorded in `install/debs.txt`. On the Mac, assemble local build outputs (POSIX sh and `sha256sum` or `shasum` required):

```sh
sh UFI003/install/make-bundle.sh /tmp/ufi003-bundle /path/to/openxplay-relay /path/to/oxp-relay /path/to/web/dist /path/to/admin/dist /path/to/debs /path/to/OpenXPlay-Relay/rust/packaging
```

Copy `<output>.tar.gz` to the device, unpack it into an empty directory and run as root (copying the directory itself from a Mac can add `._*` files, which the installer rejects):

```sh
sh /path/to/ufi003-bundle/UFI003/install/install-ufi003.sh /path/to/ufi003-bundle
```

Both scripts accept `--dry-run` before their arguments: verification runs without changes. Identical bundle builds are repeatable; different existing output is preserved and rejected. The installer verifies the complete bundle and independent deb/module digests before changes, skips installed package versions, installs RFCOMM, the fixed Bluetooth driver and the Bluetooth guard, removes the Secure Connections drop-in of earlier releases, fixes unbound system dnsmasq, disables Wi-Fi power save and NetworkManager's scan MAC randomisation on `wlan0`, and enables Bluetooth/time sync. Wi-Fi policy takes effect on subsequent connections and is applied live when possible. Relay deployment calls its generic GPL installer, which must include `DESTDIR` support. Bundle checksums provide integrity, not authenticity; use a trusted transfer channel.

The device uses POSIX sh, awk, sha256sum, find, sort, stat and date alongside its system/package tools; Python and OpenSSL are not required. The manifest must list every regular bundle file except itself exactly once, with a 64-digit hex digest and a safe `./relative/path`; `sha256sum -c` verifies the contents.

Before each relay start, the clock guard enables/kicks systemd-timesyncd and returns success within at most three seconds, even if local commands stall. Relay startup never waits for synchronization or Internet access. Generated relay certificates use rcgen defaults valid from 1975 to 4096, so an incorrect device clock does not narrow their validity. Only after `timedatectl` reports `NTPSynchronized=yes`, the guard removes generated TLS files whose filesystem mtime is in the future: `admin-tls.json` individually, or both `receiver-tls/cert.pem` and `key.pem` if either is future-dated. Otherwise it leaves TLS state alone, including incomplete pairs. Relay regenerates removed TLS state; browsers may need to trust it again.

Symlinks and MFi identities are rejected from bundles. Supply your own `identity.pk8` and `certificate.p7b` separately under `/var/lib/openxplay/mfi`, mode `0600`, then start the relay. Existing identities are preserved; installation restarts the relay only when both files exist.

Use an absolute `DESTDIR` and command stubs on `PATH` for fake-root testing: file/package operations are redirected and host runtime actions suppressed. Run `sh UFI003/install/tests/run.sh` for the temporary-root suite.

## License

`bluetooth/` is AGPL-3.0-only like the rest of this repository. Everything in `rfcomm/` and `btqcomsmd/` is part of Linux kernel modules and keeps the kernel's license, [GPL-2.0-only](../LICENSE-GPL-2.0): the modules, their sources (Linux v5.15 `net/bluetooth/rfcomm`; for `btqcomsmd`, Linux v5.15 `drivers/bluetooth/btqcomsmd.c` with the included patch), the device's kernel config and `Module.symvers`, and the `build.sh` scripts that control the modules' compilation. The complete kernel source is `linux-5.15.tar.xz` from kernel.org (SHA-256 `57b2cf6991910e3b67a1b3490022e8a0674b6965c74c12da1e99d138d1991ee8`).
