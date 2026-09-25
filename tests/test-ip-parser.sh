#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../src/lib/validate.sh
source "$ROOT/src/lib/validate.sh"
cases=0
while IFS=$'\t' read -r mode value networks expected_status expected; do
    [[ -n $mode && $mode != \#* ]] || continue
    [[ $networks != - ]] || networks=''
    [[ $expected != - ]] || expected=''
    status=0
    actual=$(rw_ip_tool "$mode" "$value" "$networks") || status=$?
    [[ $status == "$expected_status" && $actual == "$expected" ]] || {
        printf 'FAIL: IP fixture %s %s %s (status %s, output %s)\n' "$mode" "$value" "$networks" "$status" "$actual" >&2
        exit 1
    }
    cases=$((cases + 1))
done <"$ROOT/tests/fixtures/ip-cases.tsv"
((cases >= 2000)) || { printf 'FAIL: incomplete IP fixture set\n' >&2; exit 1; }
for invalid in '' 1 1.2.3 1.2.3.256 01.2.3.4 1.2.3.-1 1.2.3.4/33 \
    1.2.3.4/-1 1.2.3.4/ 1.2.3.4/24/24 1.2.3.4/255.0.255.0 \
    :::1 1::2::3 1:2:3:4:5:6:7:8:9 1:2:3:4:5:6:7 1:2:3:4:5:6:7:8:: \
    ::ffff:999.0.0.1 ::g 12345:: ::/129 ::/255.255.0.0 'fe80::1%ens3' \
    '$(touch x)' '1.2.3.4\n' $'1.2.3.4\n5.6.7.8'; do
    ! rw_normalize_ip_list "$invalid" >/dev/null || { printf 'FAIL: invalid IP accepted: %s\n' "$invalid" >&2; exit 1; }
done
[[ $(rw_normalize_ip_list ' 192.0.2.1,2001:DB8::1,192.0.2.1, ') == '192.0.2.1,2001:db8::1' ]]
! rw_ip_in_list 192.0.2.1 ::/0
! rw_ip_in_list 2001:db8::1 0.0.0.0/0
printf 'OK: %s frozen IP/CIDR expectations and invalid-input checks\n' "$cases"
