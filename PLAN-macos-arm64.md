# Plan: RunCVM macOS ARM64 Compatibility

**Branch:** `claude/macos-docker-compatibility-InrFB`
**Goal:** Enable RunCVM to work inside the Linux VMs that back Docker/Podman on
suitably recent ARM64 macOS (Apple Silicon M-series, macOS 15+), specifically:
- **Lima `template:docker`** — Ubuntu VM running dockerd, nested KVM available
  after setting `nestedVirtualization: true`
- **Podman Desktop** — Fedora CoreOS VM running Podman, nested KVM available
  (enabled by default in recent versions)

---

## Background

RunCVM intercepts OCI `runc create/exec` calls, modifies `config.json` to
redirect execution to QEMU, and launches a micro-VM inside the container.

On macOS, Docker/Podman do not run natively — they operate inside a Linux VM
provided by Lima or Podman Desktop. That Linux VM is `aarch64`. With nested
virtualisation enabled, `/dev/kvm` is available inside it, making KVM-
accelerated QEMU feasible.

The current codebase is **exclusively x86_64**: the build system, binary
bundles, kernels, and some script shebangs all hardcode x86_64.

---

## Gap Analysis

### 1. Build system (`Dockerfile`)

| Item | Current | Required |
|---|---|---|
| QEMU binary | `qemu-system-x86_64` (apk) | `qemu-system-aarch64` on arm64 |
| UEFI firmware | `ovmf` (x86_64 OVMF) | `aavmf` (ARM UEFI) on arm64 |
| SeaBIOS build stage | always runs | skip on arm64 (ISA-bus, x86 only) |
| Alpine pkg COPY paths | `/root/packages/main/x86_64` | `/root/packages/main/aarch64` on arm64 |
| `BUNDELF_BINARIES` env | includes `qemu-system-x86_64` | `qemu-system-aarch64` on arm64 |
| Debian kernel stage | `amd64/debian:bookworm` + `linux-image-amd64` | `arm64/debian:bookworm` + `linux-image-arm64` |
| Ubuntu kernel stage | `amd64/ubuntu:jammy` + `linux-image-generic:amd64` | `arm64/ubuntu:jammy` + `linux-image-generic:arm64` |
| Alpine/OpenWrt kernels | build natively | build natively (APK selects correct arch) |
| OracleLinux kernel | `oraclelinux:9` (amd64 on Docker Hub) | `oraclelinux:9` arm64 variant |
| `runcvm-runtime` shebang patch | not done at build time | detect ld-musl arch, patch during installer stage |

Docker BuildKit exposes `TARGETARCH` (`amd64`/`arm64`) and `TARGETPLATFORM`
(`linux/amd64`/`linux/arm64`) as ARGs, which should be used to condition all
architecture-specific steps.

Alpine package paths follow the kernel `uname -m` convention:
- x86_64 → `/root/packages/main/x86_64`
- aarch64 → `/root/packages/main/aarch64`

The Dockerfile should use `ARG TARGETARCH` / `ARG TARGETPLATFORM` (automatically
set by BuildKit) and `RUN --mount` or shell conditionals to select the right paths.

### 2. `runcvm-runtime` — hardcoded x86_64 shebang

```
#!/opt/runcvm/lib/ld-musl-x86_64.so.1 /opt/runcvm/bin/bash
```

This is the OCI runtime binary invoked directly by dockerd/podman.
On `aarch64`, the musl dynamic linker is `ld-musl-aarch64.so.1`.

**Fix:** In the `installer` Dockerfile stage, after copying scripts, detect the
architecture and patch the shebang:

```dockerfile
RUN LD_BIN=$(ls /opt/runcvm/lib/ld-musl-*.so.1 | head -1 | xargs basename) && \
    sed -i "1s|.*|#!/opt/runcvm/lib/${LD_BIN} /opt/runcvm/bin/bash|" \
      /opt/runcvm/scripts/runcvm-runtime
```

### 3. `runcvm-ctr-qemu` — ARM64 missing KVM acceleration

The current ARM64 branch:
```bash
if [ "$RUNCVM_QEMU_ARCH" = "arm64" ]; then
  CMD="$(which qemu-system-aarch64)"
  MACHINE+=(-cpu max -machine virt,gic-version=max,usb=off)
```

With `/dev/kvm` available (nested virt), this should become:
```bash
if [ "$RUNCVM_QEMU_ARCH" = "arm64" ]; then
  CMD="$(which qemu-system-aarch64)"
  if [ -e /dev/kvm ]; then
    MACHINE+=(-cpu host -machine virt,accel=kvm,gic-version=max,usb=off)
  else
    MACHINE+=(-cpu max -machine virt,gic-version=max,usb=off)
  fi
```

The `-cpu host` flag (passing through the physical CPU) requires KVM; without
it, `-cpu max` emulates the widest possible feature set in software.

### 4. `runcvm-ctr-qemu` — SeaBIOS fw_cfg option on ARM64

The line:
```bash
OPTS+=(-fw_cfg opt/org.seabios/etc/sercon-port,string=0)
```
is guarded by `if [ "$RUNCVM_BIOS_DEBUG" != "1" ]` but is **not** guarded by
architecture. QEMU emits a warning on ARM64 for unknown fw_cfg paths from
SeaBIOS. This should be further restricted to x86_64.

### 5. `runcvm-runtime` — `RUNCVM_QEMU_ARCH` is never auto-detected

`runcvm-ctr-qemu` branches on `RUNCVM_QEMU_ARCH` but the variable is only set
by the user via `--env=RUNCVM_QEMU_ARCH=arm64`. It should be auto-detected from
`uname -m` in `runcvm-runtime` at `create` time, then set as a container env var
(via `set_config_env`), falling back to user-supplied value if present.

```bash
# In runcvm-runtime, during 'create':
RUNCVM_QEMU_ARCH_HOST=$(uname -m)
case "$RUNCVM_QEMU_ARCH_HOST" in
  aarch64) RUNCVM_QEMU_ARCH_DEFAULT="arm64" ;;
  x86_64)  RUNCVM_QEMU_ARCH_DEFAULT="x86_64" ;;
  *)       RUNCVM_QEMU_ARCH_DEFAULT="x86_64" ;;
esac
RUNCVM_QEMU_ARCH=$(get_config_env "RUNCVM_QEMU_ARCH" "$RUNCVM_QEMU_ARCH_DEFAULT")
set_config_env "RUNCVM_QEMU_ARCH" "$RUNCVM_QEMU_ARCH"
```

### 6. `runcvm-ctr-defaults` — missing `qemu-system-aarch64` alias

`create_aliases` lists `qemu-system-x86_64` but not `qemu-system-aarch64`.
Add it alongside `qemu-system-x86_64`.

### 7. `runcvm-install-runtime.sh` — Podman Desktop / Lima awareness

The install script currently:
- Requires the `docker` binary; fails if only `podman` is present
- Restarts dockerd via systemd, sysvinit, or docker-init (GitHub Codespaces)
- Has no awareness of Lima or Podman Desktop VM environments

Required improvements:

**a. Podman Desktop support**

Podman Desktop on macOS uses a Fedora CoreOS VM. The Podman daemon (`podman
system service`) replaces dockerd. Inside the VM, the container runtime
configuration is `/etc/containers/containers.conf`. The install script should:

- Detect when `podman` is available but `docker` is not
- Install to `/opt/runcvm` as before (same binary layout)
- Write to `/etc/containers/containers.conf` instead of `/etc/docker/daemon.json`
- Restart `podman.socket` or skip restart (Podman is socket-activated and picks
  up runtime config on next invocation without a restart)

**b. Lima `template:docker` support**

The Lima docker VM presents as a standard Ubuntu system with systemd and
dockerd. The existing systemd restart path in `docker_restart` should work.
However:

- Lima VMs may have `docker.service` managed differently (socket-activated);
  confirm `systemctl restart docker` is correct vs `systemctl restart docker.socket`
- Consider detecting Lima environment (presence of `/etc/lima*` files or the
  `LIMA_HOME` env) to emit a helpful context message

**c. General: distinguish container runtime type early**

Add a `RUNTIME` variable (values: `docker`, `podman`) detected at the top of
the install script, and branch all runtime-specific steps on it.

### 8. Container device access — `/dev/kvm` inside Podman containers

`runcvm-runtime` already adds `/dev/kvm` (major 10, minor 232) to
`linux.devices` and `linux.resources.devices` in `config.json`. This should
work for both Docker and Podman. However, Podman's default security policy
(SELinux on Fedora CoreOS) may deny access; the install script should note
that `--security-opt label=disable` or equivalent may be required for Podman
if SELinux is enforcing.

Note: `runcvm-runtime` already sets `.linux.seccomp |= empty` (seccomp
unconfined), which is correct, but SELinux is a separate concern.

---

## Proposed Implementation Order

### Phase 1 — Auto-detect architecture; ARM64 KVM (runtime, no rebuild needed)

These changes are pure script changes and can be tested immediately without
rebuilding the Docker image (by editing scripts in `/opt/runcvm/scripts/`):

1. **`runcvm-runtime`**: Auto-detect and set `RUNCVM_QEMU_ARCH` from `uname -m`
2. **`runcvm-ctr-qemu`**: Enable `-cpu host -machine virt,accel=kvm,...` when
   `/dev/kvm` is present on ARM64
3. **`runcvm-ctr-qemu`**: Guard SeaBIOS fw_cfg opt within the x86_64 branch
4. **`runcvm-ctr-defaults`**: Add `qemu-system-aarch64` to `create_aliases`

### Phase 2 — Multi-arch build system (Dockerfile)

5. Add `ARG TARGETARCH` to all relevant stages
6. Conditionalize QEMU package installation (`qemu-system-x86_64` vs `qemu-system-aarch64`)
7. Conditionalize UEFI firmware (`ovmf` vs `aavmf`)
8. Skip SeaBIOS build stage entirely on `arm64` (or make it a no-op)
9. Fix Alpine package COPY paths: replace hardcoded `x86_64` with `${ARCH}`
   (using a `RUN` step to copy into a fixed path, or using BuildKit `ARG TARGETARCH`)
10. Add arm64 kernel build stages:
    - Alpine/OpenWrt: these build natively and should work without changes
    - Debian: add `FROM --platform=linux/arm64 debian:bookworm as debian-kernel-arm64`
      installing `linux-image-arm64`
    - Ubuntu: add `FROM --platform=linux/arm64 ubuntu:jammy as ubuntu-kernel-arm64`
      installing `linux-image-generic`
    - OracleLinux: add `FROM --platform=linux/arm64 oraclelinux:9 as oracle-kernel-arm64`
11. In `installer` stage: patch `runcvm-runtime` shebang for detected arch
12. In `installer` stage: copy correct arch kernel sets into the final image

### Phase 3 — Install script improvements

13. **`runcvm-install-runtime.sh`**: Add `RUNTIME` detection (`docker` vs `podman`)
14. **`runcvm-install-runtime.sh`**: Add Podman runtime install path
    (write `containers.conf`, no restart needed)
15. **`runcvm-install-runtime.sh`**: Add Lima environment detection and guidance
16. **`runcvm-install-runtime.sh`**: Add note about SELinux for Podman Desktop

### Phase 4 — Documentation & testing

17. Update `README.md` with macOS ARM64 prerequisites:
    - Lima: `limactl start --set='.nestedVirtualization=true' template://docker`
    - Podman Desktop: enable nested virtualisation in VM settings (recent versions
      default to enabled)
    - Verify `/dev/kvm` exists before installing
18. Add `tests/` smoke-test that validates a RunCVM container launches on arm64

---

## Key Constraints and Notes

- **KVM detection at runtime is the right approach** — hard-requiring KVM would
  break non-nested environments; fall back to software emulation gracefully.
- **The `vhost-net` acceleration** (`RUNCVM_QEMU_NET_VHOST=1`) requires
  `/dev/vhost-net`, which may not be available in all nested-virt environments.
  Leave it off-by-default and document it as optional.
- **`aio=io_uring`** on disk devices requires kernel ≥ 5.1 with io_uring
  enabled. Lima Ubuntu 24.04 and Podman Desktop Fedora CoreOS both satisfy this.
- **`memory-backend-file` with `mem-path=/dev/shm`** should work on both
  platforms; `hugetlb` may not be available in nested VMs and should remain
  opt-in.
- **Alpine pkg COPY paths**: Docker BuildKit's `TARGETARCH` is `amd64`/`arm64`
  (not `x86_64`/`aarch64`). Need to map: `amd64→x86_64`, `arm64→aarch64`.
  This mapping should be done once with a `RUN` helper and reused.
- **SeaBIOS is x86-only** — the SeaBIOS build stage and the related QEMU
  `fw_cfg` option must be entirely excluded on ARM64 builds.
- **AAVMF (ARM UEFI)** is only needed if booting via EFI (`RUNCVM_BIOS=EFI`).
  RunCVM normally boots directly with `-kernel`/`-initrd` which bypasses
  firmware, so AAVMF is optional but useful to include for completeness.
- **Podman Desktop vs Lima/Docker**: These are genuinely different runtimes.
  The install script needs to detect which is in use and configure accordingly.
  A user inside a Lima docker VM will have `docker`; a user inside a Podman
  Desktop VM will have `podman` but not `docker`.
