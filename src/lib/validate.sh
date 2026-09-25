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
    rw_ip_tool version "$1"
}

rw_ip_tool() {
    local helper
    helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)/rw-ip.awk"
    LC_ALL=C RW_IP_MODE=$1 RW_IP_INPUT=$2 RW_IP_LIST=${3:-} awk -f "$helper"
}

rw_validate_single_ip() {
    [[ $1 != */* ]] || return 1
    rw_ip_version "$1" >/dev/null
}

rw_validate_node_port() {
    local port=$1
    # Reject leading zeroes, expressions and service names before arithmetic.
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] || return 1
    (( port <= 65535 )) || return 1
    case $port in
        22|80|443|8443) return 1 ;;
    esac
}

rw_ip_in_list() {
    rw_ip_tool in-list "$1" "$2"
}

rw_normalize_ip_list() {
    rw_ip_tool normalize "$1"
}

rw_ip_list_has_world() {
    rw_ip_tool world "$1"
}

rw_validate_email() {
    [[ -z $1 || $1 =~ ^[A-Za-z0-9.!#$%\&\'*+/=?^_{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]
}

rw_validate_secret() (
    # Keep decoded bytes in a pipe: Bash variables silently discard NUL bytes.
    # iconv is supplied by Debian's essential libc-bin package.
    set -o pipefail
    local value=$1
    [[ ${#value} -ge 16 && $value =~ ^[A-Za-z0-9_+/-]+={0,2}$ ]] || return 1
    while ((${#value} % 4)); do value+='='; done
    printf '%s' "$value" | tr '_-' '/+' | base64 --decode 2>/dev/null |
        iconv -f UTF-8 -t UTF-8 2>/dev/null | jq -e -R -s '
        # jq 1.6 otherwise truncates fromjson input at a raw NUL byte.
        if index("\u0000") != null then error("NUL in JSON") else fromjson end |
        type == "object" and
        all(.caCertPem, .jwtPublicKey, .nodeCertPem, .nodeKeyPem;
            type == "string" and test("\\S"))' >/dev/null 2>&1
)

rw_resolve_google_doh() {
    local domain=$1 record_type=$2 response expected version answer normalized answers
    response=$(curl -fsS --max-time 8 --retry 2 --retry-delay 1 --retry-all-errors \
        "https://dns.google/resolve?name=${domain}&type=${record_type}" 2>/dev/null) || return 1
    printf '%s' "$response" | jq -e '.Status == 0 or .Status == 3' >/dev/null 2>&1 || return 1
    if [[ $record_type == A ]]; then expected=1 version=4; else expected=28 version=6; fi
    answers=$(printf '%s' "$response" | jq -r --argjson type "$expected" \
        '(.Answer // [])[] | select(.type == $type) | .data | select(type == "string")') || return 1
    while IFS= read -r answer; do
        [[ -n $answer && $answer != */* ]] || continue
        [[ $(rw_ip_version "$answer" 2>/dev/null) == "$version" ]] || continue
        normalized=$(rw_normalize_ip_list "$answer") || continue
        printf '%s\n' "$normalized"
    done <<<"$answers" | sort -u
}

rw_resolve_v4() {
    local result
    if result=$(rw_resolve_google_doh "$1" A); then
        printf '%s\n' "$result" | sed '/^$/d'
        return 0
    fi
    dig +time=3 +tries=2 +short A "$1" 2>/dev/null | \
        awk -F. '
            NF == 4 && $0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
                valid = 1
                for (i = 1; i <= 4; i++) {
                    if ($i < 0 || $i > 255) valid = 0
                }
                if (valid) print
            }
        ' | sort -u
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
