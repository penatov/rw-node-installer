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

mapfile -t shell_files < <(find . -type f \( -name '*.sh' -o -path './src/bin/rw-node' -o -path './src/scripts/rw-node-*' \) -not -path './.git/*' | sort)
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

"$PYTHON_BIN" -m py_compile tools/site_generator.py
ok "Python syntax"

[[ -x src/bin/rw-node ]] || fail "missing runtime entry point"
[[ -r src/lib/common.sh ]] || fail "missing runtime libraries"
[[ -x src/scripts/rw-node-healthcheck ]] || fail "missing runtime helpers"
[[ -r src/systemd/rw-node-firewall.service ]] || fail "missing systemd units"
[[ -r tools/site_generator.py ]] || fail "missing site generator"
ok "repository layout"

if grep -RInE 'https?://fonts\.(googleapis|gstatic)\.com|@import[[:space:]]+url' tools/site_generator.py assets/site; then
    fail "generated site source contains a remote font dependency"
fi
ok "no remote font dependency"

if grep -RInE 'i-love-russia\.online|s8rf75P3ICHCsGcX26Ib_|wLL1okdr6ZXjDM6t9orV7' \
    --exclude-dir=.git --exclude='test-static.sh' .; then
    fail "a secret or user-specific domain from the supplied example was embedded"
fi
ok "no supplied secret/domain embedded"

if grep -RInE '^[[:space:]]*flush[[:space:]]+ruleset' src/lib src/scripts src/systemd; then
    fail "global nftables flush is prohibited"
fi
ok "no global nftables flush"

if grep -Eq 'chain[[:space:]]+forward|hook[[:space:]]+forward' src/lib/firewall.sh; then
    fail "host firewall must not override Docker/Plugin forwarding policy"
fi
ok "forwarding remains owned by Docker/Plugins"

if grep -Eq 'DEFAULT_REF="main"|RW_INSTALLER_REF:-main|REPOSITORY/main/install\.sh' install.sh README.md; then
    fail "remote root bootstrap must not use a mutable default branch"
fi
ok "immutable remote bootstrap policy"

grep -Fq 'admin off' src/lib/caddy.sh || fail "Caddy admin API is not disabled"
grep -Fq 'protocols h1 h2' src/lib/caddy.sh || fail "loopback Caddy unnecessarily advertises HTTP/3"
grep -Fq -- '-Alt-Svc' src/lib/caddy.sh || fail "internal Caddy port may leak through Alt-Svc"
grep -Fq -- '-Server' src/lib/caddy.sh || fail "Caddy product header is exposed"
grep -Fq 'DPkg::Lock::Timeout=' src/lib/platform.sh || fail "APT does not wait for dpkg locks"
grep -Fq 'https://dns.google/resolve?' src/lib/validate.sh || \
    fail "DNS validation has no public DoH source"
if grep -Fq '{1,3}' src/lib/validate.sh; then
    fail "DNS validation uses an interval regexp unsupported by Debian 12 mawk"
fi
grep -Fq "'{{.State.Running}} {{.HostConfig.NetworkMode}}'" src/lib/install.sh || \
    fail "reinstall preflight does not verify the managed host-network container"
grep -Fq 'docker top remnanode -eo pid' src/lib/install.sh || \
    fail "reinstall preflight does not verify listener ownership by container PID"
grep -Fq 'Password([[:space:]]*\([Pp]ublic[Kk]ey\))?' src/lib/remnawave.sh || \
    fail "current Xray Password (PublicKey) label is not recognized"
if grep -RInE 'rm[[:space:]].*(/var/lib/dpkg|/var/lib/apt).*(lock|lock-frontend)' src install.sh; then
    fail "package manager lock files must never be deleted"
fi
grep -Fq 'runuser -u caddy' src/lib/caddy.sh || fail "Caddy validation does not use the service identity"
if grep -Eq '^[[:space:]]*caddy validate' src/lib/caddy.sh; then
    fail "Caddy validation runs as root"
fi
grep -Fq 'ssh.service.d/20-rw-node-firewall.conf' src/lib/firewall.sh || fail "SSH lacks firewall dependency"
grep -Fq 'systemctl start rw-node-firewall.service' src/lib/firewall.sh || fail "firewall unit is not activated before dependent services"
grep -Fq 'RuntimeDirectory=rw-node-installer' src/systemd/rw-node-firewall.service || fail "firewall unit lacks a private runtime directory"
grep -Fq 'ReadWritePaths=/run/rw-node-installer' src/systemd/rw-node-firewall.service || fail "firewall runtime directory is read-only"
grep -Fq 'ReadWritePaths=$RW_RUNTIME_DIR' src/lib/firewall.sh || fail "rollback runtime directory is read-only"
if grep -nE 'mktemp[[:space:]]+/run/' src/scripts/rw-node-firewall-*; then
    fail "sandboxed runtime helper writes directly to read-only /run"
fi
grep -Fq -- '--show-private-key' src/bin/rw-node || fail "private key reveal is not explicit"
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

for executable in install.sh src/bin/rw-node src/scripts/rw-node-* tests/test-*.sh; do
    [[ -x $executable ]] || fail "not executable: $executable"
done
ok "executable modes"

printf 'Static checks passed.\n'
