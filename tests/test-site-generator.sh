#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

cases=0
while read -r expected seed; do
    [[ -n $expected && $expected != \#* ]] || continue
    bash "$ROOT/tools/site_generator.sh" --quiet --seed "$seed" --output "$work/site.html"
    actual=$(awk -f "$ROOT/tests/normalize-site.awk" "$work/site.html" | sha256sum)
    [[ ${actual%% *} == "$expected" ]] || {
        printf 'FAIL: site regression for seed %s\nExpected: %s\nActual: %s\n' "$seed" "$expected" "${actual%% *}" >&2
        exit 1
    }
    cases=$((cases + 1))
done <"$ROOT/tests/fixtures/site-sha256.txt"
((cases == 100)) || { printf 'FAIL: incomplete site fixture set\n' >&2; exit 1; }
printf 'OK: %s full HTML regression snapshots\n' "$cases"
