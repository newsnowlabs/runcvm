# RunCVM Kubernetes Roadmap (Advanced Integration)

**Last Updated**: December 7, 2025  
**Prerequisites**: Docker feature parity (ROADMAP-DOCKER.md Phase 3)  
**Current Status**: QEMU mode production-ready, Firecracker mode not yet started for K8s  
**Focus**: Advanced Kubernetes integration with Firecracker hypervisor

---

## Table of Contents
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Feature Status](#feature-status)
- [Completed Work](#completed-work)
- [Planned Phases](#planned-phases)
- [Timeline](#timeline)

---

## Overview

This roadmap covers **advanced Kubernetes integration** with RunCVM Firecracker mode. Basic Kubernetes support with QEMU is already production-ready. This roadmap focuses on bringing Firecracker performance to Kubernetes workloads.

### Current State (December 7, 2025)

**QEMU + Kubernetes**: ✅ Production Ready
- Full k3s integration
- RuntimeClass working
- CNI networking
- Pod lifecycle management
- Interactive exec (`kubectl exec -it`)
- ConfigMaps and Secrets (basic)

**Firecracker + Kubernetes**: 🚫 Not Started
- Blocked by Docker feature parity
- Requires storage/volume support
- Needs K8s-specific testing

---

## Prerequisites

### Must Complete First (From ROADMAP-DOCKER.md)

Before starting Kubernetes integration with Firecracker, we need:

✅ **From Docker Roadmap Phase 3** (Target: March 1, 2026):
1. ✅ Docker volumes working (`-v` flag)
2. ✅ Named volumes support
3. ✅ Rootfs caching
4. ✅ Persistent overlays
5. ✅ Performance optimization (<500ms boot)

**Why?** Kubernetes heavily relies on volumes (PVs, ConfigMaps, Secrets, EmptyDir). Without volume support, Firecracker can't work with K8s.

### Current Blocker Status

| Blocker | Status | ETA |
|---------|--------|-----|
| Docker volume support | 🔄 In Progress | Jan 4, 2026 |
| Rootfs caching | 🔄 In Progress | Jan 4, 2026 |
| Performance optimization | 📅 Planned | Feb 22, 2026 |

**Earliest K8s Work Can Start**: January 5, 2026

---

## Feature Status

### Kubernetes Features (QEMU vs Firecracker)

**As of December 7, 2025**

#### Core Pod Operations

| Feature | QEMU | Firecracker | Status | Depends On |
|---------|------|-------------|--------|------------|
| **Basic Pod** | ✅ | 🚫 | Not Started | Docker Phase 3 |
| **Multi-container Pod** | ✅ | 🚫 | Not Started | Docker Phase 3 |
| **Init containers** | ✅ | 🚫 | Not Started | Docker Phase 3 |
| **Sidecar containers** | ✅ | 🚫 | Not Started | Docker Phase 3 |
| **kubectl exec** | ✅ | 🚫 | Not Started | Docker Phase 3 |
| **kubectl logs** | ✅ | 🚫 | Not Started | Docker Phase 3 |
| **kubectl attach** | ✅ | 🚫 | Not Started | Docker Phase 3 |
| **kubectl port-forward** | ✅ | 🚫 | Not Started | Docker Phase 3 |

#### Storage

| Feature | QEMU | Firecracker | Status | Depends On |
|---------|------|-------------|--------|------------|
| **EmptyDir (memory)** | ✅ | 🚫 | Not Started | Docker volumes |
| **EmptyDir (disk)** | ✅ | 🚫 | Not Started | Docker volumes |
| **PersistentVolume** | ✅ | 🚫 | Not Started | Docker volumes |
| **PVC (RWO)** | ✅ | 🚫 | Not Started | Docker volumes |
| **PVC (RWX)** | ✅ | 🚫 | Not Started | Docker volumes |
| **ConfigMap (volume)** | ✅ | 🚫 | Not Started | Docker volumes |
| **Secret (volume)** | ✅ | 🚫 | Not Started | Docker volumes |
| **Projected volumes** | ✅ | 🚫 | Not Started | Docker volumes |
| **CSI volumes** | 🟡 | 🚫 | Not Started | Docker volumes |

#### Networking

| Feature | QEMU | Firecracker | Status | Depends On |
|---------|------|-------------|--------|------------|
| **Pod networking (CNI)** | ✅ | 🚫 | Not Started | Basic |
| **ClusterIP service** | ✅ | 🚫 | Not Started | Pod networking |
| **NodePort service** | ✅ | 🚫 | Not Started | Pod networking |
| **LoadBalancer** | ✅ | 🚫 | Not Started | Pod networking |
| **Ingress** | ✅ | 🚫 | Not Started | Service |
| **Network policies** | 🟡 | 🚫 | Not Started | CNI support |
| **IPv4** | ✅ | 🚫 | Not Started | Basic |
| **IPv6** | 🟡 | 🚫 | Not Started | IPv4 first |

#### Workload Controllers

| Feature | QEMU | Firecracker | Status | Depends On |
|---------|------|-------------|--------|------------|
| **Deployment** | ✅ | 🚫 | Not Started | Basic Pod |
| **StatefulSet** | ✅ | 🚫 | Not Started | PVC support |
| **DaemonSet** | ✅ | 🚫 | Not Started | Basic Pod |
| **Job** | ✅ | 🚫 | Not Started | Basic Pod |
| **CronJob** | ✅ | 🚫 | Not Started | Job |

#### Configuration

| Feature | QEMU | Firecracker | Status | Depends On |
|---------|------|-------------|--------|------------|
| **ConfigMap (env)** | ✅ | 🚫 | Not Started | Basic |
| **Secret (env)** | ✅ | 🚫 | Not Started | Basic |
| **Resource limits** | ✅ | 🚫 | Not Started | Basic |
| **Resource requests** | ✅ | 🚫 | Not Started | Basic |
| **Node selectors** | ✅ | 🚫 | Not Started | Basic |
| **Affinity/Anti-affinity** | ✅ | 🚫 | Not Started | Basic |
| **Taints/Tolerations** | ✅ | 🚫 | Not Started | Basic |

---

## Completed Work

### ✅ Phase K0: QEMU + Kubernetes (Q4 2024 - Q1 2025)

**Goal**: Production-ready Kubernetes with QEMU hypervisor

**Completed**: January 2025

**Achievements**:
- ✅ k3s integration and testing
- ✅ RuntimeClass configuration
- ✅ CNI networking (Flannel tested)
- ✅ SLIRP user-mode networking for pods
- ✅ Auto-detection of Kubernetes environment
- ✅ Pod lifecycle management
- ✅ Interactive exec (`kubectl exec -it bash`)
- ✅ Container logs streaming
- ✅ Basic ConfigMap support
- ✅ Basic Secret support
- ✅ Resource limits (CPU, memory)
- ✅ Performance optimization (<5s to Running)

**Key Files**:
- `runcvm-ctr-entrypoint` - Kubernetes mode detection
- `runcvm-ctr-qemu` - SLIRP networking for K8s
- `runcvm-ctr-exec` - Kubernetes exec handling

**Example Working Configuration**:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-vm
spec:
  runtimeClassName: runcvm
  containers:
  - name: nginx
    image: nginx
    env:
    - name: RUNCVM_KERNEL
      value: "alpine"
    - name: RUNCVM_KERNEL_APPEND
      value: "quiet loglevel=0 mitigations=off"
    - name: RUNCVM_CGROUPFS
      value: "none"
    ports:
    - containerPort: 80
```

**Performance Metrics**:
- Pod creation to Running: ~4-5 seconds
- kubectl exec response: <1 second
- Network throughput: Near-native

**Timeline**: October 2024 - January 2025

---

## Planned Phases

### Phase K1: Firecracker + Kubernetes Foundation (Q2 2026)

**Prerequisites**: ✅ Docker Phase 3 complete (March 1, 2026)

**Start Date**: April 1, 2026  
**Target Completion**: June 30, 2026 (12 weeks)

**Goal**: Basic Kubernetes functionality with Firecracker

---

#### Week 1-2: Environment Setup (Apr 1 - Apr 14, 2026)

**Objective**: Prepare test environment

**Tasks**:
- [ ] Set up k3s test cluster
- [ ] Configure RuntimeClass for Firecracker
- [ ] Update containerd config
- [ ] Create test namespace
- [ ] Prepare test images

**Deliverables**:
- k3s cluster with Firecracker runtime
- Test harness for K8s + Firecracker
- CI/CD pipeline setup

---

#### Week 3-5: Basic Pod Support (Apr 15 - May 5, 2026)

**Objective**: Single-container pods working

**Tasks**:
- [ ] **Week 3**: Basic pod creation
  - [ ] Adapt Firecracker to K8s environment
  - [ ] CNI network integration
  - [ ] Pod IP assignment
  - [ ] DNS resolution
  
  ```yaml
  apiVersion: v1
  kind: Pod
  metadata:
    name: test-fc
  spec:
    runtimeClassName: runcvm
    containers:
    - name: alpine
      image: alpine
      command: ["sleep", "infinity"]
      env:
      - name: RUNCVM_HYPERVISOR
        value: "firecracker"
  ```

- [ ] **Week 4**: Pod lifecycle
  - [ ] kubectl create/delete
  - [ ] kubectl get/describe
  - [ ] Pod status reporting
  - [ ] Container state tracking
  
- [ ] **Week 5**: Exec and logs
  - [ ] kubectl exec working
  - [ ] kubectl logs streaming
  - [ ] kubectl attach support
  - [ ] kubectl cp testing

**Expected Outcome**:
- ✅ Basic pods create successfully
- ✅ kubectl exec works
- ✅ kubectl logs works
- ✅ Pod networking functional

---

#### Week 6-8: Storage Integration (May 6 - May 26, 2026)

**Objective**: Kubernetes volume support

**Tasks**:
- [ ] **Week 6**: EmptyDir volumes
  - [ ] Memory-backed EmptyDir
  - [ ] Disk-backed EmptyDir
  - [ ] Size limits
  - [ ] Multiple EmptyDir per pod
  
  ```yaml
  volumes:
  - name: cache
    emptyDir: {}
  - name: data
    emptyDir:
      medium: Memory
      sizeLimit: 1Gi
  ```

- [ ] **Week 7**: ConfigMaps and Secrets
  - [ ] ConfigMap as volume
  - [ ] Secret as volume
  - [ ] File permissions (0644, 0600)
  - [ ] Automatic updates
  - [ ] Multiple mounts
  
  ```yaml
  volumes:
  - name: config
    configMap:
      name: app-config
  - name: secrets
    secret:
      secretName: app-secrets
  ```

- [ ] **Week 8**: PersistentVolumes
  - [ ] PVC mounting
  - [ ] RWO volumes
  - [ ] Volume expansion
  - [ ] Reclaim policies
  - [ ] StatefulSet support
  
  ```yaml
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: app-data
  ```

**Expected Outcome**:
- ✅ All volume types work
- ✅ ConfigMaps mount correctly
- ✅ Secrets mount with correct permissions
- ✅ PVCs work with StatefulSets

---

#### Week 9-10: Networking Validation (May 27 - Jun 9, 2026)

**Objective**: Full K8s networking support

**Tasks**:
- [ ] **Week 9**: Service networking
  - [ ] ClusterIP services
  - [ ] NodePort services
  - [ ] LoadBalancer services
  - [ ] Service discovery (DNS)
  - [ ] Endpoint management
  
  ```yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: app-service
  spec:
    type: ClusterIP
    selector:
      app: myapp
    ports:
    - port: 80
      targetPort: 8080
  ```

- [ ] **Week 10**: Advanced networking
  - [ ] Ingress support
  - [ ] Network policies (if CNI supports)
  - [ ] Pod-to-pod communication
  - [ ] Service mesh compatibility (Istio, Linkerd)

**Expected Outcome**:
- ✅ Services route traffic correctly
- ✅ DNS resolution works
- ✅ Ingress works
- ✅ Network policies enforced

---

#### Week 11-12: Testing & Documentation (Jun 10 - Jun 30, 2026)

**Objective**: Production readiness

**Tasks**:
- [ ] **Week 11**: Comprehensive testing
  - [ ] All pod types (Deployment, StatefulSet, DaemonSet, Job)
  - [ ] Multi-container pods
  - [ ] Init containers
  - [ ] Sidecar patterns
  - [ ] Resource limits
  - [ ] Node affinity
  
- [ ] **Week 12**: Documentation and examples
  - [ ] User guide for K8s + Firecracker
  - [ ] Migration guide from QEMU
  - [ ] Performance tuning
  - [ ] Troubleshooting
  - [ ] Example manifests

**Deliverables**:
- Test suite with >80% coverage
- Performance benchmark report
- Complete documentation
- Example application deployments

---

### Phase K2: Advanced Kubernetes Features (Q3 2026)

**Start Date**: July 1, 2026  
**Target Completion**: September 30, 2026

**Goal**: Advanced K8s features and production hardening

**Planned**:
- [ ] Custom Resource Definitions (CRDs)
- [ ] RunCVM Operator
  - [ ] VM lifecycle management
  - [ ] Automatic scaling
  - [ ] Health monitoring
  
- [ ] Advanced storage
  - [ ] CSI driver integration
  - [ ] Snapshot support
  - [ ] Volume cloning
  - [ ] RWX volumes (if possible)
  
- [ ] Multi-tenancy
  - [ ] Namespace isolation
  - [ ] Resource quotas
  - [ ] Pod security policies
  
- [ ] Observability
  - [ ] Metrics (Prometheus)
  - [ ] Logging (Fluentd/Loki)
  - [ ] Tracing (Jaeger)
  - [ ] Dashboard integration

**Timeline**: Q3 2026

---

### Phase K3: Production Scale (Q4 2026)

**Start Date**: October 1, 2026  
**Target Completion**: December 31, 2026

**Goal**: Production-scale deployments

**Planned**:
- [ ] High availability
  - [ ] Multiple replicas
  - [ ] Load balancing
  - [ ] Failure recovery
  
- [ ] Performance at scale
  - [ ] 100+ pods per node
  - [ ] Fast pod startup (<1s)
  - [ ] Resource efficiency
  
- [ ] Security hardening
  - [ ] Pod security standards
  - [ ] Network policies
  - [ ] RBAC integration
  - [ ] Audit logging
  
- [ ] Enterprise features
  - [ ] Backup/restore
  - [ ] Disaster recovery
  - [ ] Multi-cluster support

**Timeline**: Q4 2026

---

## Timeline

```
2025 Q1          2026 Q2         2026 Q3         2026 Q4         2027 Q1
   |                |               |               |               |
   ▼                ▼               ▼               ▼               ▼
┌──────────┐   ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
│ Phase K0 │   │ Docker  │   │ Phase K1 │   │ Phase K2 │   │ Phase K3 │
│   QEMU   │──▶│ Phase 3 │──▶│Firecrk   │──▶│ Advanced │──▶│  Scale   │
│    K8s   │   │ (prereq)│   │  K8s     │   │ Features │   │  & HA    │
└──────────┘   └─────────┘   └──────────┘   └──────────┘   └──────────┘
     ✅             🔄             📅             📅             📅

                   ▲
                   │
              We are here
          December 7, 2025
          (Working on Docker Phase 3)

      K8s work blocked until Docker Phase 3 done
```

### Critical Path

```
Dec 7, 2025  ──────────▶  Mar 1, 2026  ──────────▶  Jun 30, 2026  ──────────▶
   Today              Docker Phase 3           K8s Phase K1
                        Complete                Complete
                      
                      ↓ (Prerequisite)
                      
              ┌──────────────────────┐
              │ Volume support       │
              │ Rootfs caching       │
              │ Performance tuning   │
              └──────────────────────┘
                      ↓
              ┌──────────────────────┐
              │ K8s integration      │
              │ can start            │
              └──────────────────────┘
```

---

## Success Criteria

### Phase K1 Completion (June 30, 2026)

**Must Have**:
- ✅ Single-container pods work
- ✅ Multi-container pods work
- ✅ kubectl exec/logs/attach work
- ✅ EmptyDir volumes work
- ✅ ConfigMaps mount correctly
- ✅ Secrets mount correctly
- ✅ PersistentVolumes work
- ✅ StatefulSets work
- ✅ Services work (ClusterIP, NodePort)
- ✅ DNS resolution works
- ✅ Test coverage >80%

**Should Have**:
- ✅ Ingress working
- ✅ Network policies (basic)
- ✅ Performance <2s pod startup
- ✅ Documentation complete
- ✅ Example applications

**Nice to Have**:
- ✅ Service mesh compatible
- ✅ CSI driver integration
- ✅ Operator framework

---

## Testing Strategy

### Unit Tests
- Firecracker config generation for K8s
- Volume mount parsing
- CNI integration logic
- Pod lifecycle state machine

### Integration Tests
```bash
# Basic pod test
kubectl apply -f test-pod.yaml
kubectl wait --for=condition=Ready pod/test-pod
kubectl exec test-pod -- echo "OK"
kubectl delete pod test-pod

# Volume test
kubectl apply -f test-statefulset.yaml
kubectl exec sts-0 -- ls /data
kubectl delete statefulset test-sts

# Service test
kubectl apply -f test-service.yaml
kubectl run -it test --image=alpine --rm -- wget -O- http://test-service
```

### E2E Tests
- Deploy real applications (WordPress, GitLab, etc.)
- Test upgrade scenarios
- Test failure recovery
- Load testing

### Performance Tests
```bash
# Pod startup time
time kubectl run test --image=alpine \
  --overrides='{"spec":{"runtimeClassName":"runcvm"}}' \
  -- sleep 1

# Concurrent pod creation
for i in {1..10}; do
  kubectl run test-$i --image=alpine \
    --overrides='{"spec":{"runtimeClassName":"runcvm"}}' \
    -- sleep infinity &
done
wait
```

---

## Migration Guide

### From QEMU to Firecracker (For K8s Users)

**When Phase K1 is complete**, users can migrate:

```yaml
# Before (QEMU - default)
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  runtimeClassName: runcvm
  containers:
  - name: app
    image: myapp
```

```yaml
# After (Firecracker - faster boot)
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  runtimeClassName: runcvm
  containers:
  - name: app
    image: myapp
    env:
    - name: RUNCVM_HYPERVISOR
      value: "firecracker"  # ← Only change
```

**Expected improvement**:
- Pod startup: 4-5s → <2s
- Memory overhead: -90%
- No other changes needed

---

## Risk Assessment

### High Risk
1. **Volume support complexity**
   - Mitigation: Complete Docker Phase 3 first
   - Mitigation: Extensive testing with real workloads

2. **CNI compatibility**
   - Mitigation: Test with multiple CNI plugins
   - Mitigation: Document known limitations

3. **Performance at scale**
   - Mitigation: Early performance testing
   - Mitigation: Optimization phase built in

### Medium Risk
1. **StatefulSet support**
   - Mitigation: Focus on PVC support early
   - Mitigation: Test with databases

2. **Multi-container pods**
   - Mitigation: Share network namespace carefully
   - Mitigation: Test init container patterns

### Low Risk
1. **Basic pod operations** (already works in QEMU)
2. **Service networking** (CNI handles this)
3. **ConfigMaps/Secrets** (builds on volume support)

---

## Current Status Summary

**Date**: December 7, 2025

**K8s + QEMU**: ✅ Production Ready
- Fully functional
- Used in testing/development
- Performance optimized

**K8s + Firecracker**: 🚫 Blocked
- Waiting for Docker Phase 3
- Cannot start until volume support ready
- Earliest start: January 5, 2026

**Next Action**: 
- Focus on Docker ROADMAP Phase 3
- Complete volume support
- Prepare K8s test environment

---

## Dependencies

```
┌─────────────────────────────────────────────┐
│          Docker Phase 3                     │
│  (Storage & Persistence)                    │
│                                             │
│  ✅ Docker volumes (-v)                     │
│  ✅ Named volumes                           │
│  ✅ Rootfs caching                          │
│  ✅ Performance (<500ms)                    │
└─────────────────┬───────────────────────────┘
                  │
                  │ Prerequisite
                  ▼
┌─────────────────────────────────────────────┐
│          K8s Phase K1                       │
│  (Basic Kubernetes)                         │
│                                             │
│  📅 EmptyDir volumes                        │
│  📅 ConfigMaps/Secrets                      │
│  📅 PersistentVolumes                       │
│  📅 Services                                │
└─────────────────┬───────────────────────────┘
                  │
                  │ Foundation
                  ▼
┌─────────────────────────────────────────────┐
│          K8s Phase K2                       │
│  (Advanced Features)                        │
│                                             │
│  📅 CRDs & Operators                        │
│  📅 CSI integration                         │
│  📅 Observability                           │
└─────────────────────────────────────────────┘
```

---

**Document Version**: 1.0  
**Last Updated**: December 7, 2025  
**Status**: Blocked - awaiting Docker Phase 3  
**Next Review**: March 1, 2026 (after Docker Phase 3)  
**Owner**: RunCVM Team

---

## Notes

### Why Separate Roadmap?

1. **Different complexity level**
   - Docker: Direct volume mounts
   - K8s: Complex volume types, CSI, projections

2. **Different timelines**
   - Docker: 12 weeks
   - K8s: Requires Docker completion first

3. **Different stakeholders**
   - Docker: Individual developers
   - K8s: Platform teams, operators

4. **Dependency chain**
   - K8s depends entirely on Docker features
   - Makes sense to complete Docker first

### Design Philosophy

**Docker-First Approach**:
- Build solid foundation
- Test thoroughly with Docker
- Then extend to K8s

**Incremental Delivery**:
- Phase K1: Basic functionality
- Phase K2: Advanced features
- Phase K3: Production scale

**Real-World Testing**:
- Test with actual applications
- Performance benchmarks
- Load testing before GA
