#!/bin/sh
# Exercise the epair plugin off a real host: ifconfig, jls, route, dhclient
# and the IPAM plugin are stubs on PATH that record what they were asked to do.
# Needs jq. Usage: tests/run.sh [path/to/epair]

set -u
PLUGIN=${1:-$(dirname "$0")/../epair}
PLUGIN=$(cd "$(dirname "$PLUGIN")" && pwd)/$(basename "$PLUGIN")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/run"

# ifconfig: answers the queries the plugin makes, logs the rest, and fails any
# call matching $FAIL_MATCH.
cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/sh
echo "ifconfig $*" >> "$STUB_LOG"
if [ -n "${FAIL_MATCH:-}" ] && echo "$*" | grep -q -- "$FAIL_MATCH"; then
    exit 1
fi
case "$*" in
"epair create") echo epair0a ;;
nobridge) exit 1 ;;
bridge0) printf 'bridge0: flags=8843<UP> metric 0 mtu %s\n\tbridge flags=%s\n' "${BRIDGE_MTU:-1500}" "${BRIDGE_FLAGS:-0}" ;;
epair0a) printf 'epair0a: flags=8843<UP>\n\tether 02:00:00:00:00:0a\n' ;;
"-j 7 eth0") printf 'eth0: flags=8843<UP>\n\tether 02:00:00:00:00:0b\n' ;;
esac
exit 0
EOF

cat > "$T/bin/jls" <<'EOF'
#!/bin/sh
echo "abcdef123456 7"
EOF

cat > "$T/bin/route" <<'EOF'
#!/bin/sh
echo "route $*" >> "$STUB_LOG"
EOF

cat > "$T/bin/netstat" <<'EOF'
#!/bin/sh
echo "netstat $*" >> "$STUB_LOG"
case "$*" in
*"-f inet6"*)
    for gw in ${CURRENT_GW6:-}; do
        printf 'default %s UGS eth0\n' "$gw"
    done
    ;;
*"-f inet"*)
    for gw in ${CURRENT_GW4:-}; do
        printf 'default %s UGS eth0\n' "$gw"
    done
    ;;
esac
EOF

# dhclient: reads the plugin's config for its script, reports a lease through
# it, then idles like the real one until the plugin kills it.
cat > "$T/bin/dhclient" <<'EOF'
#!/bin/sh
echo "dhclient $*" >> "$STUB_LOG"
conf=$3
echo "dhclient-conf $(cat "$conf")" >> "$STUB_LOG"
script=$(sed -n 's/.*script "\([^"]*\)".*/\1/p' "$conf")
reason=BOUND new_ip_address=192.168.1.50 new_subnet_mask=255.255.255.0 \
    new_routers=192.168.1.1 new_domain_name_servers="192.168.1.53 1.1.1.1" \
    sh "$script"
exec sleep 30
EOF

cat > "$T/bin/host-local" <<'EOF'
#!/bin/sh
echo "host-local $CNI_COMMAND" >> "$STUB_LOG"
[ "$CNI_COMMAND" = ADD ] && cat <<JSON
{"cniVersion":"1.0.0","ips":[{"address":"fd00::5/64","gateway":"fd00::1"},{"address":"10.88.0.5/24","gateway":"10.88.0.1"}]}
JSON
exit 0
EOF
chmod +x "$T/bin/"*

export PATH="$T/bin:$PATH" STUB_LOG="$T/calls"
export CNI_EPAIR_LOG="$T/log" CNI_EPAIR_STATE="$T/state" CNI_EPAIR_RUN="$T/run"
export CNI_PATH="$T/bin" CNI_CONTAINERID=abcdef1234567890 CNI_NETNS=abcdef1234567890
export CNI_IFNAME=eth0 CNI_ARGS="IgnoreUnknown=1;K8S_POD_NAME=web"

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }

# run <command> <config> [VAR=value...]: sets $out and $rc
run() {
    local cmd=$1 conf=$2
    shift 2
    : > "$STUB_LOG"
    out=$(printf '%s\n' "$conf" | env CNI_COMMAND="$cmd" "$@" sh "$PLUGIN")
    rc=$?
}
# check <name> <jq filter>: the output is JSON and the filter holds
check() {
    if printf '%s\n' "$out" | jq -e "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "$out"; fi
}
called() {
    if grep -qx -- "$2" "$STUB_LOG"; then ok "$1"; else bad "$1" "$(cat "$STUB_LOG")"; fi
}
not_called() {
    if grep -q -- "$2" "$STUB_LOG"; then bad "$1" "$(grep -- "$2" "$STUB_LOG")"; else ok "$1"; fi
}
conf() { echo "{\"cniVersion\":\"1.0.0\",\"name\":\"t\",\"type\":\"epair\",\"master\":\"bridge0\"$1,\"ipam\":{\"type\":\"$2\"}}"; }

# --- a static address from CNI_ARGS (foreign v4 default replaced; v6 untouched)
rm -f "$T/state/$CNI_CONTAINERID.gw"
run ADD "$(conf '' static)" CNI_ARGS="IP=10.0.0.5/24" CURRENT_GW4="10.99.0.1"
[ "$rc" -eq 0 ] && ok "static: exit 0" || bad "static: exit $rc" "$out"
check "static: address and guessed gateway" '.ips[0].address == "10.0.0.5/24" and .ips[0].gateway == "10.0.0.1"'
check "static: no dns without a lease" 'has("dns") | not'
called "static: address set in the jail" "ifconfig -j 7 eth0 inet 10.0.0.5/24"
called "static: deletes foreign v4 default route" "route -j 7 delete default 10.99.0.1"
called "static: adds v4 default route" "route -j 7 add default 10.0.0.1"
not_called "static: does not touch v6 default route" "delete -inet6 default"
not_called "static: no MTU set on a 1500 bridge" " mtu "
[ "$(cat "$T/state/$CNI_CONTAINERID")" = epair0a ] && ok "static: state recorded" || bad "static: state recorded"
grep -qxF "7 inet 10.0.0.1" "$T/state/$CNI_CONTAINERID.gw" && ok "static: gateway recorded" || bad "static: gateway recorded"

rm -f "$T/state/$CNI_CONTAINERID.gw"
run ADD "$(conf '' static)" CNI_ARGS="IP=fd00::5/64" CURRENT_GW4="10.99.0.1" CURRENT_GW6="fd99::1"
[ "$rc" -eq 0 ] && ok "static v6 without gateway: exit 0" || bad "static v6 without gateway: exit $rc" "$out"
not_called "static v6 without gateway: keeps existing v4 default" "delete default"
not_called "static v6 without gateway: keeps existing v6 default" "delete -inet6 default"

# --- MTU, as a number and as a string
for m in 9000 '"9000"'; do
    run ADD "$(conf ",\"mtu\":$m" static)" CNI_ARGS="IP=10.0.0.5/24"
    [ "$rc" -eq 0 ] && ok "mtu $m: exit 0" || bad "mtu $m: exit $rc" "$out"
    called "mtu $m: host end" "ifconfig epair0a mtu 9000"
    called "mtu $m: jail end" "ifconfig epair0b mtu 9000"
done
run ADD "$(conf '' static)" CNI_ARGS="IP=10.0.0.5/24" BRIDGE_MTU=9000
called "no mtu on a 9000 bridge: host end follows it" "ifconfig epair0a mtu 9000"
called "no mtu on a 9000 bridge: jail end follows it" "ifconfig epair0b mtu 9000"
run ADD "$(conf ',"mtu":1500' static)" CNI_ARGS="IP=10.0.0.5/24" BRIDGE_MTU=9000
called "mtu 1500 on a 9000 bridge: the config wins" "ifconfig epair0a mtu 1500"
run ADD "$(conf ',"mtu":"big"' static)" CNI_ARGS="IP=10.0.0.5/24"
[ "$rc" -eq 1 ] && ok "mtu big: refused" || bad "mtu big: exit $rc" "$out"
check "mtu big: error is JSON" '.code == 100 and (.msg | test("mtu"))'
run ADD "$(conf ',"mtu":100' static)" CNI_ARGS="IP=10.0.0.5/24"
check "mtu 100: out of range" '.code == 100 and (.msg | test("576-65535"))'
not_called "mtu 100: nothing created" "epair create"

# --- errors that quote their example stay JSON
run ADD "$(conf ',"taggedVlans":[3,4]' static)" CNI_ARGS="IP=10.0.0.5/24"
check "taggedVlans array: error is JSON with the example" '.code == 100 and (.msg | contains("\"3,4\""))'
run ADD "$(conf ',"vlan":2' static)" CNI_ARGS="IP=10.0.0.5/24"
check "vlan without vlanfilter: refused" '.code == 100 and (.msg | test("vlanfilter"))'
run ADD "$(conf ',"vlan":2' static)" CNI_ARGS="IP=10.0.0.5/24" BRIDGE_FLAGS="1<VLANFILTER>"
called "vlan on vlanfilter: untagged member" "ifconfig bridge0 addm epair0a untagged 2"

# --- a failed step reports failure and cleans up
run ADD "$(conf '' static)" CNI_ARGS="IP=10.0.0.5/24" FAIL_MATCH="vnet"
[ "$rc" -eq 1 ] && ok "failed move: exit 1" || bad "failed move: exit $rc" "$out"
check "failed move: error names the step" '.code == 100 and (.msg | test("move epair0b"))'
called "failed move: epair destroyed" "ifconfig epair0a destroy"
[ ! -e "$T/state/$CNI_CONTAINERID" ] && ok "failed move: no state left" || bad "failed move: state left"
run ADD "$(conf ',"mtu":9000' static)" CNI_ARGS="IP=10.0.0.5/24" FAIL_MATCH="mtu"
check "failed mtu: error names it" '.code == 100 and (.msg | test("MTU"))'

# --- DHCP: the lease's address, gateway and DNS server
run ADD "$(conf '' dhcp)" CNI_ARGS="K8S_POD_NAME=Web_App"
[ "$rc" -eq 0 ] && ok "dhcp: exit 0" || bad "dhcp: exit $rc" "$out"
check "dhcp: leased address" '.ips[0].address == "192.168.1.50/24" and .ips[0].gateway == "192.168.1.1"'
check "dhcp: no lease DNS unless asked" 'has("dns") | not'
grep -qF 'send host-name "web-app"' "$STUB_LOG" && ok "dhcp: asks under the container's name" || bad "dhcp: host-name" "$(cat "$STUB_LOG")"
[ -z "$(ls "$T/run")" ] && ok "dhcp: run dir cleaned up" || bad "dhcp: run dir left" "$(ls -R "$T/run")"

run ADD "$(conf ',"leaseDns":true' dhcp)" CNI_ARGS="K8S_POD_NAME=web"
check "dhcp with leaseDns: lease DNS in the result" '.dns.nameservers == ["192.168.1.53"]'

# --- host-local from CNI_PATH, both families in either order
rm -f "$T/state/$CNI_CONTAINERID.gw"
run ADD "$(conf '' host-local)" CNI_ARGS="" CURRENT_GW4="10.99.0.1" CURRENT_GW6="fd99::1"
check "host-local: v4 and v6" '[.ips[].address] == ["10.88.0.5/24", "fd00::5/64"]'
check "host-local: gateways by family" '[.ips[].gateway] == ["10.88.0.1", "fd00::1"]'
called "host-local: v6 enabled first" "ifconfig -j 7 eth0 inet6 -ifdisabled"
called "host-local: deletes foreign v4 default" "route -j 7 delete default 10.99.0.1"
called "host-local: adds v4 default" "route -j 7 add default 10.88.0.1"
called "host-local: deletes foreign v6 default" "route -j 7 delete -inet6 default fd99::1"
called "host-local: adds v6 default" "route -j 7 add -inet6 default fd00::1"
awk '/^route -j 7 delete default 10\.99\.0\.1$/{d=NR} /^route -j 7 add default 10\.88\.0\.1$/{a=NR} END{exit !(d && a && d<a)}' "$STUB_LOG" &&
    ok "host-local: v4 delete precedes add" || bad "host-local: v4 delete order" "$(cat "$STUB_LOG")"
awk '/^route -j 7 delete -inet6 default fd99::1$/{d=NR} /^route -j 7 add -inet6 default fd00::1$/{a=NR} END{exit !(d && a && d<a)}' "$STUB_LOG" &&
    ok "host-local: v6 delete precedes add" || bad "host-local: v6 delete order" "$(cat "$STUB_LOG")"
run ADD "$(conf '' no-such-ipam)" CNI_ARGS=""
check "missing IPAM: refused by name" '.code == 100 and (.msg | test("no-such-ipam"))'

# --- multi-LAN and mixed LAN + private route reconciliation (CNI)
# 1) Two epair networks (lan1 -> lan2): 1st sets default, 2nd keeps it
rm -f "$T/state/$CNI_CONTAINERID.gw"
run ADD "$(conf '' static)" CNI_ARGS="IP=192.168.86.10/24" CNI_IFNAME=eth0 CURRENT_GW4=""
called "cni 2-epair A: 1st installs default" "route -j 7 add default 192.168.86.1"
run ADD "$(conf '' static)" CNI_ARGS="IP=192.168.4.10/24" CNI_IFNAME=eth1 CURRENT_GW4="192.168.86.1"
not_called "cni 2-epair A: 2nd does not delete 1st default" "route -j 7 delete"
not_called "cni 2-epair A: 2nd does not add its default" "route -j 7 add default"

# 2) Reverse order (lan2 -> lan1): 1st (lan2) keeps default
rm -f "$T/state/$CNI_CONTAINERID.gw"
run ADD "$(conf '' static)" CNI_ARGS="IP=192.168.4.10/24" CNI_IFNAME=eth0 CURRENT_GW4=""
called "cni 2-epair B: 1st (lan2) installs default" "route -j 7 add default 192.168.4.1"
run ADD "$(conf '' static)" CNI_ARGS="IP=192.168.86.10/24" CNI_IFNAME=eth1 CURRENT_GW4="192.168.4.1"
not_called "cni 2-epair B: 2nd does not delete lan2 default" "route -j 7 delete"
not_called "cni 2-epair B: 2nd does not add its default" "route -j 7 add default"

# 3) Private -> lan1 -> lan2: lan1 deletes priv, lan2 keeps lan1
rm -f "$T/state/$CNI_CONTAINERID.gw"
run ADD "$(conf '' static)" CNI_ARGS="IP=192.168.86.10/24" CNI_IFNAME=eth1 CURRENT_GW4="10.89.0.1"
called "cni priv->lan1->lan2: lan1 replaces foreign 10.89.0.1" "route -j 7 delete default 10.89.0.1"
called "cni priv->lan1->lan2: lan1 installs 192.168.86.1" "route -j 7 add default 192.168.86.1"
run ADD "$(conf '' static)" CNI_ARGS="IP=192.168.4.10/24" CNI_IFNAME=eth2 CURRENT_GW4="192.168.86.1"
not_called "cni priv->lan1->lan2: lan2 keeps lan1 default" "route -j 7 delete"
not_called "cni priv->lan1->lan2: lan2 adds nothing" "route -j 7 add default"

# 4) lan1 -> private (ECMP added 10.89.0.1 alongside 192.168.86.1) -> lan2:
# lan2 strips ONLY 10.89.0.1 and keeps 192.168.86.1!
rm -f "$T/state/$CNI_CONTAINERID.gw"
run ADD "$(conf '' static)" CNI_ARGS="IP=192.168.86.10/24" CNI_IFNAME=eth0 CURRENT_GW4=""
run ADD "$(conf '' static)" CNI_ARGS="IP=192.168.4.10/24" CNI_IFNAME=eth2 CURRENT_GW4="192.168.86.1 10.89.0.1"
called "cni lan1->priv->lan2: lan2 deletes foreign 10.89.0.1" "route -j 7 delete default 10.89.0.1"
not_called "cni lan1->priv->lan2: lan2 keeps 192.168.86.1" "delete default 192.168.86.1"
not_called "cni lan1->priv->lan2: lan2 adds no third default" "route -j 7 add default"

# --- DEL destroys the epair, removes .gw state, and releases the addresses
echo epair0a > "$T/state/$CNI_CONTAINERID"
run DEL "$(conf '' host-local)"
[ "$rc" -eq 0 ] && ok "del: exit 0" || bad "del: exit $rc" "$out"
called "del: epair destroyed" "ifconfig epair0a destroy"
called "del: addresses released" "host-local DEL"
[ ! -e "$T/state/$CNI_CONTAINERID" ] && ok "del: state removed" || bad "del: state removed"
[ ! -e "$T/state/$CNI_CONTAINERID.gw" ] && ok "del: gateway state removed" || bad "del: gateway state removed"

run VERSION "{}"
check "version: lists 1.0.0" '.supportedVersions | index("1.0.0")'

# --- netavark plugin mode: the same file called as `epair <command> [id]`
# nv <command> <id> <json> [VAR=value...]: sets $out and $rc
nv() {
    local cmd=$1 id=$2 json=$3
    shift 3
    : > "$STUB_LOG"
    out=$(printf '%s\n' "$json" | env "$@" sh "$PLUGIN" "$cmd" $id)
    rc=$?
}
ID=$CNI_CONTAINERID
# nvnet <network fields> <network_options fields>
nvnet() { echo "{\"container_id\":\"$ID\",\"container_name\":\"Web_App\",\"network\":{\"driver\":\"epair\",\"name\":\"lan\",\"network_interface\":\"bridge0\"$1},\"network_options\":{\"interface_name\":\"eth0\"$2}}"; }

nv info "" "{}"
check "netavark info: api version" '.api_version == "1.0.0"'
nv create "" '{"name":"lan","driver":"epair"}'
[ "$rc" -eq 1 ] && ok "netavark create without a bridge: refused" || bad "netavark create without a bridge: exit $rc" "$out"
check "netavark create without a bridge: says how" '.error | test("interface-name")'
nv create "" '{"name":"lan","driver":"epair","network_interface":"bridge0"}'
check "netavark create: the network comes back" '.name == "lan" and .network_interface == "bridge0"'

nv setup "$ID" "$(nvnet ',"ipam_options":{"driver":"none"}' ',"static_ips":null,"static_mac":"0e:00:00:00:00:01"')"
[ "$rc" -eq 0 ] && ok "netavark dhcp: exit 0" || bad "netavark dhcp: exit $rc" "$out"
check "netavark dhcp: the lease in the status block" '.interfaces.eth0.subnets == [{"ipnet":"192.168.1.50/24","gateway":"192.168.1.1"}]'
check "netavark dhcp: the pinned MAC" '.interfaces.eth0.mac_address == "0e:00:00:00:00:01"'
check "netavark dhcp: no DNS server unless asked" '.dns_server_ips == []'
called "netavark dhcp: MAC set before the request" "ifconfig epair0b ether 0e:00:00:00:00:01"
grep -qF 'send host-name "web-app"' "$STUB_LOG" && ok "netavark dhcp: asks under the container's name" || bad "netavark dhcp: host-name" "$(cat "$STUB_LOG")"

nv setup "$ID" "$(nvnet ',"options":{"lease_dns":"true","mtu":"9000"}' ',"static_ips":null,"static_mac":null')"
check "netavark lease_dns: the lease's server is passed on" '.dns_server_ips == ["192.168.1.53"]'
check "netavark: the MAC the interface has" '.interfaces.eth0.mac_address == "02:00:00:00:00:0b"'
called "netavark: mtu from the network's options" "ifconfig epair0b mtu 9000"

rm -f "$T/state/$ID.gw"
nv setup "$ID" "$(nvnet ',"subnets":[{"gateway":"10.0.0.254","subnet":"10.0.0.0/16"}]' ',"static_ips":["10.0.0.9"],"static_mac":null')" CURRENT_GW4="10.99.0.1"
check "netavark static: podman's address with the subnet's prefix and gateway" '.interfaces.eth0.subnets == [{"ipnet":"10.0.0.9/16","gateway":"10.0.0.254"}]'
called "netavark static: address set in the jail" "ifconfig -j 7 eth0 inet 10.0.0.9/16"
called "netavark static: deletes foreign default route" "route -j 7 delete default 10.99.0.1"
called "netavark static: the network's gateway, not a guess" "route -j 7 add default 10.0.0.254"
not_called "netavark static: no DHCP request" "dhclient"

# Multi-LAN and mixed under netavark mode: priv -> lan1 -> lan2 keeps lan1
rm -f "$T/state/$ID.gw"
nv setup "$ID" "$(nvnet ',"subnets":[{"gateway":"192.168.86.1","subnet":"192.168.86.0/24"}]' ',"static_ips":["192.168.86.9"],"static_mac":null')" CURRENT_GW4="10.89.0.1"
called "netavark priv->lan1->lan2: lan1 replaces 10.89.0.1" "route -j 7 delete default 10.89.0.1"
called "netavark priv->lan1->lan2: lan1 adds 192.168.86.1" "route -j 7 add default 192.168.86.1"
nv setup "$ID" "$(nvnet ',"subnets":[{"gateway":"192.168.4.1","subnet":"192.168.4.0/24"}]' ',"static_ips":["192.168.4.9"],"static_mac":null')" CURRENT_GW4="192.168.86.1"
not_called "netavark priv->lan1->lan2: lan2 keeps lan1 default" "route -j 7 delete"
not_called "netavark priv->lan1->lan2: lan2 adds nothing" "route -j 7 add default"

nv setup "$ID" "$(nvnet '' ',"static_ips":["10.0.0.9"]')" FAIL_MATCH="vnet"
[ "$rc" -eq 1 ] && ok "netavark failed move: exit 1" || bad "netavark failed move: exit $rc" "$out"
check "netavark failed move: the reason, as netavark reads errors" '.error | test("move epair0b")'
called "netavark failed move: epair destroyed" "ifconfig epair0a destroy"

echo epair0a > "$T/state/$ID"
nv teardown "$ID" "$(nvnet '' '')"
[ "$rc" -eq 0 ] && ok "netavark teardown: exit 0" || bad "netavark teardown: exit $rc" "$out"
called "netavark teardown: epair destroyed" "ifconfig epair0a destroy"
[ ! -e "$T/state/$ID" ] && ok "netavark teardown: state removed" || bad "netavark teardown: state removed"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
