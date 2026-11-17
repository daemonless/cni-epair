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

# --- a static address from CNI_ARGS
run ADD "$(conf '' static)" CNI_ARGS="IP=10.0.0.5/24"
[ "$rc" -eq 0 ] && ok "static: exit 0" || bad "static: exit $rc" "$out"
check "static: address and guessed gateway" '.ips[0].address == "10.0.0.5/24" and .ips[0].gateway == "10.0.0.1"'
check "static: no dns without a lease" 'has("dns") | not'
called "static: address set in the jail" "ifconfig -j 7 eth0 inet 10.0.0.5/24"
not_called "static: no MTU set on a 1500 bridge" " mtu "
[ "$(cat "$T/state/$CNI_CONTAINERID")" = epair0a ] && ok "static: state recorded" || bad "static: state recorded"

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
check "dhcp: lease DNS in the result" '.dns.nameservers == ["192.168.1.53"]'
grep -qF 'send host-name "web-app"' "$STUB_LOG" && ok "dhcp: asks under the container's name" || bad "dhcp: host-name" "$(cat "$STUB_LOG")"
[ -z "$(ls "$T/run")" ] && ok "dhcp: run dir cleaned up" || bad "dhcp: run dir left" "$(ls -R "$T/run")"

# --- host-local from CNI_PATH, both families in either order
run ADD "$(conf '' host-local)" CNI_ARGS=""
check "host-local: v4 and v6" '[.ips[].address] == ["10.88.0.5/24", "fd00::5/64"]'
check "host-local: gateways by family" '[.ips[].gateway] == ["10.88.0.1", "fd00::1"]'
called "host-local: v6 enabled first" "ifconfig -j 7 eth0 inet6 -ifdisabled"
run ADD "$(conf '' no-such-ipam)" CNI_ARGS=""
check "missing IPAM: refused by name" '.code == 100 and (.msg | test("no-such-ipam"))'

# --- DEL destroys the epair and releases the addresses
echo epair0a > "$T/state/$CNI_CONTAINERID"
run DEL "$(conf '' host-local)"
[ "$rc" -eq 0 ] && ok "del: exit 0" || bad "del: exit $rc" "$out"
called "del: epair destroyed" "ifconfig epair0a destroy"
called "del: addresses released" "host-local DEL"
[ ! -e "$T/state/$CNI_CONTAINERID" ] && ok "del: state removed" || bad "del: state removed"

run VERSION "{}"
check "version: lists 1.0.0" '.supportedVersions | index("1.0.0")'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
