# Networking in Firecracker Mode

RunCVM Firecracker Edition supports robust networking capabilities, matching standard Docker behavior while maintaining microVM isolation.

## Supported Network Modes

| Docker Network Mode | RunCVM Support | Implementation Details |
|---------------------|----------------|------------------------|
| **Bridge (Default)** | ✅ Full | Uses bridge devices, standard Docker IPAM. |
| **Custom Networks** | ✅ Full | Supports multiple networks/NICs per container. |
| **Host (`--net=host`)** | ✅ Full* | Uses NAT/TAP with IP Masquerading. |
| **None (`--net=none`)** | ✅ Full | No network interfaces created. |

---

## Multiple Network Interfaces (Multi-NIC)

RunCVM automatically detects when a container is attached to multiple Docker networks and creates corresponding network interfaces inside the Firecracker microVM.

### Usage
Simply use the standard Docker syntax:
```bash
docker run --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  --net runcvm-net1 \
  --net runcvm-net2 \
  alpine ip a
```

**Result inside VM:**
- `eth0`: Connected to `runcvm-net1`
- `eth1`: Connected to `runcvm-net2`
- Separate gateways and routes are configured automatically.

---

## Host Networking (`--net=host`)

> [!IMPORTANT]
> **Requirement**: Host networking REQUIRES the `--privileged` flag to configure NAT tables and IP forwarding.

In standard Docker, `--net=host` removes network isolation, sharing the host's network namespace. In Firecracker, we cannot share the host's physical interface directly without breaking host connectivity. Instead, RunCVM uses a **NAT/TAP** approach.

### How it Works
1. RunCVM creates a `tap0` device connected to the VM.
2. The VM is assigned a private Link-Local IP (`169.254.100.2`).
3. RunCVM configures IP Masquerading (NAT) on the host's default gateway.
4. Outbound traffic from the VM appears to come from the host's IP.

### Usage
You must specify **both** `--net=host` and the explicit `RUNCVM_NETWORK_MODE=host` environment variable:

```bash
docker run --rm --privileged --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_NETWORK_MODE=host \
  --net=host \
  alpine ip a
```

### Limitations
- The VM does **not** see the host's full list of interfaces (it sees `eth0` as the TAP).
- Inbound ports are not automatically opened on the host (unlike true `--net=host`). Use standard `-p` port mapping if you need inbound access, although outbound is "open".

---

## Troubleshooting

### "Read-only file system" / "iptables not found"
If you see errors related to `ip_forward` or `iptables` when using Host Mode, start the container with `--privileged`. This is required to modify network stack rules on the host runner.

```bash
docker run --privileged ...
```
