#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
"""Small real Debian archives for offline bundle tests; no dpkg or Docker required."""
import gzip
import hashlib
import io
from pathlib import Path
import sys
import tarfile


def firmware(directory, pins):
    directory.mkdir()
    contents = {"cyfmac43455-sdio.bin": b"test-only Wi-Fi firmware\n",
                "cyfmac43455-sdio.clm_blob": b"test-only CLM\n",
                "LICENCE.cypress": b"test-only licence\n"}
    rows = ["# Test-only linux-firmware commit upstream-path sha256"]
    for name, data in contents.items():
        (directory / name).write_bytes(data)
        upstream = ("LICENSES/" if name == "LICENCE.cypress" else "cypress/") + name
        rows.append(f"{'a' * 40} {upstream} {hashlib.sha256(data).hexdigest()}")
    pins.write_text("\n".join(rows))  # Exercise a final row without a newline.
    return contents


def payload(path):
    data = Path(path).read_bytes()
    assert data[:8] == b"!<arch>\n", path
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        size = int(header[48:58])
        if header[:16].decode().strip().startswith("data.tar"):
            with tarfile.open(fileobj=io.BytesIO(data[offset + 60:offset + 60 + size])) as tar:
                return {entry.name.removeprefix("./"): (tar.extractfile(entry).read(), entry.mode)
                        for entry in tar if entry.isfile()}
        offset += 60 + size + size % 2
    raise AssertionError("No data member: " + str(path))


def deb(path, name, version, arch, source=None):
    fields = {"Package": name, "Version": version, "Architecture": arch,
              "Maintainer": "Test <test@example.invalid>", "Description": "Offline fixture"}
    if source:
        fields["Source"] = source
    data = "".join(f"{key}: {value}\n" for key, value in fields.items()).encode()
    control = io.BytesIO()
    with tarfile.open(fileobj=control, mode="w") as tar:
        entry = tarfile.TarInfo("./control")
        entry.size = len(data)
        tar.addfile(entry, io.BytesIO(data))
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w"):
        pass
    archive = bytearray(b"!<arch>\n")
    for member, value in (("debian-binary", b"2.0\n"),
                          ("control.tar.gz", gzip.compress(control.getvalue(), mtime=0)),
                          ("data.tar.gz", gzip.compress(payload.getvalue(), mtime=0))):
        header = f"{member:<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(value):<10}`\n"
        archive.extend(header.encode() + value + (b"\n" if len(value) % 2 else b""))
    Path(path).write_bytes(archive)


def fields(path):
    data = Path(path).read_bytes()
    assert data[:8] == b"!<arch>\n", path
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        size = int(header[48:58])
        member = header[:16].decode().strip().rstrip("/")
        value = data[offset + 60:offset + 60 + size]
        if member.startswith("control.tar"):
            with tarfile.open(fileobj=io.BytesIO(value)) as tar:
                control = tar.extractfile("./control").read().decode()
            return dict(line.split(": ", 1) for line in control.splitlines() if ": " in line)
        offset += 60 + size + size % 2
    raise AssertionError("No control member: " + str(path))


if __name__ == "__main__":
    version, out = sys.argv[1:]
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    deb(out / f"openxplay-phicomm-n1_{version}_all.deb", "openxplay-phicomm-n1", version, "all")
