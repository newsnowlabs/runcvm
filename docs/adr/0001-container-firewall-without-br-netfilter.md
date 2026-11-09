# ADR 0001: Container firewall rules without `br_netfilter`

Status: accepted

## Context

Each RunCVM container joins its network interface to the VM's tap device with a Linux bridge. Some of the VM's traffic is for RunCVM's own services in the container, not for the network beyond the bridge:

- the VM's replies to `docker exec`'s connections, which `dbclient` makes from the bridge's address, source-NATed to RunCVM's DNS address;
- the VM's DNS requests to `dnsmasq`, where `dnsmasq` is its DNS server;
- in VNC display mode, connections to QEMU's VNC server, published from the host.

Such traffic crosses the bridge, so the container's IPv4 stack sees it only if something hands it from the bridge to that stack. Two mechanisms can:

1. **`br_netfilter`**: with this module loaded on the host (and `bridge-nf-call-iptables`, its default, in the container's network namespace), bridged IPv4 packets also traverse the `ip` family's netfilter hooks, where `nat` rules (`REDIRECT`, `SNAT`) can claim them.
2. **Bridge-family `nf_tables` rules**: a rule in the bridge's `prerouting` hook rewrites the destination MAC address to the bridge's own and sets the packet type to `host`, so the bridge delivers the packet to the container's stack instead of forwarding it; `ip` family `nat` rules then hand it to the service.

## Decision

RunCVM uses bridge-family `nf_tables` rules (mechanism 2), installed with `nft` in each container by `runcvm-ctr-entrypoint`, and does not use `br_netfilter`.

- `br_netfilter` is a host-wide setting: once loaded, it passes every bridged IPv4 packet on the host, not only RunCVM's, through the `ip` family hooks. Many hosts do not load it, and RunCVM would otherwise have to load it, or require it, on the host.
- The bridge-family rules match only RunCVM's own traffic, by arrival interface, addresses and ports; everything else crosses the bridge unchanged.
- The host's kernel needs `CONFIG_NF_TABLES_BRIDGE` and `CONFIG_NFT_BRIDGE_META` (listed, with RunCVM's other kernel requirements, in the README's [System requirements](../../README.md#system-requirements)). The kernels of common distributions provide both. Where they are missing, `runcvm-ctr-entrypoint` cannot install the rules and stops the container with an error that names them.

## Plan if `br_netfilter` support is needed

If a host turns up whose kernel provides `br_netfilter` and `ip` family `nf_tables` but not bridge-family `nf_tables`, RunCVM can support it with a second rule set, rather than requiring a different kernel:

- **Rules:** the same effect as mechanism 1, written for `nft` (not `iptables`, so no `xtables` binaries return to RunCVM's package): in the `ip` family `nat` table, `prerouting` rules redirecting UDP port 53 to RunCVM's DNS address, and (in VNC display mode) the VNC port, to the container; and `postrouting` rules source-NATing the bridge's traffic to the VM (TCP to `dropbear`'s port, to RunCVM's DNS address; DNS, to the container's address).
- **Address:** RunCVM's DNS address, which must not clash with an address the host's network uses, such as cloud metadata services' `169.254.169.254`.
- **Selection:** automatic, in `runcvm-ctr-entrypoint`: the bridge-family rule set where it loads; otherwise, where `/proc/sys/net/bridge/bridge-nf-call-iptables` exists in the container (i.e. `br_netfilter` is loaded on the host), the `br_netfilter` rule set; otherwise, the error described under Decision, naming both options. A setting to force one rule set may help testing.
- **Testing:** the integration tests' networking, `docker exec`, DNS and VNC tests (such as `24-networking`, `35-exec-args`, `36-vnc` and `38-multi-network`) under each rule set, the `br_netfilter` one on a host with the module loaded and with `rp_filter` at both 1 and 2, and a test that the selection falls back as described.

Until such a host is reported, RunCVM keeps one rule set: a second would need its own testing, on every change to RunCVM's networking, for hosts that are not known to exist.
