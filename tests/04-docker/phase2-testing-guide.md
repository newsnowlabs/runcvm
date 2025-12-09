# Phase 2 Named Volumes Testing Guide

**Purpose**: Step-by-step guide to debug and verify Phase 2 named volume tests  
**Date**: December 9, 2025

---

## Quick Diagnosis

Based on your error output:
```
✗ FAIL: NV-001 - Create Named Volume
test-vol-nv001-2210544

✗ FAIL: NV-002 - Use Named Volume
test-vol-nv002-2210544

/.runcvm/guest/usr/bin/dbclient: Connection to root@172.17.0.2:22222 exited: Connect failed: Host is unreachable
```

**Likely Issues**:
1. Named volumes may not be working with runcvm runtime
2. SSH connection issue in long-running containers (NV-003)
3. Volume creation succeeding but data not persisting

---

## Step-by-Step Manual Testing

### Test 1: Verify Docker Volume Creation

```bash
# Create a test volume
docker volume create test-manual-vol

# Verify it exists
docker volume ls | grep test-manual-vol

# Inspect the volume
docker volume inspect test-manual-vol

# Expected output should show:
# - Name: test-manual-vol
# - Driver: local
# - Mountpoint: /var/lib/docker/volumes/test-manual-vol/_data
```

**✅ If this works**: Docker volumes are functional  
**❌ If this fails**: Docker volume subsystem issue

---

### Test 2: Use Named Volume with RunCVM Firecracker

```bash
# Create volume
docker volume create test-runcvm

# Write data with runcvm runtime
sudo docker run --rm \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v test-runcvm:/data \
  alpine sh -c 'echo "runcvm-test" > /data/file.txt'

# Read data back
docker run --rm \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v test-runcvm:/data \
  alpine cat /data/file.txt

# Expected output: "runcvm-test"

# Cleanup
docker volume rm test-runcvm
```

**✅ If this works**: Named volumes work with runcvm  
**❌ If this fails**: RunCVM volume integration issue

---

### Test 3: Check Where Volume Data Goes

```bash
# Create and use volume
docker volume create test-location
docker run --rm \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v test-location:/data \
  alpine sh -c 'echo "location-test" > /data/file.txt'

# Find the volume mountpoint
MOUNTPOINT=$(docker volume inspect test-location -f '{{.Mountpoint}}')
echo "Volume mountpoint: $MOUNTPOINT"

# Check if file exists on host
ls -la "$MOUNTPOINT"
cat "$MOUNTPOINT/file.txt" 2>/dev/null || echo "File not found on host"

# Cleanup
docker volume rm test-location
```

**Expected**: File should exist at the mountpoint  
**If missing**: Volume data not syncing back to host

---

### Test 4: Debug Volume Mount Inside Container

```bash
# Create volume
docker volume create test-debug

# Run container with shell access
docker run --rm -it \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v test-debug:/data \
  alpine sh

# Inside container, run these commands:
mount | grep /data
ls -la /data
echo "test" > /data/test.txt
cat /data/test.txt
exit

# Cleanup
docker volume rm test-debug
```

**Check**:
- Is `/data` mounted?
- What filesystem type? (should show 9p if 9P is working)
- Can you write files?
- Can you read them back?

---

### Test 5: Check 9P Mount Status

```bash
# Run container and check 9P
docker run --rm \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v test-9p:/data \
  alpine sh -c '
    echo "=== Checking 9P Support ==="
    grep 9p /proc/filesystems || echo "9P not in kernel"
    
    echo ""
    echo "=== Mount Info ==="
    mount | grep /data || echo "No /data mount found"
    
    echo ""
    echo "=== Directory Contents ==="
    ls -la /data
    
    echo ""
    echo "=== Write Test ==="
    echo "test-data" > /data/test.txt && echo "Write successful" || echo "Write failed"
    
    echo ""
    echo "=== Read Test ==="
    cat /data/test.txt || echo "Read failed"
  '
```

**Expected 9P Output**:
```
=== Checking 9P Support ===
nodev   9p

=== Mount Info ===
169.254.1.1:/data on /data type 9p (rw,...)

=== Write Test ===
Write successful

=== Read Test ===
test-data
```

---

## Common Issues and Solutions

### Issue 1: Volume Created But Empty

**Symptom**: `docker volume ls` shows volume, but no data inside

**Possible Causes**:
1. Volume not mounted correctly in VM
2. 9P mount failing silently
3. Volume path mismatch

**Debug**:
```bash
# Check runcvm logs
journalctl -u runcvm -n 50 --no-pager

# Check if diod (9P server) is running
ps aux | grep diod

# Check volume driver
docker volume inspect test-vol | grep Driver
```

---

### Issue 2: SSH Connection Failed (NV-003)

**Symptom**: `Connection to root@172.17.0.2:22222 exited: Host is unreachable`

**Possible Causes**:
1. Long-running containers not starting properly
2. Network not configured
3. SSH daemon not running in container

**Solution**: Simplify NV-003 test to not use `docker exec`, instead:

```bash
# Alternative approach - use volume to verify persistence
docker volume create test-persist

# Container 1: Write data
docker run -d --name persist-test \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v test-persist:/data \
  alpine sh -c 'echo "iteration-1" > /data/counter.txt; sleep 3600'

# Wait for container to start
sleep 5

# Stop container
docker stop persist-test

# Container 2: Read data (new container, same volume)
docker run --rm \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v test-persist:/data \
  alpine cat /data/counter.txt

# Expected: "iteration-1"

# Cleanup
docker rm persist-test
docker volume rm test-persist
```

---

### Issue 3: Named Volumes Not Working with RunCVM

**Symptom**: Bind mounts work, but named volumes don't

**Possible Cause**: RunCVM may handle named volumes differently than bind mounts

**Debug Steps**:

1. **Check how runcvm handles volumes**:
```bash
# Look at runcvm runtime script
grep -A 20 "volume" /usr/local/bin/runcvm-runtime
```

2. **Compare bind mount vs named volume**:
```bash
# Bind mount (known working from Phase 1)
mkdir -p /tmp/test-bind
docker run --rm \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v /tmp/test-bind:/data \
  alpine sh -c 'echo "bind" > /data/test.txt'
cat /tmp/test-bind/test.txt

# Named volume
docker volume create test-named
docker run --rm \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v test-named:/data \
  alpine sh -c 'echo "named" > /data/test.txt'

# Check if data persisted
MOUNTPOINT=$(docker volume inspect test-named -f '{{.Mountpoint}}')
cat "$MOUNTPOINT/test.txt" 2>/dev/null || echo "Not found"
```

---

## Simplified Phase 2 Tests

If the full test script fails, try these minimal tests:

### Minimal NV-001: Create Named Volume

```bash
#!/bin/bash
echo "=== NV-001: Create Named Volume ==="

VOL="test-nv001"
docker volume create "$VOL"

if docker volume ls | grep -q "$VOL"; then
  echo "✅ Volume created"
  
  # Use it
  docker run --rm --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
    -v "$VOL:/data" alpine sh -c 'echo "test" > /data/file.txt'
  
  # Read back
  RESULT=$(docker run --rm --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
    -v "$VOL:/data" alpine cat /data/file.txt 2>&1)
  
  if [ "$RESULT" = "test" ]; then
    echo "✅ NV-001 PASS: Data persisted"
  else
    echo "❌ NV-001 FAIL: Got '$RESULT'"
  fi
else
  echo "❌ NV-001 FAIL: Volume not created"
fi

docker volume rm "$VOL" 2>/dev/null
```

### Minimal NV-002: Use Named Volume

```bash
#!/bin/bash
echo "=== NV-002: Use Named Volume ==="

VOL="test-nv002"
docker volume create "$VOL"

# Write
docker run --rm --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
  -v "$VOL:/data" alpine sh -c 'echo "persistent" > /data/test.txt'

# Read in new container
RESULT=$(docker run --rm --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
  -v "$VOL:/data" alpine cat /data/test.txt 2>&1)

if [ "$RESULT" = "persistent" ]; then
  echo "✅ NV-002 PASS"
else
  echo "❌ NV-002 FAIL: Got '$RESULT'"
fi

docker volume rm "$VOL"
```

### Minimal NV-003: Volume Persistence (Without docker exec)

```bash
#!/bin/bash
echo "=== NV-003: Volume Persistence ==="

VOL="test-nv003"
docker volume create "$VOL"

# Write iteration 1
docker run --rm --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
  -v "$VOL:/data" alpine sh -c 'echo "iteration-1" > /data/counter.txt'

# Simulate container restart by using new container
RESULT1=$(docker run --rm --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
  -v "$VOL:/data" alpine cat /data/counter.txt 2>&1)

if [ "$RESULT1" = "iteration-1" ]; then
  echo "✅ Data persisted after first run"
  
  # Append iteration 2
  docker run --rm --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
    -v "$VOL:/data" alpine sh -c 'echo "iteration-2" >> /data/counter.txt'
  
  # Read both
  RESULT2=$(docker run --rm --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
    -v "$VOL:/data" alpine cat /data/counter.txt 2>&1)
  
  EXPECTED="iteration-1
iteration-2"
  
  if [ "$RESULT2" = "$EXPECTED" ]; then
    echo "✅ NV-003 PASS"
  else
    echo "❌ NV-003 FAIL: Expected:"
    echo "$EXPECTED"
    echo "Got:"
    echo "$RESULT2"
  fi
else
  echo "❌ NV-003 FAIL: First iteration lost"
fi

docker volume rm "$VOL"
```

---

## Diagnostic Checklist

Run through this checklist:

- [ ] Docker daemon is running
- [ ] `docker volume create` works
- [ ] Standard Docker can use named volumes
- [ ] RunCVM can use bind mounts (Phase 1 tests pass)
- [ ] 9P filesystem is available in kernel (`grep 9p /proc/filesystems`)
- [ ] diod (9P server) is running when container starts
- [ ] Named volumes work with `--runtime=runcvm`
- [ ] Data persists between container runs
- [ ] Volume mountpoint on host contains the data

---

## Expected Test Results

### If 9P is Working Correctly

All tests should show:
```
✅ PASS: NV-001 - Create Named Volume
✅ PASS: NV-002 - Use Named Volume
✅ PASS: NV-003 - Volume Persistence
✅ PASS: NV-004 - Share Volume Between Containers
✅ PASS: NV-005 - Volume Deletion
✅ PASS: NV-006 - Volume Inspection
```

### If 9P is NOT Working

You'll see:
```
❌ FAIL: NV-001 - Volume created but data not persisted
❌ FAIL: NV-002 - Cannot read data back
❌ FAIL: NV-003 - Data lost between runs
```

**Action**: Check if 9P mounts are actually happening:
```bash
# Inside a running container
mount | grep 9p
# Should show: 169.254.1.1:/volume-name on /data type 9p
```

---

## Next Steps Based on Results

### Scenario 1: All Tests Pass ✅
- Phase 2 is complete!
- Move to Phase 3 (tmpfs mounts)
- Update design.md to mark Phase 2 complete

### Scenario 2: Named Volumes Don't Work ❌
- Check if runcvm-runtime handles named volumes
- May need to add volume translation logic
- Verify 9P server starts for named volumes

### Scenario 3: 9P Not Mounting ❌
- Verify kernel has 9P support
- Check diod configuration
- Review network bridge setup
- Check firecracker VM network connectivity

---

## Quick Reference Commands

```bash
# List all volumes
docker volume ls

# Inspect a volume
docker volume inspect <volume-name>

# Remove a volume
docker volume rm <volume-name>

# Remove all unused volumes
docker volume prune -f

# Check runcvm logs
journalctl -u runcvm -f

# Check if 9P is available in VM
docker run --rm --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
  alpine grep 9p /proc/filesystems

# Check mounts in VM
docker run --rm --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker \
  -v test:/data alpine mount | grep /data
```

---

## Report Your Findings

After testing, document:

1. **Which tests passed/failed**
2. **Error messages** (exact output)
3. **Mount output** (from `mount | grep /data`)
4. **9P availability** (from `grep 9p /proc/filesystems`)
5. **Volume inspection** (from `docker volume inspect`)

This will help identify the exact issue!

---

**Good luck with testing! 🧪**
