#!/usr/bin/env bash

rw_restore_first_backup() {
    local path=$1 manifest="${RW_STATE_DIR}/backup-manifest.tsv" backup
    [[ -r $manifest ]] || return 1
    backup=$(awk -F '\t' -v p="$path" '$1 == p {print $2; exit}' "$manifest")
    [[ -n $backup && ( -e $backup || -L $backup ) ]] || return 1
    install -d -m 0755 "$(dirname "$path")"
    cp -a -- "$backup" "$path"
}

rw_safe_remove_tree() {
    local target=$1
    case "$target" in
        /opt/remnanode|/var/www/rw-node-site|/etc/rw-node-installer|/var/lib/rw-node-installer|/etc/ssl/hysteria|/usr/local/lib/rw-node-installer|/var/lib/caddy/rw-node-storage)
            [[ -n $target && $target != / ]] || return 1
            rm -rf --one-file-system -- "$target"
            ;;
        *) rw_die "Отказ удалять неожиданный путь: $target" ;;
    esac
}

rw_uninstall_command() {
    local purge=false assume=false arg
    for arg in "$@"; do
        case "$arg" in
            --purge-packages) purge=true ;;
            --yes|-y) assume=true ;;
            *) rw_die "Неизвестный параметр uninstall: $arg" ;;
        esac
    done
    rw_require_root
    rw_acquire_lock
    rw_load_config || rw_die "Установка не найдена."
    if [[ $assume != true ]] && ! rw_confirm "Удалить Remnawave Node, сайт, сертификаты и правила rw-node?" no; then
        rw_info "Удаление отменено."
        return 0
    fi

    systemctl disable --now rw-node-auto-update.timer rw-node-cert-sync.timer rw-node-nic-tune.service \
        >/dev/null 2>&1 || true
    if [[ -f ${RW_PROJECT_DIR}/docker-compose.yml ]]; then
        (cd "$RW_PROJECT_DIR" && docker compose down) || true
    fi
    systemctl disable --now caddy.service >/dev/null 2>&1 || true
    nft delete table inet "$RW_FIREWALL_TABLE" >/dev/null 2>&1 || true
    systemctl disable rw-node-firewall.service >/dev/null 2>&1 || true

    rm -f /etc/systemd/system/rw-node-firewall.service \
        /etc/systemd/system/rw-node-cert-sync.service /etc/systemd/system/rw-node-cert-sync.timer \
        /etc/systemd/system/rw-node-auto-update.service /etc/systemd/system/rw-node-auto-update.timer \
        /etc/systemd/system/rw-node-nic-tune.service \
        /etc/systemd/system/docker.service.d/20-rw-node-firewall.conf \
        /etc/systemd/system/caddy.service.d/20-rw-node-firewall.conf \
        /etc/systemd/system/ssh.service.d/20-rw-node-firewall.conf \
        /etc/sysctl.d/90-rw-node.conf /etc/modules-load.d/rw-node.conf \
        /etc/systemd/journald.conf.d/90-rw-node.conf /etc/ssh/sshd_config.d/90-rw-node.conf \
        /usr/local/sbin/rw-node

    if [[ -s ${RW_STATE_DIR}/created-swapfile ]]; then
        swap_file=$(<"${RW_STATE_DIR}/created-swapfile")
        if [[ $swap_file == /swapfile ]]; then
            swapoff /swapfile >/dev/null 2>&1 || true
            sed -i '\|^/swapfile[[:space:]]|d' /etc/fstab
            rm -f /swapfile
        fi
    fi

    rw_restore_first_backup /etc/caddy/Caddyfile || rm -f /etc/caddy/Caddyfile
    rw_restore_first_backup /etc/apt/apt.conf.d/20auto-upgrades || true

    rw_safe_remove_tree "$RW_PROJECT_DIR"
    rw_safe_remove_tree "$RW_SITE_DIR"
    rw_safe_remove_tree "$RW_CERT_DIR"
    rw_safe_remove_tree /var/lib/caddy/rw-node-storage

    if [[ $purge == true ]]; then
        apt-get purge -y caddy docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
        apt-get autoremove -y || true
    fi

    systemctl daemon-reload
    systemctl restart systemd-journald.service >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
    rw_safe_remove_tree "$RW_CONFIG_DIR"
    rw_safe_remove_tree "$RW_STATE_DIR"
    rw_safe_remove_tree "$RW_INSTALL_DIR"
    rw_log "Удаление завершено. Пакеты Docker/Caddy $([[ $purge == true ]] && echo удалены || echo сохранены)."
}
