# syntax=docker/dockerfile:1.3-labs

# Alpine version to build with
ARG ALPINE_VERSION=3.19
ARG FIRECRACKER_VERSION=1.13.1
ARG FIRECRACKER_KERNEL_VERSION=6.6.50

# --- BUILD STAGE ---
# Build base alpine-sdk image for later build stages
FROM alpine:$ALPINE_VERSION as alpine-sdk

RUN apk update && apk add --no-cache alpine-sdk coreutils && \
    abuild-keygen -an && \
    # Copy the public keys to the system keys
    cp -a /root/.abuild/*.pub /etc/apk/keys && \
    git clone --depth 1 --single-branch --filter=blob:none --sparse https://gitlab.alpinelinux.org/alpine/aports.git ~/aports && \
    cd ~/aports/ && \
    git sparse-checkout set main/dnsmasq main/dropbear main/mkinitfs main/

# NOTE: SeaBIOS is x86-specific and not needed for ARM64
# ARM64 uses UEFI boot via QEMU's built-in firmware or EDK2

# --- BUILD STAGE ---
# Build patched dnsmasq
# that does not require /etc/passwd file to run
# (needed for images such as hello-world)
FROM alpine-sdk as alpine-dnsmasq

ADD patches/dnsmasq/remove-passwd-requirement.patch /root/aports/main/dnsmasq/remove-passwd-requirement.patch

RUN <<EOF
set -e
cd /root/aports/main/dnsmasq
echo 'sha512sums="${sha512sums}$(sha512sum remove-passwd-requirement.patch)"' >>APKBUILD
echo 'source="${source}remove-passwd-requirement.patch"' >>APKBUILD
abuild -rFf
EOF

# --- BUILD STAGE ---
# Build patched dropbear with epka plugin
# that does not require /etc/passwd or PAM to run
FROM alpine-sdk as alpine-dropbear

ADD patches/dropbear/runcvm.patch /root/aports/main/dropbear/runcvm.patch

RUN <<EOF
set -e
cd /root/aports/main/dropbear
sed -ri '/--disable-pututline/a --enable-plugin \\' APKBUILD
echo 'sha512sums="${sha512sums}$(sha512sum runcvm.patch)"' >>APKBUILD
echo 'source="${source}runcvm.patch"' >>APKBUILD
abuild -rFf

cd /root
git clone https://github.com/fabriziobertocci/dropbear-epka.git
cd dropbear-epka
apk add --no-cache automake autoconf libtool
libtoolize --force
aclocal
autoheader || true
automake --force-missing --add-missing
autoconf
./configure
make install
EOF

# --- BUILD STAGE ---
# Build patched mkinitfs/nlplug-findfs
# with shorter timeout for speedier boot (saving ~4s)
FROM alpine-sdk as alpine-mkinitfs

ADD patches/mkinitfs/nlplug-findfs.patch /root/aports/main/mkinitfs/nlplug-findfs.patch

RUN <<EOF
set -e
cd /root/aports/main/mkinitfs
echo 'sha512sums="${sha512sums}$(sha512sum nlplug-findfs.patch)"' >>APKBUILD
echo 'source="${source} nlplug-findfs.patch"' >>APKBUILD
abuild -rFf
EOF

# --- BUILD STAGE ---
# Build dist-independent dynamic binaries and libraries for ARM64
FROM alpine:$ALPINE_VERSION as binaries

RUN apk update && \
    apk add --no-cache file bash \
    qemu-system-aarch64 \
    qemu-virtiofsd \
    qemu-ui-curses \
    qemu-guest-agent \
    qemu-hw-display-virtio-gpu \
    aavmf \
    jq iproute2 netcat-openbsd e2fsprogs blkid util-linux \
    s6 dnsmasq iptables nftables \
    ncurses coreutils \
    patchelf

# Install patched dnsmasq
COPY --from=alpine-dnsmasq /root/packages/main/aarch64 /tmp/dnsmasq/
RUN apk add --allow-untrusted /tmp/dnsmasq/dnsmasq-2*.apk /tmp/dnsmasq/dnsmasq-common*.apk

# Install patched dropbear
COPY --from=alpine-dropbear /root/packages/main/aarch64 /usr/local/lib/libepka_file.so /tmp/dropbear/
RUN apk add --allow-untrusted /tmp/dropbear/dropbear-ssh*.apk /tmp/dropbear/dropbear-dbclient*.apk /tmp/dropbear/dropbear-2*.apk

# Patch the binaries and set up symlinks
COPY build-utils/make-bundelf-bundle.sh /usr/local/bin/make-bundelf-bundle.sh

# Changed from qemu-system-x86_64 to qemu-system-aarch64
ENV BUNDELF_BINARIES="busybox bash jq ip nc mke2fs blkid findmnt dnsmasq xtables-legacy-multi nft xtables-nft-multi nft mount s6-applyuidgid qemu-system-aarch64 qemu-ga /usr/lib/qemu/virtiofsd tput coreutils getent dropbear dbclient dropbearkey"
ENV BUNDELF_EXTRA_LIBS="/usr/lib/xtables /usr/libexec/coreutils /tmp/dropbear/libepka_file.so /usr/lib/qemu/*.so"
ENV BUNDELF_EXTRA_SYSTEM_LIB_PATHS="/usr/lib/xtables"
ENV BUNDELF_CODE_PATH="/opt/runcvm"
ENV BUNDELF_EXEC_PATH="/.runcvm/guest"

RUN /usr/local/bin/make-bundelf-bundle.sh --bundle && \
    mkdir -p $BUNDELF_CODE_PATH/bin && \
    cd $BUNDELF_CODE_PATH/bin && \
    for cmd in \
    uname mkdir rmdir cp mv free ip awk base64 cat chgrp chmod cut grep head hostname init ln ls \
    mkdir poweroff ps rm rmdir route sh sysctl tr touch; \
    do \
    ln -s busybox $cmd; \
    done && \
    mkdir -p $BUNDELF_CODE_PATH/usr/share && \
    cp -a /usr/share/qemu $BUNDELF_CODE_PATH/usr/share && \
    cp -a /etc/terminfo $BUNDELF_CODE_PATH/usr/share && \
    # Copy AAVMF UEFI firmware for ARM64
    mkdir -p $BUNDELF_CODE_PATH/usr/share/AAVMF && \
    cp -a /usr/share/AAVMF/* $BUNDELF_CODE_PATH/usr/share/AAVMF/ && \
    # Remove setuid/setgid bits from any/all binaries
    chmod -R -s $BUNDELF_CODE_PATH/

# --- BUILD STAGE ---
# Build static runcvm-init
FROM alpine:$ALPINE_VERSION as runcvm-init

RUN apk update && \
    apk add --no-cache gcc musl-dev

ADD runcvm-init /root/runcvm-init
RUN cd /root/runcvm-init && cc -o /root/runcvm-init/runcvm-init -std=gnu99 -static -s -Wall -Werror -O3 dumb-init.c

# --- BUILD STAGE ---
# Build static qemu-exit for ARM64
# Note: ARM64 uses PSCI for power control, not x86 I/O ports
FROM alpine:$ALPINE_VERSION as qemu-exit

RUN apk update && \
    apk add --no-cache gcc musl-dev linux-headers

ADD qemu-exit /root/qemu-exit
RUN cd /root/qemu-exit && cc -o /root/qemu-exit/qemu-exit -std=gnu99 -static -s -Wall -Werror -O3 qemu-exit.c

# --- BUILD STAGE ---
# Build alpine kernel and initramfs with virtiofs module for ARM64
FROM alpine:$ALPINE_VERSION as alpine-kernel

RUN apk update && apk add --no-cache linux-lts linux-firmware-none mkinitfs

# Install patched mkinitfs
COPY --from=alpine-mkinitfs /root/packages/main/aarch64 /tmp/mkinitfs/
RUN apk add --allow-untrusted /tmp/mkinitfs/mkinitfs*.apk

# Add virtiofs to initramfs features
RUN echo 'features="ata base cdrom ext4 keymap kms mmc nvme raid scsi usb virtio virtiofs"' > /etc/mkinitfs/mkinitfs.conf && \
    mkinitfs -o /tmp/initramfs $(ls /lib/modules/)

RUN BASENAME=$(basename $(ls -d /lib/modules/*)) && \
    mkdir -p /opt/runcvm/kernels/alpine/$BASENAME && \
    cp -aL /boot/vmlinuz-lts /opt/runcvm/kernels/alpine/$BASENAME/vmlinuz && \
    cp -aL /tmp/initramfs /opt/runcvm/kernels/alpine/$BASENAME/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/alpine/$BASENAME/ && \
    cp -a /boot/config-lts /opt/runcvm/kernels/alpine/$BASENAME/modules/$BASENAME/config && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/alpine

# --- BUILD STAGE ---
# Build Debian bookworm kernel and initramfs with virtiofs module for ARM64
FROM debian:bookworm as debian-kernel

ARG DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install -y linux-image-arm64 && \
    echo 'virtiofs' >>/etc/initramfs-tools/modules && \
    echo 'virtio_console' >>/etc/initramfs-tools/modules && \
    echo "RESUME=none" >/etc/initramfs-tools/conf.d/resume && \
    update-initramfs -u
RUN BASENAME=$(basename $(ls -d /lib/modules/*)) && \
    mkdir -p /opt/runcvm/kernels/debian/$BASENAME && \
    cp -aL /vmlinuz /opt/runcvm/kernels/debian/$BASENAME/vmlinuz && \
    cp -aL /initrd.img /opt/runcvm/kernels/debian/$BASENAME/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/debian/$BASENAME/ && \
    cp -a /boot/config-$BASENAME /opt/runcvm/kernels/debian/$BASENAME/modules/$BASENAME/config && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/debian

# --- BUILD STAGE ---
# Build Ubuntu kernel and initramfs with virtiofs module for ARM64
FROM ubuntu:jammy as ubuntu-kernel

ARG DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install -y linux-generic && \
    echo 'virtiofs' >>/etc/initramfs-tools/modules && \
    echo 'virtio_console' >>/etc/initramfs-tools/modules && \
    echo "RESUME=none" >/etc/initramfs-tools/conf.d/resume && \
    update-initramfs -u
RUN BASENAME=$(basename $(ls -d /lib/modules/*)) && \
    mkdir -p /opt/runcvm/kernels/ubuntu/$BASENAME && \
    cp -aL /boot/vmlinuz /opt/runcvm/kernels/ubuntu/$BASENAME/vmlinuz && \
    cp -aL /boot/initrd.img /opt/runcvm/kernels/ubuntu/$BASENAME/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/ubuntu/$BASENAME/ && \
    cp -a /boot/config-$BASENAME /opt/runcvm/kernels/ubuntu/$BASENAME/modules/$BASENAME/config && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/ubuntu

# --- BUILD STAGE ---
# Download Firecracker-compatible kernel (uncompressed vmlinux format)
# FROM alpine:3.19 as firecracker-kernel

# RUN apk add --no-cache curl

# RUN ARCH=$(uname -m) && \
#     echo "Downloading Firecracker kernel for $ARCH..." && \
#     mkdir -p /opt/firecracker-kernel && \
#     if [ "$ARCH" = "aarch64" ]; then \
#       curl -fsSL -o /opt/firecracker-kernel/vmlinux \
#         "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.5/aarch64/vmlinux-5.10.186" ; \
#     elif [ "$ARCH" = "x86_64" ]; then \
#       curl -fsSL -o /opt/firecracker-kernel/vmlinux \
#         "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.5/x86_64/vmlinux-5.10.186" ; \
#     fi && \
#     ls -la /opt/firecracker-kernel/vmlinux && \
#     echo "Kernel download complete"

# --- BUILD STAGE ---
# Build Firecracker kernel with 9P support (auto-detect architecture)
FROM alpine:$ALPINE_VERSION as firecracker-kernel-build

ARG FIRECRACKER_KERNEL_VERSION

RUN apk add --no-cache \
    build-base bc flex bison perl \
    linux-headers elfutils-dev openssl-dev ncurses-dev \
    xz curl bash diffutils findutils kmod

RUN echo "$(uname -m)" > /tmp/build-arch

WORKDIR /build
RUN MAJOR_VERSION=$(echo $FIRECRACKER_KERNEL_VERSION | cut -d. -f1) && \
    curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR_VERSION}.x/linux-${FIRECRACKER_KERNEL_VERSION}.tar.xz" \
    -o linux.tar.xz && \
    tar -xJf linux.tar.xz && \
    rm linux.tar.xz && \
    mv linux-${FIRECRACKER_KERNEL_VERSION} linux

COPY kernels/firecracker/config-firecracker-x86_64 /build/config-x86_64
COPY kernels/firecracker/config-firecracker-aarch64 /build/config-aarch64

RUN ARCH=$(cat /tmp/build-arch) && \
    if [ "$ARCH" = "x86_64" ]; then \
    cp /build/config-x86_64 /build/linux/.config; \
    elif [ "$ARCH" = "aarch64" ]; then \
    cp /build/config-aarch64 /build/linux/.config; \
    fi

WORKDIR /build/linux
RUN ARCH=$(cat /tmp/build-arch) && \
    if [ "$ARCH" = "x86_64" ]; then \
    make olddefconfig && \
    make -j$(nproc) vmlinux && \
    mkdir -p /opt/runcvm/kernels/firecracker/${FIRECRACKER_KERNEL_VERSION} && \
    cp vmlinux /opt/runcvm/kernels/firecracker/ && \
    cp .config /opt/runcvm/kernels/firecracker/config; \
    elif [ "$ARCH" = "aarch64" ]; then \
    make ARCH=arm64 olddefconfig && \
    make ARCH=arm64 -j$(nproc) Image modules && \
    mkdir -p /opt/runcvm/kernels/firecracker/${FIRECRACKER_KERNEL_VERSION} && \
    mkdir -p /opt/runcvm/kernels/firecracker/modules && \
    make ARCH=arm64 INSTALL_MOD_PATH=/opt/runcvm/kernels/firecracker/modules modules_install && \
    cp arch/arm64/boot/Image /opt/runcvm/kernels/firecracker/vmlinux && \
    cp .config /opt/runcvm/kernels/firecracker/config; \
    fi && \
    ls -alh /opt/runcvm/kernels/firecracker/vmlinux && \
    echo "=== Checking if modules were built ===" && \
    if [ -d /opt/runcvm/kernels/firecracker/modules ]; then \
    echo "Modules directory exists:"; \
    ls -la /opt/runcvm/kernels/firecracker/modules/lib/modules/; \
    else \
    echo "WARNING: Modules directory not created!"; \
    fi

# Add this to your Dockerfile BEFORE the "installer" stage
# This downloads and extracts the Firecracker binary for ARM64

# -- BUILD STAGE ---
# Add DIOD bundled
FROM alpine:3.19 as diod-builder

# Install ALL required build dependencies
RUN apk add --no-cache \
    build-base autoconf automake libtool git \
    linux-headers libcap-dev libcap-static musl-dev \
    lua5.3-dev ncurses-dev ncurses-static

# Clone and build diod
RUN git clone https://github.com/chaos/diod.git -b v1.1.0 && \
    cd diod && \
    ./autogen.sh && \
    LDFLAGS="-static" ./configure --prefix=/usr \
    --disable-diodmount \
    --disable-auth \
    --disable-config \
    CFLAGS="-static" \
    LDFLAGS="-static" && \
    make CFLAGS="-static" LDFLAGS="-static" && \
    make DESTDIR=/diod-install install

# --- BUILD STAGE ---
# Download Firecracker binary
FROM alpine:3.19 as firecracker-bin

RUN apk add --no-cache curl tar gzip

# Firecracker version
ARG FIRECRACKER_VERSION=v1.13.1

# Detect architecture and download appropriate binary
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
    FC_ARCH="aarch64"; \
    elif [ "$ARCH" = "x86_64" ]; then \
    FC_ARCH="x86_64"; \
    else \
    echo "Unsupported architecture: $ARCH"; exit 1; \
    fi && \
    echo "Downloading Firecracker ${FIRECRACKER_VERSION} for ${FC_ARCH}..." && \
    curl -L -o /tmp/firecracker.tgz \
    "https://github.com/firecracker-microvm/firecracker/releases/download/${FIRECRACKER_VERSION}/firecracker-${FIRECRACKER_VERSION}-${FC_ARCH}.tgz" && \
    cd /tmp && \
    tar -xzf firecracker.tgz && \
    mv release-${FIRECRACKER_VERSION}-${FC_ARCH}/firecracker-${FIRECRACKER_VERSION}-${FC_ARCH} /usr/local/bin/firecracker && \
    chmod +x /usr/local/bin/firecracker && \
    rm -rf /tmp/firecracker.tgz /tmp/release-*

# ============================================================
# Then in your "installer" stage, add this line after the other COPY commands:
# ============================================================
# COPY --from=firecracker-bin /usr/local/bin/firecracker /opt/runcvm/bin/firecracker

# --- BUILD STAGE ---
# Build RunCVM installer
FROM alpine:$ALPINE_VERSION as installer

COPY --from=binaries /opt/runcvm /opt/runcvm
COPY --from=runcvm-init /root/runcvm-init/runcvm-init /opt/runcvm/sbin/
COPY --from=qemu-exit /root/qemu-exit/qemu-exit /opt/runcvm/sbin/
COPY --from=firecracker-bin /usr/local/bin/firecracker /opt/runcvm/sbin/
# Use Alpine kernel for Firecracker (has working 9P vsock support)
COPY --from=alpine-kernel /opt/runcvm/kernels/alpine /opt/runcvm/kernels/firecracker
COPY --from=diod-builder /diod-install/usr/sbin/diod /opt/runcvm/bin/diod

RUN apk update && apk add --no-cache rsync

ADD runcvm-scripts /opt/runcvm/scripts/

ADD build-utils/entrypoint-install.sh /
ENTRYPOINT ["/entrypoint-install.sh"]

# Install needed kernels.
# Comment out any kernels that are unneeded.
COPY --from=alpine-kernel /opt/runcvm/kernels/alpine /opt/runcvm/kernels/alpine
COPY --from=debian-kernel /opt/runcvm/kernels/debian /opt/runcvm/kernels/debian
# COPY --from=ubuntu-kernel /opt/runcvm/kernels/ubuntu /opt/runcvm/kernels/ubuntu

# Add 'latest' symlinks for available kernels
RUN for d in /opt/runcvm/kernels/*; do \
    cd "$d" && \
    tgt="$(ls -d */ 2>/dev/null | sed 's:/$::' | grep -v '^latest$' | sort -Vr | head -n 1)"; \
    [ -n "$tgt" ] && ln -sfn "$tgt" latest; \
    done