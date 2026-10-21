#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
"""Offline bundle/manifest and fake-device installer tests. Never run a host device command."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
from fixtures import deb

n1 = Path(__file__).resolve().parents[2]
checks = 0


def check(value, message):
    global checks
    assert value, message
    checks += 1


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


with tempfile.TemporaryDirectory(prefix="n1 installer ") as tmp:
    work = Path(tmp)
    source = work / "repo/PhicommN1"
    shutil.copytree(n1, source)
    shutil.copyfile(n1.parent / "LICENSE", source.parent / "LICENSE")
    inputs = work / "inputs"
    inputs.mkdir()
    out = work / "out"
    bins = work / "bin"
    bins.mkdir()
    root = work / "device"
    (root / "proc/device-tree").mkdir(parents=True)
    (root / "etc/openxplay").mkdir(parents=True)
    model = root / "proc/device-tree/model"
    model.write_bytes(b"Phicomm N1\0")
    os_release = root / "etc/os-release"
    os_release.write_text('ID=debian\nVERSION_ID="13"\n')
    shutil.copyfile(n1 / "host.json", root / "etc/openxplay/host.json")
    state = work / "state.json"
    state.write_text("{}")
    log = work / "commands.jsonl"
    fixture_script = n1 / "package/tests/fixtures.py"
    # Only the package build is stubbed. The bundle builder reads real ar/control archives.
    (source / "package/build-deb.sh").write_text('#!/bin/sh\nexec "$FIXTURE_PYTHON" "$FIXTURES" "$2" "$3"\n')
    stub = r'''import json, os, pathlib, re, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["FIXTURE_LIB"])
from fixtures import fields
cmd = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TEST_LOG"], "a") as log:
    log.write(json.dumps([cmd, *args]) + "\n")
state = pathlib.Path(os.environ["TEST_STATE"])
installed = json.loads(state.read_text())
def compare(a, b):
    def split(v):
        epoch, v = v.split(":", 1) if ":" in v else ("0", v)
        upstream, revision = v.rsplit("-", 1) if "-" in v else (v, "0")
        return int(epoch), upstream, revision
    def part(a, b):
        def order(c):
            if c == "~": return -1
            if not c or c.isdigit(): return 0
            return ord(c) if c.isalpha() else ord(c) + 256
        while a or b:
            while (a and not a[0].isdigit()) or (b and not b[0].isdigit()):
                x, y = order(a[:1]), order(b[:1])
                if x != y: return (x > y) - (x < y)
                a, b = a[1:], b[1:]
            x, y = re.match(r"[0-9]*", a)[0], re.match(r"[0-9]*", b)[0]
            a, b = a[len(x):], b[len(y):]
            x, y = int(x or "0"), int(y or "0")
            if x != y: return (x > y) - (x < y)
        return 0
    a, b = split(a), split(b)
    return (a[0] > b[0]) - (a[0] < b[0]) or part(a[1], b[1]) or part(a[2], b[2])
if cmd == "id":
    assert args == ["-u"]
    print(os.environ.get("TEST_UID", "0"))
elif cmd == "uname":
    assert args == ["-r"]
    print(os.environ.get("TEST_KERNEL", "6.12.112-ophub"))
elif cmd == "df":
    print("Filesystem 1024-blocks Used Available Capacity Mounted on")
    print("fixture 200000 1000 " + os.environ.get("TEST_FREE", "100000") + " 1% /")
elif cmd == "dpkg-deb":
    if os.environ.get("TEST_CONTROL_FAIL"): sys.exit(2)
    assert args[0] == "-f"
    print(fields(args[1]).get(args[2], ""))
elif cmd == "dpkg-query":
    assert args[:1] == ["-W"]
    value = installed.get(args[-1])
    if value is None: sys.exit(1)
    print((value["status"] + " " + value["version"]) if isinstance(value, dict)
          else "install ok installed " + value, end="")
elif cmd == "apt-get":
    assert args[:7] == ["-s", "--no-install-recommends", "-o", "Dir::Etc::SourceList=/dev/null",
                        "-o", "Dir::Etc::SourceParts=/dev/null", "install"], args
    assert args[7:] and all(pathlib.Path(path).is_absolute() and pathlib.Path(path).is_file()
                           and path.endswith(".deb") for path in args[7:]), args
    print("Reading package lists... Done")
    if os.environ.get("TEST_APT_FAIL"):
        print("The following packages have unmet dependencies:")
        print(" libnftables1 : Depends: libnftnl11 (>= 1.2.6) but it is not installable")
        print("               Depends: libxtables12 but it is not installable")
        print(" dnsmasq-base : Depends: libnftnl11 but it is not going to be installed")
        print("E: Unable to correct problems, you have held broken packages.", file=sys.stderr)
        sys.exit(100)
elif cmd == "dpkg":
    if args == ["--print-architecture"]:
        print(os.environ.get("TEST_ARCH", "arm64"))
    elif args[:1] == ["--compare-versions"]:
        assert args[2] in ("ge", "gt")
        value = compare(args[1], args[3])
        sys.exit(0 if (value >= 0 if args[2] == "ge" else value > 0) else 1)
    elif args == ["--audit"]:
        print(os.environ.get("TEST_AUDIT", ""), end="")
    elif "-i" in args:
        if os.environ.get("TEST_DPKG_FAIL"): sys.exit(1)
        assert args[:3] == ["--force-confdef", "--force-confold", "-i"]
        for path in args[3:]:
            meta = fields(path)
            installed[meta["Package"]] = meta["Version"]
        state.write_text(json.dumps(installed))
    else: raise AssertionError(args)
elif cmd == "systemctl":
    if args == ["is-enabled", "openxplay-usb-gadget.service"]:
        value = os.environ.get("TEST_GADGET", "enabled")
        print(value)
        sys.exit(0 if value == "enabled" else 1)
    assert args == ["is-active", "--quiet", "bluetooth.service"], args
    sys.exit(int(os.environ.get("TEST_BLUETOOTH_FAIL", "0")))
elif cmd == "modprobe":
    assert args == ["-n", "rfcomm"], args
    sys.exit(int(os.environ.get("TEST_RFCOMM_FAIL", "0")))
else: raise AssertionError(cmd)
'''
    for cmd in ("id", "uname", "df", "dpkg-deb", "dpkg-query", "apt-get", "dpkg", "systemctl", "modprobe"):
        path = bins / cmd
        path.write_text(f"#!{sys.executable}\n" + stub)
        path.chmod(0o755)
    # Only fake package/device commands and POSIX/core utilities are available to the installer.
    runtime = work / "runtime"
    runtime.mkdir()
    for cmd in ("sh", "dirname", "awk", "sha256sum", "find", "sort", "cmp", "tr", "grep", "sed", "wc"):
        executable = shutil.which(cmd)
        check(executable is not None, "Test dependency: " + cmd)
        (runtime / cmd).symlink_to(executable)
    env = dict(os.environ, SOURCE_DATE_EPOCH="1792540800", FIXTURE_PYTHON=sys.executable,
               FIXTURES=str(fixture_script), FIXTURE_LIB=str(fixture_script.parent),
               OPENXPLAY_N1_ROOT=str(root), TEST_LOG=str(log), TEST_STATE=str(state))

    def run(script, args=(), code=0, error=None, extra=None, device=False, stderr_lines=()):
        e = {**env, **(extra or {})}
        if device:
            e["PATH"] = str(bins) + os.pathsep + str(runtime)
        result = subprocess.run(["sh", str(script), *map(str, args)], env=e, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=40)
        output = result.stdout + result.stderr
        check(result.returncode == code, f"Unexpected exit {result.returncode}: {output}")
        if error:
            check(error in output, output)
        for line in stderr_lines:
            check(line in result.stderr.splitlines() and line not in result.stdout.splitlines(), output)
        if device:
            prefix = "OXP-STAGE device " + ("wrong-device:" if code == 2 else "failed:" if code else "")
            check(output.splitlines()[-1].startswith(prefix), output)
        return output

    pins = source / "install/debs.txt"
    rows = []
    packages = [("z-runtime-data", "1.2-1", "all"), ("a-runtime-lib", "2.0~rc1-1", "arm64"),
                ("c-runtime", "1:2.0-1", "all")]
    for pkg, version, arch in packages:
        path = inputs / f"{pkg}_{version.split(':')[-1]}_{arch}.deb"
        deb(path, pkg, version, arch, "runtime-source (1.0)")
        rows.append(f"{pkg} {version} {digest(path)}")
    builder = source / "package/build-bundle.sh"
    # Empty pins work and include exactly the device package.
    pins.write_text("# Package version sha256\n")
    run(builder, [inputs, out])
    bundle = out / "openxplay-phicomm-n1-device-0.1.0"
    check(len(json.loads((bundle / "manifest.json").read_text())["packages"]) == 1, "Empty pins")
    installer = bundle / "install-device.sh"
    run(installer, ["--dry-run", bundle], device=True)
    run(installer, [bundle], device=True)
    check(json.loads(state.read_text()) == {"openxplay-phicomm-n1": "0.1.0"}, "Empty pins install")
    state.write_text("{}")
    log.write_text("")
    # An arbitrary dependency list, in an order that differs from lexicographic file order.
    pins.write_text("# Package version sha256\n" + "\n".join(rows))  # Deliberately no final newline.
    sources = work / "sources"
    sources.mkdir()
    (sources / "runtime-source_1.0.dsc").write_text("fixture source\n")
    (sources / "ignore.txt").write_text("not a source archive\n")
    run(builder, ["--sources", sources, inputs, out])
    manifest = json.loads((bundle / "manifest.json").read_text())
    expected_packages = [p[0] for p in packages] + ["openxplay-phicomm-n1"]
    check([p["name"] for p in manifest["packages"]] == expected_packages, "Manifest dependency order")
    check(manifest["schema"] == "org.openxplay.flash-stage/1" and manifest["stage"] == "device", "Manifest schema")
    check(manifest["device"] == "phicomm-n1" and manifest["transport"] == "ssh", "N1 SSH manifest")
    check(manifest["requires"] == {"stages": ["base"], "deviceTreeModel": "Phicomm N1",
          "debianVersion": "13", "dpkgArchitecture": "arm64", "freeKiB": 65536}, "No kernel pin")
    check(manifest["writes"] == "files" and manifest["reboot"] == "required", "Manifest stage contract")
    for key, mode in (("preflight", "--dry-run "), ("install", ""), ("verify", "--verify ")):
        check(manifest[key] == "sh install-device.sh " + mode + ".", key)
    for package in manifest["packages"]:
        check(digest(bundle / package["file"]) == package["sha256"], "Manifest package digest")
    check("runtime-source 1.0" in (bundle / "SOURCES.txt").read_text(), "Source field is used")
    check((bundle / "sources/runtime-source_1.0.dsc").is_file() and
          not (bundle / "sources/ignore.txt").exists(), "Optional source archives")
    with tarfile.open(str(bundle) + ".tar.gz") as tar:
        check(all(p.name.split("/")[0] == bundle.name for p in tar), "One archive top directory")

    def calls():
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def installs():
        return [call for call in calls() if call[0] == "dpkg" and "-i" in call]

    def simulations():
        return [call for call in calls() if call[0] == "apt-get"]

    def snapshot(path):
        return {str(p.relative_to(path)): p.read_bytes() for p in path.rglob("*") if p.is_file()}

    before = (snapshot(root), snapshot(bundle), state.read_bytes())
    run(installer, ["--dry-run", bundle], device=True)
    check(before == (snapshot(root), snapshot(bundle), state.read_bytes()), "Dry run changes nothing")
    check(not installs(), "Dry run does not install")
    check(simulations()[-1][8:] == [str(bundle / package["file"]) for package in manifest["packages"]],
          "Dry run solves exactly the absolute bundle paths in install order")
    for value in (b"Other Board\0", b"Phicomm N1 Plus\0", b"phicomm n1\0", b""):
        model.write_bytes(value)
        run(installer, ["--dry-run", bundle], code=2, error="expected Phicomm N1", device=True)
    model.unlink()
    run(installer, [bundle], code=2, error="unknown", device=True)
    model.write_bytes(b"Phicomm N1\0")
    for content in ('ID=debian\nVERSION_ID="12"\n', 'ID=ubuntu\nVERSION_ID="13"\n'):
        os_release.write_text(content)
        run(installer, [bundle], code=2, error="requires Debian 13", device=True)
    os_release.write_text('ID=debian\nVERSION_ID="13"\n')
    run(installer, [bundle], code=2, error="arm64", extra={"TEST_ARCH": "amd64"}, device=True)
    run(installer, [bundle], code=1, error="unexpected installer error", extra={"TEST_CONTROL_FAIL": "1"}, device=True)
    run(installer, [bundle], code=1, error="run as root", extra={"TEST_UID": "1000"}, device=True)
    run(installer, [bundle], code=1, error="KiB free", extra={"TEST_FREE": "100"}, device=True)
    missing = "OXP-STAGE device failed: missing dependencies: libnftnl11 libxtables12"
    for args in (["--dry-run", bundle], [bundle]):
        output = run(installer, args, code=1, error=missing, extra={"TEST_APT_FAIL": "1"}, device=True,
                     stderr_lines=(" libnftables1 : Depends: libnftnl11 (>= 1.2.6) but it is not installable",
                                   "               Depends: libxtables12 but it is not installable",
                                   " dnsmasq-base : Depends: libnftnl11 but it is not going to be installed",
                                   "E: Unable to correct problems, you have held broken packages.", missing))
        check(output.splitlines()[-1] == missing, "Final failure lists missing dependencies once")
        check("Reading package lists" not in output, "Only relevant solver diagnostics are printed")
        check(not installs(), "Unmet dependencies prevent every dpkg -i call")
        check(before == (snapshot(root), snapshot(bundle), state.read_bytes()), "Solver failure changes nothing")
    apt_get = bins / "apt-get"
    apt_get.rename(bins / "disabled-apt-get")
    for args in (["--dry-run", bundle], [bundle]):
        run(installer, args, code=1, error="missing command: apt-get", device=True)
    (bins / "disabled-apt-get").rename(apt_get)
    check(not installs(), "Preflight failures change no packages")
    run(installer, [bundle], device=True)
    check(simulations()[-1][8:] == installs()[-1][4:], "Install solves exactly the packages passed to dpkg")
    actual = [Path(path).name.split("_")[0] for path in installs()[-1][4:]]
    check(actual == expected_packages, "Dependency order, device last")
    count = len(installs())
    run(installer, [bundle], device=True)
    check(len(installs()) == count, "Exact versions skipped")
    installed = json.loads(state.read_text())
    installed.update({"z-runtime-data": "1.1-1", "a-runtime-lib": "2.0-1", "c-runtime": "2:1.0-1"})
    state.write_text(json.dumps(installed))
    run(installer, [bundle], device=True)
    actual = [Path(path).name.split("_")[0] for path in installs()[-1][4:]]
    check(actual == ["z-runtime-data"], "Only older installed pins upgraded; prerelease/epoch never downgraded")
    check(simulations()[-1][8:] == installs()[-1][4:], "Solver respects installed newer versions")
    installed = json.loads(state.read_text())
    installed["a-runtime-lib"] = {"status": "install ok unpacked", "version": "3.0"}
    state.write_text(json.dumps(installed))
    count = len(installs())
    run(installer, [bundle], code=1, error="unconfigured packages", extra={"TEST_AUDIT": "unpacked a-runtime-lib"}, device=True)
    check(len(installs()) == count, "Unpacked newer packages never downgraded")
    installed["a-runtime-lib"] = "2.0-1"
    installed["openxplay-phicomm-n1"] = "0.2.0"
    state.write_text(json.dumps(installed))
    count = len(installs())
    run(installer, [bundle], device=True)
    check(len(installs()) == count, "Newer device package is never downgraded")
    run(installer, ["--verify", bundle], code=1, error="expected openxplay-phicomm-n1 0.1.0", device=True)
    installed["openxplay-phicomm-n1"] = "0.1.0"
    state.write_text(json.dumps(installed))
    for kernel in ("6.12.112-ophub", "6.12.113-ophub", "6.18.1-ophub"):
        run(installer, ["--verify", bundle], extra={"TEST_KERNEL": kernel}, device=True)
    for extra, error in (({"TEST_GADGET": "disabled"}, "not enabled"),
                         ({"TEST_BLUETOOTH_FAIL": "1"}, "bluetooth.service is not active"),
                         ({"TEST_RFCOMM_FAIL": "1"}, "lacks usable RFCOMM")):
        run(installer, ["--verify", bundle], code=1, error=error, extra=extra, device=True)
    profile = root / "etc/openxplay/host.json"
    profile.write_text('{}')
    run(installer, ["--verify", bundle], code=1, error="host profile", device=True)
    shutil.copyfile(n1 / "host.json", profile)
    installed.pop("openxplay-phicomm-n1")
    state.write_text(json.dumps(installed))
    run(installer, ["--verify", bundle], code=1, error="package version", device=True)
    run(installer, [bundle], code=1, error="dpkg failed", extra={"TEST_DPKG_FAIL": "1"}, device=True)
    run(installer, [bundle], code=1, error="unconfigured packages", extra={"TEST_AUDIT": "broken"}, device=True)

    def sums():
        (bundle / "SHA256SUMS").write_text("".join(
            digest(p) + "  " + p.relative_to(bundle).as_posix() + "\n"
            for p in sorted(bundle.rglob("*")) if p.is_file() and p != bundle / "SHA256SUMS"))

    checksum = bundle / "SHA256SUMS"
    valid_sums = checksum.read_text()
    first = valid_sums.splitlines()[0]
    for bad in (first, "f" * 64 + "  ../escape", "g" * 64 + "  missing", "# comment", ""):
        checksum.write_text(valid_sums + bad + "\n")
        run(installer, [bundle], code=1, error="SHA256SUMS entry", device=True)
    checksum.write_text(valid_sums)
    for mode in ("--dry-run", "--verify", None):
        path = bundle / "SOURCES.txt"
        data = path.read_bytes()
        path.write_bytes(data + b"corrupt")
        run(installer, ([mode] if mode else []) + [bundle], code=1, error="checksum mismatch", device=True)
        path.write_bytes(data)
    path = bundle / "extra"
    path.write_text("unlisted")
    run(installer, [bundle], code=1, error="cover exactly", device=True)
    path.unlink()
    for name in ("key.pk8", "offline-mfi-backup", "bad\\name"):
        path = bundle / name
        path.write_text("forbidden fixture")
        run(installer, [bundle], code=1, error="unsafe paths", device=True)
        path.unlink()
    path = bundle / "symlink"
    path.symlink_to(bundle / "manifest.json")
    run(installer, [bundle], code=1, error="symlinks", device=True)
    path.unlink()
    path = bundle / manifest["packages"][0]["file"]
    data = path.read_bytes()
    path.write_bytes(data + b"corrupt")
    sums()  # Even if the outer sums are regenerated, the independent pin must reject it.
    run(installer, [bundle], code=1, error="pinned checksum mismatch", device=True)
    path.write_bytes(data)
    sums()
    ordered = bundle / "debs/debs.txt"
    original = ordered.read_text()
    for changed, error in ((original + rows[0] + "\n", "duplicate package"),
                           ("\n".join(original.splitlines()[:-1]), "missing device package")):
        ordered.write_text(changed)
        sums()
        run(installer, [bundle], code=1, error=error, device=True)
    ordered.write_text(original)
    sums()
    # Builder rejects digests, controls and architectures before publishing anything.
    pin_text = pins.read_text()
    pins.write_text(pin_text.replace(rows[0].split()[-1], "0" * 64))
    run(builder, [inputs, work / "rejected"], code=1, error="SHA-256 mismatch")
    pins.write_text(pin_text + "\n" + rows[0] + "\n")
    run(builder, [inputs, work / "rejected"], code=1, error="Duplicate pinned package")
    pins.write_text(pin_text)
    path = inputs / "z-runtime-data_1.2-1_all.deb"
    deb(path, "z-runtime-data", "1.2-1", "amd64")
    run(builder, [inputs, work / "rejected"], code=1, error="Unsupported architecture")
    deb(path, "z-runtime-data", "1.2-1", "arm64")
    run(builder, [inputs, work / "rejected"], code=1, error="Control metadata")
    path.unlink()
    run(builder, [inputs, work / "rejected"], code=1, error="Missing pinned")

print(f"PASS {checks} N1 bundle, manifest and installer checks")
