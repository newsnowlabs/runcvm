#!/bin/bash
# ============================================================
# build-kernel.sh - Simple Firecracker Kernel Builder
# ============================================================
# Builds Firecracker kernels using docker build + docker cp
# (avoids docker buildx export hanging issue)
#
# Usage:
#   ./build-kernel.sh [OPTIONS]
#
# Options:
#   -a, --arch ARCH         Target: x86_64 or arm64 (default: auto-detect)
#   -k, --kernel VERSION    Kernel version (default: 5.10.204)
#   -A, --alpine VERSION    Alpine version (default: 3.19)
#   -o, --output FILE       Output file path (default: ./vmlinux or ./Image)
#   -d, --dockerfile FILE   Dockerfile path (default: ./Dockerfile.firecracker-kernels)
#   -c, --config DIR        Config directory (default: ./kernels/firecracker)
#   --keep                  Keep Docker image after build
#   --clean                 Remove existing Docker images before build
#   -h, --help              Show this help
#
# Examples:
#   ./build-kernel.sh
#   ./build-kernel.sh --arch arm64 --kernel 6.6.5 --output ./my-kernel
#   ./build-kernel.sh -a x86_64 -k 5.15.0 -A 3.18 -o ./vmlinux-5.15
# ============================================================

set -euo pipefail

# Defaults
ARCH="auto"
KERNEL_VERSION="5.10.204"
ALPINE_VERSION="3.19"
OUTPUT=""
DOCKERFILE="./Dockerfile.firecracker-kernels"
CONFIG_DIR="./kernels/firecracker"
KEEP_IMAGE=false
CLEAN_FIRST=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ============================================================
# Parse Arguments
# ============================================================
show_help() {
    head -30 "$0" | grep -E "^#" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--arch)      ARCH="$2"; shift 2 ;;
        -k|--kernel)    KERNEL_VERSION="$2"; shift 2 ;;
        -A|--alpine)    ALPINE_VERSION="$2"; shift 2 ;;
        -o|--output)    OUTPUT="$2"; shift 2 ;;
        -d|--dockerfile) DOCKERFILE="$2"; shift 2 ;;
        -c|--config)    CONFIG_DIR="$2"; shift 2 ;;
        --keep)         KEEP_IMAGE=true; shift ;;
        --clean)        CLEAN_FIRST=true; shift ;;
        -h|--help)      show_help ;;
        *)              error "Unknown option: $1" ;;
    esac
done

# ============================================================
# Detect Architecture
# ============================================================
if [[ "$ARCH" == "auto" ]]; then
    case "$(uname -m)" in
        x86_64|amd64)   ARCH="x86_64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        *)              error "Unsupported architecture: $(uname -m)" ;;
    esac
    log "Auto-detected architecture: $ARCH"
fi

# Normalize arch names
case "$ARCH" in
    x86_64|amd64)   ARCH="x86_64" ;;
    arm64|aarch64)  ARCH="arm64" ;;
    *)              error "Invalid architecture: $ARCH (use x86_64 or arm64)" ;;
esac

# ============================================================
# Set Architecture-Specific Variables
# ============================================================
if [[ "$ARCH" == "x86_64" ]]; then
    TARGET="firecracker-kernel-x86"
    KERNEL_FILE="vmlinux"
    KERNEL_PATH="/opt/runcvm/kernels/firecracker/x86_64/latest/vmlinux"
    CONFIG_FILE="$CONFIG_DIR/config-firecracker-x86_64"
    DEFAULT_OUTPUT="./vmlinux"
else
    TARGET="firecracker-kernel-arm64"
    KERNEL_FILE="Image"
    KERNEL_PATH="/opt/runcvm/kernels/firecracker/aarch64/latest/Image"
    CONFIG_FILE="$CONFIG_DIR/config-firecracker-aarch64"
    DEFAULT_OUTPUT="./Image"
fi

# Set output path
OUTPUT="${OUTPUT:-$DEFAULT_OUTPUT}"

# Docker image/container names
IMAGE_NAME="fc-kernel-${ARCH}:${KERNEL_VERSION}"
CONTAINER_NAME="fc-kernel-extract-$$"

# ============================================================
# Validation
# ============================================================
log "============================================================"
log "Firecracker Kernel Builder"
log "============================================================"
log "Architecture:    $ARCH"
log "Kernel Version:  $KERNEL_VERSION"
log "Alpine Version:  $ALPINE_VERSION"
log "Output File:     $OUTPUT"
log "Dockerfile:      $DOCKERFILE"
log "Config File:     $CONFIG_FILE"
log "Docker Target:   $TARGET"
log "============================================================"

# Check prerequisites
[[ -f "$DOCKERFILE" ]] || error "Dockerfile not found: $DOCKERFILE"
[[ -f "$CONFIG_FILE" ]] || error "Config file not found: $CONFIG_FILE"
command -v docker &>/dev/null || error "Docker not found"

# ============================================================
# Clean Previous Builds (optional)
# ============================================================
if [[ "$CLEAN_FIRST" == true ]]; then
    log "Cleaning previous builds..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker rmi -f "$IMAGE_NAME" 2>/dev/null || true
fi

# ============================================================
# Build Kernel
# ============================================================
log "Building kernel (this may take several minutes)..."

docker build \
    --build-arg KERNEL_VERSION="$KERNEL_VERSION" \
    --build-arg ALPINE_VERSION="$ALPINE_VERSION" \
    --target "$TARGET" \
    -t "$IMAGE_NAME" \
    -f "$DOCKERFILE" \
    .

log "Build complete!"

# ============================================================
# Extract Kernel
# ============================================================
log "Extracting kernel from Docker image..."

# Remove container if exists
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Create container
docker create --name "$CONTAINER_NAME" "$IMAGE_NAME" >/dev/null

# Copy kernel
docker cp "$CONTAINER_NAME:$KERNEL_PATH" "$OUTPUT"

# Copy config (optional)
CONFIG_OUTPUT="${OUTPUT%/*}/config-${KERNEL_VERSION}"
docker cp "$CONTAINER_NAME:${KERNEL_PATH%/*}/config" "$CONFIG_OUTPUT" 2>/dev/null || true

# Cleanup container
docker rm -f "$CONTAINER_NAME" >/dev/null

# Cleanup image (unless --keep)
if [[ "$KEEP_IMAGE" != true ]]; then
    log "Removing Docker image..."
    docker rmi -f "$IMAGE_NAME" >/dev/null 2>&1 || true
fi

# ============================================================
# Done
# ============================================================
echo ""
log "============================================================"
log "✓ Kernel built successfully!"
log "============================================================"
log "Output:  $OUTPUT"
log "Size:    $(du -h "$OUTPUT" | cut -f1)"
[[ -f "$CONFIG_OUTPUT" ]] && log "Config:  $CONFIG_OUTPUT"
log ""
log "To use with Firecracker:"
if [[ "$ARCH" == "x86_64" ]]; then
    log '  "kernel_image_path": "'$OUTPUT'",'
    log '  "boot_args": "console=ttyS0 reboot=k panic=1 root=/dev/vda rw"'
else
    log '  "kernel_image_path": "'$OUTPUT'",'
    log '  "boot_args": "keep_bootcon console=ttyAMA0 reboot=k panic=1 root=/dev/vda rw"'
fi
log "============================================================"