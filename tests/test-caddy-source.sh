#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../src/lib/common.sh
source "$ROOT/src/lib/common.sh"
# shellcheck source=../src/lib/platform.sh
source "$ROOT/src/lib/platform.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
export RW_CADDY_APT_SOURCE_FILE="$WORK/caddy-stable.list"
rw_backup_file() { cp -- "$1" "$WORK/backup"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

printf '%s\n' '# Caddy stable' \
    'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main' >"$RW_CADDY_APT_SOURCE_FILE"
RW_CADDY_SOURCE=apt rw_prepare_caddy_source
[[ -f $RW_CADDY_APT_SOURCE_FILE ]] || fail 'APT default changed source'
RW_CADDY_SOURCE=github rw_prepare_caddy_source
[[ ! -e $RW_CADDY_APT_SOURCE_FILE && -s $WORK/backup ]] || fail 'source not preserved/disabled'
RW_CADDY_SOURCE=github rw_prepare_caddy_source
cp "$WORK/backup" "$RW_CADDY_APT_SOURCE_FILE"
printf '%s\n' 'deb https://example.invalid/debian stable main' >>"$RW_CADDY_APT_SOURCE_FILE"
if (RW_CADDY_SOURCE=github rw_prepare_caddy_source); then fail 'mixed source accepted'; fi
[[ -f $RW_CADDY_APT_SOURCE_FILE ]] || fail 'mixed source removed'
rm -- "$RW_CADDY_APT_SOURCE_FILE"
ln -s "$WORK/backup" "$RW_CADDY_APT_SOURCE_FILE"
if (RW_CADDY_SOURCE=github rw_prepare_caddy_source); then fail 'symlink accepted'; fi
if (RW_CADDY_SOURCE=wrong rw_prepare_caddy_source); then fail 'invalid mode accepted'; fi

# Exercise the download gate without network, APT or installing any package.
export MOCK_ARCH=amd64 MOCK_HASH=ok MOCK_META=ok MOCK_INSTALLED=absent
dpkg() { if [[ $1 == --print-architecture ]]; then echo "$MOCK_ARCH"; else return 0; fi; }
dpkg-query() { [[ $MOCK_INSTALLED == present ]] && echo 'install ok installed 2.11.7'; }
curl() { printf '%s\n' "$*" >>"$WORK/downloads"; }
sha256sum() {
    local expected
    case $MOCK_ARCH in
        amd64) expected=a22b914ffd1958da42bc7ab13b7b62c6100634e0798ab594891d2d61d53ba749 ;;
        arm64) expected=ca8ae5a50439642d7672344b4ec64e47cbddf81beb5da302420a78522eb5a47e ;;
    esac
    local line
    IFS= read -r line
    [[ $MOCK_HASH == ok && $line == "$expected  "* ]]
}
dpkg-deb() {
    case $3 in
        Package) echo caddy ;;
        Architecture) echo "$MOCK_ARCH" ;;
        Version) if [[ $MOCK_META == ok ]]; then echo 2.11.7; else echo 0.0.0; fi ;;
    esac
}
rw_apt_get() { printf '%s\n' "$*" >>"$WORK/apt"; }
rw_install_caddy_github
MOCK_ARCH=arm64 rw_install_caddy_github
[[ $(wc -l <"$WORK/apt") -eq 2 ]] || fail 'expected both architectures to install'
if (MOCK_HASH=bad rw_install_caddy_github); then fail 'bad checksum accepted'; fi
if (MOCK_META=bad rw_install_caddy_github); then fail 'bad metadata accepted'; fi
MOCK_INSTALLED=present rw_install_caddy_github
[[ $(wc -l <"$WORK/apt") -eq 2 && $(wc -l <"$WORK/downloads") -eq 4 ]] || fail 'failed gate installed or existing version downloaded'
printf 'OK: Caddy source selection, safe recovery, pinned checksums and metadata gates\n'
