#!/usr/bin/env python3
"""Regression guard for removing visible generator diagnostics, not designs."""

import hashlib
import json
from pathlib import Path
import sys
import os
import random
import subprocess
import tempfile
import re

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests/reference"))
import site_generator as generator


class PortRandom(random.Random):
    """Same two-component stream as awk, for testing selection equivalence."""
    second_seed = 1

    def __init__(self, seed):
        self.a = seed
        self.b = self.second_seed

    def random(self):
        self.a = self.a * 40014 % 2147483563
        self.b = self.b * 40692 % 2147483399
        delta = self.a - self.b
        if delta < 1:
            delta += 2147483562
        return delta / 2147483563

    def randint(self, lo, hi):
        return lo + int(self.random() * (hi - lo + 1))

    def choice(self, values):
        return values[self.randint(0, len(values) - 1)]

    def shuffle(self, values):
        for i in range(len(values) - 1, 0, -1):
            j = self.randint(0, i)
            values[i], values[j] = values[j], values[i]

    def sample(self, values, k):
        pool = list(values)
        return [pool.pop(self.randint(0, len(pool) - 1)) for _ in range(k)]


def compare(expected, actual, path="dna"):
    if path.endswith(".signature"):
        return  # Diagnostic identifier has a different hash implementation.
    if isinstance(expected, dict):
        assert expected.keys() == actual.keys(), path
        for key in expected:
            compare(expected[key], actual[key], f"{path}.{key}")
    elif isinstance(expected, (list, tuple)):
        assert len(expected) == len(actual), path
        for i, (a, b) in enumerate(zip(expected, actual)):
            compare(a, b, f"{path}[{i}]")
    elif isinstance(expected, float):
        assert abs(expected - actual) < 0.000001, (path, expected, actual)
    else:
        assert expected == actual, (path, expected, actual)


def test_port():
    awk = os.environ.get("RW_AWK", "awk")
    generator.random.Random = PortRandom
    for i in range(int(os.environ.get("RW_SITE_CASES", "100"))):
        digest = hashlib.sha256(f"port-equivalence-{i}".encode()).hexdigest()
        a, b = int(digest[:8], 16), int(digest[8:16], 16)
        PortRandom.second_seed = b % 2147483398 + 1
        expected = generator.generate_site(a % 2147483562 + 1)
        with tempfile.TemporaryDirectory() as tmp:
            dna_file = Path(tmp) / "dna.json"
            env = dict(os.environ, LC_ALL="C", RW_SITE_SEED_A=str(a),
                       RW_SITE_SEED_B=str(b), RW_SITE_DNA_FILE=str(dna_file), RW_SITE_AUDIT="0")
            cmd = [awk]
            for file in ("runtime", "design", "check", "main"):
                cmd += ["-f", str(ROOT / f"tools/site-generator/{file}.awk")]
            result = subprocess.run(cmd, env=env, capture_output=True, check=True)
            actual = json.loads(dna_file.read_text(encoding="utf-8"))
            compare(expected.dna, actual)
            html = result.stdout.decode("utf-8")
            # Compare the complete rendering, not just its settings. Decimal
            # spelling may differ between Python and awk's number formatting.
            def normalize_html(value):
                return re.sub(r"(?<![\w#])[-+]?\d+\.\d+(?:e[-+]?\d+)?",
                              lambda m: format(float(m[0]) or 0, ".8g"), value)
            wanted, got = normalize_html(expected.html), normalize_html(html)
            if wanted != got:
                position = next((j for j, (x, y) in enumerate(zip(wanted, got)) if x != y), min(len(wanted), len(got)))
                raise AssertionError((i, position, wanted[max(0, position-60):position+150], got[max(0, position-60):position+150]))
            report = generator.validate_html(html, actual)
            assert report.ok, (i, report.errors)
            assert len(html) > 60000
    print("OK: awk choices match reference with equivalent random stream; HTML validates")


def main():
    results = [
        generator.generate_site(generator.parse_seed(f"shell-port-regression-{i}"))
        for i in range(100)
    ]
    # Captured before editing the renderer. No random choices, design settings,
    # or variant families may change as a side effect of hiding internal data.
    digest = hashlib.sha256(json.dumps(
        [result.dna for result in results], sort_keys=True,
        ensure_ascii=False, separators=(",", ":"),
    ).encode()).hexdigest()
    assert digest == "26e4f2acba8ae8edffea99a1e34695d31f64768e393243816ba97fabe4827261"
    assert len({result.signature for result in results}) == 100
    assert len({result.dna["hero"]["family"] for result in results}) == 18
    assert {result.dna["footer"]["family"] for result in results} == {
        "columns", "editorial", "giant-wordmark", "index", "minimal", "technical",
    }
    for result in results:
        for label in ("DNA", "SYSTEM", "MODE", "GRID"):
            assert f"<span>{label}</span>" not in result.html
        assert "групп параметров</small>" not in result.html
        assert f"<b>{result.dna['art_direction']}</b>" not in result.html
    print("OK: 100 distinct designs; unchanged choices; no visible generator diagnostics")
    test_port()


if __name__ == "__main__":
    main()
