#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
(( EUID == 0 )) || { printf 'Run this integration test as root.\n' >&2; exit 1; }

TEMP_ROOT=$(mktemp -d /tmp/rw-node-linux-integration.XXXXXX)
CADDY_USER_CREATED=false
cleanup() {
    rm -rf -- "$TEMP_ROOT"
    if [[ $CADDY_USER_CREATED == true ]]; then userdel caddy >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
chmod 0755 "$TEMP_ROOT"

if ! id caddy >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --shell /usr/sbin/nologin caddy
    CADDY_USER_CREATED=true
fi

export RW_CONFIG_DIR="$TEMP_ROOT/etc/rw-node-installer"
export RW_STATE_DIR="$TEMP_ROOT/state"
export RW_BACKUP_DIR="$RW_STATE_DIR/backups"
export RW_CADDY_LOG_DIR="$TEMP_ROOT/var/log/caddy"
export RW_CADDY_STORAGE="$TEMP_ROOT/var/lib/caddy/storage"
mkdir -p "$RW_CADDY_LOG_DIR" "$RW_STATE_DIR"
touch "$RW_CADDY_LOG_DIR/rw-node-access.log"
# shellcheck source=../src/lib/common.sh
source "$ROOT/src/lib/common.sh"
# shellcheck source=../src/lib/caddy.sh
source "$ROOT/src/lib/caddy.sh"
rw_prepare_caddy_runtime
[[ ! -e $RW_CADDY_LOG_DIR/rw-node-access.log ]]
[[ $(stat -c '%u:%g' "$RW_CADDY_LOG_DIR") == "$(id -u caddy):$(id -g caddy)" ]]
touch "$RW_CADDY_LOG_DIR/rw-node-access.log"
chown caddy:caddy "$RW_CADDY_LOG_DIR/rw-node-access.log"
chmod 0400 "$RW_CADDY_LOG_DIR/rw-node-access.log"
rw_prepare_caddy_runtime
[[ $(stat -c '%a' "$RW_CADDY_LOG_DIR/rw-node-access.log") == 640 ]]
printf 'OK: root-owned Caddy access log repair\n'

DOMAIN=node.example.com
CONFIG="$TEMP_ROOT/config.env"
CERT_DIR="$TEMP_ROOT/cert-output"
STORAGE="$TEMP_ROOT/caddy-storage"
CA_CERT="$TEMP_ROOT/ca.crt"
CA_KEY="$TEMP_ROOT/ca.key"
LEAF_KEY="$TEMP_ROOT/leaf.key"
LEAF_CSR="$TEMP_ROOT/leaf.csr"
LEAF_CERT="$TEMP_ROOT/leaf.crt"
CERT_STORAGE="$STORAGE/certificates/acme-test/$DOMAIN"

printf 'DOMAIN=%q\n' "$DOMAIN" >"$CONFIG"
chmod 0600 "$CONFIG"
mkdir -p "$CERT_STORAGE" "$CERT_DIR"

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3 \
    -subj '/CN=rw-node test CA' -keyout "$CA_KEY" -out "$CA_CERT" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -sha256 -subj "/CN=$DOMAIN" \
    -keyout "$LEAF_KEY" -out "$LEAF_CSR" >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' \
    "$DOMAIN" >"$TEMP_ROOT/leaf.ext"
openssl x509 -req -sha256 -days 3 -in "$LEAF_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" \
    -CAcreateserial -extfile "$TEMP_ROOT/leaf.ext" -out "$LEAF_CERT" >/dev/null 2>&1

cat "$LEAF_CERT" "$CA_CERT" >"$CERT_STORAGE/$DOMAIN.crt"
cp "$LEAF_KEY" "$CERT_STORAGE/$DOMAIN.key"
chown -R "$(id -u nobody):$(id -g nobody)" "$STORAGE"
chmod 0700 "$STORAGE" "$STORAGE/certificates" "$STORAGE/certificates/acme-test" "$CERT_STORAGE"
chmod 0600 "$CERT_STORAGE/$DOMAIN.crt" "$CERT_STORAGE/$DOMAIN.key"

env \
    RW_CERT_SYNC_CONFIG="$CONFIG" \
    RW_CERT_SYNC_CERT_DIR="$CERT_DIR" \
    RW_CERT_SYNC_STORAGE="$STORAGE" \
    RW_CERT_SYNC_PROJECT="$TEMP_ROOT/project" \
    RW_CERT_SYNC_CADDY_USER=nobody \
    RW_CERT_SYNC_CA_BUNDLE="$CA_CERT" \
    "$ROOT/src/scripts/rw-node-cert-sync" >/dev/null

openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -checkhost "$DOMAIN" >/dev/null
openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -checkend 86400 >/dev/null
[[ $(stat -c '%a' "$CERT_DIR/fullchain.pem") == 600 ]]
[[ $(stat -c '%a' "$CERT_DIR/privkey.pem") == 600 ]]
[[ $(stat -c '%u:%g' "$CERT_DIR/privkey.pem") == 0:0 ]]

printf 'OK: Caddy certificate boundary and publication\n'
