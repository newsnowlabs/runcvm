# RunCVM Firecracker Integration Guide

## Overview

This document describes the integration of Firecracker microVM support into RunCVM. Firecracker provides faster boot times (~125ms vs ~3s for QEMU) and lower memory overhead, making it ideal for serverless and high-density workloads.

## Architecture Differences

### QEMU (Current)
```
┌─────────────────────────────────────────────────────┐
│ Docker Container                                     │
│  ┌────────────────┐  ┌─────────────────────────────┐│
│  │   virtiofsd    │  │         QEMU                ││
│  │   (shares fs)  │◄─┤  ┌─────────────────────┐    ││
│  └────────────────┘  │  │    Guest VM         │    ││
│                      │  │  ┌───────────────┐  │    ││
│  Container FS ──────►│  │  │ virtiofs root │  │    ││
│  (overlay)           │  │  └───────────────┘  │    ││
│                      │  └─────────────────────┘    ││
│                      └─────────────────────────────┘│
└─────────────────────────────────────────────────────┘
```

### Firecracker (New)
```
┌─────────────────────────────────────────────────────┐
│ Docker Container                                     │
│  ┌────────────────┐  ┌─────────────────────────────┐│
│  │ rootfs creator │  │      Firecracker            ││
│  │ (ext4 image)   │  │  ┌─────────────────────┐    ││
│  └───────┬────────┘  │  │    Guest VM         │    ││
│          │           │  │  ┌───────────────┐  │    ││
│          ▼           │  │  │ virtio-blk    │  │    ││
│  /.runcvm/rootfs.ext4│◄─┤  │ (ext4 root)   │  │    ││
│                      │  │  └───────────────┘  │    ││
│                      │  └─────────────────────┘    ││
│                      └─────────────────────────────┘│
└─────────────────────────────────────────────────────┘
```

## Key Trade-offs

| Feature | QEMU | Firecracker |
|---------|------|-------------|
| Boot time | ~3s | ~125ms |
| Memory overhead | Higher | Lower (~5MB) |
| Filesystem | Live (virtiofs) | Snapshot (ext4 image) |
| File changes | Immediate | Lost on restart* |
| Features | Full VM | Minimal microVM |
| USB support | Yes | No |
| Graphics | Yes | No |
| Device model | Full | Minimal |

\* Unless using persistent volumes

## Implementation Status

### Completed
- [x] Phase 1.3: Rootfs creation proof-of-concept (by you!)
- [x] Core script architecture design
- [x] `runcvm-ctr-firecracker` - Main launcher script
- [x] `runcvm-vm-init-firecracker` - VM init for Firecracker
- [x] `runcvm-create-rootfs` - Rootfs image creation utility
- [x] Kernel configuration for Firecracker
- [x] Dockerfile additions for building Firecracker support
- [x] Basic test script

### Pending
- [ ] Phase 1.1: Add Firecracker binary to build
- [ ] Phase 1.2: Build Firecracker-compatible kernel
- [ ] Phase 2: Runtime integration (`runcvm-runtime` modifications)
- [ ] Phase 3: Network integration testing
- [ ] Phase 4: Docker exec support
- [ ] Phase 5: Full testing suite

## Files Created

```
runcvm-firecracker/
├── runcvm-scripts/
│   ├── runcvm-ctr-firecracker           # Firecracker launcher (≈ runcvm-ctr-qemu)
│   ├── runcvm-vm-init-firecracker       # VM init for Firecracker
│   ├── runcvm-ctr-entrypoint-unified    # Modified entrypoint supporting both
│   └── runcvm-create-rootfs             # Rootfs creation utility
├── kernels/
│   └── firecracker/
│       └── config-firecracker-x86_64    # Kernel config
├── tests/
│   └── test-firecracker-basic.sh        # Basic integration test
├── Dockerfile.firecracker-additions      # Build additions
└── INTEGRATION_GUIDE.md                  # This file
```

## Next Steps

### Step 1: Test Rootfs Creation with Your Setup

Since you've already successfully created a bootable rootfs, test the `runcvm-create-rootfs` script:

```bash
# Make it executable
chmod +x runcvm-scripts/runcvm-create-rootfs

# Create a test rootfs from an Alpine container
docker run --rm -v /tmp/alpine-root:/rootfs alpine sh -c "cp -a / /rootfs/"
./runcvm-scripts/runcvm-create-rootfs /tmp/alpine-root /tmp/test-rootfs.ext4
```

### Step 2: Test Basic Firecracker Boot

```bash
# Set your kernel path
export KERNEL_PATH=/home/reski/firecracker/vmlinux

# Run the test
chmod +x tests/test-firecracker-basic.sh
./tests/test-firecracker-basic.sh
```

### Step 3: Download Firecracker Binaries

```bash
# x86_64
FC_VERSION=1.6.0
curl -fsSL "https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/firecracker-v${FC_VERSION}-x86_64.tgz" | tar -xz
sudo mv release-v${FC_VERSION}-x86_64/firecracker-v${FC_VERSION}-x86_64 /usr/local/bin/firecracker
sudo mv release-v${FC_VERSION}-x86_64/jailer-v${FC_VERSION}-x86_64 /usr/local/bin/jailer

# aarch64
curl -fsSL "https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/firecracker-v${FC_VERSION}-aarch64.tgz" | tar -xz
```

### Step 4: Build Firecracker Kernel

Option A: Download pre-built kernel
```bash
# From Amazon's Firecracker CI
curl -fsSL "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.6.0/x86_64/vmlinux-5.10.bin" \
  -o /opt/runcvm/kernels/firecracker/vmlinux
```

Option B: Build your own kernel
```bash
# Use the provided config-firecracker-x86_64
cd /tmp
curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.10.204.tar.xz" | tar -xJ
cd linux-5.10.204
cp /path/to/config-firecracker-x86_64 .config
make olddefconfig
make -j$(nproc) vmlinux
cp vmlinux /opt/runcvm/kernels/firecracker/
```

### Step 5: Integrate with RunCVM Runtime

Modify `runcvm-runtime` to support hypervisor selection:

```bash
# In runcvm-runtime, add after parsing config:
RUNCVM_HYPERVISOR=$(get_config_env 'RUNCVM_HYPERVISOR' 'qemu')

# Then route to appropriate scripts based on hypervisor
```

### Step 6: Test Full Integration

```bash
# Launch with QEMU (default)
docker run --runtime=runcvm --rm alpine echo "Hello from QEMU VM"

# Launch with Firecracker
docker run --runtime=runcvm --rm -e RUNCVM_HYPERVISOR=firecracker alpine echo "Hello from Firecracker"
```

## Usage Examples (Target State)

### Basic Usage
```bash
# Default (QEMU) - full features, slower boot
docker run --runtime=runcvm nginx

# Firecracker - fast boot, minimal features
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker nginx
```

### When to Use Firecracker
- Fast-starting serverless functions
- High-density container deployments
- Short-lived workloads
- When boot time matters more than features

### When to Use QEMU
- Need live filesystem changes
- Need USB, graphics, or special devices
- Running Docker-in-Docker
- Complex networking requirements
- Long-running workloads where boot time doesn't matter

## Known Limitations

### Firecracker Mode
1. **No live filesystem** - Changes must be persisted via volumes
2. **Rootfs creation overhead** - First start takes longer to create image
3. **No virtiofs** - Cannot share host directories live
4. **Minimal devices** - No USB, graphics, etc.
5. **Network limitations** - TAP devices only

### Workarounds
1. Use persistent volumes for data that needs to survive restarts
2. Pre-build rootfs images for frequently-used base images
3. Use QEMU mode when live filesystem access is needed

## Debugging

### Check Firecracker logs
```bash
cat /run/.firecracker.log
```

### Test API directly
```bash
curl --unix-socket /run/.firecracker.sock http://localhost/
```

### Enable verbose boot
```bash
docker run --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_KERNEL_DEBUG=1 \
  alpine
```

## Performance Comparison

Target performance metrics:

| Metric | QEMU | Firecracker | Improvement |
|--------|------|-------------|-------------|
| Cold start | ~3s | ~200ms* | 15x |
| Memory overhead | ~128MB | ~10MB | 12x |
| Startup CPU | Higher | Lower | ~50% |

\* Including rootfs creation; ~125ms for subsequent starts with cached rootfs

## Contributing

When working on Firecracker integration:

1. Test with both hypervisors
2. Keep QEMU as the stable default
3. Document any Firecracker-specific limitations
4. Add tests for new functionality
