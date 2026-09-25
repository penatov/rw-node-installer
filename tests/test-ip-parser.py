#!/usr/bin/env python3
"""Development-only differential checks of the native IP/CIDR parser."""
import ipaddress
import os
from pathlib import Path
import random
import subprocess

ROOT = Path(__file__).resolve().parents[1]
AWK = os.environ.get("RW_AWK", "awk")


def run(mode, value, networks=""):
    result = subprocess.run(
        [AWK, "-f", str(ROOT / "src/scripts/rw-ip.awk")],
        env=dict(os.environ, LC_ALL="C", RW_IP_MODE=mode,
                 RW_IP_INPUT=value, RW_IP_LIST=networks),
        capture_output=True, text=True,
    )
    assert result.returncode in (0, 1), result.stderr
    return result.returncode == 0, result.stdout.strip()


rng = random.Random(98217)
values = ["0.0.0.0", "255.255.255.255", "::", "::1", "2001:DB8::1",
          "::ffff:192.0.2.1", "2001:db8:0:1:0:0:0:1", "1::2:0:0:3",
          "192.0.2.5/255.255.255.0", "192.0.2.5/0.0.0.255",
          "192.0.2.5/0.0.0.0", "192.0.2.5/255.255.255.255"]
for version in (4, 6):
    bits = 32 if version == 4 else 128
    cls = ipaddress.IPv4Address if version == 4 else ipaddress.IPv6Address
    for i in range(100):
        address = cls(rng.getrandbits(bits))
        values.extend([str(address), f"{address}/{rng.randint(0, bits)}"])
    for prefix in range(bits + 1):
        values.append(f"{cls(rng.getrandbits(bits))}/{prefix}")

for value in values:
    expected = (ipaddress.ip_network(value, strict=False) if "/" in value
                else ipaddress.ip_address(value))
    assert run("normalize", value) == (True, str(expected)), value
    assert run("version", value) == (True, str(expected.version)), value
    if "/" in value:
        inside = str(expected.network_address)
        assert run("in-list", inside, value)[0], (inside, value)
        other = ipaddress.ip_address("198.51.100.26" if expected.version == 4 else "2001:db8::26")
        assert run("in-list", str(other), value)[0] == (other in expected), value
        assert run("world", value)[0] == (expected.prefixlen == 0), value

for value in ("", "1", "1.2.3", "1.2.3.256", "01.2.3.4", "1.2.3.-1",
              "1.2.3.4/33", "1.2.3.4/-1", "1.2.3.4/", "1.2.3.4/24/24",
              "1.2.3.4/255.0.255.0", ":::1", "1::2::3", "1:2:3:4:5:6:7:8:9",
              "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8::", "::ffff:999.0.0.1",
              "::g", "12345::", "::/129", "::/255.255.0.0", "fe80::1%ens3",
              "$(touch x)", "1.2.3.4\\n", "1.2.3.4\n5.6.7.8"):
    assert not run("normalize", value)[0], repr(value)
assert run("normalize", " 192.0.2.1,2001:DB8::1,192.0.2.1, ") == (True, "192.0.2.1,2001:db8::1")
assert not run("in-list", "192.0.2.1", "::/0")[0]
assert not run("in-list", "2001:db8::1", "0.0.0.0/0")[0]
print(f"OK: {len(values)} IP/CIDR cases agree with ipaddress; malformed inputs rejected")
