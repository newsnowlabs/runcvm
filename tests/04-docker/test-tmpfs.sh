#!/bin/bash
# test-tmpfs.sh
# Phase 3: tmpfs Validation

set -e
RUNTIME=${RUNTIME:-runcvm}
HYPERVISOR=${RUNCVM_HYPERVISOR:-firecracker}
TEST_NAME="tmpfs-test-$$"
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

cleanup() {
    docker rm -f "$TEST_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Testing $RUNTIME tmpfs..."

# Create container with tmpfs
docker run -d --label runcvm-test=true --name "$TEST_NAME" \
  --runtime="$RUNTIME" \
  -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
  --tmpfs /tmp:rw,size=100m \
  alpine sleep 3600

# Write to tmpfs
docker exec "$TEST_NAME" sh -c 'echo "tmpfs data" > /tmp/test.txt'

# Verify write succeeded
RESULT=$(docker exec "$TEST_NAME" cat /tmp/test.txt)
if [ "$RESULT" = "tmpfs data" ]; then
    echo -e "${GREEN}✅ tmpfs write works${NC}"
else
    echo -e "${RED}❌ tmpfs write failed${NC}"
    exit 1
fi

# Restart container (data should be lost)
docker restart "$TEST_NAME"

# Check if data is gone
if docker exec "$TEST_NAME" test -f /tmp/test.txt 2>/dev/null; then
    echo -e "${RED}❌ tmpfs data persisted (should be volatile!)${NC}"
    exit 1
else
    echo -e "${GREEN}✅ tmpfs data correctly volatile${NC}"
fi
