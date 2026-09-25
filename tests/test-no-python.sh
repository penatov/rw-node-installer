#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
for name in python python3; do
    printf '#!/bin/sh\necho "Unexpected Python dependency" >&2\nexit 99\n' >"$work/bin/$name"
    chmod +x "$work/bin/$name"
done
export PATH="$work/bin:$PATH"
bash "$ROOT/tests/test-units.sh"
bash "$ROOT/tools/site_generator.sh" --seed 'no-python, Unicode: тест $() ;' --output "$work/a.html" --quiet
bash "$ROOT/tools/site_generator.sh" --seed 'no-python, Unicode: тест $() ;' --output "$work/b.html" --quiet
cmp "$work/a.html" "$work/b.html"
bash "$ROOT/tools/site_generator.sh" --seed different --output "$work/c.html" --quiet
! cmp -s "$work/a.html" "$work/c.html"
bash "$ROOT/tools/site_generator.sh" --output "$work/random-a.html" --quiet
bash "$ROOT/tools/site_generator.sh" --output "$work/random-b.html" --quiet
! cmp -s "$work/random-a.html" "$work/random-b.html"
bash "$ROOT/tools/site_generator.sh" --seed '' --output "$work/empty-a.html" --quiet
bash "$ROOT/tools/site_generator.sh" --seed '' --output "$work/empty-b.html" --quiet
cmp "$work/empty-a.html" "$work/empty-b.html"
# Invalid CLI input must not overwrite an existing page.
! bash "$ROOT/tools/site_generator.sh" --audit bad --output "$work/a.html" 2>/dev/null
cmp "$work/a.html" "$work/b.html"
bash "$ROOT/tools/site_generator.sh" --audit 100 --seed no-python-audit
printf 'OK: node runtime, deterministic seeds and entropy without Python\n'
