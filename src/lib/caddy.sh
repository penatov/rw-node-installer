#!/usr/bin/env bash

rw_render_caddyfile() {
    local file=$RW_CADDYFILE email_line tmp public_bind loopback_bind
    rw_backup_file "$file"
    email_line=""
    [[ -n ${ACME_EMAIL:-} ]] && email_line="    email \"${ACME_EMAIL}\""
    public_bind="0.0.0.0"
    loopback_bind="127.0.0.1"
    if rw_ipv6_loopback_available; then
        public_bind+=" ::"
        loopback_bind+=" ::1"
    fi
    tmp=$(rw_mktemp_near "$file")
    cat >"$tmp" <<EOF
${RW_OWNER_MARKER}
{
${email_line}
    admin off
    http_port 80
    https_port 8443
    default_sni ${DOMAIN}
    auto_https disable_redirects
    storage file_system ${RW_CADDY_STORAGE}
    servers {
        protocols h1 h2
    }
}

http:// {
    bind ${public_bind}
    header -Server
    redir https://${DOMAIN}{uri} 308
}

https://${DOMAIN}:8443 {
    bind ${loopback_bind}

    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }

    root * ${RW_SITE_DIR}
    encode zstd gzip

    header {
        -X-Powered-By
        -Server
        -Alt-Svc
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "camera=(), microphone=(), geolocation=()"
    }

    handle /favicon.ico {
        rewrite * /favicon.svg
        file_server
    }

    file_server

    log {
        output file ${RW_CADDY_LOG_DIR}/rw-node-access.log {
            mode 0640
            roll_size 25MiB
            roll_keep 3
            roll_keep_for 168h
        }
        format json
    }
}
EOF
    rw_atomic_install "$tmp" "$file" 0644
    rm -f "$tmp"
}

rw_install_cert_sync_units() {
    local name
    for name in rw-node-cert-sync.service rw-node-cert-sync.timer; do
        rw_atomic_install "$RW_INSTALL_DIR/systemd/$name" "/etc/systemd/system/$name" 0644
    done
    systemctl daemon-reload
    systemctl enable rw-node-cert-sync.timer >/dev/null
}

rw_prepare_caddy_runtime() {
    local access_log="${RW_CADDY_LOG_DIR}/rw-node-access.log" caddy_owner
    [[ ! -L $RW_CADDY_LOG_DIR ]] || rw_die "Каталог логов Caddy не может быть symlink: $RW_CADDY_LOG_DIR"
    [[ ! -L $RW_CADDY_STORAGE ]] || rw_die "Storage Caddy не может быть symlink: $RW_CADDY_STORAGE"
    install -d -m 0750 -o caddy -g caddy "$RW_CADDY_LOG_DIR"
    install -d -m 0700 -o caddy -g caddy "$RW_CADDY_STORAGE"

    # Older installer revisions validated Caddy as root and therefore created
    # this 0640 file as root:root. Remove only that managed path so validation
    # under the real service identity can recreate it with correct ownership.
    if [[ -L $access_log ]]; then
        rm -f -- "$access_log"
    elif [[ -e $access_log ]]; then
        [[ -f $access_log ]] || rw_die "Ожидался обычный файл лога: $access_log"
        caddy_owner="$(id -u caddy):$(id -g caddy)"
        if [[ $(stat -c '%u:%g' -- "$access_log") != "$caddy_owner" ]]; then
            rw_warn "Исправляю владельца ранее созданного Caddy access log."
            rm -f -- "$access_log"
        else
            chmod 0640 "$access_log"
        fi
    fi
}

rw_caddy_diagnostics() {
    systemctl --no-pager --full status caddy.service rw-node-firewall.service >&2 || true
    journalctl -b -u caddy.service --no-pager -n 120 | rw_redact >&2 || true
}

rw_caddy_configure() {
    rw_prepare_caddy_runtime
    rw_render_caddyfile
    caddy fmt --overwrite "$RW_CADDYFILE"
    chmod 0644 "$RW_CADDYFILE"
    if ! runuser -u caddy -- env HOME=/var/lib/caddy \
        XDG_DATA_HOME=/var/lib/caddy/.local/share \
        XDG_CONFIG_HOME=/var/lib/caddy/.config \
        /usr/bin/caddy validate --config "$RW_CADDYFILE" --adapter caddyfile; then
        rw_die "Caddyfile не прошёл проверку от пользователя caddy."
    fi
    systemctl enable caddy.service >/dev/null
    if ! systemctl restart caddy.service; then
        rw_caddy_diagnostics
        rw_die "Не удалось перезапустить caddy.service."
    fi
    if ! rw_wait_until 30 2 "Caddy не стал active" systemctl is-active --quiet caddy.service; then
        rw_caddy_diagnostics
        rw_die "caddy.service завершился после запуска."
    fi
}

rw_caddy_wait_for_certificate() {
    rw_log "Ожидаю сертификат Caddy через ACME HTTP-01..."
    if ! rw_wait_until 300 5 "сертификат Caddy для $DOMAIN не получен" \
        rw_caddy_try_cert_sync; then
        journalctl -u caddy.service --no-pager -n 80 | rw_redact >&2 || true
        rw_die "Caddy не получил или не синхронизировал сертификат. Проверьте DNS и доступность TCP 80."
    fi
    systemctl start rw-node-cert-sync.timer
}

rw_caddy_try_cert_sync() {
    "$RW_INSTALL_DIR/scripts/rw-node-cert-sync" >/dev/null 2>&1
}

rw_caddy_local_check() {
    curl -fsS --resolve "${DOMAIN}:8443:127.0.0.1" "https://${DOMAIN}:8443/" -o /dev/null
}
