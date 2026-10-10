#!/usr/bin/env bash

rw_apt_get() {
    local timeout=${RW_APT_LOCK_TIMEOUT:-600}
    [[ $timeout =~ ^[0-9]+$ ]] || rw_die "RW_APT_LOCK_TIMEOUT должен быть числом секунд."
    # Debian may start apt-daily/unattended-upgrades at boot or immediately
    # after package installation. APT's native fcntl-lock wait avoids both a
    # race-prone process poll and the dangerous practice of deleting lock files.
    apt-get -o "DPkg::Lock::Timeout=${timeout}" "$@"
}

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
    rw_prepare_caddy_source
    rw_log "Обновляю индекс APT и устанавливаю базовые зависимости..."
    rw_apt_get update
    rw_apt_get install -y --no-install-recommends \
        ca-certificates curl gnupg jq mawk nftables iproute2 ethtool \
        procps psmisc openssl dnsutils util-linux coreutils findutils kmod \
        systemd-timesyncd unattended-upgrades apt-transport-https openssh-server
}

rw_prepare_caddy_source() {
    local source_file=${RW_CADDY_APT_SOURCE_FILE:-/etc/apt/sources.list.d/caddy-stable.list} disabled
    case ${RW_CADDY_SOURCE:-apt} in
        apt) return 0 ;;
        github) ;;
        *) rw_die "RW_CADDY_SOURCE должен быть apt или github." ;;
    esac
    # A failed earlier installation leaves this source active. Disable it before
    # the FIRST apt update, not just before installing the runtime packages.
    [[ -e $source_file || -L $source_file ]] || return 0
    [[ -f $source_file && ! -L $source_file ]] || rw_die "Небезопасный APT source: $source_file"
    awk '
        /^[[:space:]]*($|#)/ { next }
        /^[[:space:]]*deb(-src)?[[:space:]]/ && /https:\/\/dl\.cloudsmith\.io\/public\/caddy\/stable\/deb\/debian([[:space:]]|$)/ { found=1; next }
        { bad=1 }
        END { exit !(found && !bad) }
    ' "$source_file" || rw_die "В $source_file есть неизвестные записи; не отключаю их автоматически."
    rw_backup_file "$source_file"
    disabled="${source_file}.disabled-$(date +%s)-$$"
    [[ ! -e $disabled && ! -L $disabled ]] || rw_die "Backup уже существует: $disabled"
    mv -- "$source_file" "$disabled"
    rw_warn "Cloudsmith отключён для APT; исходный список сохранён: $disabled"
}

rw_install_caddy_github() (
    # Fixed release and independently recorded digests: never execute a package
    # just because an unverified checksum downloaded alongside it matches.
    local version=2.11.7 arch digest installed work package
    arch=$(dpkg --print-architecture)
    case $arch in
        amd64) digest=a22b914ffd1958da42bc7ab13b7b62c6100634e0798ab594891d2d61d53ba749 ;;
        arm64) digest=ca8ae5a50439642d7672344b4ec64e47cbddf81beb5da302420a78522eb5a47e ;;
        *) rw_die "Неподдерживаемая архитектура Caddy: $arch" ;;
    esac
    installed=$(dpkg-query -W -f='${Status} ${Version}' caddy 2>/dev/null || true)
    if [[ $installed == 'install ok installed '* ]] && \
       dpkg --compare-versions "${installed#install ok installed }" ge "$version"; then
        rw_info "Caddy ${installed#install ok installed } уже установлен; downgrade не выполняется."
        exit 0
    fi
    work=$(mktemp -d /tmp/rw-caddy-release.XXXXXX)
    package="$work/caddy.deb"
    trap 'rm -f -- "$package"; rmdir -- "$work"' EXIT
    rw_log "Устанавливаю официальный Caddy ${version} с GitHub (SHA-256 закреплена)..."
    curl -fL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 300 --retry 3 \
        "https://github.com/caddyserver/caddy/releases/download/v${version}/caddy_${version}_linux_${arch}.deb" \
        -o "$package" || rw_die "Не удалось загрузить официальный пакет Caddy с GitHub."
    printf '%s  %s\n' "$digest" "$package" | sha256sum --check --status || \
        rw_die "SHA-256 пакета Caddy не совпадает. Установка запрещена."
    [[ $(dpkg-deb -f "$package" Package) == caddy && \
       $(dpkg-deb -f "$package" Architecture) == "$arch" && \
       $(dpkg-deb -f "$package" Version) == "$version" ]] || \
        rw_die "Метаданные DEB-пакета Caddy не соответствуют ожидаемым."
    rw_apt_get install -y --no-install-recommends "$package"
)

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
    gpg --batch --with-colons --show-keys "$key_tmp" >/dev/null 2>&1
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
    gpg --batch --with-colons --show-keys "$key_tmp" >/dev/null 2>&1
    install -m 0644 "$key_tmp" "$key_file"
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o "$source_tmp"
    rw_atomic_install "$source_tmp" "$source_file" 0644
    rm -f "$armored_tmp" "$key_tmp" "$source_tmp"
}

rw_install_runtime_packages() {
    export DEBIAN_FRONTEND=noninteractive
    rw_log "Подключаю официальный репозиторий Docker и источник Caddy..."
    rw_install_docker_repository
    if [[ ${RW_CADDY_SOURCE:-apt} == github ]]; then
        rw_prepare_caddy_source
    else
        rw_install_caddy_repository
    fi
    rw_apt_get update
    if [[ ${RW_CADDY_SOURCE:-apt} == github ]]; then
        rw_install_caddy_github
        rw_warn "Caddy установлен с GitHub: новые версии не будут поступать через Cloudsmith, пока его APT source отключён."
    fi
    rw_apt_get install -y --no-install-recommends \
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
