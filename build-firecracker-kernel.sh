#!/bin/bash
# ============================================================
# build-firecracker-kernel.sh
# ============================================================
# Build Firecracker kernels with 9P support for x86_64 and ARM64
#
# Usage:
#   ./build-firecracker-kernel.sh [OPTIONS]
#
# Options:
#   --arch ARCH       Target architecture: x86_64, arm64, or all (default: auto-detect)
#   --method METHOD   Build method: native, docker, cross (default: auto)
#   --kernel VERSION  Kernel version (default: 5.10.204)
#   --output DIR      Output directory (default: ./output)
#   --config DIR      Config directory containing config-firecracker-* files
#   --clean           Clean build (remove existing build artifacts)
#   --help            Show this help message
#
# Examples:
#   # Auto-detect and build for current architecture
#   ./build-firecracker-kernel.sh
#
#   # Build ARM64 kernel via cross-compilation
#   ./build-firecracker-kernel.sh --arch arm64 --method cross
#
#   # Build both architectures using Docker
#   ./build-firecracker-kernel.sh --arch all --method docker
#
#   # Build specific kernel version
#   ./build-firecracker-kernel.sh --kernel 5.15.0 --arch x86_64
# ============================================================

set -euo pipefail

# Default configuration
KERNEL_VERSION="${KERNEL_VERSION:-5.10.204}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
CONFIG_DIR="${CONFIG_DIR:-./kernels/firecracker}"
BUILD_METHOD="${BUILD_METHOD:-auto}"
TARGET_ARCH="${TARGET_ARCH:-auto}"
CLEAN_BUILD="${CLEAN_BUILD:-false}"
JOBS="${JOBS:-$(nproc)}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================
# Helper Functions
# ============================================================

log() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

header() {
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}============================================================${NC}"
}

detect_host_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            echo "x86_64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            error "Unsupported host architecture: $(uname -m)"
            ;;
    esac
}

check_dependencies_native() {
    local missing=()
    
    for cmd in make gcc flex bison bc perl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}
Install with:
  Ubuntu/Debian: sudo apt install build-essential flex bison bc libelf-dev libssl-dev libncurses-dev
  Alpine: apk add build-base flex bison bc elfutils-dev openssl-dev ncurses-dev perl"
    fi
}

check_dependencies_cross() {
    if ! command -v aarch64-linux-gnu-gcc &>/dev/null; then
        error "Cross-compiler not found: aarch64-linux-gnu-gcc
Install with:
  Ubuntu/Debian: sudo apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
  Fedora: sudo dnf install gcc-aarch64-linux-gnu"
    fi
}

check_dependencies_docker() {
    if ! command -v docker &>/dev/null; then
        error "Docker not found. Please install Docker first."
    fi
    
    if ! docker info &>/dev/null; then
        error "Docker daemon not running or insufficient permissions."
    fi
}

download_kernel() {
    local version="$1"
    local dest="$2"
    
    local major_version="${version%%.*}"
    local url="https://cdn.kernel.org/pub/linux/kernel/v${major_version}.x/linux-${version}.tar.xz"
    
    if [[ -d "$dest/linux-${version}" ]]; then
        log "Kernel source already exists at $dest/linux-${version}"
        return 0
    fi
    
    log "Downloading Linux kernel ${version}..."
    mkdir -p "$dest"
    curl -fsSL "$url" -o "$dest/linux-${version}.tar.xz"
    
    log "Extracting kernel source..."
    tar -xJf "$dest/linux-${version}.tar.xz" -C "$dest"
    rm "$dest/linux-${version}.tar.xz"
}

# ============================================================
# Build Methods
# ============================================================

build_native_x86_64() {
    header "Building x86_64 kernel (native)"
    
    check_dependencies_native
    
    local build_dir="/tmp/firecracker-kernel-build"
    download_kernel "$KERNEL_VERSION" "$build_dir"
    
    local src_dir="$build_dir/linux-${KERNEL_VERSION}"
    local config_file="$CONFIG_DIR/config-firecracker-x86_64"
    
    if [[ ! -f "$config_file" ]]; then
        error "Config file not found: $config_file"
    fi
    
    log "Copying kernel config..."
    cp "$config_file" "$src_dir/.config"
    
    log "Running olddefconfig..."
    make -C "$src_dir" olddefconfig
    
    log "Building kernel with $JOBS jobs..."
    make -C "$src_dir" -j"$JOBS" vmlinux
    
    log "Copying output..."
    mkdir -p "$OUTPUT_DIR/x86_64"
    cp "$src_dir/vmlinux" "$OUTPUT_DIR/x86_64/"
    cp "$src_dir/.config" "$OUTPUT_DIR/x86_64/config"
    
    log "✓ x86_64 kernel built: $OUTPUT_DIR/x86_64/vmlinux"
}

build_native_arm64() {
    header "Building ARM64 kernel (native)"
    
    check_dependencies_native
    
    local build_dir="/tmp/firecracker-kernel-build"
    download_kernel "$KERNEL_VERSION" "$build_dir"
    
    local src_dir="$build_dir/linux-${KERNEL_VERSION}"
    local config_file="$CONFIG_DIR/config-firecracker-aarch64"
    
    if [[ ! -f "$config_file" ]]; then
        error "Config file not found: $config_file"
    fi
    
    log "Copying kernel config..."
    cp "$config_file" "$src_dir/.config"
    
    log "Running olddefconfig..."
    make -C "$src_dir" ARCH=arm64 olddefconfig
    
    log "Building kernel with $JOBS jobs..."
    make -C "$src_dir" ARCH=arm64 -j"$JOBS" Image
    
    log "Copying output..."
    mkdir -p "$OUTPUT_DIR/aarch64"
    cp "$src_dir/arch/arm64/boot/Image" "$OUTPUT_DIR/aarch64/"
    cp "$src_dir/.config" "$OUTPUT_DIR/aarch64/config"
    
    log "✓ ARM64 kernel built: $OUTPUT_DIR/aarch64/Image"
}

build_cross_arm64() {
    header "Building ARM64 kernel (cross-compile from x86_64)"
    
    check_dependencies_native
    check_dependencies_cross
    
    local build_dir="/tmp/firecracker-kernel-build"
    download_kernel "$KERNEL_VERSION" "$build_dir"
    
    local src_dir="$build_dir/linux-${KERNEL_VERSION}"
    local config_file="$CONFIG_DIR/config-firecracker-aarch64"
    
    if [[ ! -f "$config_file" ]]; then
        error "Config file not found: $config_file"
    fi
    
    log "Copying kernel config..."
    cp "$config_file" "$src_dir/.config"
    
    log "Running olddefconfig..."
    make -C "$src_dir" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
    
    log "Cross-compiling kernel with $JOBS jobs..."
    make -C "$src_dir" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS" Image
    
    log "Copying output..."
    mkdir -p "$OUTPUT_DIR/aarch64"
    cp "$src_dir/arch/arm64/boot/Image" "$OUTPUT_DIR/aarch64/"
    cp "$src_dir/.config" "$OUTPUT_DIR/aarch64/config"
    
    log "✓ ARM64 kernel built: $OUTPUT_DIR/aarch64/Image"
}

build_docker_x86_64() {
    header "Building x86_64 kernel (Docker)"
    
    check_dependencies_docker
    
    local docker_out="$OUTPUT_DIR/docker-x86"
    rm -rf "$docker_out"
    
    log "Building Docker image for x86_64 kernel..."
    docker buildx build \
        --build-arg KERNEL_VERSION="$KERNEL_VERSION" \
        --target firecracker-kernel-x86 \
        --output "type=local,dest=$docker_out" \
        -f Dockerfile.firecracker-kernels \
        .
    
    log "Docker build complete. Locating kernel..."
    
    # Find the vmlinux file
    local vmlinux_file
    vmlinux_file=$(find "$docker_out" -name "vmlinux" -type f 2>/dev/null | head -1)
    
    if [[ -z "$vmlinux_file" ]]; then
        error "Kernel vmlinux not found in Docker output. Check $docker_out"
    fi
    
    local config_file
    config_file=$(find "$docker_out" -name "config" -type f 2>/dev/null | head -1)
    
    log "Found kernel at: $vmlinux_file"
    
    mkdir -p "$OUTPUT_DIR/x86_64"
    cp "$vmlinux_file" "$OUTPUT_DIR/x86_64/vmlinux"
    [[ -n "$config_file" ]] && cp "$config_file" "$OUTPUT_DIR/x86_64/config"
    
    # Cleanup docker output
    rm -rf "$docker_out"
    
    log "✓ x86_64 kernel built: $OUTPUT_DIR/x86_64/vmlinux"
    ls -lh "$OUTPUT_DIR/x86_64/vmlinux"
}

build_docker_arm64() {
    header "Building ARM64 kernel (Docker cross-compile)"
    
    check_dependencies_docker
    
    local docker_out="$OUTPUT_DIR/docker-arm64"
    rm -rf "$docker_out"
    
    log "Building Docker image for ARM64 kernel (cross-compile)..."
    docker buildx build \
        --build-arg KERNEL_VERSION="$KERNEL_VERSION" \
        --target firecracker-kernel-arm64-cross \
        --output "type=local,dest=$docker_out" \
        -f Dockerfile.firecracker-kernels \
        .
    
    log "Docker build complete. Locating kernel..."
    
    # Find the Image file (path varies based on Docker output structure)
    local image_file
    image_file=$(find "$docker_out" -name "Image" -type f 2>/dev/null | head -1)
    
    if [[ -z "$image_file" ]]; then
        error "Kernel Image not found in Docker output. Check $docker_out"
    fi
    
    local config_file
    config_file=$(find "$docker_out" -name "config" -type f 2>/dev/null | head -1)
    
    log "Found kernel at: $image_file"
    
    mkdir -p "$OUTPUT_DIR/aarch64"
    cp "$image_file" "$OUTPUT_DIR/aarch64/Image"
    [[ -n "$config_file" ]] && cp "$config_file" "$OUTPUT_DIR/aarch64/config"
    
    # Cleanup docker output
    rm -rf "$docker_out"
    
    log "✓ ARM64 kernel built: $OUTPUT_DIR/aarch64/Image"
    ls -lh "$OUTPUT_DIR/aarch64/Image"
}

build_docker_arm64_native() {
    header "Building ARM64 kernel (Docker native on ARM64)"
    
    check_dependencies_docker
    
    local docker_out="$OUTPUT_DIR/docker-arm64"
    rm -rf "$docker_out"
    
    log "Building Docker image for ARM64 kernel (native)..."
    docker buildx build \
        --platform linux/arm64 \
        --build-arg KERNEL_VERSION="$KERNEL_VERSION" \
        --target firecracker-kernel-arm64 \
        --output "type=local,dest=$docker_out" \
        -f Dockerfile.firecracker-kernels \
        .
    
    log "Docker build complete. Locating kernel..."
    
    # Find the Image file (path varies based on Docker output structure)
    local image_file
    image_file=$(find "$docker_out" -name "Image" -type f 2>/dev/null | head -1)
    
    if [[ -z "$image_file" ]]; then
        error "Kernel Image not found in Docker output. Check $docker_out"
    fi
    
    local config_file
    config_file=$(find "$docker_out" -name "config" -type f 2>/dev/null | head -1)
    
    log "Found kernel at: $image_file"
    
    mkdir -p "$OUTPUT_DIR/aarch64"
    cp "$image_file" "$OUTPUT_DIR/aarch64/Image"
    [[ -n "$config_file" ]] && cp "$config_file" "$OUTPUT_DIR/aarch64/config"
    
    # Cleanup docker output
    rm -rf "$docker_out"
    
    log "✓ ARM64 kernel built: $OUTPUT_DIR/aarch64/Image"
    ls -lh "$OUTPUT_DIR/aarch64/Image"
}

# ============================================================
# Main Logic
# ============================================================

show_help() {
    head -50 "$0" | grep -E "^#" | sed 's/^# //' | sed 's/^#//'
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --arch)
                TARGET_ARCH="$2"
                shift 2
                ;;
            --method)
                BUILD_METHOD="$2"
                shift 2
                ;;
            --kernel)
                KERNEL_VERSION="$2"
                shift 2
                ;;
            --output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --config)
                CONFIG_DIR="$2"
                shift 2
                ;;
            --clean)
                CLEAN_BUILD="true"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    
    header "Firecracker Kernel Builder"
    log "Kernel version: $KERNEL_VERSION"
    log "Output directory: $OUTPUT_DIR"
    log "Config directory: $CONFIG_DIR"
    
    # Auto-detect architecture if needed
    if [[ "$TARGET_ARCH" == "auto" ]]; then
        TARGET_ARCH="$(detect_host_arch)"
        log "Auto-detected target architecture: $TARGET_ARCH"
    fi
    
    # Auto-detect build method if needed
    if [[ "$BUILD_METHOD" == "auto" ]]; then
        if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
            BUILD_METHOD="docker"
        else
            BUILD_METHOD="native"
        fi
        log "Auto-detected build method: $BUILD_METHOD"
    fi
    
    # Clean build directory if requested
    if [[ "$CLEAN_BUILD" == "true" ]]; then
        log "Cleaning build artifacts..."
        rm -rf /tmp/firecracker-kernel-build
        rm -rf "$OUTPUT_DIR"
    fi
    
    mkdir -p "$OUTPUT_DIR"
    
    # Execute build based on architecture and method
    case "$TARGET_ARCH" in
        x86_64|amd64)
            case "$BUILD_METHOD" in
                native)
                    build_native_x86_64
                    ;;
                docker)
                    build_docker_x86_64
                    ;;
                *)
                    error "Invalid build method for x86_64: $BUILD_METHOD"
                    ;;
            esac
            ;;
        arm64|aarch64)
            HOST_ARCH="$(detect_host_arch)"
            case "$BUILD_METHOD" in
                native)
                    if [[ "$HOST_ARCH" == "arm64" ]]; then
                        build_native_arm64
                    else
                        error "Native ARM64 build requires ARM64 host. Use --method cross or --method docker"
                    fi
                    ;;
                cross)
                    if [[ "$HOST_ARCH" == "x86_64" ]]; then
                        build_cross_arm64
                    else
                        error "Cross-compilation is only supported from x86_64 host"
                    fi
                    ;;
                docker)
                    if [[ "$HOST_ARCH" == "arm64" ]]; then
                        build_docker_arm64_native
                    else
                        build_docker_arm64
                    fi
                    ;;
                *)
                    error "Invalid build method for ARM64: $BUILD_METHOD"
                    ;;
            esac
            ;;
        all)
            log "Building kernels for all architectures..."
            HOST_ARCH="$(detect_host_arch)"
            
            case "$BUILD_METHOD" in
                docker)
                    build_docker_x86_64
                    build_docker_arm64
                    ;;
                native|cross)
                    if [[ "$HOST_ARCH" == "x86_64" ]]; then
                        build_native_x86_64
                        build_cross_arm64
                    elif [[ "$HOST_ARCH" == "arm64" ]]; then
                        build_native_arm64
                        warn "Cannot build x86_64 kernel from ARM64 host without Docker"
                    fi
                    ;;
                *)
                    error "Invalid build method: $BUILD_METHOD"
                    ;;
            esac
            ;;
        *)
            error "Invalid target architecture: $TARGET_ARCH"
            ;;
    esac
    
    header "Build Complete!"
    log "Output files:"
    find "$OUTPUT_DIR" -type f -name "vmlinux" -o -name "Image" | while read -r f; do
        echo "  - $f ($(du -h "$f" | cut -f1))"
    done
}

main "$@"