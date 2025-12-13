#!/bin/bash
# test-storage.sh
# Consolidated storage tests (Phase 1 & 2) for RunCVM with NFS

set -e

# Configuration
RUNTIME=${RUNTIME:-runcvm}
HYPERVISOR=${RUNCVM_HYPERVISOR:-firecracker}
TEST_DIR="/tmp/runcvm-storage-tests-$$"
mkdir -p "$TEST_DIR"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS] $1${NC}"; }
fail() { echo -e "${RED}[FAIL] $1${NC}"; exit 1; }
info() { echo -e "\n=== $1 ==="; }

cleanup() {
    rm -rf "$TEST_DIR"
    docker rm -f $(docker ps -a -q --filter label=runcvm-test=true) 2>/dev/null || true
    docker volume prune -f >/dev/null 2>/dev/null || true
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# NFS-001: NFS Daemon Verification
# -----------------------------------------------------------------------------
info "NFS-001: NFS Daemon Verification"

# Start a background container
CID=$(docker run -d --rm --label runcvm-test=true \
    --runtime="$RUNTIME" -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
    -v "$TEST_DIR:/data" \
    alpine sleep 3600)

info "Container started: $CID"
sleep 2 # Give it a moment to initialize

# Check for unfsd process
if pgrep -a "unfsd" | grep -q "$CID"; then
    pass "unfsd process found for container"
else
    # Fallback check: look for unfsd generally
    if pgrep -x "unfsd" >/dev/null; then
         # If we can't match CID in process list (maybe truncated), check exports
         if [ -f "/run/runcvm-nfs/$CID.exports" ]; then
             pass "unfsd process running and exports file exists"
         else
             fail "unfsd running but exports file missing for container"
         fi
    else
        fail "unfsd process NOT found"
    fi
fi

# Check exports file content
if [ -f "/run/runcvm-nfs/$CID.exports" ]; then
    pass "Exports file found at /run/runcvm-nfs/$CID.exports"
    cat "/run/runcvm-nfs/$CID.exports"
else
    fail "Exports file missing"
fi

docker stop "$CID" >/dev/null

# -----------------------------------------------------------------------------
# BM-001 & BM-002: Bind Mount Read/Write
# -----------------------------------------------------------------------------
info "BM-001 & BM-002: Bind Mount Read/Write"

echo "host-data" > "$TEST_DIR/host-file.txt"

# Run container to read/write
docker run --rm --label runcvm-test=true \
    --runtime="$RUNTIME" -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
    -v "$TEST_DIR:/data" \
    alpine sh -c '
        echo "Reading file..."
        cat /data/host-file.txt
        echo "container-data" > /data/container-file.txt
        echo "Appending from container" >> /data/host-file.txt
    '

# Verify
if grep -q "host-data" "$TEST_DIR/host-file.txt" && \
   grep -q "Appending from container" "$TEST_DIR/host-file.txt"; then
    pass "Bidirectional sync worked (Host -> Container -> Host)"
else
    fail "File content mismatch on host"
fi

if [ "$(cat $TEST_DIR/container-file.txt)" = "container-data" ]; then
    pass "File created in container exists on host"
else
    fail "File created in container missing on host"
fi

# -----------------------------------------------------------------------------
# BM-003: Read-Only Mount
# -----------------------------------------------------------------------------
info "BM-003: Read-Only Mount"

if docker run --rm --label runcvm-test=true \
    --runtime="$RUNTIME" -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
    -v "$TEST_DIR:/data:ro" \
    alpine sh -c 'echo "fail" > /data/readonly.txt' 2>/dev/null; then
    fail "Wrote to read-only mount (should have failed)"
else
    pass "Write to read-only mount failed as expected"
fi

# -----------------------------------------------------------------------------
# NV-001: Named Volumes
# -----------------------------------------------------------------------------
info "NV-001: Named Volumes"

VOL_NAME="runcvm-test-vol-$$"
docker volume create "$VOL_NAME"

# Write data
docker run --rm --label runcvm-test=true \
    --runtime="$RUNTIME" -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
    -v "$VOL_NAME:/data" \
    alpine sh -c 'echo "persistent-data" > /data/persist.txt'

# Verify persistence in new container
RESULT=$(docker run --rm --label runcvm-test=true \
    --runtime="$RUNTIME" -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
    -v "$VOL_NAME:/data" \
    alpine cat /data/persist.txt)

if [ "$RESULT" = "persistent-data" ]; then
    pass "Named volume persistence verified"
else
    fail "Named volume data lost"
fi

docker volume rm "$VOL_NAME"

# -----------------------------------------------------------------------------
# NFS-002: Concurrent Access
# -----------------------------------------------------------------------------
info "NFS-002: Concurrent Access"

CONCURRENT_FILE="$TEST_DIR/concurrent.txt"
echo "start" > "$CONCURRENT_FILE"

# Start container A
CID_A=$(docker run -d --label runcvm-test=true \
    --runtime="$RUNTIME" -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
    -v "$TEST_DIR:/data" \
    alpine sh -c 'while true; do echo "A" >> /data/concurrent.txt; sleep 0.1; done')

# Start container B
CID_B=$(docker run -d --label runcvm-test=true \
    --runtime="$RUNTIME" -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
    -v "$TEST_DIR:/data" \
    alpine sh -c 'while true; do echo "B" >> /data/concurrent.txt; sleep 0.1; done')

sleep 2
docker stop "$CID_A" "$CID_B" >/dev/null

# Verify both wrote
if grep -q "A" "$CONCURRENT_FILE" && grep -q "B" "$CONCURRENT_FILE"; then
    pass "Both containers wrote to file successfully"
else
    fail "One or both containers failed to write"
fi

info "All tests passed successfully!"
