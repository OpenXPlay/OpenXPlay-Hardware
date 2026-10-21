#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
"""Offline release checks: versions, archive integrity, identity paths and pinned downloads."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

helper = Path(__file__).resolve().parents[1] / "release-common.sh"
checks = 0


def run(command, *args, ok=True, error=None, env=None):
    global checks
    result = subprocess.run(
        ["sh", "-eu", "-c", '. "$1"; shift; ' + command, "release-test", str(helper), *map(str, args)],
        env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30,
    )
    assert (result.returncode == 0) == ok, result.stdout
    if not ok:
        assert "::error::" in result.stdout, result.stdout
    if error:
        assert error in result.stdout, result.stdout
    checks += 1
    return result.stdout


sha = "0123456789abcdef0123456789abcdef01234567"
version_command = 'ufi003_release_version "$@"; printf "%s %s %s\\n" "$RELEASE_VERSION" "$DEBVERSION" "$PRERELEASE"'
for version, debversion, prerelease in (
    ("0.2.0", "0.2.0", "false"),
    ("10.20.30", "10.20.30", "false"),
    ("0.2.0-beta.1", "0.2.0~beta.1", "true"),
    ("1.2.3-0", "1.2.3~0", "true"),
    ("1.2.3-rc-1.2", "1.2.3~rc-1.2", "true"),
):
    assert run(version_command, "push", "refs/tags/ufi003-device-v" + version, sha).strip() == \
        f"{version} {debversion} {prerelease}"
for version in (
    "", "1", "1.2", "1.2.3.4", "v1.2.3", "01.2.3", "1.02.3", "1.2.03", "1.2.3-",
    "1.2.3-01", "1.2.3-beta..1", "1.2.3-beta_1", "1.2.3+build.1", "1.2.3/escape", "1.2.3 rc1",
    "1.2.3\nextra",
):
    run(version_command, "push", "refs/tags/ufi003-device-v" + version, sha, ok=False)
for ref in ("refs/heads/ufi003-device-v1.2.3", "refs/tags/v1.2.3"):
    run(version_command, "push", ref, sha, ok=False)
assert run(version_command, "workflow_dispatch", "refs/heads/device-release", sha).strip() == \
    "0.0.0~dev.0123456 0.0.0~dev.0123456 false"
run(version_command, "workflow_dispatch", "refs/heads/main", "bad-sha", ok=False)
run(version_command, "pull_request", "refs/heads/main", sha, ok=False)

with tempfile.TemporaryDirectory(prefix="ufi003 release ") as tmp:
    root = Path(tmp)
    version = "0.2.0~beta.1"
    name = "openxplay-ufi003-device-" + version
    bundle = root / (name + ".tar.gz")
    manifest = {"schema": "org.openxplay.flash-stage/1", "stage": "device", "device": "ufi003", "version": version}

    def archive(changed_manifest=None, corrupt=False, extra=(), raw_manifest=None):
        files = {
            "manifest.json": raw_manifest if raw_manifest is not None else json.dumps(changed_manifest or manifest).encode(),
            "SOURCES.txt": b"fixture sources\n",
        }
        sums = "".join(hashlib.sha256(data).hexdigest() + "  " + path + "\n" for path, data in files.items())
        files["SHA256SUMS"] = sums.encode()
        if corrupt:
            files["SOURCES.txt"] += b"corrupt\n"
        with tarfile.open(bundle, "w:gz") as tar:
            directory = tarfile.TarInfo(name + "/")
            directory.type = tarfile.DIRTYPE
            directory.mode = 0o755
            tar.addfile(directory)
            for path, data in files.items():
                entry = tarfile.TarInfo(name + "/" + path)
                entry.size = len(data)
                tar.addfile(entry, io.BytesIO(data))
            for path in extra:
                tar.addfile(tarfile.TarInfo(path), io.BytesIO(b""))

    check_command = 'ufi003_check_bundle "$@"'
    archive()
    run(check_command, version, root)
    run(check_command, "9.9.9", root, ok=False, error="Missing expected bundle")
    archive(corrupt=True)
    run(check_command, version, root, ok=False, error="SHA256SUMS check failed")
    for key in manifest:
        archive(changed_manifest={**manifest, key: "wrong"})
        run(check_command, version, root, ok=False, error="Invalid bundle manifest")
    for raw_manifest in (b"{bad", json.dumps(manifest).encode() * 2):
        archive(raw_manifest=raw_manifest)
        run(check_command, version, root, ok=False, error="Invalid bundle manifest")
    for extra in ("another-top/file", name + "/../escape"):
        archive(extra=(extra,))
        run(check_command, version, root, ok=False)
    for identity in ("offline-mfi", "nested/offline-mfi-backup/key", "tls.password", "nested/key.pk8",
                     "cert.p7b", "key.p12", "key.pfx", "nested/key.pfx/child"):
        archive(extra=(name + "/" + identity,))
        run(check_command, version, root, ok=False, error="forbidden identity path")

    # A fake curl serves local bytes only. It models regular/security pools and snapshot's
    # binary lookup (including an irrelevant architecture), never a live HTTP service.
    stub = root / "bin"
    stub.mkdir()
    curl = stub / "curl"
    curl.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
out = pathlib.Path(args[args.index("--output") + 1])
url = args[-1]
with open(os.environ["FETCH_LOG"], "a") as log:
    log.write(url + "\\n")
data = os.environ["FETCH_DATA"].encode()
if os.environ.get("FETCH_CORRUPT"):
    data = b"wrong digest"
mode = os.environ["FETCH_MODE"]
if url.startswith("https://archive.debian.org/"):
    if mode == "snapshot" or (mode == "security" and "/debian-security/" not in url):
        sys.exit(22)
    out.write_bytes(data)
elif "/mr/binary/" in url:
    out.write_text(json.dumps({"result": [
        {"architecture": "amd64", "hash": "a" * 40},
        {"architecture": "arm64", "hash": "b" * 40}]}))
elif url == "https://snapshot.debian.org/file/" + "b" * 40:
    out.write_bytes(data)
else:
    sys.exit(99)
''')
    curl.chmod(0o755)
    pins = root / "debs.txt"
    log = root / "fetch.log"
    debs = root / "debs"
    mappings = (
        ("libasound2-data", "1.2.4-1.1", "a/alsa-lib", "all"),
        ("libasound2", "1.2.4-1.1", "a/alsa-lib", "arm64"),
        ("libelf1", "0.183-1", "e/elfutils", "arm64"),
        ("libdw1", "0.183-1", "e/elfutils", "arm64"),
        ("libnl-3-200", "3.4.0-1+b1", "libn/libnl3", "arm64"),
        ("libnl-genl-3-200", "3.4.0-1+b1", "libn/libnl3", "arm64"),
        ("iw", "5.9-3", "i/iw", "arm64"),
        ("bluez", "5.55-3.1+deb11u1", "b/bluez", "arm64"),
    )
    env = dict(os.environ, PATH=str(stub) + os.pathsep + os.environ["PATH"],
               FETCH_LOG=str(log), FETCH_DATA="fixture Debian binary", FETCH_MODE="archive")
    digest = hashlib.sha256(env["FETCH_DATA"].encode()).hexdigest()
    pins.write_text("# Package version sha256\n" + "".join(f"{pkg} {ver} {digest}\n" for pkg, ver, _, _ in mappings))
    run('ufi003_fetch_debs "$@"', pins, debs, env=env)
    urls = log.read_text().splitlines()
    assert len(urls) == 8, urls
    for (pkg, ver, pool, arch), url in zip(mappings, urls):
        filename = f"{pkg}_{ver}_{arch}.deb"
        assert url == f"https://archive.debian.org/debian/pool/main/{pool}/{filename}", url
        assert (debs / filename).read_text() == env["FETCH_DATA"]
    pkg, ver, _, _ = mappings[-1]
    pins.write_text(f"{pkg} {ver} {digest}\n")
    for mode in ("security", "snapshot"):
        log.unlink()
        run('ufi003_fetch_debs "$@"', pins, debs, env={**env, "FETCH_MODE": mode})
        urls = log.read_text().splitlines()
        if mode == "security":
            assert len(urls) == 2 and "/debian-security/pool/updates/main/b/bluez/" in urls[-1], urls
        else:
            assert len(urls) == 4 and "/mr/binary/bluez/5.55-3.1%2Bdeb11u1/binfiles" in urls[-2], urls
    log.unlink()
    run('ufi003_fetch_debs "$@"', pins, debs, env={**env, "FETCH_CORRUPT": "1"},
        ok=False, error="SHA-256 mismatch")
    assert len(log.read_text().splitlines()) == 1, "Digest mismatches must not try another mirror"

print(f"PASS {checks} offline release cases")
