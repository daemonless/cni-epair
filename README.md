# cni-epair

A CNI plugin that gives FreeBSD containers an address on a real LAN segment, by
creating an `epair` per container and attaching one end to a host bridge.

FreeBSD has no macvlan. The bridge + epair pair is the native equivalent, and
this plugin is what stands in for the upstream `macvlan` plugin on these hosts.

## Installing it as `epair`

CNI resolves a network's `type` to a binary of that name in
`/usr/local/libexec/cni/`, so the plugin is installed as:

```
/usr/local/libexec/cni/epair
```

podman will not *create* a network with an unknown driver (`--driver epair`
fails with "unsupported driver"), but it reads the driver straight from the
conflist, so the sequence is:

```sh
podman network create --driver macvlan --subnet ... --interface-name <bridge> <name>
sed -i '' 's/"type": "macvlan"/"type": "epair"/' /usr/local/etc/cni/net.d/<name>.conflist
```

`podman network ls` then reports `driver: epair`, which is the truth.

**Do not install it as `macvlan`.** That was the original arrangement and it is
a trap. `containernetworking-plugins` ships no `macvlan` plugin on FreeBSD, so
squatting that name buys nothing, and the file ends up owned by no package at
all: `pkg` cannot verify it, will not reinstall it, and nothing restores it if a
host rebuild or a stray cleanup removes it. It also makes `podman network ls`
lie about what is doing the work. Under its own name the file is still
unpackaged, but at least it is honestly named and nothing else claims it.

The per-network `sed` is the cost of this approach. It is easy to forget, so it
belongs in whatever provisions the network rather than in someone's memory.

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
| `bridge` | yes | host bridge to attach the epair to |
| `mtu` | no | interface MTU, default 1500 |

IPAM must supply `ips[].address` and `ips[].gateway`. Capabilities: `mac`, `ips`.

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
install -m 755 epair /usr/local/libexec/cni/epair
```

Verify what is installed:

```sh
head -3 /usr/local/libexec/cni/epair   # should be a shell script, not ELF
podman network ls                      # networks using it report driver: epair
```

## Where it runs

Installed on **jupiter**, the only host with bridged container networks. saturn
has no copy; venus is Linux and uses the upstream plugins.

| network | bridge | subnet |
|---|---|---|
| `vlan5` | `vlan5bridge` | 192.168.5.0/24 |
| `lan86` | `bridge86` | 192.168.86.0/24 |

Both conflists name `epair`. A second copy of this script remains installed as
`macvlan`; nothing references it any more and it can be removed once both
networks have been through a container restart on the new name.

## Fixes

The plugin ran in production for nine months before these were found. Both are
worth knowing about if you are reading the code or porting the idea.

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

- When a static IP arrives via `CNI_ARGS` rather than IPAM, the gateway is
  guessed as `.1` of that subnet and a missing prefix is assumed to be `/24`.
- `get_jail_id` falls back to progressively looser matches against `jls` output,
  the last of which greps the whole line — a container id prefix appearing in a
  path could in principle select the wrong jail.
- JSON is parsed with `sed` and `grep` to avoid a `jq` dependency, so keys are
  matched anywhere in the document rather than at a known position. This holds
  because CNI configs are small and flat.
