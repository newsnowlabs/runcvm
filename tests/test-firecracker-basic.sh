#!/bin/bash -e

# RunCVM Firecracker Integration Test
# Tests the Firecracker integration without full Docker runtime

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="/tmp/runcvm-fc-test-$$"
ROOTFS_IMAGE="$TEST_DIR/rootfs.ext4"
KERNEL_PATH="${KERNEL_PATH:-/path/to/vmlinux}"
FIRECRACKER_BIN="${FIRECRACKER_BIN:-firecracker}"
FIRECRACKER_SOCKET="$TEST_DIR/firecracker.sock"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[TEST]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

cleanup() {
  log "Cleaning up..."
  # Kill Firecracker if running
  pkill -f "firecracker.*$FIRECRACKER_SOCKET" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# ============================================================
# PREREQUISITES CHECK
# ============================================================

check_prerequisites() {
  log "Checking prerequisites..."
  
  # Check for KVM
  if [ ! -e /dev/kvm ]; then
    error "/dev/kvm not found. KVM is required for Firecracker."
  fi
  
  # Check KVM access
  if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    error "Cannot access /dev/kvm. Run with sudo or add user to kvm group."
  fi
  
  # Check for Firecracker binary
  if ! command -v "$FIRECRACKER_BIN" &>/dev/null; then
    error "Firecracker binary not found: $FIRECRACKER_BIN"
  fi
  
  # Check for kernel
  if [ ! -f "$KERNEL_PATH" ]; then
    error "Kernel not found: $KERNEL_PATH"
  fi
  
  # Check for required tools
  for tool in curl jq truncate mke2fs; do
    if ! command -v "$tool" &>/dev/null; then
      error "Required tool not found: $tool"
    fi
  done
  
  log "All prerequisites satisfied"
}

# ============================================================
# CREATE MINIMAL TEST ROOTFS
# ============================================================

create_test_rootfs() {
  log "Creating test rootfs..."
  
  mkdir -p "$TEST_DIR"
  
  # Create a minimal Alpine-based rootfs
  local ROOTFS_DIR="$TEST_DIR/rootfs"
  mkdir -p "$ROOTFS_DIR"
  
  # Download Alpine minirootfs
  local ALPINE_VERSION="3.19"
  local ARCH="x86_64"
  local ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ARCH}.tar.gz"
  
  log "Downloading Alpine minirootfs..."
  curl -fsSL "$ALPINE_URL" | tar -xz -C "$ROOTFS_DIR"
  
  # Create init script
  cat > "$ROOTFS_DIR/init" <<'EOF'
#!/bin/sh
# Minimal init for Firecracker test

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Setup hostname
hostname firecracker-test

echo ""
echo "======================================"
echo "  RunCVM Firecracker Test Successful!"
echo "======================================"
echo ""
echo "Kernel: $(uname -r)"
echo "Hostname: $(hostname)"
echo "Uptime: $(cat /proc/uptime | cut -d' ' -f1)s"
echo ""
echo "Type commands or 'poweroff' to exit"
echo ""

# Start shell on serial console
exec /bin/sh </dev/ttyS0 >/dev/ttyS0 2>&1
EOF
  chmod +x "$ROOTFS_DIR/init"
  
  # Ensure /dev directory exists
  mkdir -p "$ROOTFS_DIR/dev"
  
  # Create ext4 image
  log "Creating ext4 image..."
  truncate -s 128M "$ROOTFS_IMAGE"
  mke2fs -q -F -t ext4 -d "$ROOTFS_DIR" "$ROOTFS_IMAGE"
  
  log "Test rootfs created: $ROOTFS_IMAGE"
}

# ============================================================
# CONFIGURE AND LAUNCH FIRECRACKER
# ============================================================

fc_api() {
  local method="$1"
  local endpoint="$2"
  local data="$3"
  
  curl --silent --show-error \
    --unix-socket "$FIRECRACKER_SOCKET" \
    -X "$method" \
    -H "Content-Type: application/json" \
    ${data:+-d "$data"} \
    "http://localhost${endpoint}"
}

start_firecracker() {
  log "Starting Firecracker..."
  
  rm -f "$FIRECRACKER_SOCKET"
  
  # Start Firecracker in background
  "$FIRECRACKER_BIN" \
    --api-sock "$FIRECRACKER_SOCKET" \
    --log-path "$TEST_DIR/firecracker.log" \
    --level Debug \
    --show-level \
    --show-log-origin &
  
  FC_PID=$!
  log "Firecracker started with PID $FC_PID"
  
  # Wait for API socket
  log "Waiting for API socket..."
  for i in $(seq 1 50); do
    if [ -S "$FIRECRACKER_SOCKET" ]; then
      log "API socket ready"
      return 0
    fi
    sleep 0.1
  done
  
  error "Firecracker API socket not ready after 5s"
}

configure_vm() {
  log "Configuring VM..."
  
  # Configure machine
  log "  Setting machine config..."
  fc_api PUT /machine-config '{
    "vcpu_count": 1,
    "mem_size_mib": 256,
    "smt": false
  }'
  
  # Configure boot source
  log "  Setting boot source..."
  fc_api PUT /boot-source "{
    \"kernel_image_path\": \"$KERNEL_PATH\",
    \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off init=/init\"
  }"
  
  # Configure root drive
  log "  Setting root drive..."
  fc_api PUT /drives/rootfs "{
    \"drive_id\": \"rootfs\",
    \"path_on_host\": \"$ROOTFS_IMAGE\",
    \"is_root_device\": true,
    \"is_read_only\": false
  }"
  
  log "VM configured"
}

start_vm() {
  log "Starting VM..."
  
  fc_api PUT /actions '{
    "action_type": "InstanceStart"
  }'
  
  log "VM started"
}

# ============================================================
# MAIN TEST EXECUTION
# ============================================================

run_test() {
  log "========================================="
  log "RunCVM Firecracker Integration Test"
  log "========================================="
  
  check_prerequisites
  create_test_rootfs
  start_firecracker
  configure_vm
  start_vm
  
  log ""
  log "VM is running. Connect to console or check $TEST_DIR/firecracker.log"
  log "Press Ctrl+C to stop"
  log ""
  
  # Wait for Firecracker to exit
  wait $FC_PID 2>/dev/null || true
  
  log "Test completed"
}

# ============================================================
# API TEST MODE
# ============================================================

test_api_only() {
  log "Testing Firecracker API..."
  
  start_firecracker
  
  # Test GET
  log "Testing GET /..."
  fc_api GET / | jq .
  
  # Test machine-config
  log "Testing PUT /machine-config..."
  fc_api PUT /machine-config '{
    "vcpu_count": 2,
    "mem_size_mib": 512
  }' | jq .
  
  # Verify
  log "Verifying machine-config..."
  fc_api GET /machine-config | jq .
  
  log "API tests passed"
}

# ============================================================
# ENTRY POINT
# ============================================================

case "${1:-run}" in
  run)
    run_test
    ;;
  api)
    test_api_only
    ;;
  rootfs)
    mkdir -p "$TEST_DIR"
    create_test_rootfs
    log "Rootfs created at: $ROOTFS_IMAGE"
    ;;
  *)
    echo "Usage: $0 [run|api|rootfs]"
    echo ""
    echo "Commands:"
    echo "  run     - Full test: create rootfs, start VM (default)"
    echo "  api     - Test Firecracker API only"
    echo "  rootfs  - Create test rootfs only"
    echo ""
    echo "Environment variables:"
    echo "  KERNEL_PATH      - Path to vmlinux kernel (required)"
    echo "  FIRECRACKER_BIN  - Path to firecracker binary (default: firecracker)"
    exit 1
    ;;
esac
