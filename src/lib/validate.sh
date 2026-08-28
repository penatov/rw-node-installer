#!/usr/bin/env bash

rw_normalize_domain() {
    local value=${1,,}
    value=${value%.}
    printf '%s' "$value"
}

rw_validate_domain() {
    local domain
    domain=$(rw_normalize_domain "$1")
    [[ ${#domain} -le 253 ]] || return 1
    [[ $domain == *.* ]] || return 1
    [[ $domain != *'..'* ]] || return 1
    [[ $domain =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
    local label
    IFS='.' read -r -a _rw_labels <<<"$domain"
    for label in "${_rw_labels[@]}"; do
        [[ -n $label && ${#label} -le 63 ]] || return 1
        [[ $label != -* && $label != *- ]] || return 1
    done
}

rw_ip_version() {
    python3 - "$1" <<'PY'
import ipaddress, sys
try:
    value = sys.argv[1]
    obj = ipaddress.ip_network(value, strict=False) if "/" in value else ipaddress.ip_address(value)
    print(obj.version)
except ValueError:
    raise SystemExit(1)
PY
}

rw_validate_single_ip() {
    [[ $1 != */* ]] || return 1
    rw_ip_version "$1" >/dev/null
}

rw_ip_in_list() {
    python3 - "$1" "$2" <<'PY'
import ipaddress, sys
try:
    address = ipaddress.ip_address(sys.argv[1])
    networks = []
    for value in sys.argv[2].split(','):
        value = value.strip()
        if value:
            networks.append(ipaddress.ip_network(value, strict=False))
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if any(address.version == network.version and address in network for network in networks) else 1)
PY
}

rw_normalize_ip_list() {
    python3 - "$1" <<'PY'
import ipaddress, sys
raw = sys.argv[1]
seen = set()
result = []
for chunk in raw.split(','):
    value = chunk.strip()
    if not value:
        continue
    try:
        obj = ipaddress.ip_network(value, strict=False) if '/' in value else ipaddress.ip_address(value)
    except ValueError as exc:
        print(f"Некорректный IP/CIDR: {value}: {exc}", file=sys.stderr)
        raise SystemExit(1)
    normalized = str(obj)
    if normalized not in seen:
        seen.add(normalized)
        result.append(normalized)
if not result:
    print("Список IP пуст.", file=sys.stderr)
    raise SystemExit(1)
print(','.join(result))
PY
}

rw_ip_list_has_world() {
    python3 - "$1" <<'PY'
import ipaddress, sys
for value in sys.argv[1].split(','):
    value = value.strip()
    if not value:
        continue
    network = ipaddress.ip_network(value, strict=False) if '/' in value else None
    if network is not None and network.prefixlen == 0:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

rw_validate_email() {
    [[ -z $1 || $1 =~ ^[A-Za-z0-9.!#$%\&\'*+/=?^_{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]
}

rw_validate_secret() {
    python3 - "$1" <<'PY'
import base64
import binascii
import json
import sys

value = sys.argv[1]
if len(value) < 16 or "\n" in value or "\r" in value:
    raise SystemExit(1)
try:
    padded = value + "=" * (-len(value) % 4)
    payload = json.loads(base64.b64decode(padded, altchars=b"-_", validate=True).decode("utf-8"))
except (ValueError, binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(1)
required = ("caCertPem", "jwtPublicKey", "nodeCertPem", "nodeKeyPem")
if not isinstance(payload, dict) or any(not isinstance(payload.get(key), str) or not payload[key].strip() for key in required):
    raise SystemExit(1)
PY
}

rw_resolve_google_doh() {
    local domain=$1 record_type=$2 response
    response=$(curl -fsS --max-time 8 --retry 2 --retry-delay 1 --retry-all-errors \
        "https://dns.google/resolve?name=${domain}&type=${record_type}" 2>/dev/null) || return 1
    python3 - "$record_type" "$response" <<'PY'
import ipaddress
import json
import sys

record_type = sys.argv[1].upper()
try:
    payload = json.loads(sys.argv[2])
except json.JSONDecodeError:
    raise SystemExit(1)

# NOERROR and NXDOMAIN are authoritative DNS answers. Other status codes are
# resolver failures, so the caller may fall back to the machine resolver.
status = payload.get("Status")
if status not in (0, 3):
    raise SystemExit(1)

expected_type = 1 if record_type == "A" else 28
expected_version = 4 if record_type == "A" else 6
values = set()
for answer in payload.get("Answer") or ():
    if answer.get("type") != expected_type:
        continue
    try:
        address = ipaddress.ip_address(answer.get("data", ""))
    except ValueError:
        continue
    if address.version == expected_version:
        values.add(str(address))
for value in sorted(values):
    print(value)
PY
}

rw_resolve_v4() {
    local result
    if result=$(rw_resolve_google_doh "$1" A); then
        printf '%s\n' "$result" | sed '/^$/d'
        return 0
    fi
    dig +time=3 +tries=2 +short A "$1" 2>/dev/null | \
        awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print}' | sort -u
}

rw_resolve_v6() {
    # Query AAAA explicitly. getent ahostsv6 may synthesize IPv4-mapped
    # addresses on some libc/NSS configurations, incorrectly implying AAAA.
    local result
    if result=$(rw_resolve_google_doh "$1" AAAA); then
        printf '%s\n' "$result" | sed '/^$/d'
        return 0
    fi
    dig +time=3 +tries=2 +short AAAA "$1" 2>/dev/null | \
        awk 'index($0, ":") {print tolower($0)}' | sort -u
}

rw_ipv6_loopback_available() {
    case ${RW_TEST_IPV6_AVAILABLE:-auto} in
        true) return 0 ;;
        false) return 1 ;;
    esac
    [[ -r /proc/net/if_inet6 ]] && grep -Eqi '^0{31}1[[:space:]]' /proc/net/if_inet6
}

rw_detect_public_v4() {
    curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
}

rw_detect_public_v6() {
    curl -6fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true
}

rw_validate_dns() {
    local domain=$1 v4 v6 public4 public6
    v4=$(rw_resolve_v4 "$domain" || true)
    v6=$(rw_resolve_v6 "$domain" || true)
    [[ -n $v4 || -n $v6 ]] || rw_die "Домен $domain не имеет A или AAAA-записи."

    public4=$(rw_detect_public_v4)
    public6=$(rw_detect_public_v6)
    if [[ -n $public4 && -n $v4 ]] && ! grep -Fxq "$public4" <<<"$v4"; then
        rw_die "A-запись $domain не содержит публичный IPv4 этой машины ($public4)."
    fi
    if [[ -z $v6 ]]; then
        rw_warn "У домена нет AAAA-записи; установка продолжится только с IPv4."
    elif [[ -z $public6 ]]; then
        rw_die "У домена есть AAAA-запись, но исходящий IPv6 на сервере не работает."
    elif ! grep -Fxiq "$public6" <<<"$v6"; then
        rw_die "AAAA-запись $domain не содержит публичный IPv6 этой машины ($public6)."
    fi
    rw_info "DNS A: ${v4:-нет}; AAAA: ${v6:-нет}"
}
