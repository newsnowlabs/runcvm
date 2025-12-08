#!/bin/bash
# Enhanced test script with debugging for Firecracker volumes
# This version adds debugging output to understand what's happening

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== Enhanced Firecracker Volume Test ===${NC}"
echo ""

# Cleanup from previous runs
rm -rf /tmp/test-vol 2>/dev/null || true
mkdir -p /tmp/test-vol
echo "initial" > /tmp/test-vol/data.txt

echo "Initial file content:"
cat /tmp/test-vol/data.txt
echo ""

echo -e "${YELLOW}Running Firecracker container with verbose output...${NC}"
echo ""

# Run with a more detailed command to see what's happening inside
docker run --rm \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v /tmp/test-vol:/data \
  alpine sh -c '
    echo "=== Inside Firecracker VM ==="
    
    # Check if 9P is supported in kernel
    echo ""
    echo "--- Kernel 9P support ---"
    if grep -q 9p /proc/filesystems 2>/dev/null; then
      echo "✓ 9P filesystem supported"
      grep 9p /proc/filesystems
    else
      echo "✗ 9P filesystem NOT supported in kernel"
      echo "Available filesystems:"
      cat /proc/filesystems
    fi
    
    # Check kernel config for 9P
    echo ""
    echo "--- Kernel 9P config ---"
    if [ -f /proc/config.gz ]; then
      zcat /proc/config.gz 2>/dev/null | grep -E "CONFIG_(NET_)?9P" || echo "No 9P config found"
    else
      echo "/proc/config.gz not available"
    fi
    
    # Check 9p-mounts file
    echo ""
    echo "--- 9P mount config ---"
    if [ -f /.runcvm/9p-mounts ]; then
      echo "✓ 9p-mounts file exists:"
      cat /.runcvm/9p-mounts
    else
      echo "✗ No /.runcvm/9p-mounts file found"
      echo "Contents of /.runcvm/:"
      ls -la /.runcvm/ 2>/dev/null || echo "/.runcvm/ does not exist"
    fi
    
    # Check current mounts
    echo ""
    echo "--- Current 9P mounts ---"
    mount | grep 9p || echo "No 9P mounts found"
    
    # Check /data mount
    echo ""
    echo "--- /data mount status ---"
    if mountpoint -q /data 2>/dev/null; then
      echo "✓ /data is a mountpoint"
      mount | grep "/data" || true
    else
      echo "✗ /data is NOT a mountpoint"
    fi
    
    # Check /data contents
    echo ""
    echo "--- /data contents ---"
    ls -la /data/ 2>/dev/null || echo "/data does not exist or is empty"
    
    # Check if data.txt exists
    echo ""
    echo "--- data.txt status ---"
    if [ -f /data/data.txt ]; then
      echo "Content before write:"
      cat /data/data.txt
    else
      echo "✗ /data/data.txt does not exist"
    fi
    
    # Try to write
    echo ""
    echo "--- Attempting write ---"
    if echo "modified" >> /data/data.txt 2>&1; then
      echo "✓ Write succeeded"
      echo "Content after write:"
      cat /data/data.txt
      
      # Force sync
      sync
      echo "✓ Sync completed"
    else
      echo "✗ Write failed"
    fi
    
    echo ""
    echo "=== End of VM diagnostics ==="
  '

echo ""
echo -e "${CYAN}=== Host-side verification ===${NC}"
echo ""
echo "File content on host after container exit:"
cat /tmp/test-vol/data.txt
echo ""

if grep -q "modified" /tmp/test-vol/data.txt 2>/dev/null; then
    echo -e "${GREEN}✓ PASS: Changes persisted to host${NC}"
else
    echo -e "${RED}✗ FAIL: Changes did NOT persist to host${NC}"
    echo ""
    echo -e "${YELLOW}Possible causes:${NC}"
    echo "1. Kernel missing 9P support (CONFIG_9P_FS)"
    echo "2. diod server not running on host"
    echo "3. vsock not configured in Firecracker"
    echo "4. mount_9p_volumes() not called in VM init"
    echo "5. Volume mount path mismatch"
    echo ""
    echo "Run the diagnostic script for more details:"
    echo "  ./debug-fc-volumes.sh"
fi