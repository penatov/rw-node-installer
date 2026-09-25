#!/usr/bin/env bash
# Root-only packet-path tests; all listeners/rules live in disposable netns.
set -Eeuo pipefail
export LC_ALL=C
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
((EUID == 0)) || { echo 'Run as root: requires network namespaces and nftables.' >&2; exit 1; }
for tool in ip nft ss socat nc timeout; do
    command -v "$tool" >/dev/null || { echo "Missing test tool: $tool" >&2; exit 1; }
done
SERVER=rw-fw-s-$$ CLIENT=rw-fw-c-$$
work=$(mktemp -d)
created=()
cleanup() {
    local name
    local -a pids=()
    for name in "${created[@]}"; do
        mapfile -t pids < <(ip netns pids "$name")
        if ((${#pids[@]})); then kill "${pids[@]}" 2>/dev/null || true; fi
        ip netns delete "$name" || true
    done
    rm -rf -- "$work"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$work"/*.log >&2; exit 1; }
ns() { ip netns exec "$@"; }
for name in "$SERVER" "$CLIENT"; do
    ip netns add "$name"
    created+=("$name")
    ns "$name" ip link set lo up
done
ns "$SERVER" ip link add srv0 type veth peer name cli0
ns "$SERVER" ip link set cli0 netns "$CLIENT"
for suffix in 1 2 10 20; do
    name=$CLIENT interface=cli0
    if ((suffix == 1)); then name=$SERVER interface=srv0; fi
    ns "$name" ip addr add "198.18.0.$suffix/24" dev "$interface"
    ns "$name" ip -6 addr add "fd42::$suffix/64" dev "$interface" nodad
    ns "$name" ip link set "$interface" up
done
for family in 4 6; do
    options=reuseaddr,fork
    if ((family == 6)); then options+=,ipv6only=1; fi
    for port in 22 80 443 2222 8443 32456; do
        ns "$SERVER" socat "TCP${family}-LISTEN:$port,$options" EXEC:/bin/cat 2>"$work/tcp-$family-$port.log" &
    done
    for port in 443 45678; do
        ns "$SERVER" socat "UDP${family}-RECVFROM:$port,$options" EXEC:/bin/cat 2>"$work/udp-$family-$port.log" &
    done
done
ready=false
for ((attempt=0; attempt<50; attempt++)); do
    tcp_count=$(ns "$SERVER" ss -H -lnt | wc -l)
    udp_count=$(ns "$SERVER" ss -H -lnu | wc -l)
    if ((tcp_count == 12 && udp_count == 4)); then ready=true; break; fi
    sleep 0.1
done
[[ $ready == true ]] || fail 'listeners failed to start'

probe_tcp() {
    local namespace=$1 target=$2 source=$3 port=$4 expected=$5 family=4 status=0 result
    [[ $target != *:* ]] || family=6
    result=$(ns "$namespace" timeout 3 nc "-$family" -n -z -v -w 1 -s "$source" "$target" "$port" 2>&1) || status=$?
    case $expected in
        open) ((status == 0)) || fail "TCP $source -> $target:$port: expected open; $result" ;;
        closed) ((status != 0)) && [[ $result == *'Connection refused'* ]] ||
            fail "TCP $source -> $target:$port: expected refusal, not timeout; $result" ;;
    esac
}
probe_udp() {
    local target=$1 source=$2 port=$3 expected=$4 family=4 status=0 result
    if [[ $target == *:* ]]; then family=6; target="[$target]"; source="[$source]"; fi
    result=$(printf probe | ns "$CLIENT" timeout 4 socat -t2 -T2 - \
        "UDP${family}-DATAGRAM:$target:$port,bind=$source" 2>"$work/probe.log") || status=$?
    case $expected in
        open) ((status == 0)) && [[ $result == probe ]] || fail "UDP $target:$port did not echo" ;;
        drop) ((status == 0 || status == 124)) && [[ -z $result && ! -s $work/probe.log ]] ||
            fail "UDP $target:$port: expected silence, not rejection" ;;
    esac
}

ns "$SERVER" nft add table inet plugin_sentinel
for panel_family in 4 6; do
    if ((panel_family == 4)); then panel=198.18.0.10 admin=198.18.0.20; else panel=fd42::10 admin=fd42::20; fi
    for api_port in 2222 32456; do
        (
            cd "$ROOT"
            # shellcheck source=../src/lib/common.sh
            source src/lib/common.sh
            # shellcheck source=../src/lib/validate.sh
            source src/lib/validate.sh
            # shellcheck source=../src/lib/firewall.sh
            source src/lib/firewall.sh
            PANEL_IP=$panel ADMIN_IPS=$admin NODE_PORT=$api_port
            rw_render_firewall "$work/firewall.nft"
        )
        for _ in 1 2; do
            ns "$SERVER" env RW_RUNTIME_DIR="$work" bash "$ROOT/src/scripts/rw-node-firewall-apply" "$work/firewall.nft"
        done
        ns "$SERVER" nft list table inet plugin_sentinel >/dev/null
        for family in 4 6; do
            if ((family == 4)); then prefix=198.18.0.; else prefix=fd42::; fi
            target=${prefix}1
            for port in 80 443; do probe_tcp "$CLIENT" "$target" "${prefix}2" "$port" open; done
            # Live private listeners and an unused port must look equally closed.
            for port in 22 2222 8443 32456 45678; do probe_tcp "$CLIENT" "$target" "${prefix}2" "$port" closed; done
            for suffix in 10 20; do
                for port in 22 "$api_port"; do
                    source=${prefix}${suffix} expected=closed
                    if [[ $source == "$panel" || ( $source == "$admin" && $port == 22 ) ]]; then expected=open; fi
                    probe_tcp "$CLIENT" "$target" "$source" "$port" "$expected"
                done
            done
            if ((api_port != 2222)); then probe_tcp "$CLIENT" "$target" "${prefix}10" 2222 closed; fi
            probe_udp "$target" "${prefix}2" 443 open
            probe_udp "$target" "${prefix}2" 45678 drop
        done
        for address in 127.0.0.1 ::1; do probe_tcp "$SERVER" "$address" "$address" 8443 open; done
    done
done
echo 'PASS: IPv4/IPv6 allowlists, TCP refusal, public TCP/UDP, UDP drop, loopback, idempotency and foreign tables'
