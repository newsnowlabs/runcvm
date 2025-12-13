#!/bin/bash
# Storage Test Script for RunCVM Firecracker Mode
# Tests based on docs/docker/storage/test-plan.md
# Generates markdown report at the end
#
# Strategy: Write test outputs to files in the mounted volume,
# then read them from the host to avoid VM boot message pollution.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Report file
REPORT_FILE="/tmp/runcvm-storage-test-report.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Test results arrays
declare -a TEST_IDS
declare -a TEST_NAMES
declare -a TEST_RESULTS
declare -a TEST_OUTPUTS

PASS_COUNT=0
FAIL_COUNT=0

# Initialize report
init_report() {
    cat > "$REPORT_FILE" << EOF
# RunCVM Storage Test Report

**Generated**: $TIMESTAMP  
**Runtime**: runcvm with Firecracker  
**Test Plan**: docs/docker/storage/test-plan.md

---

## Test Results Summary

| Test ID | Test Name | Result |
|---------|-----------|--------|
EOF
}

# Add test result to report
add_test_result() {
    local test_id="$1"
    local test_name="$2"
    local result="$3"
    local output="$4"
    
    TEST_IDS+=("$test_id")
    TEST_NAMES+=("$test_name")
    TEST_RESULTS+=("$result")
    TEST_OUTPUTS+=("$output")
    
    if [ "$result" = "PASS" ]; then
        echo "| $test_id | $test_name | ✅ PASS |" >> "$REPORT_FILE"
        PASS_COUNT=$((PASS_COUNT + 1))
        echo -e "${GREEN}✓ PASS:${NC} $test_id - $test_name"
    else
        echo "| $test_id | $test_name | ❌ FAIL |" >> "$REPORT_FILE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo -e "${RED}✗ FAIL:${NC} $test_id - $test_name"
    fi
}

# Finalize report with detailed outputs
finalize_report() {
    cat >> "$REPORT_FILE" << EOF

---

## Test Statistics

- **Total Tests**: $((PASS_COUNT + FAIL_COUNT))
- **Passed**: $PASS_COUNT
- **Failed**: $FAIL_COUNT
- **Pass Rate**: $(( PASS_COUNT * 100 / (PASS_COUNT + FAIL_COUNT) ))%

---

## Detailed Test Outputs

EOF

    for i in "${!TEST_IDS[@]}"; do
        local id="${TEST_IDS[$i]}"
        local name="${TEST_NAMES[$i]}"
        local result="${TEST_RESULTS[$i]}"
        local output="${TEST_OUTPUTS[$i]}"
        
        if [ "$result" = "PASS" ]; then
            result_icon="✅"
        else
            result_icon="❌"
        fi
        
        cat >> "$REPORT_FILE" << EOF
### $id: $name $result_icon

**Result**: $result

<details>
<summary>Output</summary>

\`\`\`
$output
\`\`\`

</details>

EOF
    done
    
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "*End of Report*" >> "$REPORT_FILE"
}

info() {
    echo -e "${CYAN}→${NC} $1"
}

separator() {
    echo ""
    echo -e "${YELLOW}===== $1 =====${NC}"
}

# Run docker and discard all output (we verify via host filesystem)
run_silent() {
    docker run --rm \
        --runtime=runcvm \
        -e RUNCVM_HYPERVISOR=firecracker \
        "$@" >/dev/null 2>&1 || true
}

# ============================================================
# Test Setup
# ============================================================
separator "Test Environment Setup"

# Cleanup from previous runs
rm -rf /tmp/runcvm-storage-tests 2>/dev/null || true
mkdir -p /tmp/runcvm-storage-tests

info "Test directory: /tmp/runcvm-storage-tests"
info "Report file: $REPORT_FILE"

init_report

# ============================================================
# BM-001: Simple Bind Mount (Read)
# ============================================================
separator "BM-001: Simple Bind Mount (Read)"

TEST_DIR="/tmp/runcvm-storage-tests/bm001"
mkdir -p "$TEST_DIR"
echo "Hello from host" > "$TEST_DIR/test.txt"

# Container reads file and writes result to output.txt in mounted dir
run_silent -v "$TEST_DIR:/data" alpine sh -c 'cat /data/test.txt > /data/output.txt'

# Read the output from host filesystem (avoids VM boot messages)
OUTPUT=$(cat "$TEST_DIR/output.txt" 2>/dev/null || echo "OUTPUT FILE NOT CREATED")

if [ "$OUTPUT" = "Hello from host" ]; then
    add_test_result "BM-001" "Simple Bind Mount (Read)" "PASS" "Content read: '$OUTPUT'"
else
    add_test_result "BM-001" "Simple Bind Mount (Read)" "FAIL" "Expected 'Hello from host', got: '$OUTPUT'"
fi

# ============================================================
# BM-002: Bind Mount (Read-Write)
# ============================================================
separator "BM-002: Bind Mount (Read-Write)"

TEST_DIR="/tmp/runcvm-storage-tests/bm002"
mkdir -p "$TEST_DIR"
echo "initial" > "$TEST_DIR/data.txt"

# Container appends to file
run_silent -v "$TEST_DIR:/data" alpine sh -c 'echo "modified" >> /data/data.txt; sync'

# Check host file after container exit
HOST_CONTENT=$(cat "$TEST_DIR/data.txt" 2>/dev/null || echo "FILE NOT FOUND")

if echo "$HOST_CONTENT" | grep -q "modified"; then
    add_test_result "BM-002" "Bind Mount (Read-Write)" "PASS" "Host file content after write:
$HOST_CONTENT"
else
    add_test_result "BM-002" "Bind Mount (Read-Write)" "FAIL" "Write did not persist to host.
Host content: $HOST_CONTENT"
fi

# ============================================================
# BM-003: Bind Mount (Read-Only Enforcement)
# ============================================================
separator "BM-003: Bind Mount (Read-Only)"

TEST_DIR="/tmp/runcvm-storage-tests/bm003"
mkdir -p "$TEST_DIR"
echo "immutable" > "$TEST_DIR/readonly.txt"

# Try to write (should fail due to :ro)
run_silent -v "$TEST_DIR:/data:ro" alpine sh -c 'echo "changed" > /data/readonly.txt 2>/dev/null || true'

# Check if file was modified on host
HOST_CONTENT=$(cat "$TEST_DIR/readonly.txt" 2>/dev/null || echo "FILE NOT FOUND")

if [ "$HOST_CONTENT" = "immutable" ]; then
    add_test_result "BM-003" "Bind Mount (Read-Only)" "PASS" "File remained unchanged: '$HOST_CONTENT'"
else
    add_test_result "BM-003" "Bind Mount (Read-Only)" "FAIL" "File was modified! Content: '$HOST_CONTENT'"
fi

# ============================================================
# BM-004: Multiple Bind Mounts
# ============================================================
separator "BM-004: Multiple Bind Mounts"

mkdir -p /tmp/runcvm-storage-tests/multi-{1,2,3}
echo "data1" > /tmp/runcvm-storage-tests/multi-1/file1.txt
echo "data2" > /tmp/runcvm-storage-tests/multi-2/file2.txt
echo "data3" > /tmp/runcvm-storage-tests/multi-3/file3.txt

# Container reads all 3 files and writes combined output
run_silent \
    -v /tmp/runcvm-storage-tests/multi-1:/m1 \
    -v /tmp/runcvm-storage-tests/multi-2:/m2 \
    -v /tmp/runcvm-storage-tests/multi-3:/m3 \
    alpine sh -c 'cat /m1/file1.txt /m2/file2.txt /m3/file3.txt > /m1/combined.txt'

OUTPUT=$(cat /tmp/runcvm-storage-tests/multi-1/combined.txt 2>/dev/null || echo "OUTPUT FILE NOT CREATED")

EXPECTED="data1
data2
data3"

if [ "$OUTPUT" = "$EXPECTED" ]; then
    add_test_result "BM-004" "Multiple Bind Mounts" "PASS" "All 3 mounts accessible:
$OUTPUT"
else
    add_test_result "BM-004" "Multiple Bind Mounts" "FAIL" "Expected:
$EXPECTED
Got:
$OUTPUT"
fi

# ============================================================
# 9P-001: Verify 9P Mount Details
# ============================================================
separator "9P-001: Verify 9P Configuration"

TEST_DIR="/tmp/runcvm-storage-tests/9p001"
mkdir -p "$TEST_DIR"
echo "9p-test-content" > "$TEST_DIR/test.txt"

# Container writes diagnostic info to mounted volume
run_silent -v "$TEST_DIR:/data" alpine sh -c '
{
  echo "=== Mount Type ==="
  mount | grep "/data" || echo "No mount found for /data"
  
  echo ""
  echo "=== 9P in Kernel ==="
  grep 9p /proc/filesystems 2>/dev/null || echo "9P not found"
  
  echo ""
  echo "=== runcvm Config ==="
  cat /.runcvm/9p-mounts 2>/dev/null || echo "No config file"
  
  echo ""
  echo "=== File Content ==="
  cat /data/test.txt 2>/dev/null || echo "Cannot read file"
} > /data/diagnostic.txt
'

OUTPUT=$(cat "$TEST_DIR/diagnostic.txt" 2>/dev/null || echo "DIAGNOSTIC FILE NOT CREATED")

if echo "$OUTPUT" | grep -q "9p-test-content"; then
    add_test_result "9P-001" "9P Mount Configuration" "PASS" "$OUTPUT"
else
    add_test_result "9P-001" "9P Mount Configuration" "FAIL" "$OUTPUT"
fi

# ============================================================
# PERF-001: Write Performance
# ============================================================
separator "PERF-001: Write Performance"

TEST_DIR="/tmp/runcvm-storage-tests/perf001"
mkdir -p "$TEST_DIR"

START=$(date +%s%N)
run_silent -v "$TEST_DIR:/data" alpine sh -c 'dd if=/dev/zero of=/data/test.bin bs=1M count=1 2>/dev/null; sync'
END=$(date +%s%N)

DURATION=$(( (END - START) / 1000000 ))

if [ -f "$TEST_DIR/test.bin" ]; then
    SIZE=$(stat -c%s "$TEST_DIR/test.bin" 2>/dev/null || stat -f%z "$TEST_DIR/test.bin" 2>/dev/null || echo 0)
    if [ "$SIZE" -ge 1000000 ]; then
        add_test_result "PERF-001" "Write Performance (1MB)" "PASS" "File created on host: $SIZE bytes
Total container time: ${DURATION}ms"
    else
        add_test_result "PERF-001" "Write Performance (1MB)" "FAIL" "File too small: $SIZE bytes (expected >= 1MB)"
    fi
else
    add_test_result "PERF-001" "Write Performance (1MB)" "FAIL" "Test file not created on host"
fi

# ============================================================
# Finalize Report
# ============================================================
separator "Test Complete"

finalize_report

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo -e "Total Tests: $TOTAL"
echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "${RED}Failed: $FAIL_COUNT${NC}"
echo ""
echo -e "Report saved to: ${CYAN}$REPORT_FILE${NC}"

# Copy report to docs
DOCS_REPORT="./docs/docker/storage/test-report.md"
if [ -d "./docs/docker/storage" ]; then
    cp "$REPORT_FILE" "$DOCS_REPORT"
    echo -e "Report also saved to: ${CYAN}$DOCS_REPORT${NC}"
fi

echo ""
if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. See report for details.${NC}"
    exit 1
fi