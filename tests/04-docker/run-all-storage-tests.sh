#!/bin/bash
# run-all-storage-tests.sh
# Master runner for RunCVM Storage Validation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RUNTIME=${RUNTIME:-runcvm}
export RUNCVM_HYPERVISOR=${RUNCVM_HYPERVISOR:-firecracker}

echo "========================================="
echo "Storage Test Suite - RunCVM ($RUNCVM_HYPERVISOR)"
echo "========================================="
echo "Date: $(date)"
echo "Using Runtime: $RUNTIME"
echo "========================================="
echo ""

# Array to track results
declare -A RESULTS
PASS_COUNT=0
FAIL_COUNT=0

run_test() {
    local test_name=$1
    local test_script=$2
    
    echo "-----------------------------------------"
    echo "Running: $test_name"
    echo "Script: $test_script"
    echo "-----------------------------------------"
    
    if "$SCRIPT_DIR/$test_script"; then
        RESULTS["$test_name"]="PASS"
        echo "✅ $test_name: PASS"
        ((PASS_COUNT++))
    else
        RESULTS["$test_name"]="FAIL"
        echo "❌ $test_name: FAIL"
        ((FAIL_COUNT++))
    fi
    echo ""
}

# Run tests
run_test "Phase 1 & 2: Bind Mounts & Volumes" "test-storage.sh"
run_test "Phase 3: tmpfs Mounts" "test-tmpfs.sh"
run_test "Phase 4: Caching & Boot Performance" "test-caching.sh"
run_test "Phase 5: Data Persistence (MySQL & Postgres)" "test-persistence.sh"

# Summary
echo "========================================="
echo "Test Summary"
echo "========================================="
for test in "${!RESULTS[@]}"; do
    if [ "${RESULTS[$test]}" = "PASS" ]; then
        echo "✅ $test"
    else
        echo "❌ $test"
    fi
done

echo ""
echo "Total: $((PASS_COUNT + FAIL_COUNT)) tests"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo "✅ All tests passed!"
    exit 0
else
    echo "❌ Some tests failed"
    exit 1
fi
