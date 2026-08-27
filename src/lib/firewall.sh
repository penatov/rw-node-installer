#!/usr/bin/env bash

rw_nft_split_sets() {
    local values=$1 v4_name=$2 v6_name=$3 value version joined separator
    local -a v4=() v6=()
    IFS=',' read -r -a _rw_values <<<"$values"
    for value in "${_rw_values[@]}"; do
        [[ -n $value ]] || continue
        version=$(rw_ip_version "$value") || rw_die "Некорректный IP/CIDR: $value"
        if [[ $version == 4 ]]; then v4+=("$value"); else v6+=("$value"); fi
    done
    joined="" separator=""
    for value in "${v4[@]}"; do joined+="${separator}${value}"; separator=", "; done
    printf -v "$v4_name" '%s' "$joined"
    joined="" separator=""
    for value in "${v6[@]}"; do joined+="${separator}${value}"; separator=", "; done
    printf -v "$v6_name" '%s' "$joined"
}

rw_nft_set() {
    local name=$1 type=$2 elements=$3
    printf '    set %s {\n' "$name"
    printf '        type %s\n' "$type"
    printf '        flags interval\n'
    printf '        auto-merge\n'
    if [[ -n $elements ]]; then
        printf '        elements = { %s }\n' "$elements"
    fi
    printf '    }\n\n'
}

rw_render_firewall() {
    local output=${1:-$RW_FIREWALL_FILE}
    local panel_v4 panel_v6 admin_v4 admin_v6 ssh_values tmp
    ssh_values="${PANEL_IP},${ADMIN_IPS}"
    ssh_values=$(rw_normalize_ip_list "$ssh_values")
    rw_nft_split_sets "$PANEL_IP" panel_v4 panel_v6
    rw_nft_split_sets "$ssh_values" admin_v4 admin_v6

    [[ -d $(dirname "$output") ]] || install -d -m 0700 "$(dirname "$output")"
    tmp=$(rw_mktemp_near "$output")
    {
        printf '%s\n' "$RW_OWNER_MARKER"
        printf 'table inet %s {\n' "$RW_FIREWALL_TABLE"
        rw_nft_set panel_v4 ipv4_addr "$panel_v4"
        rw_nft_set panel_v6 ipv6_addr "$panel_v6"
        rw_nft_set ssh_v4 ipv4_addr "$admin_v4"
        rw_nft_set ssh_v6 ipv6_addr "$admin_v6"
        cat <<EOF
    chain input {
        type filter hook input priority filter; policy drop;

        iifname "lo" counter accept
        iifname != "lo" ip saddr 127.0.0.0/8 counter drop
        iifname != "lo" ip6 saddr ::1 counter drop

        ct state invalid counter drop
        ct state { established, related } counter accept

        # DHCP replies are needed on providers that configure addresses dynamically.
        udp sport 67 udp dport 68 counter accept
        udp sport 547 udp dport 546 counter accept

        # Never block essential ICMP/ICMPv6 control traffic. Echo is rate-limited.
        ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem } counter accept
        ip protocol icmp icmp type echo-request limit rate 20/second burst 40 packets counter accept
        meta l4proto ipv6-icmp counter accept

        ip saddr @ssh_v4 tcp dport 22 ct state new counter accept
        ip6 saddr @ssh_v6 tcp dport 22 ct state new counter accept

        ip saddr @panel_v4 tcp dport ${NODE_PORT} ct state new counter accept
        ip6 saddr @panel_v6 tcp dport ${NODE_PORT} ct state new counter accept

        tcp dport { 80, 443 } ct state new counter accept
        udp dport 443 counter accept

        # Silent drop is intentional: do not reveal closed management ports.
        counter drop
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
    } >"$tmp"
    chmod 0600 "$tmp"
    chown root:root "$tmp"
    mv -f "$tmp" "$output"
}

rw_install_firewall_service() {
    local unit=/etc/systemd/system/rw-node-firewall.service
    rw_backup_file "$unit"
    rw_atomic_install "$RW_INSTALL_DIR/systemd/rw-node-firewall.service" "$unit" 0644

    systemctl daemon-reload
}

rw_install_firewall_dependencies() {
    local directory
    for directory in docker.service.d caddy.service.d ssh.service.d; do
        install -d -m 0755 "/etc/systemd/system/$directory" || return 1
        if ! cat >"/etc/systemd/system/$directory/20-rw-node-firewall.conf" <<'EOF'
[Unit]
Requires=rw-node-firewall.service
After=rw-node-firewall.service
EOF
        then
            return 1
        fi
    done
    systemctl daemon-reload || return 1
}

rw_cancel_firewall_rollback() {
    local unit=$1 snapshot=$2 metadata=$3
    systemctl stop "${unit}.timer" "${unit}.service" >/dev/null 2>&1 || true
    systemctl reset-failed "${unit}.timer" "${unit}.service" >/dev/null 2>&1 || true
    rm -f -- "$snapshot" "$metadata"
}

rw_resolve_pending_firewall_transaction() {
    local unit snapshot
    [[ -e $RW_FIREWALL_PENDING ]] || return 0
    unit=$(sed -n '1p' "$RW_FIREWALL_PENDING" 2>/dev/null || true)
    snapshot=$(sed -n '2p' "$RW_FIREWALL_PENDING" 2>/dev/null || true)
    [[ $unit =~ ^rw-node-firewall-rollback-[0-9]+-[0-9]+$ && \
       $snapshot == "$RW_RUNTIME_DIR"/firewall-before.*.nft && -e $snapshot ]] || \
        rw_die "Повреждены метаданные незавершённой firewall-транзакции; используйте VNC и проверьте $RW_FIREWALL_PENDING."
    if systemctl is-active --quiet "${unit}.timer" "${unit}.service" 2>/dev/null; then
        rw_die "Предыдущая firewall-транзакция ещё ожидает rollback. Подождите три минуты, проверьте доступ через VNC и повторите установку."
    fi
    rw_warn "Восстанавливаю firewall после прерванной до запуска rollback транзакции."
    "$RW_INSTALL_DIR/scripts/rw-node-firewall-rollback" "$snapshot" "$RW_FIREWALL_PENDING" || \
        rw_die "Не удалось восстановить firewall; используйте VNC."
}

rw_restore_firewall_transaction() {
    local unit=$1 snapshot=$2 metadata=$3
    if "$RW_INSTALL_DIR/scripts/rw-node-firewall-rollback" "$snapshot" "$metadata"; then
        rw_cancel_firewall_rollback "$unit" "$snapshot" "$metadata"
    else
        rw_warn "Автоматический возврат firewall не удался; используйте VNC."
    fi
}

rw_commit_firewall() {
    local candidate=$1
    rw_atomic_install "$candidate" "$RW_FIREWALL_FILE" 0600 || return 1
    systemctl enable rw-node-firewall.service >/dev/null || return 1
    rw_install_firewall_dependencies || return 1
    # The rules were applied transactionally above, but the oneshot unit must
    # also be active before Docker/Caddy package hooks try to start services
    # that Require it. Starting it here verifies the persistent boot path too.
    if ! systemctl start rw-node-firewall.service >/dev/null; then
        rw_error "Постоянный firewall unit не запустился:"
        systemctl --no-pager --full status rw-node-firewall.service >&2 || true
        journalctl -b --no-pager -n 80 -u rw-node-firewall.service >&2 || true
        return 1
    fi
    # The clean-host preflight rejected an active or enabled stock service.
    # Keep it disabled so it cannot later load a global `flush ruleset` file.
    systemctl disable nftables.service >/dev/null 2>&1 || true
}

rw_apply_firewall_safely() {
    local candidate=$1 snapshot persistent_backup unit metadata_tmp answer
    local was_enabled=false was_active=false persistent_existed=false dependencies_existed=false
    [[ -r $candidate ]] || rw_die "Не найден кандидат правил: $candidate"
    install -d -m 0700 "$RW_RUNTIME_DIR"
    rw_resolve_pending_firewall_transaction

    snapshot=$(mktemp "$RW_RUNTIME_DIR/firewall-before.XXXXXX.nft")
    if nft list table inet "$RW_FIREWALL_TABLE" >"$snapshot" 2>/dev/null; then
        chmod 0600 "$snapshot"
    else
        : >"$snapshot"
    fi
    systemctl is-enabled --quiet rw-node-firewall.service 2>/dev/null && was_enabled=true
    systemctl is-active --quiet rw-node-firewall.service 2>/dev/null && was_active=true
    persistent_backup=$(mktemp "$RW_RUNTIME_DIR/firewall-persistent.XXXXXX.nft")
    if [[ -r $RW_FIREWALL_FILE ]]; then
        cp -- "$RW_FIREWALL_FILE" "$persistent_backup"
        persistent_existed=true
    fi
    if [[ -f /etc/systemd/system/docker.service.d/20-rw-node-firewall.conf && \
          -f /etc/systemd/system/caddy.service.d/20-rw-node-firewall.conf && \
          -f /etc/systemd/system/ssh.service.d/20-rw-node-firewall.conf ]]; then
        dependencies_existed=true
    fi
    unit="rw-node-firewall-rollback-$(date +%s)-$$"
    metadata_tmp=$(mktemp "$RW_RUNTIME_DIR/firewall-pending.XXXXXX")
    printf '%s\n%s\n' "$unit" "$snapshot" >"$metadata_tmp"
    chmod 0600 "$metadata_tmp"
    mv -f "$metadata_tmp" "$RW_FIREWALL_PENDING"

    if ! systemd-run --quiet --unit="$unit" --on-active=180s --timer-property=AccuracySec=1s \
        --property=NoNewPrivileges=yes --property=CapabilityBoundingSet=CAP_NET_ADMIN \
        --property=ProtectSystem=strict --property=ProtectHome=yes \
        --property="ReadWritePaths=$RW_RUNTIME_DIR" \
        "$RW_INSTALL_DIR/scripts/rw-node-firewall-rollback" "$snapshot" "$RW_FIREWALL_PENDING"; then
        rm -f -- "$snapshot" "$persistent_backup" "$RW_FIREWALL_PENDING"
        rw_die "Не удалось запланировать безопасный rollback nftables."
    fi

    if ! "$RW_INSTALL_DIR/scripts/rw-node-firewall-apply" "$candidate"; then
        rw_restore_firewall_transaction "$unit" "$snapshot" "$RW_FIREWALL_PENDING"
        rm -f -- "$persistent_backup"
        rw_die "nftables не принял правила. Старый firewall не изменён."
    fi

    if ! nft list table inet "$RW_FIREWALL_TABLE" >/dev/null; then
        rw_restore_firewall_transaction "$unit" "$snapshot" "$RW_FIREWALL_PENDING"
        rm -f -- "$persistent_backup"
        rw_die "Таблица nftables не создана; старые правила восстановлены."
    fi
    rw_log "nftables применён. Автоматический rollback активен ещё 180 секунд."
    if [[ ! -r /dev/tty ]]; then
        rw_restore_firewall_transaction "$unit" "$snapshot" "$RW_FIREWALL_PENDING"
        rm -f -- "$persistent_backup"
        rw_die "Firewall нельзя подтвердить без TTY; правила возвращены."
    fi
    printf '%s\n' "Откройте НОВУЮ SSH-сессию и только после успешного входа введите yes." >/dev/tty
    IFS= read -r -p "Сохранить правила? [yes/NO] " answer </dev/tty || true
    if [[ ${answer,,} != yes && ${answer,,} != да ]]; then
        rw_restore_firewall_transaction "$unit" "$snapshot" "$RW_FIREWALL_PENDING"
        rm -f -- "$persistent_backup"
        rw_die "Новые правила отменены пользователем."
    fi
    if ! rw_commit_firewall "$candidate"; then
        if [[ $persistent_existed == true ]]; then
            rw_atomic_install "$persistent_backup" "$RW_FIREWALL_FILE" 0600 || true
        else
            rm -f -- "$RW_FIREWALL_FILE"
        fi
        [[ $was_enabled == true ]] || systemctl disable rw-node-firewall.service >/dev/null 2>&1 || true
        if [[ $was_active != true ]]; then
            systemctl stop rw-node-firewall.service >/dev/null 2>&1 || true
            systemctl reset-failed rw-node-firewall.service >/dev/null 2>&1 || true
        fi
        if [[ $dependencies_existed != true ]]; then
            rm -f /etc/systemd/system/docker.service.d/20-rw-node-firewall.conf \
                /etc/systemd/system/caddy.service.d/20-rw-node-firewall.conf \
                /etc/systemd/system/ssh.service.d/20-rw-node-firewall.conf
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        rw_restore_firewall_transaction "$unit" "$snapshot" "$RW_FIREWALL_PENDING"
        rm -f -- "$persistent_backup"
        rw_die "Не удалось зафиксировать firewall; старые правила восстановлены."
    fi
    rw_cancel_firewall_rollback "$unit" "$snapshot" "$RW_FIREWALL_PENDING"
    rm -f -- "$candidate" "$persistent_backup"
    rw_log "Firewall подтверждён, сохранён и связан с запуском SSH/Docker/Caddy."
}

rw_firewall_status() {
    nft -a list table inet "$RW_FIREWALL_TABLE"
}
