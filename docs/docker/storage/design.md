# Firecracker Storage Design Document

## Executive Summary

This document outlines the storage architecture design for RunCVM's Firecracker integration. Unlike QEMU which supports virtiofs for live filesystem sharing, Firecracker has a minimal device model that requires alternative approaches for Docker volume mounts.

**Key Decision**: We will implement a 3-layer architecture using **virtio-blk** (transport) + **Single Block Device with Bind Mounts** (volume strategy) + **9P over vsock** (sync strategy) to achieve feature parity with QEMU's virtiofs while maintaining Firecracker's fast boot times.

---

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [Architecture Overview](#architecture-overview)
3. [Layer 1: Transport](#layer-1-transport)
4. [Layer 2: Volume Strategy](#layer-2-volume-strategy)
5. [Layer 3: Sync Strategy](#layer-3-sync-strategy)
6. [Final Architecture Decision](#final-architecture-decision)
7. [Implementation Plan](#implementation-plan)
8. [Kernel Configuration Requirements](#kernel-configuration-requirements)
9. [References](#references)

---

## Problem Statement

### The Failed Test Case

```bash
# This test currently fails with Firecracker
mkdir -p /tmp/test-rw
echo "initial" > /tmp/test-rw/data.txt

docker run --rm \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v /tmp/test-rw:/data \
  alpine sh -c 'echo "modified from Firecracker" >> /data/data.txt'

cat /tmp/test-rw/data.txt  # Should show "modified" but doesn't work
```

### Root Cause: Firecracker Doesn't Support virtiofs

| Hypervisor | Filesystem Sharing | Status |
|------------|-------------------|--------|
| QEMU | virtiofs | ✅ Supported |
| Firecracker | virtiofs | ❌ Not supported |

**Why Firecracker doesn't support virtiofs:**

1. **Minimal Device Model**: Firecracker only supports 5 devices: virtio-net, virtio-block, virtio-vsock, serial console, and keyboard controller
2. **Security Concerns**: The Firecracker team rejected a virtiofs PR due to the large attack surface
3. **Design Philosophy**: Firecracker is built for short-lived serverless workloads (AWS Lambda) where live filesystem access is "unnecessary"

> "This is the kind of thing we need to really reflect on before merging since it's both a large piece of functionality, and a large new attack surface."
> — Firecracker maintainers on virtiofs PR #1351

### Options to Add virtiofs Support

| Option | Feasibility | Recommendation |
|--------|-------------|----------------|
| Modify Firecracker source | Hard - requires fork, rejected by upstream | ❌ Not recommended |
| Workarounds in RunCVM | Achievable - uses existing Firecracker features | ✅ Recommended |

---

## Architecture Overview

We use a 3-layer architecture to solve the storage problem:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        LAYER 3: SYNC STRATEGY                           │
│                  "How do changes get back to host?"                     │
│                                                                         │
│   Options: Sync on Exit | Periodic Sync | Inotify | 9P | NFS | FUSE    │
├─────────────────────────────────────────────────────────────────────────┤
│                     LAYER 2: VOLUME STRATEGY                            │
│               "How do we handle multiple -v mounts?"                    │
│                                                                         │
│   Options: One Device Per Volume | Single Device + Bind Mounts         │
├─────────────────────────────────────────────────────────────────────────┤
│                     LAYER 1: TRANSPORT                                  │
│                "How does storage get into the VM?"                      │
│                                                                         │
│   Options: virtio-blk (only option for Firecracker)                    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Layer 1: Transport

### Available Options

| Option | Firecracker Support | Description |
|--------|---------------------|-------------|
| **virtio-blk** | ✅ Supported | Block device emulation via virtio-mmio |
| virtiofs | ❌ Not supported | Live filesystem sharing (QEMU only) |
| virtio-scsi | ❌ Not supported | SCSI device emulation |
| NVMe | ❌ Not supported | NVMe device emulation |

### Decision: virtio-blk

**Rationale**: This is the only storage transport option available in Firecracker.

```
┌──────────────┐                      ┌──────────────┐
│     Host     │      virtio-blk      │     VM       │
│              │  ==================► │              │
│  file.ext4   │   (block device)     │  /dev/vdb    │
└──────────────┘                      └──────────────┘
```

### Firecracker virtio-blk Constraints

| Constraint | Limit | Notes |
|------------|-------|-------|
| Max block devices | ~28 usable | 32 total minus rootfs, net, vsock, console |
| Hotplug support | ❌ None | All devices must be attached before VM starts |
| Pre-formatting | Required | Devices must have filesystem before boot |

---

## Layer 2: Volume Strategy

### Problem Statement

When a user runs:
```bash
docker run -v /hostA:/dataA -v /hostB:/dataB -v /hostC:/dataC ...
```

How do we map multiple host directories into the Firecracker VM?

### Option A: One Block Device Per Volume

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│ /hostA      │  │ /hostB      │  │ /hostC      │
│     ▼       │  │     ▼       │  │     ▼       │
│ volA.ext4   │  │ volB.ext4   │  │ volC.ext4   │
│     ▼       │  │     ▼       │  │     ▼       │
│ /dev/vdb    │  │ /dev/vdc    │  │ /dev/vdd    │
└─────────────┘  └─────────────┘  └─────────────┘
      3 separate virtio-blk devices
```

| Pros | Cons |
|------|------|
| Simple implementation | Limited to ~28 volumes |
| Independent I/O | Slow startup (+50-200ms per volume) |
| Easy to reason about | Higher memory overhead |

**Startup Time Impact:**
- 1 volume: ~300ms
- 5 volumes: ~500ms
- 10 volumes: ~800ms
- 20 volumes: ~1.5s (approaching QEMU boot time!)

### Option B: Single Block Device with Bind Mounts

```
┌─────────────────────────────────────────────────────────────┐
│  Staging directory: /tmp/volumes/                           │
│    ├── dataA/  (copy of /hostA)                             │
│    ├── dataB/  (copy of /hostB)                             │
│    └── dataC/  (copy of /hostC)                             │
└─────────────────────────────────────────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Single ext4 image: volumes.ext4                            │
└─────────────────────────────────────────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  VM: /dev/vdb mounted at /mnt/volumes                       │
│    mount --bind /mnt/volumes/dataA → /dataA                 │
│    mount --bind /mnt/volumes/dataB → /dataB                 │
│    mount --bind /mnt/volumes/dataC → /dataC                 │
└─────────────────────────────────────────────────────────────┘
              1 virtio-blk device, unlimited volumes
```

| Pros | Cons |
|------|------|
| Unlimited volumes | Shared I/O bandwidth |
| Fast startup (O(1)) | More complex implementation |
| Low memory overhead | Single point of failure |

### Decision: Single Block Device with Bind Mounts

**Rationale**:
1. No artificial limit on number of volumes
2. Faster startup time (critical for Firecracker's value proposition)
3. Lower memory overhead
4. Matches user expectations from Docker

### Comparison Summary

| Metric | Option A (N devices) | Option B (1 device) |
|--------|---------------------|---------------------|
| Startup time | O(N) × 50-200ms | O(1) × 100-300ms |
| Memory | O(N) × 1-2MB | O(1) × 2MB |
| Max volumes | ~28 | Unlimited |
| I/O isolation | Per-volume | Shared |
| Complexity | Low | Medium |

---

## Layer 3: Sync Strategy

### Problem Statement

The ext4 image is a **copy** of host files. Changes inside VM don't automatically appear on host. How do we sync changes back?

This is especially important for **long-running containers** where "sync on exit" is not acceptable.

### All Available Options

#### Option 1: Sync on Exit

```
Container runs → Makes changes → Container exits → Sync to host
```

| Attribute | Value |
|-----------|-------|
| Latency | High (only on exit) |
| Data Loss Risk | High (crash = all changes lost) |
| CPU Overhead | None during runtime |
| Complexity | Low |
| Best For | Short-lived batch jobs |

**Implementation:**
```bash
# On container exit
trap 'rsync /tmp/changes/ /host/data/' EXIT
```

❌ **Not suitable for long-running containers**

---

#### Option 2: Periodic Sync

```
┌─────────────────────────────────────────────────────────────┐
│  sync-daemon (runs every N seconds)                         │
│                                                             │
│  while true; do                                             │
│    rsync /tmp/changes/ → host (via vsock)                  │
│    sleep $INTERVAL                                          │
│  done                                                       │
└─────────────────────────────────────────────────────────────┘
```

| Attribute | Value |
|-----------|-------|
| Latency | 5-60 seconds (configurable) |
| Data Loss Risk | Medium (up to N seconds of changes) |
| CPU Overhead | Low |
| Complexity | Low |
| Best For | Most general use cases |

**Implementation:**
```bash
#!/bin/sh
SYNC_INTERVAL=10

sync_to_host() {
  tar -cf - -C /tmp/changes . | socat - VSOCK-CONNECT:2:5000
}

trap 'sync_to_host; exit 0' SIGTERM SIGINT

while true; do
  sleep $SYNC_INTERVAL
  sync_to_host
done
```

⚠️ **Acceptable for many cases, but not real-time**

---

#### Option 3: Inotify + Immediate Sync

```
┌─────────────────────────────────────────────────────────────┐
│  inotifywait -m -r /data |                                 │
│  while read path action file; do                           │
│    sync_file "$path/$file" → host                          │
│  done                                                       │
└─────────────────────────────────────────────────────────────┘
```

| Attribute | Value |
|-----------|-------|
| Latency | <1 second |
| Data Loss Risk | Low |
| CPU Overhead | Medium (scales with I/O) |
| Complexity | Medium |
| Best For | Near real-time needs |

⚠️ **Good latency, but high overhead with many files**

---

#### Option 4: 9P over vsock (Recommended)

```
┌─────────────────────────────────────────────────────────────┐
│  HOST                                                       │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  diod (9P server)                                   │   │
│  │  Exports: /host/data                                │   │
│  │  Listens: vsock CID=3, port=5640                    │   │
│  └─────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
                               ▲ vsock
┌──────────────────────────────┼──────────────────────────────┐
│  GUEST VM                    │                              │
│                              ▼                              │
│  mount -t 9p -o trans=vsock hostshare /data                │
│                                                             │
│  # /data is LIVE - no sync needed!                         │
│  echo "hello" > /data/file.txt  # Instantly on host        │
└─────────────────────────────────────────────────────────────┘
```

| Attribute | Value |
|-----------|-------|
| Latency | ~1-5ms |
| Data Loss Risk | None (live filesystem) |
| CPU Overhead | Medium |
| Complexity | Medium |
| Best For | Long-running containers, full POSIX |

✅ **Best option for long-running containers**

---

#### Option 5: NFS over vsock

Similar to 9P but uses NFS protocol.

| Attribute | Value |
|-----------|-------|
| Latency | ~1-10ms |
| Data Loss Risk | None |
| CPU Overhead | Medium-High |
| Complexity | High |
| Best For | Enterprise environments |

⚠️ **More complex than 9P with similar benefits**

---

#### Option 6: Custom FUSE over vsock

Build a custom FUSE filesystem that tunnels over vsock.

| Attribute | Value |
|-----------|-------|
| Latency | ~1-5ms |
| Data Loss Risk | None |
| CPU Overhead | Medium |
| Complexity | High |
| Best For | Custom requirements |

❌ **Too complex for our needs**

---

### Sync Strategy Comparison Matrix

| Strategy | Latency | Data Loss Risk | CPU Overhead | Complexity | Long-Running? |
|----------|---------|----------------|--------------|------------|---------------|
| Sync on Exit | High | High | None | Low | ❌ |
| Periodic Sync | 5-60s | Medium | Low | Low | ⚠️ |
| Inotify | <1s | Low | Medium | Medium | ✅ |
| **9P over vsock** | **~1-5ms** | **None** | **Medium** | **Medium** | **✅** |
| NFS over vsock | ~1-10ms | None | Medium-High | High | ✅ |
| Custom FUSE | ~1-5ms | None | Medium | High | ✅ |

### Decision: 9P over vsock

**Rationale**:
1. **True live filesystem** - no sync mechanism needed, changes are instant
2. **Good POSIX compatibility** - supports most filesystem operations
3. **Low latency** - ~1-5ms per operation
4. **Proven technology** - same protocol used by WSL2, Plan 9, QEMU
5. **Automatic operation** - no user intervention required
6. **Supports long-running containers** - critical for our use case

---

## Final Architecture Decision

### Selected Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  LAYER 3: 9P over vsock                                                │
│  - Live filesystem access                                               │
│  - No sync needed                                                       │
│  - diod server on host, 9p mount in guest                              │
├─────────────────────────────────────────────────────────────────────────┤
│  LAYER 2: Single Block Device + Bind Mounts                            │
│  - Rootfs as single ext4 image                                          │
│  - Volume mounts via 9P (not in rootfs image)                          │
├─────────────────────────────────────────────────────────────────────────┤
│  LAYER 1: virtio-blk                                                   │
│  - Rootfs via virtio-blk                                                │
│  - Volumes via 9P over vsock (no additional block devices)             │
└─────────────────────────────────────────────────────────────────────────┘
```

### Complete Data Flow

```
USER RUNS:
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
  -v /host/data:/data \
  -v /host/config:/etc/myapp \
  alpine sh -c 'echo "hello" > /data/file.txt'

STEP 1: runcvm-runtime parses volume mounts
┌─────────────────────────────────────────────────────────────┐
│  Extracts from OCI config:                                  │
│    - Volume 1: /host/data → /data                          │
│    - Volume 2: /host/config → /etc/myapp                   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
STEP 2: runcvm-ctr-firecracker starts 9P servers
┌─────────────────────────────────────────────────────────────┐
│  diod --export /host/data --listen vsock:3:5640 &          │
│  diod --export /host/config --listen vsock:3:5641 &        │
│                                                             │
│  Write mount config to /.runcvm/9p-mounts:                 │
│    5640:/data                                               │
│    5641:/etc/myapp                                          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
STEP 3: Launch Firecracker with vsock enabled
┌─────────────────────────────────────────────────────────────┐
│  firecracker --config:                                      │
│    - boot-source: vmlinux                                   │
│    - drives: rootfs.ext4                                    │
│    - vsock: cid=3                                           │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
STEP 4: runcvm-vm-init-firecracker mounts 9P volumes
┌─────────────────────────────────────────────────────────────┐
│  mount -t 9p -o trans=vsock,port=5640 host /data           │
│  mount -t 9p -o trans=vsock,port=5641 host /etc/myapp      │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
STEP 5: Container entrypoint runs
┌─────────────────────────────────────────────────────────────┐
│  sh -c 'echo "hello" > /data/file.txt'                     │
│                                                             │
│  Write goes directly to host via 9P!                       │
│  /host/data/file.txt now contains "hello"                  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
STEP 6: Cleanup on exit
┌─────────────────────────────────────────────────────────────┐
│  Kill Firecracker process                                   │
│  Kill all diod processes                                    │
│  Cleanup temp files                                         │
└─────────────────────────────────────────────────────────────┘
```

### User Experience

The implementation is **completely transparent** to users:

```bash
# User runs exactly the same command as with QEMU
docker run --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v /my/data:/data \
  -v /my/config:/etc/myapp \
  alpine sh

# Inside container - volumes just work!
$ echo "test" > /data/file.txt      # Instantly on host
$ cat /etc/myapp/config.yaml        # Reads from host in real-time
$ ls -la /data/                     # Full directory listing

# User doesn't know or care that 9P is being used internally
```

---

## Implementation Plan

### Phase 1: Kernel Configuration (Day 1)

Add 9P support to Firecracker kernel:

```bash
# Add to kernels/firecracker/config-firecracker-x86_64

# ============================================================
# 9P FILESYSTEM (for live volume mounts via vsock)
# ============================================================

CONFIG_NET_9P=y
CONFIG_NET_9P_VIRTIO=y
CONFIG_9P_FS=y
CONFIG_9P_FS_POSIX_ACL=y
CONFIG_9P_FS_SECURITY=y
```

### Phase 2: Bundle diod (Day 1-2)

Add 9P server to RunCVM image:

```dockerfile
# Add to Dockerfile
FROM alpine:3.19 as diod-builder
RUN apk add --no-cache build-base autoconf automake libtool
RUN git clone https://github.com/chaos/diod.git && \
    cd diod && ./autogen.sh && ./configure --prefix=/usr && make

FROM ... as final
COPY --from=diod-builder /diod/diod /opt/runcvm/bin/diod
```

### Phase 3: Host-side Implementation (Day 2-3)

Modify `runcvm-ctr-firecracker`:

```bash
#!/bin/bash
# runcvm-ctr-firecracker additions

DIOD_BIN="$RUNCVM_GUEST/bin/diod"
MOUNT_CONFIG="/.runcvm/9p-mounts"
DIOD_PIDS=()

setup_9p_volumes() {
  local port=5640
  
  > "$MOUNT_CONFIG"
  
  # Read volume mounts from OCI config
  while IFS=: read -r src dst opts; do
    [ -z "$src" ] && continue
    
    log "Setting up 9P export: $src → $dst (port $port)"
    
    # Start diod server for this volume
    $DIOD_BIN \
      --export "$src" \
      --listen "vsock:3:$port" \
      --logdest "/run/diod-$port.log" \
      --no-auth &
    
    DIOD_PIDS+=($!)
    
    # Record mount for guest
    echo "$port:$dst" >> "$MOUNT_CONFIG"
    
    port=$((port + 1))
  done < /.runcvm/volumes
  
  # Copy mount config to rootfs
  cp "$MOUNT_CONFIG" "$RUNCVM_VM_MOUNTPOINT/.runcvm/"
}

cleanup_9p_volumes() {
  for pid in "${DIOD_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
}

trap cleanup_9p_volumes EXIT SIGTERM SIGINT

# Call during container setup
setup_9p_volumes
```

### Phase 4: Guest-side Implementation (Day 3-4)

Modify `runcvm-vm-init-firecracker`:

```bash
#!/bin/sh
# runcvm-vm-init-firecracker additions

mount_9p_volumes() {
  local mount_config="/.runcvm/9p-mounts"
  
  [ -f "$mount_config" ] || return 0
  
  log "Mounting 9P volumes..."
  
  while IFS=: read -r port dst; do
    [ -z "$port" ] && continue
    
    log "  Mounting $dst (vsock port $port)"
    
    mkdir -p "$dst"
    
    mount -t 9p \
      -o trans=vsock,dfltuid=0,dfltgid=0,version=9p2000.L,port=$port,msize=65536,cache=loose \
      "hostshare" "$dst"
    
    if [ $? -eq 0 ]; then
      log "  ✓ Mounted $dst successfully"
    else
      log "  ✗ Failed to mount $dst"
    fi
  done < "$mount_config"
}

# Call during VM init, after basic setup
mount_9p_volumes
```

### Phase 5: Testing (Day 4-5)

```bash
#!/bin/bash
# Test script: test-firecracker-volumes.sh

set -e

echo "=== Test 1: Basic read/write ==="
mkdir -p /tmp/test-vol
echo "initial" > /tmp/test-vol/data.txt

docker run --rm \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v /tmp/test-vol:/data \
  alpine sh -c 'echo "modified" >> /data/data.txt && cat /data/data.txt'

grep -q "modified" /tmp/test-vol/data.txt && echo "✓ PASS" || echo "✗ FAIL"

echo "=== Test 2: Multiple volumes ==="
mkdir -p /tmp/vol-{a,b,c}
echo "A" > /tmp/vol-a/file.txt
echo "B" > /tmp/vol-b/file.txt
echo "C" > /tmp/vol-c/file.txt

docker run --rm \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v /tmp/vol-a:/data/a \
  -v /tmp/vol-b:/data/b \
  -v /tmp/vol-c:/data/c \
  alpine sh -c 'cat /data/a/file.txt /data/b/file.txt /data/c/file.txt'

echo "=== Test 3: Long-running with live updates ==="
docker run -d --name fc-test \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v /tmp/test-vol:/data \
  alpine sh -c 'while true; do cat /data/data.txt; sleep 1; done'

sleep 2
echo "host-update-$(date +%s)" >> /tmp/test-vol/data.txt
sleep 2
docker logs fc-test | tail -5
docker rm -f fc-test

echo "=== All tests completed ==="
```

### Phase 6: Documentation (Day 5)

Update ROADMAP-DOCKER.md with:
- Volume mount feature status: ✅ Complete
- Known limitations
- Performance characteristics

---

## Kernel Configuration Requirements

### Current Kernel Config (Verified Present)

```
CONFIG_VSOCKETS=y              ✅ vsock enabled
CONFIG_VIRTIO_VSOCKETS=y       ✅ virtio-vsock enabled
CONFIG_VIRTIO_VSOCKETS_COMMON=y ✅ vsock common enabled
```

### Required Additions

```bash
# Add to kernels/firecracker/config-firecracker-x86_64

# ============================================================
# 9P FILESYSTEM (for live volume mounts via vsock)
# ============================================================

CONFIG_NET_9P=y                # 9P network protocol
CONFIG_NET_9P_VIRTIO=y         # 9P over virtio transport
CONFIG_9P_FS=y                 # 9P filesystem support
CONFIG_9P_FS_POSIX_ACL=y       # POSIX ACL support for 9P
CONFIG_9P_FS_SECURITY=y        # Security label support
```

### Dependencies Summary

| Component | Location | Required | Size |
|-----------|----------|----------|------|
| diod (9P server) | Host container | Yes | ~500KB |
| 9P kernel module | Guest kernel | Yes | Built-in |
| vsock kernel module | Guest kernel | Yes | Already present |

---

## References

### Firecracker Documentation
- [Firecracker GitHub](https://github.com/firecracker-microvm/firecracker)
- [virtiofs PR #1351](https://github.com/firecracker-microvm/firecracker/pull/1351) - Rejected
- [Host Filesystem Sharing Issue #1180](https://github.com/firecracker-microvm/firecracker/issues/1180)

### 9P Protocol
- [9P Protocol Specification](http://9p.cat-v.org/)
- [Linux 9P Documentation](https://www.kernel.org/doc/Documentation/filesystems/9p.txt)
- [diod - 9P Server](https://github.com/chaos/diod)

### Related Technologies
- [virtiofs](https://virtio-fs.gitlab.io/) - What QEMU uses (not available in Firecracker)
- [WSL2 9P](https://docs.microsoft.com/en-us/windows/wsl/) - Uses 9P for Windows↔Linux file sharing

### RunCVM Internal Documentation
- [ROADMAP-DOCKER.md](./ROADMAP-DOCKER.md) - Phase 3 roadmap
- [INTEGRATION_GUIDE.md](./INTEGRATION_GUIDE.md) - Architecture differences QEMU vs Firecracker

---

## Document Information

| Field | Value |
|-------|-------|
| Version | 1.0 |
| Created | December 7, 2025 |
| Author | RunCVM Team |
| Status | Approved for Implementation |
| Next Review | December 14, 2025 |