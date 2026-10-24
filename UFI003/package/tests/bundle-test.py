#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-24
"""Build real compressed Debian fixtures offline; never install or contact a device."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

package = Path(__file__).resolve().parents[1]
checks = 0


def run(args, *, env=None, ok=True, error=None):
    global checks
    result = subprocess.run(list(map(str, args)), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    assert (result.returncode == 0) == ok, result.stdout
    if error:
        assert error in result.stdout, result.stdout
    checks += 1
    return result.stdout


with tempfile.TemporaryDirectory(prefix="ufi003 bundle ") as tmp:
    root = Path(tmp)
    copied = root / "repo/UFI003/package"
    copied.mkdir(parents=True)
    for file in ("build-bundle.sh", "install-device.sh"):
        (copied / file).write_text((package / file).read_text())
    (copied / "build-deb.sh").write_text('''#!/bin/sh
set -eu
[ "$1" = --version ]
cp "$TEST_DEVICE_DEB" "$3/openxplay-ufi003_${2}_arm64.deb"
''')
    pins = copied.parent / "install/debs.txt"
    pins.parent.mkdir()
    inputs = root / "inputs"
    inputs.mkdir()
    device = root / "device.deb"
    control = root / "control/DEBIAN"
    control.mkdir(parents=True)

    def make_deb(path, name, version, arch, compression="xz"):
        (control / "control").write_text(
            f"Package: {name}\nVersion: {version}\nArchitecture: {arch}\n"
            "Maintainer: Test <test@example.invalid>\nDescription: Offline fixture\n")
        run(["dpkg-deb", "--root-owner-group", "-Z" + compression, "-b", control.parent, path])

    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    bluez = inputs / "bluez_5.55-3.1+deb11u1_arm64.deb"
    alsa = inputs / "libasound2-data_1.2.4-1.1_all.deb"
    make_deb(bluez, "bluez", "5.55-3.1+deb11u1", "arm64", "xz")
    make_deb(alsa, "libasound2-data", "1.2.4-1.1", "all", "gzip")
    make_deb(device, "openxplay-ufi003", "0.2.1", "arm64", "xz")

    def update_pins():
        pins.write_text(f"bluez 5.55-3.1+deb11u1 {digest(bluez)}\n"
                        f"libasound2-data 1.2.4-1.1 {digest(alsa)}\n")

    update_pins()
    env = dict(os.environ, SOURCE_DATE_EPOCH="1792800000", TEST_DEVICE_DEB=str(device), LC_ALL="C")
    # A PATH without dpkg-deb exercises the ar/tar fallback with GNU tar and both xz/gzip.
    fallback = root / "fallback-bin"
    fallback.mkdir()
    for command in ("ar", "awk", "basename", "chmod", "cp", "cut", "date", "dirname", "find",
                    "grep", "gzip", "mkdir", "mktemp", "mv", "rm", "sed", "sha256sum", "sh",
                    "sort", "tar", "touch", "wc", "xz"):
        (fallback / command).symlink_to(shutil.which(command))
    expected = {"bluez": "5.55-3.1+deb11u1", "libasound2-data": "1.2.4-1.1", "openxplay-ufi003": "0.2.1"}
    for mode, build_env in (("native", env), ("fallback", {**env, "PATH": str(fallback)})):
        out = root / mode
        command = ["/bin/sh", copied / "build-bundle.sh", inputs, out]
        run(command, env=build_env)
        bundle = out / "openxplay-ufi003-device-0.2.1.tar.gz"
        with tarfile.open(bundle) as archive:
            manifest = json.load(archive.extractfile("openxplay-ufi003-device-0.2.1/manifest.json"))
        assert {item["name"]: item["version"] for item in manifest["packages"]} == expected, manifest
        for item in manifest["packages"]:
            assert digest(out / "openxplay-ufi003-device-0.2.1" / item["file"]) == item["sha256"]
        # The release guard checks every manifest entry against actual .deb control metadata.
        run(["sh", "-eu", "-c", '. "$1"; ufi003_check_bundle 0.2.1 "$2"',
             "bundle-test", package / "release-common.sh", out])
        before = digest(bundle)
        run(command, env=build_env)
        assert digest(bundle) == before, "Identical bundle builds must be reproducible"
        make_deb(bluez, "wrong-package", "5.55-3.1+deb11u1", "arm64")
        update_pins()
        run(command, env=build_env, ok=False, error="Control metadata does not match pin")
        assert digest(bundle) == before, "Failed builds must preserve the previous archive"
        make_deb(bluez, "bluez", "5.55-3.1+deb11u1", "arm64")
        update_pins()

    # Simulate a parser that silently emits empty fields; valid checksums must not allow release.
    empty = root / "empty-bin"
    empty.mkdir()
    parser = empty / "dpkg-deb"
    parser.write_text("#!/bin/sh\nexit 0\n")
    parser.chmod(0o755)
    run(["sh", copied / "build-bundle.sh", inputs, root / "empty"],
        env={**env, "PATH": str(empty) + os.pathsep + env["PATH"]}, ok=False,
        error="Control metadata does not match pin")
    # Extraction failures must propagate instead of being swallowed by a final awk command.
    (fallback / "tar").unlink()
    (fallback / "tar").write_text("#!/bin/sh\nexit 1\n")
    (fallback / "tar").chmod(0o755)
    run(["/bin/sh", copied / "build-bundle.sh", inputs, root / "broken-tar"],
        env={**env, "PATH": str(fallback)}, ok=False, error="Cannot extract Debian control metadata")

print(f"PASS {checks} offline bundle cases")
