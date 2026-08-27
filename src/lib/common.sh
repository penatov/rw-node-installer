#!/usr/bin/env bash

# Shared runtime helpers. This file is sourced by the management CLI and must
# not change shell options on its own.

RW_VERSION="${RW_VERSION:-0.1.0}"
RW_INSTALL_DIR="${RW_INSTALL_DIR:-/usr/local/lib/rw-node-installer}"
RW_CONFIG_DIR="${RW_CONFIG_DIR:-/etc/rw-node-installer}"
RW_CONFIG_FILE="${RW_CONFIG_FILE:-${RW_CONFIG_DIR}/config.env}"
RW_STATE_DIR="${RW_STATE_DIR:-/var/lib/rw-node-installer}"
RW_BACKUP_DIR="${RW_BACKUP_DIR:-${RW_STATE_DIR}/backups}"
RW_PROJECT_DIR="${RW_PROJECT_DIR:-/opt/remnanode}"
RW_SITE_DIR="${RW_SITE_DIR:-/var/www/rw-node-site}"
RW_CERT_DIR="${RW_CERT_DIR:-/etc/ssl/hysteria}"
RW_LOG_DIR="${RW_LOG_DIR:-/var/log/remnanode}"
RW_CADDYFILE="${RW_CADDYFILE:-/etc/caddy/Caddyfile}"
RW_CADDY_STORAGE="${RW_CADDY_STORAGE:-/var/lib/caddy/rw-node-storage}"
RW_CADDY_LOG_DIR="${RW_CADDY_LOG_DIR:-/var/log/caddy}"
RW_LOCK_FILE="${RW_LOCK_FILE:-/run/lock/rw-node-installer.lock}"
# shellcheck disable=SC2034 # consumed by other sourced modules
RW_FIREWALL_TABLE="rw_node_guard"
# shellcheck disable=SC2034 # consumed by other sourced modules
RW_FIREWALL_FILE="${RW_CONFIG_DIR}/firewall.nft"
RW_FIREWALL_CANDIDATE="${RW_FIREWALL_CANDIDATE:-/run/rw-node-firewall-candidate.nft}"
RW_FIREWALL_PENDING="${RW_FIREWALL_PENDING:-/run/rw-node-firewall-pending}"
RW_PROFILE_VALUES_FILE="${RW_PROFILE_VALUES_FILE:-${RW_STATE_DIR}/profile-values.txt}"
RW_OWNER_MARKER="# Managed by rw-node-installer"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RW_BOLD=$'\033[1m'
    RW_RED=$'\033[31m'
    RW_GREEN=$'\033[32m'
    RW_YELLOW=$'\033[33m'
    RW_BLUE=$'\033[34m'
    RW_RESET=$'\033[0m'
else
    # shellcheck disable=SC2034 # colour variables are consumed by sourced modules
    RW_BOLD="" RW_RED="" RW_GREEN="" RW_YELLOW="" RW_BLUE="" RW_RESET=""
fi

rw_log() { printf '%s[+]%s %s\n' "$RW_GREEN" "$RW_RESET" "$*"; }
rw_info() { printf '%s[i]%s %s\n' "$RW_BLUE" "$RW_RESET" "$*"; }
rw_warn() { printf '%s[!]%s %s\n' "$RW_YELLOW" "$RW_RESET" "$*" >&2; }
rw_error() { printf '%s[x]%s %s\n' "$RW_RED" "$RW_RESET" "$*" >&2; }
rw_die() { rw_error "$*"; exit 1; }

rw_has() { command -v "$1" >/dev/null 2>&1; }

rw_require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || rw_die "Запустите команду от root (sudo)."
}

rw_tty_read() {
    local __var=$1 prompt=$2 default=${3-} value
    if [[ ! -r /dev/tty ]]; then
        rw_die "Для интерактивного режима необходим TTY. Используйте параметры командной строки."
    fi
    if [[ -n $default ]]; then
        IFS= read -r -p "$prompt [$default]: " value </dev/tty || true
        value=${value:-$default}
    else
        IFS= read -r -p "$prompt: " value </dev/tty || true
    fi
    printf -v "$__var" '%s' "$value"
}

rw_tty_read_secret() {
    local __var=$1 prompt=$2 value
    [[ -r /dev/tty ]] || rw_die "Для безопасного ввода секрета необходим TTY."
    IFS= read -r -s -p "$prompt: " value </dev/tty || true
    printf '\n' >/dev/tty
    printf -v "$__var" '%s' "$value"
}

rw_confirm() {
    local prompt=$1 default=${2:-yes} answer suffix
    [[ $default == yes ]] && suffix='[Y/n]' || suffix='[y/N]'
    if [[ ! -r /dev/tty ]]; then
        [[ $default == yes ]]
        return
    fi
    IFS= read -r -p "$prompt $suffix " answer </dev/tty || true
    answer=${answer,,}
    if [[ -z $answer ]]; then
        [[ $default == yes ]]
    else
        [[ $answer == y || $answer == yes || $answer == д || $answer == да ]]
    fi
}

rw_acquire_lock() {
    rw_has flock || rw_die "Команда flock не найдена."
    install -d -m 0755 "$(dirname "$RW_LOCK_FILE")"
    exec 9>"$RW_LOCK_FILE"
    flock -n 9 || rw_die "Другая операция rw-node уже выполняется."
}

rw_mktemp_near() {
    local target=$1 directory
    directory=$(dirname "$target")
    [[ -d $directory ]] || install -d -m 0755 "$directory"
    mktemp "$(dirname "$target")/.rw-node.XXXXXX"
}

rw_atomic_install() {
    local source=$1 target=$2 mode=${3:-0644} owner=${4:-root} group=${5:-root}
    local tmp
    tmp=$(rw_mktemp_near "$target") || return 1
    if ! install -m "$mode" -o "$owner" -g "$group" "$source" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
}

rw_backup_file() {
    local path=$1 stamp rel destination
    [[ -e $path || -L $path ]] || return 0
    stamp=${RW_BACKUP_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
    RW_BACKUP_STAMP=$stamp
    rel=${path#/}
    destination="${RW_BACKUP_DIR}/${stamp}/${rel}"
    [[ -e $destination || -L $destination ]] && return 0
    install -d -m 0700 "$(dirname "$destination")"
    cp -a -- "$path" "$destination"
    printf '%s\t%s\n' "$path" "$destination" >>"${RW_STATE_DIR}/backup-manifest.tsv"
}

rw_shell_quote() { printf '%q' "$1"; }

rw_write_config() {
    local tmp
    install -d -m 0700 "$RW_CONFIG_DIR"
    tmp=$(rw_mktemp_near "$RW_CONFIG_FILE")
    {
        printf '%s\n' "$RW_OWNER_MARKER"
        printf 'DOMAIN=%q\n' "$DOMAIN"
        printf 'PANEL_IP=%q\n' "$PANEL_IP"
        printf 'ADMIN_IPS=%q\n' "$ADMIN_IPS"
        printf 'ACME_EMAIL=%q\n' "${ACME_EMAIL:-}"
        printf 'NODE_PORT=%q\n' "${NODE_PORT:-2222}"
        printf 'SITE_SEED=%q\n' "$SITE_SEED"
        printf 'INSTALLER_REPOSITORY=%q\n' "${INSTALLER_REPOSITORY:-}"
        printf 'INSTALLER_REF=%q\n' "${INSTALLER_REF:-local}"
        printf 'INSTALLED_VERSION=%q\n' "$RW_VERSION"
    } >"$tmp"
    chmod 0600 "$tmp"
    chown root:root "$tmp"
    mv -f "$tmp" "$RW_CONFIG_FILE"
}

rw_load_config() {
    [[ -r $RW_CONFIG_FILE ]] || return 1
    # The file is root-owned and written with printf %q by this project.
    # shellcheck disable=SC1090
    source "$RW_CONFIG_FILE"
}

rw_systemctl() {
    systemctl "$@"
}

rw_service_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

rw_is_active() {
    systemctl is-active --quiet "$1"
}

rw_wait_until() {
    local timeout=$1 interval=$2 description=$3
    shift 3
    local started now
    started=$(date +%s)
    while true; do
        if "$@"; then return 0; fi
        now=$(date +%s)
        if (( now - started >= timeout )); then
            rw_warn "Тайм-аут: $description"
            return 1
        fi
        sleep "$interval"
    done
}

rw_redact() {
    sed -E 's/(SECRET_KEY|privateKey|auth)([=: ]+)[^[:space:]]+/\1\2<redacted>/g'
}

rw_repo_root() {
    local source=${BASH_SOURCE[0]}
    cd "$(dirname "$source")/.." && pwd -P
}
