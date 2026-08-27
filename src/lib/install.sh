#!/usr/bin/env bash

rw_install_bundle() {
    local source_root=$1 runtime_source generator staging old
    local staging_parent=${RW_INSTALL_STAGING_PARENT:-/usr/local/lib}
    local sbin_dir=${RW_SBIN_DIR:-/usr/local/sbin}
    if [[ -d $source_root/src/lib ]]; then
        runtime_source=$source_root/src
        generator=$source_root/tools/site_generator.py
    else
        runtime_source=$source_root
        generator=$source_root/site_generator.py
    fi
    [[ -r $runtime_source/lib/common.sh && -r $generator ]] || \
        rw_die "Неполный source bundle: $source_root"
    staging=$(mktemp -d "$staging_parent/.rw-node-installer.XXXXXX")
    install -d -m 0755 "$staging"/{bin,lib,scripts,systemd,assets/site,assets/fonts,docs}
    cp -a "$runtime_source/bin/." "$staging/bin/"
    cp -a "$runtime_source/lib/." "$staging/lib/"
    cp -a "$runtime_source/scripts/." "$staging/scripts/"
    cp -a "$runtime_source/systemd/." "$staging/systemd/"
    cp -a "$source_root/assets/site/." "$staging/assets/site/"
    cp -a "$source_root/assets/fonts/." "$staging/assets/fonts/"
    cp -a "$source_root/docs/." "$staging/docs/" 2>/dev/null || true
    install -m 0644 "$generator" "$staging/site_generator.py"
    install -m 0644 "$source_root/VERSION" "$staging/VERSION"
    chmod 0755 "$staging/bin/rw-node" "$staging"/scripts/*

    old="${RW_INSTALL_DIR}.old"
    rm -rf -- "$old"
    if [[ -d $RW_INSTALL_DIR ]]; then mv "$RW_INSTALL_DIR" "$old"; fi
    mv "$staging" "$RW_INSTALL_DIR"
    rm -rf -- "$old"
    install -m 0755 "$RW_INSTALL_DIR/bin/rw-node" "$sbin_dir/rw-node"
}

rw_collect_install_inputs() {
    local existing_domain="" existing_panel="" existing_admin="" existing_email=""
    local arg
    DOMAIN=${RW_DOMAIN:-}
    SECRET_KEY=${RW_SECRET_KEY:-}
    PANEL_IP=${RW_PANEL_IP:-}
    ADMIN_IPS=${RW_ADMIN_IPS:-}
    ACME_EMAIL=${RW_ACME_EMAIL:-}
    NODE_PORT=2222

    if rw_load_config; then
        existing_domain=${DOMAIN:-}
        existing_panel=${PANEL_IP:-}
        existing_admin=${ADMIN_IPS:-}
        existing_email=${ACME_EMAIL:-}
        DOMAIN=${RW_DOMAIN:-$existing_domain}
        PANEL_IP=${RW_PANEL_IP:-$existing_panel}
        ADMIN_IPS=${RW_ADMIN_IPS:-$existing_admin}
        ACME_EMAIL=${RW_ACME_EMAIL:-$existing_email}
    fi

    while (($#)); do
        arg=$1
        shift
        case "$arg" in
            --domain) [[ $# -gt 0 ]] || rw_die "--domain требует значение"; DOMAIN=$1; shift ;;
            --panel-ip) [[ $# -gt 0 ]] || rw_die "--panel-ip требует значение"; PANEL_IP=$1; shift ;;
            --admin-ips) [[ $# -gt 0 ]] || rw_die "--admin-ips требует значение"; ADMIN_IPS=$1; shift ;;
            --acme-email) [[ $# -gt 0 ]] || rw_die "--acme-email требует значение"; ACME_EMAIL=$1; shift ;;
            *) rw_die "Неизвестный параметр install: $arg" ;;
        esac
    done

    [[ -n $DOMAIN ]] || rw_tty_read DOMAIN "Домен ноды"
    DOMAIN=$(rw_normalize_domain "$DOMAIN")
    if [[ -z $SECRET_KEY ]]; then rw_tty_read_secret SECRET_KEY "SECRET_KEY Remnawave"; fi
    [[ -n $PANEL_IP ]] || rw_tty_read PANEL_IP "IP-адрес панели"
    [[ -n $ADMIN_IPS ]] || rw_tty_read ADMIN_IPS "IP/CIDR администраторов через запятую"
    if [[ -z ${ACME_EMAIL+x} || -z $ACME_EMAIL ]]; then
        rw_tty_read ACME_EMAIL "Email ACME (можно оставить пустым)" "$existing_email"
    fi

    rw_validate_domain "$DOMAIN" || rw_die "Некорректный домен: $DOMAIN"
    rw_validate_secret "$SECRET_KEY" || rw_die "SECRET_KEY должен быть одной строкой длиной не менее 16 символов."
    rw_validate_single_ip "$PANEL_IP" || rw_die "IP панели должен быть одним IPv4 или IPv6 адресом без CIDR."
    ADMIN_IPS=$(rw_normalize_ip_list "$ADMIN_IPS") || rw_die "Некорректный список административных IP."
    if rw_ip_list_has_world "$ADMIN_IPS"; then
        rw_die "Административный allowlist не может содержать 0.0.0.0/0 или ::/0."
    fi
    rw_validate_email "$ACME_EMAIL" || rw_die "Некорректный email ACME."

    SITE_SEED=${SITE_SEED:-$(openssl rand -hex 24)}
    INSTALLER_REPOSITORY=${RW_INSTALLER_REPO:-${INSTALLER_REPOSITORY:-}}
    INSTALLER_REF=${RW_INSTALLER_REF:-${INSTALLER_REF:-local}}
}

rw_preflight_ports() {
    local port owner
    for port in 80 443 8443 "$NODE_PORT"; do
        owner=$(ss -H -lntup "( sport = :${port} )" 2>/dev/null || true)
        [[ -z $owner ]] && continue
        if grep -Eq 'caddy|xray|remnanode|docker-proxy' <<<"$owner" && [[ -r $RW_CONFIG_FILE ]]; then
            continue
        fi
        rw_die "Порт $port уже занят сторонним процессом: $owner"
    done
}

rw_install_command() {
    local source_root=$1
    shift
    rw_require_root
    rw_acquire_lock
    rw_check_platform
    rw_assert_clean_firewall_baseline
    install -d -m 0700 "$RW_STATE_DIR" "$RW_BACKUP_DIR"
    rw_apt_install_base
    rw_assert_clean_firewall_baseline
    rw_collect_install_inputs "$@"
    rw_validate_dns "$DOMAIN"
    rw_preflight_ports

    if [[ -n ${SSH_CONNECTION:-} ]]; then
        current_ip=${SSH_CONNECTION%% *}
        if ! rw_ip_in_list "$current_ip" "${PANEL_IP},${ADMIN_IPS}"; then
            rw_warn "Текущий SSH IP $current_ip отсутствует в постоянном allowlist. Эта сессия сохранится, но новое подключение будет закрыто."
        fi
    fi

    rw_install_bundle "$source_root"
    rw_write_config

    rw_resolve_pending_firewall_transaction
    rw_render_firewall "$RW_FIREWALL_CANDIDATE"
    rw_install_firewall_service
    rw_apply_firewall_safely "$RW_FIREWALL_CANDIDATE"

    rw_install_runtime_packages
    rw_configure_security_updates
    rw_generate_site false
    rw_verify_site_assets || rw_die "Проверка сгенерированного сайта или локальных шрифтов не пройдена."

    rw_caddy_configure
    rw_install_cert_sync_units
    rw_caddy_wait_for_certificate
    rw_caddy_local_check || rw_die "Локальный Caddy self-steal не отвечает корректно."

    rw_write_node_env "$SECRET_KEY"
    unset SECRET_KEY
    rw_render_compose
    rw_start_remnanode
    rw_install_node_units
    rw_configure_tuning

    rw_log "Запускаю итоговую диагностику..."
    if ! rw_diagnose_command; then
        rw_warn "Установка завершена, но диагностика нашла ошибки. Выполните: rw-node diagnose"
    fi
    rw_print_profile_guidance
    printf '\nУправление: rw-node status | diagnose | regenerate-site | update-node | firewall\n'
}
