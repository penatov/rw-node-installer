#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_ROOT=$(mktemp -d "${RW_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rw-node-tests.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT

export RW_CONFIG_DIR="$TEMP_ROOT/etc/rw-node-installer"
export RW_CONFIG_FILE="$RW_CONFIG_DIR/config.env"
export RW_STATE_DIR="$TEMP_ROOT/var/lib/rw-node-installer"
export RW_BACKUP_DIR="$RW_STATE_DIR/backups"
export RW_PROJECT_DIR="$TEMP_ROOT/opt/remnanode"
export RW_SITE_DIR="$TEMP_ROOT/var/www/site"
export RW_CERT_DIR="$TEMP_ROOT/etc/ssl/hysteria"
export RW_LOG_DIR="$TEMP_ROOT/var/log/remnanode"
export RW_CADDYFILE="$TEMP_ROOT/etc/caddy/Caddyfile"
export RW_CADDY_STORAGE="$TEMP_ROOT/var/lib/caddy/storage"
export RW_CADDY_LOG_DIR="$TEMP_ROOT/var/log/caddy"
export RW_INSTALL_DIR="$ROOT"
export RW_SITE_GENERATOR="$ROOT/tools/site_generator.sh"
export RW_LOCK_FILE="$TEMP_ROOT/run/lock"
export RW_RUNTIME_DIR="$TEMP_ROOT/run/rw-node-installer"
export RW_TEST_IPV6_AVAILABLE=true

# shellcheck source=../src/lib/common.sh
source "$ROOT/src/lib/common.sh"
for library in validate platform firewall site caddy remnawave install; do
    # shellcheck disable=SC1090
    source "$ROOT/src/lib/${library}.sh"
done

# Rendering functions chown root in production. Ownership is outside these unit
# tests; root-mode integration checks run during a real Debian installation.
chown() { :; }
if (( EUID != 0 )) && [[ ${OSTYPE:-} != msys* && ${OSTYPE:-} != cygwin* ]]; then
    install() {
        local -a arguments=()
        while (($#)); do
            case "$1" in
                -o|-g) shift 2 ;;
                *) arguments+=("$1"); shift ;;
            esac
        done
        command install "${arguments[@]}"
    }
fi
case ${OSTYPE:-} in
    msys*|cygwin*)
        install() {
            local directory=false
            while (($#)); do
                case "$1" in
                    -d) directory=true; shift ;;
                    -m|-o|-g) shift 2 ;;
                    --) shift; break ;;
                    -*) shift ;;
                    *) break ;;
                esac
            done
            if [[ $directory == true ]]; then
                mkdir -p -- "$@"
            else
                local -a values=("$@")
                cp -- "${values[${#values[@]}-2]}" "${values[${#values[@]}-1]}"
            fi
        }
        chmod() { :; }
        ;;
esac

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { "$@" || fail "$*"; }
assert_file_contains() {
    local file=$1 expected=$2
    grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

apt_get_arguments=""
apt-get() { printf -v apt_get_arguments '%q ' "$@"; }
RW_APT_LOCK_TIMEOUT=37 rw_apt_get install -y example-package
[[ $apt_get_arguments == *'DPkg::Lock::Timeout=37'* ]] || fail "APT lock timeout was not passed"
[[ $apt_get_arguments == *'install -y example-package'* ]] || fail "APT arguments were not preserved"
unset -f apt-get
printf 'OK: APT lock waiting\n'

# Execute only the mask-building prelude; never write NIC/sysfs settings.
for cpu_count in 4 31 32 33 64 65 256 300; do
    case $cpu_count in
        4) expected_mask=0000000f ;;
        31) expected_mask=7fffffff ;;
        32) expected_mask=ffffffff ;;
        33) expected_mask=00000001,ffffffff ;;
        64) expected_mask=ffffffff,ffffffff ;;
        65) expected_mask=00000001,ffffffff,ffffffff ;;
        *) expected_mask=ffffffff,ffffffff,ffffffff,ffffffff,ffffffff,ffffffff,ffffffff,ffffffff ;;
    esac
    actual_mask=$(RW_TEST_CPUS=$cpu_count bash -c '
        nproc() { printf "%s" "$RW_TEST_CPUS"; }
        source /dev/stdin
        printf "%s" "$mask"
    ' < <(sed '/^mapfile /,$d' "$ROOT/src/scripts/rw-node-nic-tune"))
    [[ $actual_mask == "$expected_mask" ]] || fail "NIC CPU mask: $cpu_count"
done
printf 'OK: native NIC masks (4..300 CPUs)\n'

assert rw_validate_domain node.example.com
assert rw_validate_domain xn--e1afmkfd.xn--p1ai
! rw_validate_domain localhost || fail "single-label domain accepted"
! rw_validate_domain '-bad.example' || fail "invalid domain accepted"
assert test "$(rw_normalize_domain 'Node.Example.COM.')" = node.example.com

assert rw_validate_single_ip 203.0.113.10
assert rw_validate_single_ip 2001:db8::10
! rw_validate_single_ip 203.0.113.0/24 || fail "panel CIDR accepted"
assert test "$(rw_normalize_ip_list '203.0.113.1, 2001:db8::1,203.0.113.1')" = '203.0.113.1,2001:db8::1'
assert rw_ip_list_has_world '0.0.0.0/0'
assert rw_ip_list_has_world '::/0'
! rw_ip_list_has_world '203.0.113.0/24,2001:db8::/64' || fail "ordinary prefix treated as world"
assert rw_ip_in_list 203.0.113.25 '203.0.113.0/24,2001:db8::1'
! rw_ip_in_list 203.0.114.25 '203.0.113.0/24' || fail "address outside CIDR accepted"
assert rw_validate_email admin@example.com
assert rw_validate_email ''
! rw_validate_email not-an-email || fail "invalid email accepted"
valid_secret=$(printf '%s' '{"caCertPem":"test-ca","jwtPublicKey":"test-jwt","nodeCertPem":"test-cert","nodeKeyPem":"test-key"}' | base64 | tr -d '\n=')
assert rw_validate_secret "$valid_secret"
! rw_validate_secret short || fail "short secret accepted"
! rw_validate_secret '0123456789abcdef' || fail "non-Remnawave secret accepted"
secret_json='{"caCertPem":"ca","jwtPublicKey":"jwt","nodeCertPem":"cert","nodeKeyPem":"key"}'
for invalid_json in '{}' '[]' "$secret_json$secret_json" \
    '{"caCertPem":null,"jwtPublicKey":"jwt","nodeCertPem":"cert","nodeKeyPem":"key"}' \
    '{"caCertPem":"   ","jwtPublicKey":"jwt","nodeCertPem":"cert","nodeKeyPem":"key"}'; do
    invalid_secret=$(printf '%s' "$invalid_json" | base64 | tr -d '\n')
    ! rw_validate_secret "$invalid_secret" || fail "invalid secret JSON accepted"
done
invalid_secret=$(printf '%s\000' "$secret_json" | base64 | tr -d '\n')
! rw_validate_secret "$invalid_secret" || fail "NUL in secret JSON accepted"
invalid_secret=$(printf '{"caCertPem":"\377","jwtPublicKey":"jwt","nodeCertPem":"cert","nodeKeyPem":"key"}' | base64 | tr -d '\n')
! rw_validate_secret "$invalid_secret" || fail "invalid UTF-8 in secret accepted"
printf 'OK: validators\n'

for port in 1 2222 32456 65535; do
    assert rw_validate_node_port "$port"
done
for port in '' 0 -1 65536 100000 02222 22 80 443 8443 '22+1' '1;id' 'abc' ' 2222'; do
    ! rw_validate_node_port "$port" || fail "invalid/conflicting API port accepted: $port"
done
(
    export RW_DOMAIN=node.example.com RW_SECRET_KEY="$valid_secret"
    export RW_PANEL_IP=203.0.113.10 RW_ADMIN_IPS=198.51.100.20 RW_ACME_EMAIL=admin@example.com
    unset RW_NODE_PORT
    rw_load_config() { return 1; }
    # Mock unrelated input; the port prompt's default is also valid on a TTY.
    rw_tty_read() { printf -v "$1" '%s' "${3:-}"; }
    rw_collect_install_inputs
    [[ $NODE_PORT == 2222 ]] || fail 'new install lost default port'
    rw_collect_install_inputs --node-port 32456
    [[ $NODE_PORT == 32456 ]] || fail 'custom CLI port ignored'
    rw_load_config() { NODE_PORT=32456; }
    rw_collect_install_inputs
    [[ $NODE_PORT == 32456 ]] || fail 'reinstall reset saved port'
    export RW_NODE_PORT=23456
    rw_collect_install_inputs
    [[ $NODE_PORT == 23456 ]] || fail 'environment did not override saved port'
    rw_collect_install_inputs --node-port 34567
    [[ $NODE_PORT == 34567 ]] || fail 'CLI did not override environment'
    if (rw_collect_install_inputs --node-port 8443) >/dev/null 2>&1; then
        fail 'conflicting port accepted during installation'
    fi
    if (rw_collect_install_inputs --node-port) >/dev/null 2>&1; then
        fail 'missing port argument accepted'
    fi
) || fail 'API port input precedence'
printf 'OK: API port validation and CLI/environment/saved/default precedence\n'

doh_v4=$(
    curl() {
        printf '%s\n' '{"Status":0,"Answer":[{"name":"node.example.com.","type":1,"TTL":300,"data":"203.0.113.10"}]}'
    }
    dig() { printf '%s\n' 198.51.100.20; }
    rw_resolve_v4 node.example.com
)
[[ $doh_v4 == 203.0.113.10 ]] || fail "public DoH was not preferred over stale local DNS"
doh_v6=$(
    curl() { printf '%s\n' '{"Status":0,"Authority":[]}'; }
    dig() { printf '%s\n' 2001:db8::20; }
    rw_resolve_v6 node.example.com
)
[[ -z $doh_v6 ]] || fail "DoH NODATA was replaced with a stale local AAAA record"
local_fallback=$(
    curl() { return 1; }
    dig() { printf '%s\n' 203.0.113.11; }
    rw_resolve_v4 node.example.com
)
[[ $local_fallback == 203.0.113.11 ]] || fail "local DNS fallback did not work when DoH failed"
printf 'OK: resilient public DNS resolution\n'

dns_without_aaaa=$(
    (
        rw_resolve_v4() { printf '%s\n' 203.0.113.10; }
        rw_resolve_v6() { return 0; }
        rw_detect_public_v4() { printf '%s\n' 203.0.113.10; }
        rw_detect_public_v6() { printf '%s\n' 2001:db8::10; }
        rw_validate_dns node.example.com
    ) 2>&1
) || fail "DNS validation rejected an absent AAAA record"
grep -Fq 'установка продолжится только с IPv4' <<<"$dns_without_aaaa" || \
    fail "missing AAAA warning was not emitted"
printf 'OK: IPv4-only DNS is non-fatal\n'

export DOMAIN=node.example.com
export PANEL_IP=203.0.113.10
export ADMIN_IPS='198.51.100.0/24,2001:db8:1::10'
export ACME_EMAIL=admin@example.com
export NODE_PORT=2222
export SITE_SEED=unit-test-seed
export INSTALLER_REPOSITORY=https://github.com/example/repository
export INSTALLER_REF=main

mkdir -p "$RW_STATE_DIR"
rw_write_config
if [[ ${OSTYPE:-} != msys* && ${OSTYPE:-} != cygwin* ]]; then
    assert test "$(stat -c '%a' "$RW_CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$RW_CONFIG_FILE")" = 600
fi
unset DOMAIN PANEL_IP ADMIN_IPS ACME_EMAIL NODE_PORT SITE_SEED
rw_load_config
assert test "$DOMAIN" = node.example.com
assert test "$PANEL_IP" = 203.0.113.10
printf 'OK: config round-trip\n'

ss() {
    case $* in
        *':443'*) printf '%s\n' \
            'tcp LISTEN 0 4096 *:443 *:* users:(("rw-core",pid=124,fd=7))' \
            'udp UNCONN 0 0 *:443 *:* users:(("rw-core",pid=124,fd=8))' ;;
        *':2222'*) printf '%s\n' \
            'tcp LISTEN 0 4096 *:2222 *:* users:(("rw-node",pid=123,fd=20))' ;;
    esac
    return 0
}
docker() {
    case $1 in
        inspect) printf '%s\n' 'true host' ;;
        top) printf '%s\n' PID 123 124 ;;
    esac
}
systemctl() { return 1; }
rw_preflight_ports
docker() {
    case $1 in
        inspect) printf '%s\n' 'true host' ;;
        top) printf '%s\n' PID 123 ;;
    esac
}
if (rw_preflight_ports) >/dev/null 2>&1; then
    fail "unmanaged rw-core process on 443 was accepted"
fi
ss() {
    [[ $* == *':2222'* ]] && printf '%s\n' \
        'tcp LISTEN 0 4096 *:2222 *:* users:(("rw-node",pid=123,fd=20))'
    return 0
}
docker() { return 1; }
if (rw_preflight_ports) >/dev/null 2>&1; then
    fail "unmanaged node process on 2222 was accepted"
fi
unset -f ss docker systemctl
printf 'OK: idempotent managed-port preflight\n'

rw_render_firewall
assert_file_contains "$RW_FIREWALL_FILE" 'table inet rw_node_guard {'
assert_file_contains "$RW_FIREWALL_FILE" 'elements = { 203.0.113.10 }'
assert_file_contains "$RW_FIREWALL_FILE" 'elements = { 203.0.113.10, 198.51.100.0/24 }'
assert_file_contains "$RW_FIREWALL_FILE" 'elements = { 2001:db8:1::10 }'
assert_file_contains "$RW_FIREWALL_FILE" 'tcp dport { 80, 443 }'
assert_file_contains "$RW_FIREWALL_FILE" 'udp dport 443'
assert_file_contains "$RW_FIREWALL_FILE" 'meta l4proto tcp counter reject with tcp reset'
! grep -Eq '^[[:space:]]*flush[[:space:]]+ruleset' "$RW_FIREWALL_FILE" || fail "rendered global flush"
printf 'OK: nftables rendering\n'

(
    install -d -m 0700 "$RW_RUNTIME_DIR"
    snapshot="$RW_RUNTIME_DIR/firewall-before.test.nft"
    : >"$snapshot"
    printf 'test-unit\n%s\n' "$snapshot" >"$RW_FIREWALL_PENDING"
    systemctl() { return 0; }
    assert rw_firewall_confirmation_pending test-unit "$snapshot"
    ! rw_firewall_confirmation_pending wrong-unit "$snapshot" || fail 'accepted different transaction'
    systemctl() { return 3; }
    ! rw_firewall_confirmation_pending test-unit "$snapshot" || fail 'accepted expired timer'
    systemctl() { return 0; }
    rm -f "$RW_FIREWALL_PENDING"
    ! rw_firewall_confirmation_pending test-unit "$snapshot" || fail 'accepted completed rollback'
    rm -f "$snapshot"
) || fail 'firewall confirmation lifetime'
printf 'OK: expired firewall confirmations are rejected\n'

(
    rw_require_root() { :; }
    rw_acquire_lock() { :; }
    rw_check_platform() { :; }
    nft() { :; }
    rw_resolve_pending_firewall_transaction() { :; }
    rw_install_firewall_service() { :; }
    applied=false
    rw_apply_firewall_safely() {
        assert_file_contains "$1" 'elements = { 203.0.113.10 }'
        assert_file_contains "$1" 'elements = { 203.0.113.10, 198.51.100.0/24 }'
        assert_file_contains "$1" 'meta l4proto tcp counter reject with tcp reset'
        applied=true
    }
    rw_install_bundle() { fail 'same-source runtime replacement'; }
    docker() { fail 'firewall-only update touched Docker'; }
    rw_write_config() { fail 'firewall-only update changed saved settings'; }
    rw_write_node_env() { fail 'firewall-only update changed credentials'; }
    rw_apt_install_base() { fail 'firewall-only update ran APT'; }
    rw_update_firewall_command "$RW_INSTALL_DIR"
    [[ $applied == true ]] || fail 'firewall-only update did not apply rules'

    for invalid_case in world port panel; do
        if (
            rw_load_config() {
                case $invalid_case in
                    world) ADMIN_IPS=0.0.0.0/0 ;;
                    port) NODE_PORT=443 ;;
                    panel) PANEL_IP=not-an-ip ;;
                esac
            }
            rw_update_firewall_command "$RW_INSTALL_DIR"
        ) >/dev/null 2>&1; then
            fail "firewall update accepted invalid saved settings: $invalid_case"
        fi
    done
) || fail 'firewall-only update'
printf 'OK: firewall-only update preserves settings and runtime services\n'

rw_generate_site true
rw_verify_site_assets || fail "generated site assets failed verification"
assert_file_contains "$RW_SITE_DIR/index.html" '@font-face'
assert_file_contains "$RW_SITE_DIR/sitemap.xml" 'https://node.example.com/'
printf 'OK: deterministic local site\n'

rw_render_caddyfile
assert_file_contains "$RW_CADDYFILE" 'https://node.example.com:8443'
assert_file_contains "$RW_CADDYFILE" 'bind 127.0.0.1 ::1'
assert_file_contains "$RW_CADDYFILE" 'admin off'
assert_file_contains "$RW_CADDYFILE" 'disable_tlsalpn_challenge'
assert_file_contains "$RW_CADDYFILE" 'protocols h1 h2'
assert_file_contains "$RW_CADDYFILE" '-Server'
assert_file_contains "$RW_CADDYFILE" '-Alt-Svc'
assert_file_contains "$RW_CADDYFILE" "$RW_CADDY_STORAGE"
RW_TEST_IPV6_AVAILABLE=false
rw_render_caddyfile
assert_file_contains "$RW_CADDYFILE" 'bind 0.0.0.0'
assert_file_contains "$RW_CADDYFILE" 'bind 127.0.0.1'
! grep -Fq '::' "$RW_CADDYFILE" || fail "IPv6 bind rendered when IPv6 is unavailable"
RW_TEST_IPV6_AVAILABLE=true
rw_render_caddyfile
printf 'OK: Caddyfile rendering\n'

special_secret='literal$hash#equals=quote'"'"'and-backslash\\0123456789'
rw_write_node_env "$special_secret"
assert_file_contains "$RW_PROJECT_DIR/node.env" "SECRET_KEY=$special_secret"
rw_render_compose
assert_file_contains "$RW_PROJECT_DIR/docker-compose.yml" 'format: raw'
assert_file_contains "$RW_PROJECT_DIR/docker-compose.yml" 'image: remnawave/node:latest'
assert_file_contains "$RW_PROJECT_DIR/docker-compose.yml" 'no-new-privileges:true'
assert_file_contains "$RW_PROJECT_DIR/docker-compose.yml" 'node.example.com:127.0.0.1'
printf 'OK: Compose rendering and raw secret preservation\n'

(
    NODE_PORT=32456
    RW_CONFIG_FILE="$TEMP_ROOT/custom-port.env"
    RW_FIREWALL_FILE="$TEMP_ROOT/custom-port.nft"
    RW_PROJECT_DIR="$TEMP_ROOT/custom-project"
    rw_write_config
    NODE_PORT=2222
    rw_load_config
    [[ $NODE_PORT == 32456 ]] || fail 'custom API port was not persisted'
    rw_render_firewall
    assert_file_contains "$RW_FIREWALL_FILE" 'ip saddr @panel_v4 tcp dport 32456 ct state new counter accept'
    assert_file_contains "$RW_FIREWALL_FILE" 'ip6 saddr @panel_v6 tcp dport 32456 ct state new counter accept'
    ! grep -Fq 'tcp dport 2222' "$RW_FIREWALL_FILE" || fail 'default API port remains allowed'
    rw_write_node_env "$special_secret"
    assert_file_contains "$RW_PROJECT_DIR/node.env" 'NODE_PORT=32456'
    rw_render_compose
    assert_file_contains "$RW_PROJECT_DIR/docker-compose.yml" 'path: node.env'
    ss() {
        [[ $* != *':32456'* ]] || printf '%s\n' \
            'tcp LISTEN 0 4096 *:32456 *:* users:(("unmanaged",pid=9999,fd=20))'
    }
    rw_managed_caddy_pid() { :; }
    rw_managed_node_pids() { :; }
    if (rw_preflight_ports) >/dev/null 2>&1; then
        fail 'occupied custom port accepted'
    fi
) || fail 'custom API port propagation'
printf 'OK: custom API port persistence, firewall, node environment and occupied-port check\n'

cat >"$RW_PROFILE_VALUES_FILE" <<'EOF'
REALITY X25519 output:
PrivateKey: private-value-must-not-leak
Password (PublicKey): public-value-for-reality
Hash32: irrelevant-vless-encryption-value

Short IDs:
0123456789abcdef
EOF
chmod 0600 "$RW_PROFILE_VALUES_FILE"
guidance=$(rw_print_profile_guidance)
grep -Fq 'Password (PublicKey): public-value-for-reality' <<<"$guidance" || \
    fail "current Xray public key label was not printed"
grep -Fq '0123456789abcdef' <<<"$guidance" || fail "short ID was not printed"
! grep -Fq 'private-value-must-not-leak' <<<"$guidance" || fail "REALITY private key leaked"
! grep -Fq 'irrelevant-vless-encryption-value' <<<"$guidance" || fail "irrelevant Hash32 was printed"
printf 'OK: safe current-Xray REALITY guidance\n'

RW_INSTALL_DIR="$TEMP_ROOT/installed-bundle"
RW_INSTALL_STAGING_PARENT="$TEMP_ROOT/staging"
RW_SBIN_DIR="$TEMP_ROOT/sbin"
mkdir -p "$RW_INSTALL_STAGING_PARENT" "$RW_SBIN_DIR"
rw_install_bundle "$ROOT"
assert test -x "$RW_INSTALL_DIR/bin/rw-node"
assert test -r "$RW_INSTALL_DIR/lib/common.sh"
assert test -x "$RW_INSTALL_DIR/scripts/rw-node-healthcheck"
assert test -r "$RW_INSTALL_DIR/systemd/rw-node-firewall.service"
assert test -r "$RW_INSTALL_DIR/site_generator.sh"
assert test -r "$RW_INSTALL_DIR/site-generator/design.awk"
assert test ! -e "$RW_INSTALL_DIR/site_generator.py"
assert test -x "$RW_SBIN_DIR/rw-node"
printf 'OK: repository-to-runtime bundle layout\n'

if [[ -n ${RW_TEST_OUTPUT:-} ]]; then
    mkdir -p "$RW_TEST_OUTPUT"
    cp "$RW_FIREWALL_FILE" "$RW_TEST_OUTPUT/firewall.nft"
    cp "$RW_CADDYFILE" "$RW_TEST_OUTPUT/Caddyfile"
    cp "$RW_PROJECT_DIR/docker-compose.yml" "$RW_TEST_OUTPUT/docker-compose.yml"
    cp "$RW_PROJECT_DIR/node.env" "$RW_TEST_OUTPUT/node.env"
fi

printf 'Unit checks passed.\n'
