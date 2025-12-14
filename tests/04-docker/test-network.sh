#!/bin/bash
# test-network.sh
# Test Multiple NICs and Host Networking for RunCVM Firecracker

set -e

# Configuration
RUNTIME=${RUNTIME:-runcvm}
HYPERVISOR=${RUNCVM_HYPERVISOR:-firecracker}
TEST_DIR="/tmp/runcvm-network-tests-$$"
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
    docker network rm runcvm-net1 runcvm-net2 2>/dev/null || true
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# CHECK PREREQUISITES
# -----------------------------------------------------------------------------
info "Checking Prerequisites"

if ! docker info | grep -q "Runtimes.*$RUNTIME"; then
    echo "Runtime '$RUNTIME' not found in docker info."
    echo "Please ensure you have installed/configured the runtime."
    exit 1
fi

# -----------------------------------------------------------------------------
# NET-001: Multiple NICs Support
# -----------------------------------------------------------------------------
info "NET-001: Multiple NICs Support"

# Create two networks
docker network create runcvm-net1
docker network create runcvm-net2

# Run container attached to both networks
CID=$(docker run -d --rm --label runcvm-test=true \
    --runtime="$RUNTIME" -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
    --net runcvm-net1 \
    alpine sleep 3600)

# Connect second network
docker network connect runcvm-net2 "$CID"

# Wait for reconfiguration/restart if needed (RunCVM might need restart if not hot-plug supported, 
# but here we connect, then we exec. Note: Firecracker might not support hot-plugging NICs easily 
# without reboot, but let's test if *startup* with multiple NICs works.
# Actually, standard docker network connect on running container might not hot-plug into VM.
# Better approach: Create container with multiple networks specified at creation? 
# Docker allows only one --net at run, but we can create then start.
docker stop "$CID" >/dev/null
docker rm "$CID" >/dev/null

# Create with non-running state to attach 2nd network
CID=$(docker create --rm --label runcvm-test=true \
    --runtime="$RUNTIME" -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
    --net runcvm-net1 \
    alpine sleep 3600)

docker network connect runcvm-net2 "$CID"
docker start "$CID"

info "Container started with 2 networks: $CID"
sleep 5 # Allow VM boot

# Verify interfaces inside VM
INTERFACES=$(docker exec "$CID" ip -o link show | grep -c "eth")

if [ "$INTERFACES" -ge 2 ]; then
    pass "Found $INTERFACES ethernet interfaces (expected >= 2)"
else
    # Show what we found
    docker exec "$CID" ip addr show
    fail "Found only $INTERFACES ethernet interfaces (expected >= 2)"
fi

# Verify connectivity on both (simple check: do they have IPs?)
IP1=$(docker exec "$CID" ip -o -4 addr show eth0 | awk '{print $4}')
IP2=$(docker exec "$CID" ip -o -4 addr show eth1 | awk '{print $4}')

if [ -n "$IP1" ] && [ -n "$IP2" ]; then
    pass "Both interfaces have IPs: eth0=$IP1, eth1=$IP2"
else
    fail "One or both interfaces missing IP"
fi

# -----------------------------------------------------------------------------
# NET-002: Host Networking Mode
# -----------------------------------------------------------------------------
info "NET-002: Host Networking Mode"

# Run with --net=host and RUNCVM_NETWORK_MODE=host
# Note: RUNCVM_NETWORK_MODE=host is required as explicitly defined in our implementation plan
CID_HOST=$(docker run -d --rm --label runcvm-test=true \
    --runtime="$RUNTIME" -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
    --net=host -e RUNCVM_NETWORK_MODE=host \
    alpine sleep 3600)

info "Container started in Host Mode: $CID_HOST"
sleep 5

# Verify we have internet access (outbound)
if docker exec "$CID_HOST" ping -c 1 8.8.8.8 >/dev/null; then
    pass "Outbound connectivity (Ping 8.8.8.8) works"
else
    fail "No outbound connectivity in host mode"
fi

# Verify interface configuration (should be tap0 inside VM, but named eth0 likely due to our map)
# In our implementation: we map tap0 (host) -> eth0 (guest)
HOST_IF_CFG=$(docker exec "$CID_HOST" ip addr show eth0)
if echo "$HOST_IF_CFG" | grep -q "169.254.100.2"; then
    pass "VM has expected private IP 169.254.100.2"
else
    echo "$HOST_IF_CFG"
    fail "VM does not have expected private IP"
fi

info "All network tests passed!"
