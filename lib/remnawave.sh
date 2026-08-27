#!/usr/bin/env bash

rw_write_node_env() {
    local secret=$1 tmp file="${RW_PROJECT_DIR}/node.env"
    install -d -m 0700 "$RW_PROJECT_DIR"
    tmp=$(rw_mktemp_near "$file")
    {
        printf 'NODE_PORT=%s\n' "$NODE_PORT"
        printf 'SECRET_KEY=%s\n' "$secret"
    } >"$tmp"
    chmod 0600 "$tmp"
    chown root:root "$tmp"
    mv -f "$tmp" "$file"
    # Compose auto-loads a file literally named .env for interpolation even
    # when another env_file uses raw mode. Remove the legacy managed filename.
    rm -f "${RW_PROJECT_DIR}/.env"
}

rw_render_compose() {
    local file="${RW_PROJECT_DIR}/docker-compose.yml" tmp
    rw_backup_file "$file"
    tmp=$(rw_mktemp_near "$file")
    cat >"$tmp" <<EOF
# Managed by rw-node-installer. Local changes may be replaced on reinstall.
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    network_mode: host
    restart: always
    stop_grace_period: 30s
    cap_add:
      - NET_ADMIN
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    env_file:
      # A non-default name prevents Compose from also treating secrets as
      # interpolation input. Raw mode preserves special characters.
      - path: node.env
        format: raw
    extra_hosts:
      - "${DOMAIN}:127.0.0.1"
    volumes:
      - /etc/ssl/hysteria:/etc/ssl/hysteria:ro
      - /var/log/remnanode:/var/log/remnanode
    logging:
      driver: json-file
      options:
        max-size: "25m"
        max-file: "5"
        compress: "true"
EOF
    rw_atomic_install "$tmp" "$file" 0600
    rm -f "$tmp"
}

rw_install_node_units() {
    local name
    for name in rw-node-auto-update.service rw-node-auto-update.timer; do
        rw_atomic_install "$RW_INSTALL_DIR/systemd/$name" "/etc/systemd/system/$name" 0644
    done
    systemctl daemon-reload
    systemctl enable --now rw-node-auto-update.timer >/dev/null
}

rw_start_remnanode() {
    local deployed_image
    install -d -m 0750 -o root -g root "$RW_LOG_DIR"
    cd "$RW_PROJECT_DIR" || rw_die "Не удалось открыть $RW_PROJECT_DIR"
    docker compose config --quiet
    docker compose pull remnanode
    docker compose up -d remnanode
    rw_wait_until 120 3 "Remnawave Node API не слушает TCP ${NODE_PORT}" \
        sh -c "ss -H -ltn '( sport = :${NODE_PORT} )' | grep -q ."
    deployed_image=$(docker inspect --format '{{.Image}}' remnanode)
    printf '%s\t%s\tinitial\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$deployed_image" \
        >>"${RW_STATE_DIR}/deployed-images.log"
    chmod 0600 "${RW_STATE_DIR}/deployed-images.log"
}

rw_ensure_profile_values() {
    local reality_pair short_a short_b short_c tmp
    [[ -s $RW_PROFILE_VALUES_FILE ]] && return 0
    reality_pair=$(docker exec remnanode xray x25519 2>/dev/null || true)
    [[ -n $reality_pair ]] || rw_die "Не удалось выполнить xray x25519 внутри remnanode."
    short_a=$(openssl rand -hex 8)
    short_b=$(openssl rand -hex 8)
    short_c=$(openssl rand -hex 8)
    install -d -m 0700 "$RW_STATE_DIR"
    tmp=$(rw_mktemp_near "$RW_PROFILE_VALUES_FILE")
    {
        printf 'REALITY X25519 output:\n%s\n\n' "$reality_pair"
        printf 'Short IDs:\n%s\n%s\n%s\n' "$short_a" "$short_b" "$short_c"
    } >"$tmp"
    chmod 0600 "$tmp"
    chown root:root "$tmp"
    mv -f "$tmp" "$RW_PROFILE_VALUES_FILE"
}

rw_print_profile_guidance() {
    local show_private=${1:-false} safe_values
    rw_ensure_profile_values
    # Allowlist public formats from old and new Xray releases. Unknown future
    # fields stay private by default instead of relying on a redaction blacklist.
    safe_values=$(sed -nE '/^[[:space:]]*([Pp]ublic[[:space:]_-]*[Kk]ey|Password|Hash32)[[:space:]]*:/p; /^[[:space:]]*Short IDs:/,$p' \
        "$RW_PROFILE_VALUES_FILE")
    cat <<EOF

${RW_BOLD}Данные для панели и Config Profile${RW_RESET}

Node address : ${DOMAIN}
Node port    : ${NODE_PORT}
Panel IP     : ${PANEL_IP}
REALITY target: 127.0.0.1:8443
Hysteria certificateFile: /etc/ssl/hysteria/fullchain.pem
Hysteria keyFile        : /etc/ssl/hysteria/privkey.pem

Рекомендуемый masquerade Hysteria2 (добавляется в панели вручную):
  "masquerade": {
    "type": "proxy",
    "url": "https://${DOMAIN}:8443",
    "rewriteHost": true,
    "insecure": false
  }

Для Hysteria inbound включите sniffing.destOverride: ["http", "tls", "quic"].
Для dual-stack DNS используйте queryStrategy "UseIP" вместо "UseIPv4".
В REALITY serverNames оставьте ${DOMAIN}; другие имена допустимы только если локальный
Caddy действительно обслуживает для них валидный сертификат.
Fingerprint (Firefox/QQ) задаётся в Host/клиенте и установщиком не меняется.
Создайте отдельные REALITY privateKey/publicKey и shortIds для этой ноды.
Не вставляйте ключи в репозиторий или журналы.

Публичные значения Xray и предложенные shortIds:
${safe_values}

Private key сохранён только в root-файле ${RW_PROFILE_VALUES_FILE}.
Для разового показа непосредственно в TTY: rw-node profile-guidance --show-private-key
EOF
    if [[ $show_private == true ]]; then
        [[ -w /dev/tty ]] || rw_die "Private key можно показать только в интерактивном TTY."
        printf '\nВНИМАНИЕ: не копируйте private key в логи или issue.\n' >/dev/tty
        cat "$RW_PROFILE_VALUES_FILE" >/dev/tty
    fi
}
