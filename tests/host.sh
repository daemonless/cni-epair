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
#   BACKEND=...      cni or netavark (default: auto-detected from podman info)
set -u
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }
SRC=${1:-$(dirname "$0")/../epair}
SRC=$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")
BACKEND=${BACKEND:-$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || echo cni)}
CNI_PLUGIN=/usr/local/libexec/cni/epair-test
NV_PLUGIN=/usr/local/libexec/netavark/epair-test
NETD=/usr/local/etc/cni/net.d
IMG=${IMG:-ghcr.io/daemonless/zensical:latest}
ERR=$(mktemp)
export CNI_EPAIR_LOG=${CNI_EPAIR_LOG:-$(mktemp)}

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

NETS="ept-mtu ept-auto ept-err ept-dhcp ept-dhcp-nodns ept-second"
cleanup() {
    for c in $NETS ept-ip ept-multi; do podman rm -f -t 0 "$c" >/dev/null 2>&1; done
    for n in $NETS; do
        podman network rm -f "$n" >/dev/null 2>&1 || true
        rm -f "$NETD/$n.conflist"
        rm -rf "/var/lib/cni/networks/$n"
    done
    ifconfig ept0 destroy 2>/dev/null
    rm -f "$CNI_PLUGIN" "$NV_PLUGIN" "$ERR"
}
trap cleanup EXIT
cleanup

ifconfig bridge create name ept0 mtu 9000 up >/dev/null
jid() { jls -j "$(podman inspect -f '{{.Id}}' "$1")" jid 2>/dev/null; }
mtu_of() { sed -n 's/.* mtu \([0-9]*\).*/\1/p' | head -1; }
start() {
    local c=$1 n=$2
    shift 2
    podman run -d --name "$c" --network "$n" "$@" --entrypoint /bin/sleep "$IMG" 600 >/dev/null 2>"$ERR"
}

if [ "$BACKEND" = "netavark" ]; then
    install -m 555 "$SRC" "$NV_PLUGIN"
    PLUGIN="$NV_PLUGIN"

    echo "== netavark mtu"
    podman network create -d epair-test --interface-name ept0 -o mtu=9000 --subnet 10.250.0.0/24 --gateway 10.250.0.1 ept-mtu >/dev/null
    if start ept-mtu ept-mtu; then
        m=$(ifconfig -j "$(jid ept-mtu)" eth0 | mtu_of)
        [ "$m" = 9000 ] && ok "netavark mtu=9000 -> jail end $m" || bad "netavark mtu=9000 -> jail end '$m'"
        ifconfig -j "$(jid ept-mtu)" eth0 | grep -q 'inet 10\.250\.0\.' && ok "netavark subnet address" || bad "no netavark address"
    else
        bad "start on ept-mtu: $(cat "$ERR")"
    fi
    podman network create -d epair-test --interface-name ept0 --subnet 10.250.0.0/24 --gateway 10.250.0.1 ept-auto >/dev/null
    if start ept-auto ept-auto; then
        m=$(ifconfig -j "$(jid ept-auto)" eth0 | mtu_of)
        [ "$m" = 9000 ] && ok "netavark no mtu on a 9000 bridge -> jail end $m" || bad "netavark no mtu on 9000 bridge -> '$m'"
    else
        bad "start on ept-auto: $(cat "$ERR")"
    fi
    for a in $(ifconfig ept0 | awk '/member: epair/{print $2}'); do
        m=$(ifconfig "$a" | mtu_of)
        [ "$m" = 9000 ] && ok "host end $a $m" || bad "host end $a '$m'"
    done

    echo "== netavark multi-epair default route (first attached wins) and teardown"
    podman network create -d epair-test --interface-name ept0 --subnet 10.251.0.0/24 --gateway 10.251.0.1 ept-second >/dev/null
    if start ept-multi ept-mtu --network ept-second; then
        gws=$(jexec "$(jid ept-multi)" netstat -rn -f inet | awk '$1 == "default" { print $2 }')
        [ "$gws" = "10.250.0.1" ] && ok "netavark multi-epair keeps first attached default (10.250.0.1)" ||
            bad "expected 10.250.0.1, got: $(printf '%s' "$gws" | tr '\n' ' ')"
    else
        bad "netavark multi start failed: $(cat "$ERR")"
    fi

    echo "== netavark static address"
    podman rm -f -t 0 ept-mtu >/dev/null 2>&1 || true
    if start ept-ip ept-mtu --ip 10.250.0.77; then
        ifconfig -j "$(jid ept-ip)" eth0 | grep -q 'inet 10\.250\.0\.77 ' && ok "netavark --ip 10.250.0.77 set" ||
            bad "netavark --ip not set: $(ifconfig -j "$(jid ept-ip)" eth0 | grep inet)"
    else
        bad "netavark start with --ip: $(cat "$ERR")"
    fi

    echo "== netavark errors reach podman readable"
    podman network create -d epair-test --interface-name ept0 -o mtu=70000 --subnet 10.252.0.0/24 ept-err >/dev/null 2>&1 || true
    start ept-err ept-err
    grep -q 'mtu must be 576-65535' "$ERR" && ok "netavark mtu 70000: the reason" || bad "netavark mtu 70000: $(cat "$ERR")"
    podman rm -f -t 0 ept-err >/dev/null 2>&1; podman network rm -f ept-err >/dev/null 2>&1 || true
    podman network create -d epair-test --interface-name ept0 -o vlan=2 --subnet 10.252.0.0/24 ept-err >/dev/null 2>&1 || true
    start ept-err ept-err
    grep -q 'vlanfilter' "$ERR" && ok "netavark vlan without vlanfilter: the reason" || bad "netavark vlan: $(cat "$ERR")"

    if [ -n "${DHCP_BRIDGE:-}" ]; then
        echo "== netavark dhcp on $DHCP_BRIDGE"
        podman network create -d epair-test --interface-name "$DHCP_BRIDGE" --ipam-driver none -o lease_dns=true ept-dhcp >/dev/null
        if start ept-dhcp ept-dhcp; then
            lease=$(grep 'dhcp lease=' "$CNI_EPAIR_LOG" | tail -1 | sed 's/.*lease=//')
            echo "     lease: $lease"
            ifconfig -j "$(jid ept-dhcp)" eth0 | grep -q "inet ${lease%%/*} " && ok "netavark leased address set" || bad "netavark leased address not set"
            dns=${lease##* }
            podman exec ept-dhcp grep -q "nameserver $dns" /etc/resolv.conf && ok "netavark lease_dns=true passes $dns" ||
                bad "lease DNS '$dns' not in: $(podman exec ept-dhcp grep nameserver /etc/resolv.conf | tr '\n' ' ')"
        else
            bad "start on ept-dhcp: $(cat "$ERR")"
        fi
    else
        echo "== netavark dhcp: skipped (set DHCP_BRIDGE)"
    fi

    echo "== netavark teardown"
    podman rm -f -t 0 ept-auto ept-multi ept-ip ept-err ept-dhcp >/dev/null 2>&1
    left=$(ifconfig ept0 | awk '/member: epair/{print $2}')
    [ -z "$left" ] && ok "epairs gone from ept0 (including multi-epair)" || bad "left on ept0: $left"
else

install -m 555 "$SRC" "$CNI_PLUGIN"
PLUGIN="$CNI_PLUGIN"

# net <name> <bridge> <extra keys> <ipam>
net() {
    cat > "$NETD/$1.conflist" <<EOF
{"cniVersion": "0.4.0", "name": "$1", "plugins": [{"type": "epair-test", "master": "$2"$3,
 "ipam": $4, "capabilities": {"ips": true, "mac": true}}]}
EOF
}
HOSTLOCAL='{"type": "host-local", "routes": [{"dst": "0.0.0.0/0"}], "ranges": [[{"subnet": "10.250.0.0/24", "gateway": "10.250.0.1"}]]}'

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

echo "== default route replaces foreign default, keeps epair default by CNI name"
dr_cid=$(podman inspect -f '{{.Id}}' ept-mtu)
dr_jid=$(jid ept-mtu)
dr_orig=$(cat "/var/run/cni/freebsd-epair/$dr_cid")
dr_gw_orig=$(cat "/var/run/cni/freebsd-epair/$dr_cid.gw" 2>/dev/null || true)
dr_conf_z="{\"cniVersion\":\"1.0.0\",\"name\":\"ept-z\",\"type\":\"epair-test\",\"master\":\"ept0\",\"ipam\":{\"type\":\"static\"}}"
dr_conf_a="{\"cniVersion\":\"1.0.0\",\"name\":\"ept-a\",\"type\":\"epair-test\",\"master\":\"ept0\",\"ipam\":{\"type\":\"static\"}}"

# Case 1: later-sorting network (ept-z > ept-mtu) keeps ept-mtu default.
if printf '%s\n' "$dr_conf_z" | \
    CNI_COMMAND=ADD CNI_CONTAINERID="$dr_cid" \
    CNI_NETNS="$dr_cid" CNI_IFNAME=eth1 \
    CNI_ARGS="IP=10.251.0.88/24" sh "$PLUGIN" >/dev/null 2>"$ERR"; then
    gws=$(jexec "$dr_jid" netstat -rn -f inet | awk '$1 == "default" { print $2 }')
    [ "$gws" = "10.250.0.1" ] && ok "cni later name (ept-z) keeps ept-mtu default (10.250.0.1)" ||
        bad "expected ept-mtu default 10.250.0.1, got: $(printf '%s' "$gws" | tr '\n' ' ')"
    printf '%s\n' "$dr_conf_z" | CNI_COMMAND=DEL CNI_CONTAINERID="$dr_cid" CNI_NETNS="$dr_cid" CNI_IFNAME=eth1 sh "$PLUGIN" >/dev/null 2>&1 || true
else
    bad "cni ept-z route check failed: $(cat "$ERR")"
fi

# Case 1b: earlier-sorting network (ept-a < ept-mtu) replaces ept-mtu default.
if printf '%s\n' "$dr_conf_a" | \
    CNI_COMMAND=ADD CNI_CONTAINERID="$dr_cid" \
    CNI_NETNS="$dr_cid" CNI_IFNAME=eth1 \
    CNI_ARGS="IP=10.251.0.89/24" sh "$PLUGIN" >/dev/null 2>"$ERR"; then
    gws=$(jexec "$dr_jid" netstat -rn -f inet | awk '$1 == "default" { print $2 }')
    [ "$gws" = "10.251.0.1" ] && ok "cni earlier name (ept-a) replaces ept-mtu default (10.251.0.1)" ||
        bad "expected ept-a default 10.251.0.1, got: $(printf '%s' "$gws" | tr '\n' ' ')"
    printf '%s\n' "$dr_conf_a" | CNI_COMMAND=DEL CNI_CONTAINERID="$dr_cid" CNI_NETNS="$dr_cid" CNI_IFNAME=eth1 sh "$PLUGIN" >/dev/null 2>&1 || true
else
    bad "cni ept-a route check failed: $(cat "$ERR")"
fi

# Case 2: foreign default (e.g. private bridge 10.250.0.254) is replaced cleanly.
rm -f "/var/run/cni/freebsd-epair/$dr_cid.gw"
route -j "$dr_jid" delete default >/dev/null 2>&1 || true
route -j "$dr_jid" add default 10.250.0.254 >/dev/null 2>&1
if printf '%s\n' "$dr_conf_z" | \
    CNI_COMMAND=ADD CNI_CONTAINERID="$dr_cid" \
    CNI_NETNS="$dr_cid" CNI_IFNAME=eth1 \
    CNI_ARGS="IP=10.250.0.88/24" sh "$PLUGIN" >/dev/null 2>"$ERR"; then
    gws=$(jexec "$dr_jid" netstat -rn -f inet | awk '$1 == "default" { print $2 }')
    [ "$gws" = "10.250.0.1" ] && ok "foreign default replaced (only 10.250.0.1)" ||
        bad "expected sole default 10.250.0.1, got: $(printf '%s' "$gws" | tr '\n' ' ')"
    printf '%s\n' "$dr_conf_z" | CNI_COMMAND=DEL CNI_CONTAINERID="$dr_cid" CNI_NETNS="$dr_cid" CNI_IFNAME=eth1 sh "$PLUGIN" >/dev/null 2>&1 || true
else
    bad "replace foreign default failed: $(cat "$ERR")"
fi
printf '%s\n' "$dr_orig" > "/var/run/cni/freebsd-epair/$dr_cid"
[ -n "$dr_gw_orig" ] && printf '%s\n' "$dr_gw_orig" > "/var/run/cni/freebsd-epair/$dr_cid.gw"

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

fi

echo
echo "$pass passed, $fail failed (plugin log: $CNI_EPAIR_LOG)"
[ "$fail" -eq 0 ]
