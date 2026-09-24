#!/usr/bin/env python3
"""Root-only packet-path tests. All rules and listeners live in throwaway netns."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SERVER = f"rw-fw-s-{os.getpid()}"
CLIENT = f"rw-fw-c-{os.getpid()}"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def ns(name, *args, **kwargs):
    return run("ip", "netns", "exec", name, *args, **kwargs)


LISTENERS = r'''
import selectors, socket
s = selectors.DefaultSelector()
for family, address in ((socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')):
    for port in (22, 80, 443, 2222, 8443):
        sock = socket.socket(family, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((address, port))
        sock.listen()
        s.register(sock, selectors.EVENT_READ, 'tcp')
    for port in (443, 45678):
        sock = socket.socket(family, socket.SOCK_DGRAM)
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((address, port))
        s.register(sock, selectors.EVENT_READ, 'udp')
print('ready', flush=True)
while True:
    for key, _ in s.select():
        if key.data == 'tcp':
            conn, _ = key.fileobj.accept()
            conn.close()
        else:
            data, address = key.fileobj.recvfrom(4096)
            key.fileobj.sendto(data, address)
'''

PROBE = r'''
import errno, socket, sys
target, source, port, protocol, expected = sys.argv[1:]
family = socket.AF_INET6 if ':' in target else socket.AF_INET
with socket.socket(family, socket.SOCK_STREAM if protocol == 'tcp' else socket.SOCK_DGRAM) as s:
    s.settimeout(1)
    s.bind((source, 0))
    try:
        s.connect((target, int(port)))
        if protocol == 'udp':
            s.send(b'probe')
            assert s.recv(32) == b'probe'
        result = 'open'
    except ConnectionRefusedError as e:
        assert e.errno == errno.ECONNREFUSED
        result = 'closed'
    except socket.timeout:
        result = 'drop'
assert result == expected, (target, source, port, protocol, result, expected)
'''


def main():
    if os.geteuid() != 0:
        sys.exit("Run as root: requires network namespace and nftables privileges")
    created = []
    server = None
    try:
        for name in (SERVER, CLIENT):
            run("ip", "netns", "add", name)
            created.append(name)
            ns(name, "ip", "link", "set", "lo", "up")
        ns(SERVER, "ip", "link", "add", "srv0", "type", "veth", "peer", "name", "cli0")
        ns(SERVER, "ip", "link", "set", "cli0", "netns", CLIENT)
        for name, interface, suffixes in ((SERVER, "srv0", (1,)), (CLIENT, "cli0", (2, 10, 20))):
            for suffix in suffixes:
                ns(name, "ip", "addr", "add", f"198.18.0.{suffix}/24", "dev", interface)
                ns(name, "ip", "-6", "addr", "add", f"fd42::{suffix}/64", "dev", interface, "nodad")
            ns(name, "ip", "link", "set", interface, "up")
        server = subprocess.Popen(
            ["ip", "netns", "exec", SERVER, sys.executable, "-u", "-c", LISTENERS],
            stdout=subprocess.PIPE, text=True,
        )
        assert server.stdout.readline().strip() == "ready", "listeners failed to start"
        with tempfile.TemporaryDirectory(prefix="rw-firewall-test-") as temporary:
            # A foreign table must survive every managed-table replacement.
            ns(SERVER, "nft", "add", "table", "inet", "plugin_sentinel")
            for panel, admin in (("198.18.0.10", "198.18.0.20"), ("fd42::10", "fd42::20")):
                rules = str(Path(temporary) / "firewall.nft")
                run("bash", "-c", '''
                    set -Eeuo pipefail
                    source src/lib/common.sh
                    source src/lib/validate.sh
                    source src/lib/firewall.sh
                    PANEL_IP=$1 ADMIN_IPS=$2 NODE_PORT=2222
                    rw_render_firewall "$3"
                ''', "test", panel, admin, rules, cwd=ROOT)
                for _ in range(2):
                    ns(SERVER, "env", f"RW_RUNTIME_DIR={temporary}", "bash",
                       str(ROOT / "src/scripts/rw-node-firewall-apply"), rules)
                ns(SERVER, "nft", "list", "table", "inet", "plugin_sentinel", stdout=subprocess.DEVNULL)
                for target, prefix in (("198.18.0.1", "198.18.0."), ("fd42::1", "fd42::")):
                    for port in (80, 443):
                        ns(CLIENT, sys.executable, "-c", PROBE, target, prefix + "2", str(port), "tcp", "open")
                    # 2222 and 8443 have live listeners; 45678/tcp does not.
                    # All three, and SSH, must look identically closed.
                    for port in (22, 2222, 8443, 45678):
                        ns(CLIENT, sys.executable, "-c", PROBE, target, prefix + "2", str(port), "tcp", "closed")
                    for suffix, port in ((10, 22), (10, 2222), (20, 22), (20, 2222)):
                        source = prefix + str(suffix)
                        allowed = source == panel or (source == admin and port == 22)
                        ns(CLIENT, sys.executable, "-c", PROBE, target, source, str(port), "tcp", "open" if allowed else "closed")
                    ns(CLIENT, sys.executable, "-c", PROBE, target, prefix + "2", "443", "udp", "open")
                    ns(CLIENT, sys.executable, "-c", PROBE, target, prefix + "2", "45678", "udp", "drop")
                for address in ("127.0.0.1", "::1"):
                    ns(SERVER, sys.executable, "-c", PROBE, address, address, "8443", "tcp", "open")
        print("PASS: IPv4/IPv6 allowlists, uniform TCP refusal, public TCP/UDP, UDP drop, loopback, idempotency and foreign tables")
    finally:
        if server is not None:
            server.terminate()
            server.wait(timeout=5)
        for name in reversed(created):
            run("ip", "netns", "delete", name)


if __name__ == "__main__":
    main()
