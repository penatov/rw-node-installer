#!/usr/bin/env bash

rw_render_caddyfile() {
    local file=$RW_CADDYFILE email_line tmp
    rw_backup_file "$file"
    email_line=""
    [[ -n ${ACME_EMAIL:-} ]] && email_line="    email \"${ACME_EMAIL}\""
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
}

http:// {
    bind 0.0.0.0 ::
    redir https://${DOMAIN}{uri} 308
}

https://${DOMAIN}:8443 {
    bind 127.0.0.1 ::1

    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }

    root * ${RW_SITE_DIR}
    encode zstd gzip

    header {
        -X-Powered-By
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

rw_caddy_configure() {
    install -d -m 0750 -o caddy -g caddy "$RW_CADDY_LOG_DIR"
    install -d -m 0700 -o caddy -g caddy "$RW_CADDY_STORAGE"
    rw_render_caddyfile
    caddy fmt --overwrite "$RW_CADDYFILE"
    caddy validate --config "$RW_CADDYFILE" --adapter caddyfile
    systemctl enable caddy.service >/dev/null
    systemctl restart caddy.service
    rw_wait_until 30 2 "Caddy не стал active" systemctl is-active --quiet caddy.service
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
