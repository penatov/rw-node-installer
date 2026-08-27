#!/usr/bin/env bash

rw_sysctl_supported() {
    local key=$1 path
    path=/proc/sys/${key//./\/}
    [[ -e $path ]]
}

rw_sysctl_line() {
    local key=$1 value=$2
    rw_sysctl_supported "$key" && printf '%s = %s\n' "$key" "$value"
}

rw_detect_tuning_profile() {
    local mem_kb cpu
    mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
    cpu=$(nproc)
    RW_MEMORY_MB=$((mem_kb / 1024))
    RW_CPU_COUNT=$cpu
    if (( RW_MEMORY_MB >= 32768 || cpu >= 16 )); then
        RW_TUNING_PROFILE=large
        RW_NET_BACKLOG=131072
        RW_SOCKET_MAX=67108864
        RW_TCP_MAX=33554432
        RW_CONNTRACK_MAX=2097152
        RW_FILE_MAX=4194304
    elif (( RW_MEMORY_MB >= 8192 || cpu >= 4 )); then
        RW_TUNING_PROFILE=medium
        RW_NET_BACKLOG=65536
        RW_SOCKET_MAX=33554432
        RW_TCP_MAX=16777216
        RW_CONNTRACK_MAX=1048576
        RW_FILE_MAX=2097152
    else
        RW_TUNING_PROFILE=small
        RW_NET_BACKLOG=32768
        RW_SOCKET_MAX=16777216
        RW_TCP_MAX=8388608
        RW_CONNTRACK_MAX=262144
        RW_FILE_MAX=1048576
    fi
    export RW_MEMORY_MB RW_CPU_COUNT RW_TUNING_PROFILE RW_NET_BACKLOG \
        RW_SOCKET_MAX RW_TCP_MAX RW_CONNTRACK_MAX RW_FILE_MAX
}

rw_configure_modules() {
    local file=/etc/modules-load.d/rw-node.conf
    modprobe sch_fq >/dev/null 2>&1 || true
    modprobe tcp_bbr >/dev/null 2>&1 || true
    {
        printf '%s\n' "$RW_OWNER_MARKER"
        modinfo sch_fq >/dev/null 2>&1 && printf 'sch_fq\n'
        modinfo tcp_bbr >/dev/null 2>&1 && printf 'tcp_bbr\n'
    } >"${file}.tmp"
    if ! rw_atomic_install "${file}.tmp" "$file" 0644; then
        rm -f "${file}.tmp"
        return 1
    fi
    rm -f "${file}.tmp"
}

rw_render_sysctl() {
    local file=/etc/sysctl.d/90-rw-node.conf
    rw_backup_file "$file"
    {
        printf '%s\n' "$RW_OWNER_MARKER"
        rw_sysctl_line fs.file-max "$RW_FILE_MAX"
        rw_sysctl_line net.core.somaxconn 65535
        rw_sysctl_line net.core.netdev_max_backlog "$RW_NET_BACKLOG"
        rw_sysctl_line net.core.rmem_max "$RW_SOCKET_MAX"
        rw_sysctl_line net.core.wmem_max "$RW_SOCKET_MAX"
        rw_sysctl_line net.core.rps_sock_flow_entries 65536
        rw_sysctl_line net.ipv4.tcp_max_syn_backlog 65536
        rw_sysctl_line net.ipv4.tcp_rmem "4096 131072 $RW_TCP_MAX"
        rw_sysctl_line net.ipv4.tcp_wmem "4096 65536 $RW_TCP_MAX"
        rw_sysctl_line net.ipv4.udp_rmem_min 16384
        rw_sysctl_line net.ipv4.tcp_syncookies 1
        rw_sysctl_line net.ipv4.tcp_mtu_probing 1
        if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
            rw_sysctl_line net.ipv4.tcp_congestion_control bbr
            rw_sysctl_line net.core.default_qdisc fq
        fi
        rw_sysctl_line net.netfilter.nf_conntrack_max "$RW_CONNTRACK_MAX"
        rw_sysctl_line net.ipv4.conf.all.accept_redirects 0
        rw_sysctl_line net.ipv4.conf.default.accept_redirects 0
        rw_sysctl_line net.ipv6.conf.all.accept_redirects 0
        rw_sysctl_line net.ipv6.conf.default.accept_redirects 0
        rw_sysctl_line net.ipv4.conf.all.send_redirects 0
        rw_sysctl_line net.ipv4.conf.default.send_redirects 0
        rw_sysctl_line net.ipv4.conf.all.accept_source_route 0
        rw_sysctl_line net.ipv4.conf.default.accept_source_route 0
        rw_sysctl_line net.ipv6.conf.all.accept_source_route 0
        rw_sysctl_line net.ipv6.conf.default.accept_source_route 0
        rw_sysctl_line net.ipv4.conf.all.rp_filter 2
        rw_sysctl_line net.ipv4.conf.default.rp_filter 2
        rw_sysctl_line vm.swappiness 10
        rw_sysctl_line vm.vfs_cache_pressure 50
    } >"${file}.tmp"
    if ! rw_atomic_install "${file}.tmp" "$file" 0644; then
        rm -f "${file}.tmp"
        return 1
    fi
    rm -f "${file}.tmp"
    if ! sysctl --load "$file"; then
        rw_warn "Часть sysctl отклонена ядром/гипервизором; установка продолжится с поддержанными параметрами."
    fi
}

rw_configure_swap() {
    local swap_file=/swapfile size_mb available_mb fstab=/etc/fstab
    if swapon --noheadings --show=NAME 2>/dev/null | grep -q .; then
        rw_info "Swap уже настроен; существующую конфигурацию не изменяю."
        return 0
    fi
    if [[ -e $swap_file ]]; then
        rw_warn "$swap_file уже существует, но не активен; не перезаписываю чужой файл и пропускаю создание swap."
        return 0
    fi
    if (( RW_MEMORY_MB >= 32768 )); then size_mb=2048
    elif (( RW_MEMORY_MB >= 8192 )); then size_mb=2048
    else size_mb=1024
    fi
    available_mb=$(df -Pm / | awk 'NR == 2 {print $4}')
    if [[ ! $available_mb =~ ^[0-9]+$ ]] || (( available_mb < size_mb + 512 )); then
        rw_warn "Недостаточно свободного места для безопасного создания ${size_mb} MiB swap; пропускаю."
        return 0
    fi
    rw_log "Создаю ${size_mb} MiB swapfile (существующий swap отсутствует)..."
    if ! fallocate -l "${size_mb}M" "$swap_file" 2>/dev/null && \
       ! dd if=/dev/zero of="$swap_file" bs=1M count="$size_mb" status=progress; then
        rm -f -- "$swap_file"
        rw_warn "Не удалось создать swapfile; установка продолжится без swap."
        return 0
    fi
    chmod 0600 "$swap_file"
    if ! mkswap "$swap_file" >/dev/null || ! swapon "$swap_file"; then
        swapoff "$swap_file" >/dev/null 2>&1 || true
        rm -f -- "$swap_file"
        rw_warn "Гипервизор не разрешил активировать swapfile; установка продолжится без swap."
        return 0
    fi
    if ! grep -Eq '^/swapfile[[:space:]]' "$fstab"; then
        rw_backup_file "$fstab"
        printf '/swapfile none swap sw 0 0\n' >>"$fstab"
    fi
    printf '%s\n' "$swap_file" >"${RW_STATE_DIR}/created-swapfile"
}

rw_configure_journald() {
    local file=/etc/systemd/journald.conf.d/90-rw-node.conf
    install -d -m 0755 /etc/systemd/journald.conf.d
    rw_backup_file "$file"
    cat >"${file}.tmp" <<EOF
[Journal]
SystemMaxUse=512M
RuntimeMaxUse=256M
MaxRetentionSec=7day
RateLimitIntervalSec=30s
RateLimitBurst=10000
Compress=yes
EOF
    if ! rw_atomic_install "${file}.tmp" "$file" 0644; then
        rm -f "${file}.tmp"
        return 1
    fi
    rm -f "${file}.tmp"
    systemctl restart systemd-journald.service || return 1
}

rw_configure_ssh_safely() {
    local file=/etc/ssh/sshd_config.d/90-rw-node.conf previous
    [[ -d /etc/ssh/sshd_config.d ]] || install -d -m 0755 /etc/ssh/sshd_config.d
    rw_backup_file "$file"
    cat >"${file}.tmp" <<EOF
${RW_OWNER_MARKER}
MaxAuthTries 4
LoginGraceTime 30
PermitEmptyPasswords no
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
    previous=$(mktemp /run/rw-node-sshd.XXXXXX)
    if [[ -r $file ]]; then cp -a -- "$file" "$previous"; else : >"$previous"; fi
    rw_atomic_install "${file}.tmp" "$file" 0644
    rm -f "${file}.tmp"
    if ! sshd -t || ! systemctl reload ssh.service; then
        if [[ -s $previous ]]; then cp -a -- "$previous" "$file"; else rm -f -- "$file"; fi
        rm -f -- "$previous"
        sshd -t >/dev/null 2>&1 && systemctl reload ssh.service >/dev/null 2>&1 || true
        rw_die "Новая SSH-конфигурация не прошла проверку; предыдущая восстановлена."
    fi
    rm -f -- "$previous"
}

rw_install_nic_tuning() {
    rw_atomic_install "$RW_INSTALL_DIR/systemd/rw-node-nic-tune.service" \
        /etc/systemd/system/rw-node-nic-tune.service 0644 || return 1
    systemctl daemon-reload || return 1
    systemctl enable --now rw-node-nic-tune.service >/dev/null || return 1
}

rw_configure_tuning() {
    rw_detect_tuning_profile
    rw_log "Профиль производительности: $RW_TUNING_PROFILE (${RW_CPU_COUNT} CPU, ${RW_MEMORY_MB} MiB RAM)."
    rw_configure_modules || rw_warn "Не удалось сохранить список модулей BBR/fq; продолжаю без автозагрузки."
    rw_render_sysctl
    rw_configure_swap
    rw_configure_journald || rw_warn "Не удалось применить ограничения journald; установка продолжается."
    rw_configure_ssh_safely
    rw_install_nic_tuning || rw_warn "NIC/RPS tuning не применён; это не влияет на корректность ноды."
}
