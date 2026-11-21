#!/bin/sh
# The plugin on a real FreeBSD host with podman: epairs, a bridge, jails,
# host-local and (optionally) a DHCP server. Run as root on a test machine:
#
#   sh tests/host.sh [path/to/epair]
#
# The plugin under test goes in as "epair-test", so an installed "epair" and
# its networks are left alone. Everything made here is removed on exit: the
# epair-test plugin, the ept-* networks and containers, the ept0 bridge.
#
#   IMG=...          image to run (needs /bin/sleep), default zensical
#   DHCP_BRIDGE=...  a bridge on a wire with a DHCP server; unset skips DHCP
set -u
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }
SRC=${1:-$(dirname "$0")/../epair}
SRC=$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")
PLUGIN=/usr/local/libexec/cni/epair-test
NETD=/usr/local/etc/cni/net.d
IMG=${IMG:-ghcr.io/daemonless/zensical:latest}
ERR=$(mktemp)
export CNI_EPAIR_LOG=${CNI_EPAIR_LOG:-$(mktemp)}

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

NETS="ept-mtu ept-auto ept-err ept-dhcp"
cleanup() {
    for c in $NETS ept-ip; do podman rm -f -t 0 "$c" >/dev/null 2>&1; done
    for n in $NETS; do rm -f "$NETD/$n.conflist"; rm -rf "/var/lib/cni/networks/$n"; done
    ifconfig ept0 destroy 2>/dev/null
    rm -f "$PLUGIN" "$ERR"
}
trap cleanup EXIT
cleanup

install -m 555 "$SRC" "$PLUGIN"
ifconfig bridge create name ept0 mtu 9000 up >/dev/null

# net <name> <bridge> <extra keys> <ipam>
net() {
    cat > "$NETD/$1.conflist" <<EOF
{"cniVersion": "0.4.0", "name": "$1", "plugins": [{"type": "epair-test", "master": "$2"$3,
 "ipam": $4, "capabilities": {"ips": true, "mac": true}}]}
EOF
}
HOSTLOCAL='{"type": "host-local", "routes": [{"dst": "0.0.0.0/0"}], "ranges": [[{"subnet": "10.250.0.0/24", "gateway": "10.250.0.1"}]]}'
# start <container> <network> [podman args]: runs it, error text in $ERR
start() {
    local c=$1 n=$2
    shift 2
    podman run -d --name "$c" --network "$n" "$@" --entrypoint /bin/sleep "$IMG" 600 >/dev/null 2>"$ERR"
}
jid() { jls -j "$(podman inspect -f '{{.Id}}' "$1")" jid 2>/dev/null; }
mtu_of() { sed -n 's/.* mtu \([0-9]*\).*/\1/p' | head -1; }

echo "== mtu"
net ept-mtu ept0 ', "mtu": 9000' "$HOSTLOCAL"
if start ept-mtu ept-mtu; then
    m=$(ifconfig -j "$(jid ept-mtu)" eth0 | mtu_of)
    [ "$m" = 9000 ] && ok "\"mtu\": 9000 -> jail end $m" || bad "\"mtu\": 9000 -> jail end '$m'"
    ifconfig -j "$(jid ept-mtu)" eth0 | grep -q 'inet 10\.250\.0\.' && ok "host-local address" || bad "no host-local address"
else
    bad "start on ept-mtu: $(cat "$ERR")"
fi
net ept-auto ept0 '' "$HOSTLOCAL"
if start ept-auto ept-auto; then
    m=$(ifconfig -j "$(jid ept-auto)" eth0 | mtu_of)
    [ "$m" = 9000 ] && ok "no mtu on a 9000 bridge -> jail end $m" || bad "no mtu on a 9000 bridge -> jail end '$m'"
else
    bad "start on ept-auto: $(cat "$ERR")"
fi
for a in $(ifconfig ept0 | awk '/member: epair/{print $2}'); do
    m=$(ifconfig "$a" | mtu_of)
    [ "$m" = 9000 ] && ok "host end $a $m" || bad "host end $a '$m'"
done

echo "== static address"
if start ept-ip ept-mtu --ip 10.250.0.77; then
    ifconfig -j "$(jid ept-ip)" eth0 | grep -q 'inet 10\.250\.0\.77 ' && ok "--ip 10.250.0.77 set" ||
        bad "--ip not set: $(ifconfig -j "$(jid ept-ip)" eth0 | grep inet)"
else
    bad "start with --ip: $(cat "$ERR")"
fi

echo "== errors reach podman readable"
net ept-err ept0 ', "taggedVlans": [3,4]' "$HOSTLOCAL"
start ept-err ept-err
grep -q 'taggedVlans must be a string like "3,4"' "$ERR" && ok "taggedVlans: the reason" || bad "taggedVlans: $(cat "$ERR")"
podman rm -f ept-err >/dev/null 2>&1
net ept-err ept0 ', "mtu": 70000' "$HOSTLOCAL"
start ept-err ept-err
grep -q 'mtu must be 576-65535' "$ERR" && ok "mtu 70000: the reason" || bad "mtu 70000: $(cat "$ERR")"

if [ -n "${DHCP_BRIDGE:-}" ]; then
    echo "== dhcp on $DHCP_BRIDGE"
    net ept-dhcp "$DHCP_BRIDGE" ', "leaseDns": true' '{"type": "dhcp"}'
    if start ept-dhcp ept-dhcp; then
        lease=$(grep 'dhcp lease=' "$CNI_EPAIR_LOG" | tail -1 | sed 's/.*lease=//')
        echo "     lease: $lease"
        ifconfig -j "$(jid ept-dhcp)" eth0 | grep -q "inet ${lease%%/*} " && ok "leased address set" || bad "leased address not set"
        dns=${lease##* }
        podman exec ept-dhcp grep -q "nameserver $dns" /etc/resolv.conf && ok "lease DNS $dns in resolv.conf" ||
            bad "lease DNS '$dns' not in: $(podman exec ept-dhcp grep nameserver /etc/resolv.conf | tr '\n' ' ')"
    else
        bad "start on ept-dhcp: $(cat "$ERR")"
    fi
else
    echo "== dhcp: skipped (set DHCP_BRIDGE)"
fi

echo "== teardown"
podman rm -f -t 0 ept-mtu ept-auto ept-ip >/dev/null 2>&1
left=$(ifconfig ept0 | awk '/member: epair/{print $2}')
[ -z "$left" ] && ok "epairs gone from the bridge" || bad "left on ept0: $left"
ls /var/lib/cni/networks/ept-mtu /var/lib/cni/networks/ept-auto 2>/dev/null | grep -q '^10\.' &&
    bad "host-local reservations kept" || ok "host-local reservations released"

echo
echo "$pass passed, $fail failed (plugin log: $CNI_EPAIR_LOG)"
[ "$fail" -eq 0 ]
