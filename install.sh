#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

die() { printf '[x] %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root: sudo bash install.sh"

script_dir=""
if [[ ${BASH_SOURCE[0]} != /dev/fd/* && ${BASH_SOURCE[0]} != /proc/self/fd/* ]]; then
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)
fi
if [[ -n $script_dir && -x $script_dir/src/bin/rw-node && -r $script_dir/src/lib/common.sh ]]; then
    exec "$script_dir/src/bin/rw-node" install "$@"
fi

repo=${RW_INSTALLER_REPO:-}
ref=${RW_INSTALLER_REF:-}
[[ $repo =~ ^https://github\.com/[^/]+/[^/]+(\.git)?$ ]] || die \
    "Set RW_INSTALLER_REPO=https://github.com/OWNER/REPOSITORY when using the one-line installer."
[[ $ref =~ ^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$ ]] || die \
    "Set RW_INSTALLER_REF to the full immutable 40- or 64-character Git commit ID."
repo=${repo%.git}
slug=${repo#https://github.com/}

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"
tmp_dir=$(mktemp -d /tmp/rw-node-bootstrap.XXXXXX)
trap 'case "$tmp_dir" in /tmp/rw-node-bootstrap.*) rm -rf -- "$tmp_dir";; esac' EXIT

archive="$tmp_dir/source.tar.gz"
curl -fL --proto '=https' --tlsv1.2 --retry 3 \
    "https://codeload.github.com/${slug}/tar.gz/${ref}" -o "$archive"
if [[ -n ${RW_INSTALLER_SHA256:-} ]]; then
    printf '%s  %s\n' "$RW_INSTALLER_SHA256" "$archive" | sha256sum --check --status || die "Checksum mismatch"
fi
mkdir "$tmp_dir/source"
tar -xzf "$archive" --strip-components=1 -C "$tmp_dir/source"
[[ -x $tmp_dir/source/src/bin/rw-node ]] || chmod +x "$tmp_dir/source/src/bin/rw-node"

export RW_INSTALLER_REPO="$repo"
export RW_INSTALLER_REF="$ref"
"$tmp_dir/source/src/bin/rw-node" install "$@"
