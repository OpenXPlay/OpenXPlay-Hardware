#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
"""Validate the N1 host profile without root, dpkg or hardware."""
import json
from pathlib import Path
import subprocess
import tempfile

n1 = Path(__file__).resolve().parents[2]
installer = (n1 / "package/install-device.sh").read_text()
function = installer[installer.index("host_profile_ok() {"):installer.index('[ "$(id -u)"')]
expected = {"model": "Phicomm N1", "wifiInterface": "wlan0", "bluetoothAdapter": "hci0",
            "secureConnections": "pairing-off"}
assert json.loads((n1 / "host.json").read_text()) == expected
cases = [(json.dumps(expected), True), (json.dumps(dict(reversed(list(expected.items()))), indent=2), True)]
for key in expected:
    bad = expected.copy()
    del bad[key]
    cases.append((json.dumps(bad), False))
    bad[key] = "wrong"
    cases.append((json.dumps(bad), False))
cases += [(json.dumps({**expected, "hotspotDownGapSeconds": 15}), False),
          (json.dumps(expected).replace('"Phicomm N1"', '"PhicommN1"'), False),
          (json.dumps(expected).replace('"wlan0"', '"wlan 0"'), False),
          (json.dumps(expected) + 'junk', False),
          (json.dumps(expected).replace('"model": "Phicomm N1"',
                                        '"model": "Phicomm N1", "model": "Phicomm N1"'), False),
          (json.dumps(expected)[:-1] + ',}', False), ('{}', False)]
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "host.json"
    for value, ok in cases:
        path.write_text(value)
        result = subprocess.run(["sh", "-c", function + '\nhost_profile_ok "$1"', "profile-test", str(path)],
                                capture_output=True)
        assert (result.returncode == 0) == ok, (value, result.stderr)
print(f"PASS {len(cases)} N1 profile validation cases")
