# RunCVM Firecracker Roadmap (Docker Focus)

**Last Updated**: December 7, 2025  
**Current Phase**: Phase 3 - Feature Parity (In Progress)  
**Focus**: Docker runtime integration with Firecracker hypervisor

---

## Table of Contents
- [Overview](#overview)
- [Feature Parity Status](#feature-parity-status)
- [Completed Phases](#completed-phases)
- [Current Phase](#current-phase)
- [Future Phases](#future-phases)
- [Timeline](#timeline)

---

## Overview

This roadmap focuses on **Docker runtime** integration with Firecracker, achieving feature parity with QEMU mode for Docker workloads.

### QEMU Mode (Stable - Production Ready)
- **Status**: ✅ Fully functional for Docker
- **Boot Time**: ~4-5 seconds
- **Filesystem**: virtiofs (live, zero-copy sharing)
- **Use Case**: Full-featured VMs with all capabilities

### Firecracker Mode (In Progress)
- **Status**: ⚠️ Basic functionality working
- **Boot Time**: ~200ms (20-25x faster)
- **Filesystem**: virtio-blk (ext4 image, snapshot-based)
- **Use Case**: Fast-booting, stateless Docker containers

**Goal**: Achieve full Docker feature parity so users can choose hypervisor based on performance, not limitations.

---

## Feature Parity Status

**As of December 7, 2025**

### Legend
- ✅ **Complete** - Fully implemented and tested
- 🟡 **Partial** - Basic implementation exists
- ❌ **Missing** - Not yet implemented
- 🔄 **In Progress** - Currently being worked on

### Core Docker Features

| Feature | QEMU | Firecracker | Status | Priority | ETA |
|---------|------|-------------|--------|----------|-----|
| **docker run** | ✅ | ✅ | Complete | - | ✅ Done |
| **docker exec** | ✅ | ✅ | Complete | - | ✅ Done |
| **docker exec -it** | ✅ | ✅ | Complete | - | ✅ Done |
| **docker stop** | ✅ | ✅ | Complete | - | ✅ Done |
| **docker logs** | ✅ | ✅ | Complete | - | ✅ Done |
| **docker attach** | ✅ | 🟡 | Partial | Medium | Week 8 |
| **docker cp** | ✅ | ❌ | Missing | Low | Phase 4 |

### Storage & Persistence

| Feature | QEMU | Firecracker | Status | Priority | ETA |
|---------|------|-------------|--------|----------|-----|
| **Live filesystem** | ✅ | ❌ | Missing | High | Week 1-4 |
| **Docker volumes (-v)** | ✅ | ❌ | Missing | High | Week 1-4 |
| **Named volumes** | ✅ | ❌ | Missing | High | Week 1-4 |
| **Bind mounts** | ✅ | ❌ | Missing | High | Week 1-4 |
| **tmpfs mounts** | ✅ | 🟡 | Partial | Medium | Week 5-6 |
| **Volume drivers** | ✅ | ❌ | Missing | Low | Phase 4 |
| **Rootfs caching** | N/A | ❌ | Missing | High | Week 1-4 |

### Networking

| Feature | QEMU | Firecracker | Status | Priority | ETA |
|---------|------|-------------|--------|----------|-----|
| **Bridge network** | ✅ | ✅ | Complete | - | ✅ Done |
| **Port mapping (-p)** | ✅ | ✅ | Complete | - | ✅ Done |
| **Host network** | ✅ | 🟡 | Untested | Medium | Week 5 |
| **Custom networks** | ✅ | 🟡 | Untested | Medium | Week 6 |
| **Multiple networks** | ✅ | ❌ | Missing | Low | Phase 4 |
| **Network connect** | ✅ | ❌ | Missing | Low | Phase 4 |

### Resource Management

| Feature | QEMU | Firecracker | Status | Priority | ETA |
|---------|------|-------------|--------|----------|-----|
| **CPU limits** | ✅ | ✅ | Complete | - | ✅ Done |
| **Memory limits** | ✅ | ✅ | Complete | - | ✅ Done |
| **CPU pinning** | ✅ | ❌ | Missing | Low | Phase 4 |
| **Memory balloon** | ✅ | 🟡 | Partial | Low | Phase 4 |

### Container Features

| Feature | QEMU | Firecracker | Status | Priority | ETA |
|---------|------|-------------|--------|----------|-----|
| **Environment variables** | ✅ | ✅ | Complete | - | ✅ Done |
| **Working directory** | ✅ | ✅ | Complete | - | ✅ Done |
| **User/Group** | ✅ | ✅ | Complete | - | ✅ Done |
| **Entry point** | ✅ | ✅ | Complete | - | ✅ Done |
| **CMD override** | ✅ | ✅ | Complete | - | ✅ Done |
| **Restart policies** | ✅ | 🟡 | Untested | Medium | Week 7 |

### Advanced Workloads

| Feature | QEMU | Firecracker | Status | Priority | ETA |
|---------|------|-------------|--------|----------|-----|
| **Docker-in-Docker** | ✅ | 🟡 | Untested | Medium | Week 8-9 |
| **systemd containers** | ✅ | 🟡 | Untested | Medium | Week 8-9 |
| **Multi-stage builds** | ✅ | ✅ | Complete | - | ✅ Done |

---

## Completed Phases

### ✅ Phase 0: QEMU Foundation (Q3-Q4 2024)
**Goal**: Basic Docker runtime with QEMU

**Completed**:
- ✅ OCI runtime implementation
- ✅ QEMU integration with virtiofs
- ✅ Docker daemon configuration
- ✅ Basic networking (bridge + TAP)
- ✅ SSH-based exec (dropbear)
- ✅ ARM64 and x86_64 support
- ✅ Multiple kernel support (Debian, Alpine)
- ✅ Exit code handling
- ✅ stdio/stderr redirection

**Timeline**: September - December 2024

---

### ✅ Phase 1: QEMU Stabilization (Q4 2024 - Q1 2025)
**Goal**: Production-ready Docker integration with QEMU

**Completed**:
- ✅ Docker volumes support
- ✅ Port mapping
- ✅ Network isolation
- ✅ Interactive exec (`docker exec -it`)
- ✅ Container lifecycle management
- ✅ Resource limits (CPU, memory)
- ✅ Performance optimization
- ✅ Debugging tools (RUNCVM_BREAK)

**Timeline**: October 2024 - January 2025

---

### ✅ Phase 2: Firecracker Foundation (Q1 2025)
**Goal**: Basic Firecracker integration for Docker

**Completed**:
- ✅ Firecracker binary integration
- ✅ Firecracker-compatible kernel (ARM64)
- ✅ Rootfs image creation from container filesystem
- ✅ Standalone Firecracker boot
- ✅ Docker runtime integration
- ✅ Hypervisor selection (`RUNCVM_HYPERVISOR=firecracker`)
- ✅ Basic networking (TAP devices)
- ✅ SSH access for exec
- ✅ Simple container workloads (alpine, nginx)

**Key Milestone**: December 6, 2024 - First successful Firecracker container boot

**Timeline**: November 2024 - December 6, 2025

---

## Current Phase

### 🔄 Phase 3: Docker Feature Parity (Dec 7, 2025 - Mar 2025)
**Goal**: Firecracker mode has all QEMU Docker features

**Started**: December 7, 2025  
**Target Completion**: March 2025 (12 weeks)

---

#### Week 1-4: Storage & Persistence (Dec 7 - Jan 4, 2026) 🔄

**Objective**: Enable Docker volumes and persistent storage

**Current Status**: Started December 7, 2025

**Tasks**:
- [ ] **Week 1**: Docker volume mounting
  - [ ] Parse Docker `-v` flag in runtime
  - [ ] Create virtio-blk devices for volumes
  - [ ] Mount volumes in Firecracker VM init
  - [ ] Test with simple bind mounts
  
  ```bash
  # Target: This should work
  docker run --runtime=runcvm \
    -e RUNCVM_HYPERVISOR=firecracker \
    -v /host/data:/container/data \
    alpine ls -la /container/data
  ```

- [ ] **Week 2**: Named volumes
  - [ ] Support Docker named volumes
  - [ ] Integration with Docker volume driver
  - [ ] Test volume lifecycle (create, use, delete)
  
  ```bash
  # Target: This should work
  docker volume create mydata
  docker run --runtime=runcvm \
    -e RUNCVM_HYPERVISOR=firecracker \
    -v mydata:/data \
    alpine
  ```

- [ ] **Week 3**: Rootfs caching
  - [ ] Implement base image cache
  - [ ] Generate cache key from image layers
  - [ ] Use overlay for per-instance changes
  - [ ] Add cache eviction (LRU, max size)
  
  ```bash
  # Target: Second boot should be <150ms
  # First boot: ~500ms (creates cache)
  # Second boot: ~125ms (uses cache)
  ```

- [ ] **Week 4**: Persistent overlays
  - [ ] Option to persist overlay changes
  - [ ] Integration with Docker commit
  - [ ] Cleanup on container removal
  - [ ] Test with databases (MySQL, PostgreSQL)

**Expected Outcome**:
- ✅ `docker run -v` works in Firecracker mode
- ✅ Named volumes work
- ✅ Boot time <500ms cold, <150ms warm
- ✅ Data persists across container restarts

**Deliverables**:
- Updated `runcvm-ctr-firecracker` with volume support
- `runcvm-cache-manager` script
- Test suite for volume operations
- Documentation for volume usage

**Success Criteria**:
```bash
# All these should work:
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
  -v /host:/container alpine cat /container/file.txt

docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
  -v myvolume:/data alpine touch /data/test.txt

docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
  -v myvolume:/data alpine ls /data/test.txt  # Should exist

# Database should work:
docker run -d --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
  -v pgdata:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=secret \
  postgres
```

---

#### Week 5-6: Networking Validation (Jan 5 - Jan 18, 2026)

**Objective**: Test and fix all Docker networking modes

**Tasks**:
- [ ] **Week 5**: Host networking
  - [ ] Test `--network=host` mode
  - [ ] Fix any isolation issues
  - [ ] Performance comparison with bridge
  
- [ ] **Week 6**: Custom networks
  - [ ] Test custom bridge networks
  - [ ] Test network aliases
  - [ ] Validate DNS resolution

**Expected Outcome**:
- ✅ All Docker network modes work
- ✅ DNS resolution correct
- ✅ Network performance validated

---

#### Week 7: Container Lifecycle (Jan 19 - Jan 25, 2026)

**Objective**: Ensure all container lifecycle features work

**Tasks**:
- [ ] Test restart policies
  - [ ] `--restart=no`
  - [ ] `--restart=on-failure`
  - [ ] `--restart=always`
  - [ ] `--restart=unless-stopped`
  
- [ ] Test container signals
  - [ ] SIGTERM handling
  - [ ] SIGKILL handling
  - [ ] Graceful shutdown
  
- [ ] Test exit codes
  - [ ] Normal exit (0)
  - [ ] Error exit (1-255)
  - [ ] Signal exit (128+N)

**Expected Outcome**:
- ✅ Container lifecycle matches QEMU behavior
- ✅ Restart policies work correctly
- ✅ Exit codes preserved

---

#### Week 8-9: Advanced Workloads (Jan 26 - Feb 8, 2026)

**Objective**: Validate complex Docker workloads

**Tasks**:
- [ ] **Week 8**: Docker-in-Docker
  - [ ] Test Docker daemon in Firecracker VM
  - [ ] Nested container support
  - [ ] Performance validation
  
  ```bash
  docker run --runtime=runcvm \
    -e RUNCVM_HYPERVISOR=firecracker \
    -e RUNCVM_MEM_SIZE=4096M \
    --privileged \
    docker:dind
  ```

- [ ] **Week 9**: systemd containers
  - [ ] Test systemd as PID 1
  - [ ] Service management
  - [ ] Journal logging
  
  ```bash
  docker run --runtime=runcvm \
    -e RUNCVM_HYPERVISOR=firecracker \
    -e RUNCVM_KERNEL=debian \
    systemd-image
  ```

**Expected Outcome**:
- ✅ Docker-in-Docker works
- ✅ systemd containers work
- ✅ Complex init systems supported

---

#### Week 10-11: Performance & Optimization (Feb 9 - Feb 22, 2026)

**Objective**: Maximize Firecracker's performance advantage

**Tasks**:
- [ ] Rootfs image optimization
  - [ ] Sparse ext4 images
  - [ ] Compression for cached images
  - [ ] Parallel image creation
  
- [ ] Boot optimization
  - [ ] Minimal kernel config
  - [ ] Skip unnecessary init steps
  - [ ] Parallel device init
  
- [ ] Network optimization
  - [ ] Pre-create TAP devices
  - [ ] Optimize bridge config
  - [ ] vhost-net testing
  
- [ ] Memory optimization
  - [ ] Balloon device tuning
  - [ ] Memory allocation optimization

**Target Metrics**:
- ✅ Cold boot: <500ms (including rootfs creation)
- ✅ Warm boot: <150ms (cached rootfs)
- ✅ Memory overhead: <15MB
- ✅ I/O performance: 90%+ of QEMU

**Benchmarks**:
```bash
# Boot time test
time docker run --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  alpine echo "ready"

# I/O performance test
docker run --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  alpine dd if=/dev/zero of=/tmp/test bs=1M count=100
```

---

#### Week 12: Testing & Documentation (Feb 23 - Mar 1, 2026)

**Objective**: Comprehensive testing and docs

**Tasks**:
- [ ] Integration test suite
  - [ ] All Docker commands
  - [ ] Volume operations
  - [ ] Network modes
  - [ ] Lifecycle management
  
- [ ] Performance benchmarks
  - [ ] Boot time comparison
  - [ ] I/O performance
  - [ ] Network throughput
  - [ ] Memory usage
  
- [ ] Documentation
  - [ ] Usage guide for Firecracker mode
  - [ ] Performance tuning guide
  - [ ] Migration guide from QEMU
  - [ ] Troubleshooting guide
  
- [ ] Example workloads
  - [ ] Web servers
  - [ ] Databases
  - [ ] Application servers
  - [ ] Development environments

**Deliverables**:
- Comprehensive test suite (>80% coverage)
- Performance benchmark report
- User documentation
- Example repository

---

## Future Phases

### Phase 4: Advanced Docker Features (Q2 2026)

**Goal**: Add features beyond basic parity

**Planned**:
- [ ] Multi-platform builds (x86 on ARM, ARM on x86)
- [ ] GPU passthrough support
- [ ] Live migration (experimental)
- [ ] Checkpoint/restore
- [ ] Advanced volume drivers
- [ ] Docker Compose optimizations

**Timeline**: April - June 2026

---

### Phase 5: Production Hardening (Q3 2026)

**Goal**: Enterprise-grade stability

**Planned**:
- [ ] Security hardening
  - [ ] Firecracker jailer integration
  - [ ] Seccomp profiles
  - [ ] SELinux/AppArmor
  
- [ ] Observability
  - [ ] Prometheus metrics
  - [ ] Structured logging
  - [ ] Performance profiling
  
- [ ] Reliability
  - [ ] Automatic error recovery
  - [ ] Health checks
  - [ ] Resource limits enforcement

**Timeline**: July - September 2026

---

### Phase 6: Ecosystem Integration (Q4 2026)

**Goal**: Deep integration with Docker ecosystem

**Planned**:
- [ ] Docker Compose enhancements
- [ ] Docker Swarm support
- [ ] Docker Hub optimizations
- [ ] CI/CD integrations (GitHub Actions, GitLab CI)
- [ ] Cloud provider optimizations (AWS, GCP, Azure)

**Timeline**: October - December 2026

---

## Timeline

```
2024 Q4          2025 Q1         2025 Q2         2026 Q2         2026 Q3         2026 Q4
   |                |               |               |               |               |
   ▼                ▼               ▼               ▼               ▼               ▼
┌──────────┐   ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
│ Phase 0  │   │Phase 1  │   │ Phase 2  │   │ Phase 3  │   │ Phase 4  │   │ Phase 5  │
│   QEMU   │──▶│  QEMU   │──▶│Firecrk   │──▶│ Feature  │──▶│ Advanced │──▶│  Prod    │
│  Basic   │   │ Stable  │   │  Basic   │   │  Parity  │   │ Features │   │ Harden   │
└──────────┘   └─────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘
     ✅             ✅             ✅             🔄              📅             📅

                                                 ▲
                                                 │
                                            We are here
                                         December 7, 2025
```

### Milestones

| Date | Milestone | Status |
|------|-----------|--------|
| Dec 2024 | QEMU production ready | ✅ |
| Dec 6, 2025 | First Firecracker boot | ✅ |
| **Dec 7, 2025** | **Phase 3 Started** | **🔄 Current** |
| Jan 4, 2026 | Storage & persistence complete | 📅 |
| Feb 22, 2026 | Performance optimization done | 📅 |
| Mar 1, 2026 | Docker feature parity achieved | 📅 |
| Jun 2026 | Advanced features | 📅 |
| Sep 2026 | Production ready | 📅 |

---

## Success Criteria

### Phase 3 Completion (March 1, 2026)

**Must Have**:
- ✅ All Docker volume types work (`-v`, named volumes, tmpfs)
- ✅ Boot time <500ms cold, <150ms warm
- ✅ Docker-in-Docker works
- ✅ systemd containers work
- ✅ All networking modes work
- ✅ Test coverage >80%
- ✅ Documentation complete

**Should Have**:
- ✅ Rootfs caching reduces cold start significantly
- ✅ Performance matches or exceeds QEMU (except virtiofs)
- ✅ Clear error messages for all failures
- ✅ Example workloads for common use cases

**Nice to Have**:
- ✅ Automatic fallback to QEMU
- ✅ Performance metrics collection
- ✅ Migration tooling from QEMU mode

---

## How to Test Progress

### Quick Tests (Daily)

```bash
# 1. Basic boot
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker --rm alpine echo "ok"

# 2. Volume mount (Week 1-4 goal)
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
  -v /tmp:/mnt --rm alpine ls /mnt

# 3. Boot time (Week 10-11 goal)
time docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
  --rm alpine echo "ready"
```

### Weekly Validation

```bash
# Run full test suite
cd tests/
./test-firecracker-docker.sh

# Check performance metrics
./benchmark-firecracker.sh

# Compare with QEMU
./compare-qemu-firecracker.sh
```

---

## Current Sprint (Dec 7 - Dec 14, 2025)

### This Week's Goals
- [x] Create roadmap documentation
- [ ] Implement Docker volume mount parsing
- [ ] Create virtio-blk device generation
- [ ] Test simple bind mount
- [ ] Document volume mounting design

### Daily Standup Questions
1. What did I complete yesterday?
2. What am I working on today?
3. What's blocking me?

---

## Contributing

### Priority Order (Phase 3)
1. **Storage & Persistence** (Weeks 1-4) - HIGHEST
2. **Performance Optimization** (Weeks 10-11) - HIGH
3. **Advanced Workloads** (Weeks 8-9) - MEDIUM
4. **Networking Validation** (Weeks 5-6) - MEDIUM
5. **Lifecycle Testing** (Week 7) - LOW

### How to Contribute
1. Pick a task from current week
2. Create GitHub issue describing approach
3. Submit PR with tests
4. Update roadmap with progress

---

## Notes

### Design Decisions

**Why ext4 images instead of virtiofs?**
- Firecracker doesn't support virtiofs
- ext4 images provide good compatibility
- Caching makes cold start acceptable
- Volumes provide persistence where needed

**Why Docker-first approach?**
- Docker is simpler than Kubernetes
- Easier to test and validate
- Faster iteration cycle
- Foundation for Kubernetes support later

**Why 12-week timeline?**
- Realistic given complexity
- Allows for thorough testing
- Buffer for unexpected issues
- Aligns with quarterly planning

---

**Document Version**: 1.0  
**Last Updated**: December 7, 2025  
**Next Review**: December 14, 2025  
**Owner**: RunCVM Team
