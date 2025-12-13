#!/bin/bash
# test-caching.sh
# Phase 4: Rootfs Caching & Boot Performance

set -e
RUNTIME=${RUNTIME:-runcvm}
HYPERVISOR=${RUNCVM_HYPERVISOR:-firecracker}
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

IMAGE="alpine:latest"

# Clear any existing cache to ensure cold boot
echo "Clearing cache..."
if [ -d "/var/lib/runcvm/cache" ]; then
    sudo rm -rf /var/lib/runcvm/cache/* >/dev/null 2>&1 || true
fi

echo "Testing cold boot with $IMAGE..."

# Pull image if not present
docker pull "$IMAGE" >/dev/null 2>&1

# Measure cold boot
START=$(date +%s%N)
docker run --rm --label runcvm-test=true \
  --runtime="$RUNTIME" \
  -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
  "$IMAGE" echo "ready" >/dev/null 2>&1
END=$(date +%s%N)

# MacOS might not have %N, check date capability
if [ -z "$START" ]; then
    # Fallback for systems without date +%s%N (like busybox or older coreutils on mac if gnudate not installed)
    # But user environment is Mac, usually default date doesn't support %N.
    # We will use python or perl if available, or just skip precise timing if needed.
    # Assuming perl is available on mac
    START=$(perl -MTime::HiRes -e 'printf("%d\n",Time::HiRes::time()*1000)')
    # Run again for fair measurement if python caused delay? No, capturing time around command.
    docker run --rm --label runcvm-test=true \
      --runtime="$RUNTIME" \
      -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
      "$IMAGE" echo "ready" >/dev/null 2>&1
    END=$(perl -MTime::HiRes -e 'printf("%d\n",Time::HiRes::time()*1000)')
    DURATION=$((END - START))
else
    DURATION=$(( (END - START) / 1000000 )) # Convert nanoseconds to ms
fi

echo "Cold boot duration: ${DURATION}ms"

# Benchmark validation
if [ $DURATION -lt 2000 ]; then
    echo -e "${GREEN}✅ Cold boot time acceptable (<2000ms)${NC}"
else
    echo -e "${YELLOW}⚠️  Cold boot slow ($DURATION ms)${NC}"
fi

echo "Testing warm boot (cached)..."
# Measure warm boot
START=$(perl -MTime::HiRes -e 'printf("%d\n",Time::HiRes::time()*1000)' 2>/dev/null || date +%s%N)
if [ ${#START} -gt 15 ]; then START=$((START/1000000)); fi # normalize if it was nanosec

docker run --rm --label runcvm-test=true \
  --runtime="$RUNTIME" \
  -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
  "$IMAGE" echo "ready" >/dev/null 2>&1

END=$(perl -MTime::HiRes -e 'printf("%d\n",Time::HiRes::time()*1000)' 2>/dev/null || date +%s%N)
if [ ${#END} -gt 15 ]; then END=$((END/1000000)); fi

DURATION_WARM=$((END - START))
echo "Warm boot duration: ${DURATION_WARM}ms"

if [ $DURATION_WARM -lt 500 ]; then
    echo -e "${GREEN}✅ Warm boot time acceptable (<500ms)${NC}"
else
    echo -e "${YELLOW}⚠️  Warm boot slow ($DURATION_WARM ms)${NC}"
fi

# Compare
if [ $DURATION_WARM -lt $DURATION ]; then
     echo -e "${GREEN}✅ Caching is working (Warm < Cold)${NC}"
else
     echo -e "${RED}❌ Caching might not be effective${NC}"
fi
