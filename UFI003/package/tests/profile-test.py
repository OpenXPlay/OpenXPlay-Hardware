#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-20
"""Exercise the installer's profile check without root, dpkg or device state."""
import json
from pathlib import Path
import subprocess
import tempfile

ufi = Path(__file__).resolve().parents[2]
installer = (ufi / "package/install-device.sh").read_text()
function = installer[installer.index("host_profile_ok() {"):installer.index('if [ "$mode" = verify ]')]
expected = {"model": "UFI003", "wifiInterface": "wlan0", "bluetoothAdapter": "hci0",
            "hotspotDownGapSeconds": 15, "secureConnections": "pairing-off"}
assert json.loads((ufi / "host.json").read_text()) == expected
cases = [(json.dumps(expected), True), (json.dumps(dict(reversed(list(expected.items()))), indent=2), True)]
for key in expected:
    bad = expected.copy()
    del bad[key]
    cases.append((json.dumps(bad), False))
    bad[key] = "wrong"
    cases.append((json.dumps(bad), False))
cases += [(json.dumps(expected).replace('"UFI003"', '"U FI003"'), False),
          (json.dumps(expected) + 'junk', False),
          (json.dumps(expected).replace('15', '150'), False),
          (json.dumps(expected).replace('15', '15.0'), False),
          (json.dumps(expected).replace('"model": "UFI003"', '"model": "UFI003", "model": "UFI003"'), False),
          (json.dumps(expected)[:-1] + ',}', False), ('{}', False)]
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "host.json"
    for value, ok in cases:
        path.write_text(value)
        result = subprocess.run(["sh", "-c", function + '\nhost_profile_ok "$1"', "profile-test", str(path)], capture_output=True)
        assert (result.returncode == 0) == ok, (value, result.stderr)
print(f"PASS {len(cases)} profile validation cases")
