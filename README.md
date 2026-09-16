# cni-epair

A CNI plugin that gives FreeBSD containers an address on a real LAN segment, by
creating an `epair` per container and attaching one end to a host bridge.

FreeBSD has no macvlan. The bridge + epair pair is the native equivalent, and
this plugin is what stands in for the upstream `macvlan` plugin on these hosts.

## Creating a network

Write the conflist directly. CNI resolves a network's `type` to a binary of
that name in `/usr/local/libexec/cni/`, and podman reads every conflist in
`/usr/local/etc/cni/net.d/`, so the file is the whole interface:

```sh
tee /usr/local/etc/cni/net.d/vlan4.conflist >/dev/null <<'EOF'
{
  "cniVersion": "0.4.0",
  "name": "vlan4",
  "plugins": [
    {
      "type": "epair",
      "master": "vlan4bridge",
      "ipam": {
        "type": "host-local",
        "routes": [{"dst": "0.0.0.0/0"}],
        "ranges": [[{"subnet": "192.168.4.0/24", "gateway": "192.168.4.1"}]]
      },
      "capabilities": {"ips": true}
    }
  ]
}
EOF
```

Change `name`, `master` and `subnet`/`gateway`; the filename matches `name`.
`master` is the **host bridge**, not the physical NIC. `podman network ls` then
reports the network with driver `epair`.

Copy-ready configs are in `examples/`:

| file | shows |
|---|---|
| `vlan.conflist` | the above -- a bridge, a subnet, a gateway |
| `lan.conflist` | an explicit MTU, a restricted address range, MAC assignment |

`rangeStart`/`rangeEnd` confine automatic allocation to part of the subnet,
which is what you want when the rest of the segment is handed out by a DHCP
server or used by static addresses.

**Do not use `podman network create`.** It validates `--driver` against its own
list -- bridge, macvlan, ipvlan -- and refuses anything else, so it cannot
create an epair network. Going through it means creating the network under a
driver name that is not what runs, then rewriting the file afterwards: an extra
step that, when forgotten, silently routes the network to whatever binary is
installed as `macvlan`.

## What it does

On `ADD` it creates an `epair`, attaches the `a` side to the configured bridge,
moves the `b` side into the container's jail, and applies the address IPAM
returned. On `DEL` it tears the epair down again. `CHECK` and `VERSION` are
implemented, so it satisfies the CNI contract podman expects.

It shells out to the IPAM plugin named in the network config (`host-local` on
these hosts) rather than allocating addresses itself, and parses JSON with `sed`
and `grep` to avoid a `jq` dependency.

Config keys, from the plugin's own header:

| key | required | meaning |
|---|---|---|
| `master` | yes | host bridge to attach the epair to (`bridge` is accepted too) |
| `mtu` | no | interface MTU, default 1500 |

IPAM must supply `ips[].address` and `ips[].gateway`. Capabilities: `ips` lets
a container ask for a fixed address (compose's `ipv4_address`), `mac` for a
fixed MAC.

## Runtime state

| path | purpose |
|---|---|
| `/var/run/cni/freebsd-epair` | container id → epair name, so `DEL` can find it |
| `/var/run/cni-freebsd-epair.lock` | serialises concurrent ADD/DEL |
| `/var/log/cni-freebsd-epair.log` | all logging; stderr is redirected here so it cannot corrupt the JSON podman parses |

These keep their original `freebsd-epair` spelling even though the plugin is
now named `epair`: renaming them would orphan the state of every container
already running. Each can be overridden with `CNI_EPAIR_STATE`, `CNI_EPAIR_LOCK`
and `CNI_EPAIR_LOG`, which is what makes the plugin testable off a real host.

## Install

```sh
pkg install cni-epair
```

Or by hand:

```sh
install -m 555 epair /usr/local/libexec/cni/epair
```

Verify what is installed:

```sh
head -3 /usr/local/libexec/cni/epair   # should be a shell script, not ELF
podman network ls                      # networks using it report driver: epair
```

## Fixes

Both are worth knowing about if you are reading the code or porting the idea.
Fixed in 1.0.0.

**A failed ADD reported success.** None of the commands that build the network
checked their exit status, and each discarded stderr. If the epair could not be
moved into the jail, the following steps failed too and the plugin still printed
a well-formed result claiming the address was configured. The runtime believed
the container was on the network; the container had no interface at all — which
looks like an application fault, not a networking one, and is correspondingly
expensive to diagnose.

Every step that builds the network is now checked. A failure returns a CNI error
naming the step, and destroys the epair it had already created rather than
leaking it onto the bridge.

**The lock could be released by the wrong process.** `lock()` installed an `EXIT`
trap to clean up, which `unlock()` never cleared. The trap fired again at process
exit and removed whatever lock directory existed by then — under concurrency,
the one another invocation had just acquired. `unlock()` now clears the trap
first.

Both paths are exercised with stubbed `ifconfig`, `jexec` and `jls`: a forced
failure returns a CNI error and exit 1 with the epair cleaned up; the success
path returns a valid result and exit 0.

## Known limitations

- State is keyed by container id alone, so a container attached to two epair
  networks records only one of them. Tearing such a container down removes the
  wrong interface and leaks the other.
- When a static IP arrives via `CNI_ARGS` rather than IPAM, the gateway is
  guessed as `.1` of that subnet and a missing prefix is assumed to be `/24`.
- `get_jail_id` falls back to progressively looser matches against `jls` output,
  the last of which greps the whole line — a container id prefix appearing in a
  path could in principle select the wrong jail.
- JSON is parsed with `sed` and `grep` to avoid a `jq` dependency, so keys are
  matched anywhere in the document rather than at a known position. This holds
  because CNI configs are small and flat.
