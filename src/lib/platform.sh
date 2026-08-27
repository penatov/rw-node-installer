#!/usr/bin/env bash

rw_check_platform() {
    [[ -r /etc/os-release ]] || rw_die "Не найден /etc/os-release."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == debian ]] || rw_die "Поддерживается только Debian 12/13. Обнаружено: ${PRETTY_NAME:-unknown}."
    [[ ${VERSION_ID:-} == 12 || ${VERSION_ID:-} == 13 ]] || rw_die "Поддерживается только Debian 12/13. Обнаружена версия ${VERSION_ID:-unknown}."
    [[ $(dpkg --print-architecture) == amd64 || $(dpkg --print-architecture) == arm64 ]] || \
        rw_die "Поддерживаются архитектуры amd64 и arm64."
    [[ -d /run/systemd/system ]] || rw_die "Требуется systemd."
    RW_DEBIAN_CODENAME=${VERSION_CODENAME:-}
    [[ -n $RW_DEBIAN_CODENAME ]] || rw_die "Не удалось определить кодовое имя Debian."
    export RW_DEBIAN_CODENAME
}

rw_apt_install_base() {
    export DEBIAN_FRONTEND=noninteractive
    rw_log "Обновляю индекс APT и устанавливаю базовые зависимости..."
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg jq python3 nftables iproute2 ethtool \
        procps psmisc openssl dnsutils util-linux coreutils findutils kmod \
        systemd-timesyncd unattended-upgrades apt-transport-https openssh-server
}

rw_install_docker_repository() {
    local arch source_file key_file key_tmp source_tmp
    arch=$(dpkg --print-architecture)
    key_file=/etc/apt/keyrings/docker.asc
    source_file=/etc/apt/sources.list.d/docker.list
    install -d -m 0755 /etc/apt/keyrings
    rw_backup_file "$key_file"
    rw_backup_file "$source_file"
    key_tmp=$(mktemp /etc/apt/keyrings/.rw-docker-key.XXXXXX)
    source_tmp=$(mktemp /etc/apt/sources.list.d/.rw-docker-list.XXXXXX)
    curl -fsSL https://download.docker.com/linux/debian/gpg -o "$key_tmp"
    gpg --show-keys "$key_tmp" >/dev/null
    install -m 0644 "$key_tmp" "$key_file"
    printf '%s\n' \
        "deb [arch=${arch} signed-by=${key_file}] https://download.docker.com/linux/debian ${RW_DEBIAN_CODENAME} stable" \
        >"$source_tmp"
    rw_atomic_install "$source_tmp" "$source_file" 0644
    rm -f "$key_tmp" "$source_tmp"
}

rw_install_caddy_repository() {
    local key_file source_file armored_tmp key_tmp source_tmp
    key_file=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
    source_file=/etc/apt/sources.list.d/caddy-stable.list
    rw_backup_file "$key_file"
    rw_backup_file "$source_file"
    install -d -m 0755 "$(dirname "$key_file")" "$(dirname "$source_file")"
    armored_tmp=$(mktemp /tmp/rw-caddy-key.XXXXXX)
    key_tmp=$(mktemp "$(dirname "$key_file")/.rw-caddy-key.XXXXXX")
    source_tmp=$(mktemp "$(dirname "$source_file")/.rw-caddy-list.XXXXXX")
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$armored_tmp"
    gpg --batch --yes --dearmor -o "$key_tmp" "$armored_tmp"
    gpg --show-keys "$key_tmp" >/dev/null
    install -m 0644 "$key_tmp" "$key_file"
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o "$source_tmp"
    rw_atomic_install "$source_tmp" "$source_file" 0644
    rm -f "$armored_tmp" "$key_tmp" "$source_tmp"
}

rw_install_runtime_packages() {
    export DEBIAN_FRONTEND=noninteractive
    rw_log "Подключаю официальные репозитории Docker и Caddy..."
    rw_install_docker_repository
    rw_install_caddy_repository
    apt-get update
    apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin caddy
    if ! systemctl enable --now docker.service; then
        rw_error "Docker не запустился; состояние firewall и сервисов:"
        systemctl --no-pager --full status \
            rw-node-firewall.service containerd.service docker.service >&2 || true
        journalctl -b --no-pager -n 120 \
            -u rw-node-firewall.service -u containerd.service -u docker.service >&2 || true
        rw_die "Не удалось запустить docker.service. Диагностика напечатана выше."
    fi
}

rw_configure_security_updates() {
    local file=/etc/apt/apt.conf.d/20auto-upgrades
    rw_backup_file "$file"
    cat >"${file}.tmp" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    rw_atomic_install "${file}.tmp" "$file" 0644
    rm -f "${file}.tmp"
    systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1 || true
}

rw_assert_clean_firewall_baseline() {
    local service state
    for service in ufw.service firewalld.service nftables.service; do
        rw_service_exists "$service" || continue
        if systemctl is-active --quiet "$service"; then
            rw_die "Обнаружен активный $service. Установщик для чистой системы не будет отключать существующий firewall."
        fi
        state=$(systemctl is-enabled "$service" 2>/dev/null || true)
        case "$state" in
            enabled|enabled-runtime|linked|linked-runtime|alias)
                rw_die "Обнаружен включённый $service. Отключите или перенесите его правила вручную перед установкой."
                ;;
        esac
    done
}
