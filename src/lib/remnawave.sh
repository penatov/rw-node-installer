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

rw_write_profile_example() (
    local private_key short_ids tmp
    rw_ensure_profile_values
    private_key=$(sed -nE 's/^[[:space:]]*[Pp]rivate[[:space:]_-]*[Kk]ey[[:space:]]*:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$RW_PROFILE_VALUES_FILE")
    [[ $private_key =~ ^[A-Za-z0-9_-]{43}$ ]] || rw_die "Не удалось прочитать REALITY private key из $RW_PROFILE_VALUES_FILE."
    short_ids=$(awk '/^Short IDs:/ { ids=1; next } ids && NF { print $1 }' "$RW_PROFILE_VALUES_FILE" | \
        jq -Rsc 'split("\n") | map(select(length > 0))')
    jq -e 'length > 0 and all(.[]; test("^([0-9a-fA-F]{2}){1,8}$"))' \
        <<<"$short_ids" >/dev/null || rw_die "Некорректные short IDs в $RW_PROFILE_VALUES_FILE."
    install -d -m 0700 "$RW_STATE_DIR"
    tmp=$(rw_mktemp_near "$RW_PROFILE_JSON_FILE")
    trap 'rm -f -- "$tmp"' EXIT
    # Do not put private keys in jq's argv/environment (visible to process tools).
    # --rawfile reads the already protected root-only file instead.
    jq -n --arg domain "$DOMAIN" --rawfile values "$RW_PROFILE_VALUES_FILE" \
        --argjson ids "$short_ids" '
        ($values | capture("(?im)^\\s*private[ _-]*key\\s*:\\s*(?<key>[A-Za-z0-9_-]{43})\\s*$").key) as $key |
        {
          log: {loglevel: "warning"},
          dns: {servers: [{address: "https://dns.google/dns-query", skipFallback: false}], queryStrategy: "UseIP"},
          inbounds: [
            {
              tag: ("VLESS_REALITY_" + $domain + "_443"), port: 443, listen: "0.0.0.0", protocol: "vless",
              settings: {clients: [], decryption: "none"},
              sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]},
              streamSettings: {
                network: "raw", security: "reality",
                realitySettings: {show: false, xver: 0, target: "127.0.0.1:8443", serverNames: [$domain], privateKey: $key, shortIds: $ids}
              }
            },
            {
              tag: ("HYSTERIA2_" + $domain + "_443"), port: 443, listen: "0.0.0.0", protocol: "hysteria",
              settings: {clients: [], version: 2},
              sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]},
              streamSettings: {
                network: "hysteria", security: "tls",
                tlsSettings: {alpn: ["h3"], serverName: $domain, certificates: [{keyFile: "/etc/ssl/hysteria/privkey.pem", certificateFile: "/etc/ssl/hysteria/fullchain.pem"}]},
                hysteriaSettings: {version: 2, masquerade: {type: "proxy", url: ("https://" + $domain + ":8443/"), rewriteHost: true, insecure: false}, udpIdleTimeout: 60}
              }
            }
          ],
          outbounds: [{tag: "DIRECT", protocol: "freedom"}, {tag: "BLOCK", protocol: "blackhole"}],
          routing: {rules: [{type: "field", ip: ["geoip:private"], outboundTag: "BLOCK"}, {type: "field", protocol: ["bittorrent"], outboundTag: "BLOCK"}]}
        }' >"$tmp"
    [[ -s $tmp ]] || rw_die "Не удалось сформировать Config Profile."
    chmod 0600 "$tmp"
    chown root:root "$tmp"
    mv -f -- "$tmp" "$RW_PROFILE_JSON_FILE"
)

rw_finish_profile_guidance() {
    rw_write_profile_example
    # Ordinary stdout remains public, including under tee/log collectors.
    if [[ -t 1 ]] && { : >/dev/tty; } 2>/dev/null; then
        rw_print_profile_guidance true
    else
        rw_print_profile_guidance false
        rw_warn "Нет интерактивного терминала: полный профиль с private key сохранён в $RW_PROFILE_JSON_FILE (0600)."
    fi
}

rw_print_profile_guidance() {
    local show_private=${1:-false} safe_values
    rw_ensure_profile_values
    # Allowlist public formats from old and new Xray releases. Unknown future
    # fields stay private by default instead of relying on a redaction blacklist.
    safe_values=$(sed -nE '/^[[:space:]]*([Pp]ublic[[:space:]_-]*[Kk]ey|Password([[:space:]]*\([Pp]ublic[Kk]ey\))?)[[:space:]]*:/p; /^[[:space:]]*Short IDs:/,$p' \
        "$RW_PROFILE_VALUES_FILE")
    cat <<EOF

${RW_BOLD}Данные для панели и Config Profile${RW_RESET}

Node address : ${DOMAIN}
Node port    : ${NODE_PORT}
Panel IP     : ${PANEL_IP}
REALITY target: 127.0.0.1:8443
Hysteria certificateFile: /etc/ssl/hysteria/fullchain.pem
Hysteria keyFile        : /etc/ssl/hysteria/privkey.pem

В записи ноды в панели укажите Node port = ${NODE_PORT} (это API, не порт клиентов).

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
Для этой ноды уже созданы отдельные REALITY privateKey/publicKey и shortIds.
Не вставляйте ключи в репозиторий или журналы.

Публичные значения Xray и предложенные shortIds:
${safe_values}

В актуальном Xray значение "Password (PublicKey)" — это publicKey клиента REALITY.
Hash32 относится к VLESS Encryption и для REALITY не используется.

Исходные ключи и short IDs сохранены в root-файле ${RW_PROFILE_VALUES_FILE}.
Готовый Config Profile с private key: ${RW_PROFILE_JSON_FILE} (root-only, 0600).
Для повторного показа непосредственно в TTY: rw-node profile-guidance --show-private-key
Профиль — основа для новой записи в панели, а не экспорт текущего профиля панели.
clients заполняет Remnawave; fingerprint задайте в Host. Панель автоматически не меняется.
EOF
    if [[ $show_private == true ]]; then
        { : >/dev/tty; } 2>/dev/null || rw_die "Private key можно показать только в интерактивном TTY."
        rw_write_profile_example
        printf '\nВНИМАНИЕ: полный профиль ниже содержит REALITY private key. Не публикуйте его.\n' >/dev/tty
        printf '\nГотовый Config Profile для вставки в панель:\n' >/dev/tty
        cat "$RW_PROFILE_JSON_FILE" >/dev/tty
    fi
}
