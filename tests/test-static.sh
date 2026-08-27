#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$*"; }

PYTHON_BIN=python3
if ! "$PYTHON_BIN" -c 'raise SystemExit(0)' >/dev/null 2>&1; then
    PYTHON_BIN=${RW_PYTHON:-python}
fi

mapfile -t shell_files < <(find . -type f \( -name '*.sh' -o -path './bin/rw-node' -o -path './scripts/rw-node-*' \) -not -path './.git/*' | sort)
((${#shell_files[@]} > 10)) || fail "shell file inventory is unexpectedly small"
for file in "${shell_files[@]}"; do
    bash -n "$file" || fail "bash syntax: $file"
done
ok "bash syntax (${#shell_files[@]} files)"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x -S warning "${shell_files[@]}"
    ok "ShellCheck"
else
    printf 'SKIP: shellcheck is not installed\n'
fi

"$PYTHON_BIN" -m py_compile run.py
ok "Python syntax"

if grep -RInE 'https?://fonts\.(googleapis|gstatic)\.com|@import[[:space:]]+url' run.py assets/site; then
    fail "generated site source contains a remote font dependency"
fi
ok "no remote font dependency"

if grep -RInE 'i-love-russia\.online|s8rf75P3ICHCsGcX26Ib_|wLL1okdr6ZXjDM6t9orV7' \
    --exclude-dir=.git --exclude='test-static.sh' .; then
    fail "a secret or user-specific domain from the supplied example was embedded"
fi
ok "no supplied secret/domain embedded"

if grep -RInE '^[[:space:]]*flush[[:space:]]+ruleset' lib scripts systemd; then
    fail "global nftables flush is prohibited"
fi
ok "no global nftables flush"

if grep -Eq 'DEFAULT_REF="main"|RW_INSTALLER_REF:-main|REPOSITORY/main/install\.sh' install.sh README.md; then
    fail "remote root bootstrap must not use a mutable default branch"
fi
ok "immutable remote bootstrap policy"

grep -Fq 'admin off' lib/caddy.sh || fail "Caddy admin API is not disabled"
grep -Fq 'ssh.service.d/20-rw-node-firewall.conf' lib/firewall.sh || fail "SSH lacks firewall dependency"
grep -Fq -- '--show-private-key' bin/rw-node || fail "private key reveal is not explicit"
ok "security boundary invariants"

required_fonts=(
    golos-text-cyrillic golos-text-latin unbounded-cyrillic unbounded-latin
    pt-serif-cyrillic-regular pt-serif-latin-regular pt-serif-cyrillic-bold
    pt-serif-latin-bold pt-serif-cyrillic-italic pt-serif-latin-italic
    ibm-plex-mono-cyrillic ibm-plex-mono-latin
)
for font in "${required_fonts[@]}"; do
    [[ -s assets/fonts/${font}.woff2 ]] || fail "missing font: $font"
done
for license in assets/fonts/OFL-*.txt; do
    [[ -s $license ]] || fail "missing font license"
done
ok "local fonts and licenses"

for executable in install.sh bin/rw-node scripts/rw-node-* tests/test-*.sh; do
    [[ -x $executable ]] || fail "not executable: $executable"
done
ok "executable modes"

printf 'Static checks passed.\n'
