#!/usr/bin/env bash

RW_DIAG_FAILURES=0
RW_DIAG_WARNINGS=0

rw_diag_ok() { printf '%sOK%s   %s\n' "$RW_GREEN" "$RW_RESET" "$1"; }
rw_diag_fail() { printf '%sFAIL%s %s\n' "$RW_RED" "$RW_RESET" "$1" >&2; RW_DIAG_FAILURES=$((RW_DIAG_FAILURES + 1)); }
rw_diag_warn() { printf '%sWARN%s %s\n' "$RW_YELLOW" "$RW_RESET" "$1" >&2; RW_DIAG_WARNINGS=$((RW_DIAG_WARNINGS + 1)); }

rw_diag_command() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then rw_diag_ok "$label"; else rw_diag_fail "$label"; fi
}

rw_diag_certificate_chain() {
    local leaf result
    leaf=$(mktemp /run/rw-node-cert-leaf.XXXXXX) || return 1
    if ! openssl x509 -in "$RW_CERT_DIR/fullchain.pem" -out "$leaf" >/dev/null 2>&1; then
        rm -f -- "$leaf"
        return 1
    fi
    if openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt \
        -untrusted "$RW_CERT_DIR/fullchain.pem" "$leaf" >/dev/null 2>&1; then
        result=0
    else
        result=1
    fi
    rm -f -- "$leaf"
    return "$result"
}

rw_diag_mode_600() {
    [[ $(stat -c %a -- "$1" 2>/dev/null) == 600 ]]
}

rw_status_command() {
    rw_require_root
    rw_load_config || rw_die "Установка не найдена."
    printf 'rw-node-installer %s\n' "${INSTALLED_VERSION:-unknown}"
    printf 'Domain: %s\nPanel IP: %s\nAdmin IPs: %s\nNode port: %s\n\n' \
        "$DOMAIN" "$PANEL_IP" "$ADMIN_IPS" "$NODE_PORT"
    systemctl --no-pager --full status rw-node-firewall.service caddy.service docker.service \
        rw-node-cert-sync.timer rw-node-auto-update.timer 2>/dev/null || true
    printf '\nContainers:\n'
    docker ps --filter name=remnanode --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || true
    printf '\nListening sockets:\n'
    ss -H -lntup 2>/dev/null | awk -v p=":${NODE_PORT}" '$5 ~ /:(22|80|443|8443)$/ || $5 ~ p {print}' || true
}

rw_diagnose_command() {
    rw_require_root
    rw_load_config || rw_die "Установка не найдена: $RW_CONFIG_FILE"
    RW_DIAG_FAILURES=0 RW_DIAG_WARNINGS=0

    rw_info "Диагностика ${DOMAIN}"
    rw_diag_command "Debian 12/13" sh -c '. /etc/os-release; test "$ID" = debian && { test "$VERSION_ID" = 12 || test "$VERSION_ID" = 13; }'
    rw_diag_command "nftables table ${RW_FIREWALL_TABLE}" nft list table inet "$RW_FIREWALL_TABLE"
    rw_diag_command "Firewall enabled for reboot" systemctl is-enabled --quiet rw-node-firewall.service
    rw_diag_command "SSH requires managed firewall" grep -Fq 'Requires=rw-node-firewall.service' \
        /etc/systemd/system/ssh.service.d/20-rw-node-firewall.conf
    rw_diag_command "Docker daemon" systemctl is-active --quiet docker.service
    rw_diag_command "Caddy service" systemctl is-active --quiet caddy.service
    rw_diag_command "Remnawave container runs" sh -c "test \"\$(docker inspect --format '{{.State.Running}}' remnanode 2>/dev/null)\" = true"
    rw_diag_command "Node API listens on ${NODE_PORT}/tcp" sh -c "ss -H -ltn '( sport = :${NODE_PORT} )' | grep -q ."
    rw_diag_command "Caddy listens on loopback 8443" sh -c "ss -H -ltn '( sport = :8443 )' | grep -Eq '(127\\.0\\.0\\.1|\\[::1\\]|::1)'"
    rw_diag_command "Caddy local TLS/site" curl -fsS --max-time 10 --resolve "${DOMAIN}:8443:127.0.0.1" "https://${DOMAIN}:8443/" -o /dev/null
    rw_diag_command "Hysteria certificate valid >24h" openssl x509 -in "$RW_CERT_DIR/fullchain.pem" -noout -checkend 86400
    rw_diag_command "Hysteria certificate has trusted chain" rw_diag_certificate_chain
    rw_diag_command "Hysteria private key is root-only" rw_diag_mode_600 "$RW_CERT_DIR/privkey.pem"
    rw_diag_command "Node secret file is root-only" rw_diag_mode_600 "$RW_PROJECT_DIR/node.env"
    rw_diag_command "Caddy admin API disabled" grep -Eq '^[[:space:]]*admin[[:space:]]+off' "$RW_CADDYFILE"
    rw_diag_command "Generated site has local assets" rw_verify_site_assets
    rw_diag_command "Certificate timer enabled" systemctl is-enabled --quiet rw-node-cert-sync.timer
    rw_diag_command "Image update timer enabled" systemctl is-enabled --quiet rw-node-auto-update.timer

    if ss -H -ltn '( sport = :443 )' | grep -q .; then
        rw_diag_ok "VLESS/REALITY TCP 443 listens"
    else
        rw_diag_warn "TCP 443 пока не слушает: панель могла ещё не отправить Config Profile"
    fi
    if ss -H -lun '( sport = :443 )' | grep -q .; then
        rw_diag_ok "Hysteria2 UDP 443 listens"
    else
        rw_diag_warn "UDP 443 пока не слушает: панель могла ещё не отправить Config Profile"
    fi

    local resolved4 resolved6 public4 public6
    resolved4=$(rw_resolve_v4 "$DOMAIN" || true)
    resolved6=$(rw_resolve_v6 "$DOMAIN" || true)
    public4=$(rw_detect_public_v4)
    public6=$(rw_detect_public_v6)
    [[ -n $resolved4 || -n $resolved6 ]] && rw_diag_ok "DNS resolves" || rw_diag_fail "DNS does not resolve"
    if [[ -n $public4 && -n $resolved4 ]] && ! grep -Fxq "$public4" <<<"$resolved4"; then
        rw_diag_fail "A record does not contain $public4"
    fi
    if [[ -n $resolved6 && -z $public6 ]]; then
        rw_diag_fail "AAAA exists but server IPv6 connectivity is unavailable"
    fi

    if nft list table ip remnanode >/dev/null 2>&1 || nft list table ip6 remnanode6 >/dev/null 2>&1; then
        rw_diag_ok "Remnawave Node Plugins nftables tables detected"
    else
        rw_diag_warn "Node Plugins nftables tables are absent (normal if plugins are disabled)"
    fi

    printf '\nРезультат: %d ошибок, %d предупреждений.\n' "$RW_DIAG_FAILURES" "$RW_DIAG_WARNINGS"
    (( RW_DIAG_FAILURES == 0 ))
}
