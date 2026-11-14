# syntax=docker/dockerfile:1.3-labs

# Alpine version to build RunCVM's own binaries and libraries with
ARG ALPINE_VERSION=3.24

# BuildKit predefines the platform args (TARGETARCH, TARGETPLATFORM) in the
# global scope, so the FROM lines below use them without an ARG declaration
# here. They are not visible inside a stage unless declared there: each stage
# that needs $TARGETARCH in a RUN declares ARG TARGETARCH after its own FROM
# (see the "binaries" stage). Giving either a default here would override the
# predefined value.

# Alpine version whose kernel (linux-virt) RunCVM bundles as its Alpine and OpenWrt kernels, with
# an initramfs built by that version's (patched) mkinitfs. It may differ from ALPINE_VERSION, but
# the kernel's modules must stay loadable by ALPINE_VERSION's busybox modprobe, which
# runcvm-vm-init uses.
ARG ALPINE_KERNEL_VERSION=3.24

# Compression of the Debian, Ubuntu, AlmaLinux, Fedora and openSUSE kernels' modules: 'xz' (the
# default), which busybox modprobe (used by runcvm-vm-init) and the kmod of Debian 10 (Buster),
# Ubuntu 20.04 LTS (Focal Fossa), the RHEL family's releases 7 and later, and current Fedora and
# openSUSE releases read; or 'none', for images whose own modprobe reads only uncompressed
# modules, such as Debian 9 (Stretch) and Ubuntu 18.04 LTS (Bionic Beaver). The Alpine and
# OpenWrt kernels' modules are unaffected.
ARG KERNEL_MODULE_COMPRESSION=xz

# Where the Alpine build stages fetch aports (Alpine's package build recipes) from, and, if set,
# the base URL of an Alpine distfiles mirror (with a v<version> directory per Alpine version) from
# which abuild fetches the packages' sources before trying their upstream URLs. The defaults are
# Alpine's own; CI on GitHub-hosted runners, which gitlab.alpinelinux.org refuses, uses
# https://github.com/alpinelinux/aports.git and https://distfiles.alpinelinux.org/distfiles.
ARG APORTS_URL=https://gitlab.alpinelinux.org/alpine/aports.git
ARG ALPINE_DISTFILES_MIRROR=

# --- BUILD STAGE ---
# Build base alpine-sdk image for later build stages
FROM alpine:$ALPINE_VERSION as alpine-sdk

# Redeclare so these are visible inside this stage's RUN
ARG ALPINE_VERSION
ARG APORTS_URL
ARG ALPINE_DISTFILES_MIRROR

# aports must be checked out at the stable branch matching the base image:
# APKBUILDs on master can depend on abuild features that the base release
# lacks (e.g. dropbear's nftrules subpackage).
RUN apk update && apk add --no-cache alpine-sdk coreutils && \
    abuild-keygen -an && \
    # Copy the public keys to the system keys
    cp -a /root/.abuild/*.pub /etc/apk/keys && \
    { [ -z "$ALPINE_DISTFILES_MIRROR" ] || \
      echo "DISTFILES_MIRROR=$ALPINE_DISTFILES_MIRROR/v${ALPINE_VERSION}" >>/etc/abuild.conf; } && \
    git clone --depth 1 --single-branch --filter=blob:none --sparse \
      --branch ${ALPINE_VERSION}-stable \
      "$APORTS_URL" ~/aports && \
    cd ~/aports/ && \
    git sparse-checkout set main/seabios main/dnsmasq main/dropbear community/virtiofsd

# --- BUILD STAGE ---
# Build base alpine-sdk image, at ALPINE_KERNEL_VERSION, for the patched mkinitfs's build stage
FROM alpine:$ALPINE_KERNEL_VERSION as alpine-sdk-kernel

ARG ALPINE_KERNEL_VERSION
ARG APORTS_URL
ARG ALPINE_DISTFILES_MIRROR

RUN apk update && apk add --no-cache alpine-sdk coreutils && \
    abuild-keygen -an && \
    cp -a /root/.abuild/*.pub /etc/apk/keys && \
    { [ -z "$ALPINE_DISTFILES_MIRROR" ] || \
      echo "DISTFILES_MIRROR=$ALPINE_DISTFILES_MIRROR/v${ALPINE_KERNEL_VERSION}" >>/etc/abuild.conf; } && \
    git clone --depth 1 --single-branch --filter=blob:none --sparse \
      --branch ${ALPINE_KERNEL_VERSION}-stable \
      "$APORTS_URL" ~/aports && \
    cd ~/aports/ && \
    git sparse-checkout set main/mkinitfs

# --- BUILD STAGE ---
# Build patched SeaBIOS packages (x86_64 only: SeaBIOS uses the ISA bus, which ARM64 lacks)
# to allow disabling of BIOS output by QEMU
# (without triggering QEMU warnings)
FROM alpine-sdk as alpine-seabios-amd64

ADD patches/seabios/qemu-fw-cfg-fix.patch /root/aports/main/seabios/0003-qemu-fw-cfg-fix.patch

RUN <<EOF
set -e
cd /root/aports/main/seabios
echo 'sha512sums="${sha512sums}$(sha512sum 0003-qemu-fw-cfg-fix.patch)"' >>APKBUILD
echo 'source="${source}0003-qemu-fw-cfg-fix.patch"' >>APKBUILD
abuild -rFf
EOF

# arm64 no-op: empty packages dir so COPY --from=alpine-seabios is always valid
FROM alpine:$ALPINE_VERSION as alpine-seabios-arm64
RUN mkdir -p /root/packages/main

# Select the correct SeaBIOS stage for the target platform
FROM alpine-seabios-${TARGETARCH} as alpine-seabios

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
# Build patched virtiofsd, which can apply a different cache policy to the mounts within its
# shared directory (--submount-cache, --cache-path; see RUNCVM_VIRTIOFSD_SUBMOUNT_CACHE): Alpine's
# own package, built with patches/virtiofsd/*.patch, a series against the virtiofsd version that
# Alpine ships, to be dropped once a virtiofsd release includes it.
FROM alpine-sdk as alpine-virtiofsd

ADD patches/virtiofsd/ /root/aports/community/virtiofsd/

RUN <<EOF
set -e
cd /root/aports/community/virtiofsd
# Add the patches, in order, to the package's sources and checksums, which default_prepare applies.
printf 'sha512sums="${sha512sums}%s\n"\n' "$(sha512sum *.patch)" >>APKBUILD
printf 'source="${source} %s"\n' "$(echo *.patch)" >>APKBUILD
abuild -rFf
EOF

# --- BUILD STAGE ---
# Build patched dropbear with epka plugin, which accepts only the plugin's keys
# and runs commands with RunCVM's bash, without reading the image's /etc/passwd,
# /etc/shadow, /etc/shells or authorized_keys
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
# with a shorter maximum device-event timeout than upstream (1s, not 5s), for faster boot
FROM alpine-sdk-kernel as alpine-mkinitfs

ADD patches/mkinitfs/nlplug-findfs.patch /root/aports/main/mkinitfs/nlplug-findfs.patch

RUN <<EOF
set -e
cd /root/aports/main/mkinitfs
echo 'sha512sums="${sha512sums}$(sha512sum nlplug-findfs.patch)"' >>APKBUILD
echo 'source="${source} nlplug-findfs.patch"' >>APKBUILD
# Skip mkinitfs's own test suite, which Alpine runs in its own CI: some of its cases have
# 5-second time limits, which a loaded build host (e.g. a CI runner building every stage at once)
# can exceed, failing the build.
echo 'options="$options !check"' >>APKBUILD
abuild -rFf
EOF

# --- BUILD STAGE ---
# Build patched mke2fs from upstream e2fsprogs
# that can populate subdirectories of a file system from several directories
# (repeated '-P SUBDIR=SRC'), excluding paths ('-x PATTERN') and other file systems
# ('-E one_file_system')
FROM alpine:$ALPINE_VERSION as e2fsprogs

ARG E2FSPROGS_VERSION=1.47.4
ARG E2FSPROGS_SHA256=fd5bf388cbdbe006a3d3b318d983b2948382440acc85a87f1e7d108653e8db0b

ADD patches/e2fsprogs/mke2fs-populate.patch /root/mke2fs-populate.patch

RUN <<EOF
set -e
apk add --no-cache build-base linux-headers util-linux-dev
cd /root
wget -q https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$E2FSPROGS_VERSION/e2fsprogs-$E2FSPROGS_VERSION.tar.xz
echo "$E2FSPROGS_SHA256  e2fsprogs-$E2FSPROGS_VERSION.tar.xz" | sha256sum -c -
tar xf e2fsprogs-$E2FSPROGS_VERSION.tar.xz
cd e2fsprogs-$E2FSPROGS_VERSION
patch -p1 </root/mke2fs-populate.patch
# Link util-linux's libblkid and libuuid, as Alpine's e2fsprogs package does;
# e2fsprogs' own libraries are linked statically
./configure --disable-nls --disable-libblkid --disable-libuuid --disable-uuidd --disable-fsck --disable-e2initrd-helper
make -j$(nproc) libs
make -j$(nproc) -C misc mke2fs
install -D -m 755 misc/mke2fs /usr/local/sbin/mke2fs
EOF

# --- BUILD STAGE ---
# Build dist-independent dynamic binaries and libraries
FROM alpine:$ALPINE_VERSION as binaries
ARG TARGETARCH

RUN apk update && \
    QEMU_SYSTEM=$([ "$TARGETARCH" = "arm64" ] && echo qemu-system-aarch64 || echo qemu-system-x86_64) && \
    UEFI_PKG=$([ "$TARGETARCH" = "arm64" ] && echo aavmf || echo ovmf) && \
    # arm64's virt machine has no VGA, so its virtio display is virtio-gpu-pci
    DISPLAY_PKG=$([ "$TARGETARCH" = "arm64" ] && echo qemu-hw-display-virtio-gpu-pci || echo qemu-hw-display-virtio-vga) && \
    apk add --no-cache file bash $QEMU_SYSTEM virtiofsd qemu-ui-curses qemu-guest-agent \
        $DISPLAY_PKG \
        $UEFI_PKG \
        jq iproute2 netcat-openbsd blkid util-linux \
        s6 dnsmasq nftables \
        ncurses coreutils \
        patchelf

# Install the packages of each filesystem that disks in RUNCVM_DISKS may have
ADD runcvm-etc/disk-filesystems /tmp/disk-filesystems
RUN packages=$(awk '$1 !~ /^#/ && NF && $3 != "-" { gsub(",", " ", $3); print $3 }' /tmp/disk-filesystems) && \
    if [ -n "$packages" ]; then apk add --no-cache $packages; fi

# Install patched SeaBIOS (x86_64 only: SeaBIOS is x86-specific)
COPY --from=alpine-seabios /root/packages/main /tmp/seabios-pkgs/
RUN ALPINE_ARCH=$(uname -m) && \
    if [ "$ALPINE_ARCH" = "x86_64" ]; then \
      apk add --allow-untrusted /tmp/seabios-pkgs/$ALPINE_ARCH/*.apk && \
      cp -a /usr/share/seabios/bios*.bin /usr/share/qemu/; \
    fi

# Install patched dnsmasq
COPY --from=alpine-dnsmasq /root/packages/main /tmp/dnsmasq-pkgs/
RUN ALPINE_ARCH=$(uname -m) && \
    apk add --allow-untrusted /tmp/dnsmasq-pkgs/$ALPINE_ARCH/dnsmasq-2*.apk \
                              /tmp/dnsmasq-pkgs/$ALPINE_ARCH/dnsmasq-common*.apk

# Install patched virtiofsd
COPY --from=alpine-virtiofsd /root/packages/community /tmp/virtiofsd-pkgs/
RUN ALPINE_ARCH=$(uname -m) && \
    apk add --allow-untrusted /tmp/virtiofsd-pkgs/$ALPINE_ARCH/virtiofsd-1*.apk

# Install patched mke2fs
COPY --from=e2fsprogs /usr/local/sbin/mke2fs /sbin/mke2fs

# Install patched dropbear
# dropbear's EPKA plugin, libepka_file.so, is bundled from /usr/lib/dropbear (see BUNDELF_EXTRA_LIBS)
COPY --from=alpine-dropbear /root/packages/main /tmp/dropbear-pkgs/
COPY --from=alpine-dropbear /usr/local/lib/libepka_file.so /usr/lib/dropbear/
RUN ALPINE_ARCH=$(uname -m) && \
    apk add --allow-untrusted /tmp/dropbear-pkgs/$ALPINE_ARCH/dropbear-ssh*.apk \
                              /tmp/dropbear-pkgs/$ALPINE_ARCH/dropbear-dbclient*.apk \
                              /tmp/dropbear-pkgs/$ALPINE_ARCH/dropbear-2*.apk

# Patch the binaries and set up symlinks
COPY build-utils/make-bundelf-bundle.sh /usr/local/bin/make-bundelf-bundle.sh
ENV BUNDELF_BINARIES="busybox bash jq ip nc mke2fs blkid findmnt dnsmasq nft mount s6-applyuidgid qemu-system-x86_64 qemu-ga /usr/lib/qemu/virtiofsd tput coreutils getent dropbear dbclient dropbearkey"
ENV BUNDELF_EXTRA_LIBS="/usr/libexec/coreutils /usr/lib/dropbear/libepka_file.so /usr/lib/qemu/*.so"
ENV BUNDELF_CODE_PATH="/opt/runcvm"
ENV BUNDELF_EXEC_PATH="/.runcvm/guest"

# Bundle, as well, each filesystem's mkfs command (field 6 of disk-filesystems), and the QEMU
# system emulator for the target architecture
RUN QEMU_BIN=$([ "$TARGETARCH" = "arm64" ] && echo qemu-system-aarch64 || echo qemu-system-x86_64) && \
    BUNDELF_BINARIES=$(echo "$BUNDELF_BINARIES" | sed "s/qemu-system-x86_64/$QEMU_BIN/") && \
    for cmd in $(awk '$1 !~ /^#/ && NF { print $6 }' /tmp/disk-filesystems); do \
      case " $BUNDELF_BINARIES " in *" $cmd "*) ;; *) BUNDELF_BINARIES="$BUNDELF_BINARIES $cmd" ;; esac; \
    done && \
    BUNDELF_BINARIES="$BUNDELF_BINARIES" /usr/local/bin/make-bundelf-bundle.sh --bundle && \
    mkdir -p $BUNDELF_CODE_PATH/bin && \
    cd $BUNDELF_CODE_PATH/bin && \
    for cmd in \
        awk base64 cat chgrp chmod cut grep head hostname init ln ls \
        mkdir poweroff ps rm rmdir route sh sysctl tr touch; \
    do \
        ln -s busybox $cmd; \
    done && \
    mkdir -p $BUNDELF_CODE_PATH/usr/share && \
    cp -a /usr/share/qemu $BUNDELF_CODE_PATH/usr/share && \
    cp -a /etc/terminfo $BUNDELF_CODE_PATH/usr/share && \
    if [ "$TARGETARCH" = "arm64" ]; then \
      cp -a /usr/share/AAVMF $BUNDELF_CODE_PATH/usr/share 2>/dev/null || true; \
    else \
      cp -a /usr/share/OVMF $BUNDELF_CODE_PATH/usr/share; \
    fi && \
    # Remove setuid/setgid bits from any/all binaries; make the package readable by all users, and
    # writable by root only (see the check at the end of the installer stage)
    chmod -R -s,a+rX,go-w $BUNDELF_CODE_PATH/

# --- BUILD STAGE ---
# Build static runcvm-init
FROM alpine:$ALPINE_VERSION as runcvm-init

RUN apk update && \
    apk add --no-cache gcc musl-dev

ADD runcvm-init /root/runcvm-init
RUN cd /root/runcvm-init && cc -o /root/runcvm-init/runcvm-init -std=gnu99 -static -s -Wall -Werror -O3 dumb-init.c

# --- BUILD STAGE ---
# Build static qemu-exit
FROM alpine:$ALPINE_VERSION as qemu-exit

RUN apk update && \
    apk add --no-cache gcc musl-dev

ADD qemu-exit /root/qemu-exit
RUN cd /root/qemu-exit && cc -o /root/qemu-exit/qemu-exit -std=gnu99 -static -s -Wall -Werror -O3 qemu-exit.c

# --- BUILD STAGE ---
# Build alpine kernel and initramfs with virtiofs module
FROM alpine:$ALPINE_KERNEL_VERSION as alpine-kernel

# Install patched mkinitfs
# NB: no coreutils in this stage, so avoid relying on GNU cp semantics
COPY --from=alpine-mkinitfs /root/packages/main /tmp/mkinitfs-pkgs/
RUN apk add --allow-untrusted /tmp/mkinitfs-pkgs/$(uname -m)/*.apk
RUN apk add --no-cache linux-virt
RUN (grep -qxF 'kernel/fs/fuse/virtiofs*' /etc/mkinitfs/features.d/virtio.modules || \
      echo 'kernel/fs/fuse/virtiofs*' >>/etc/mkinitfs/features.d/virtio.modules) && \
    sed -ri 's/\b(ata|nvme|raid|scsi|usb|cdrom|kms|mmc)\b//g; s/[ ]+/ /g' /etc/mkinitfs/mkinitfs.conf && \
    sed -ri 's/(nlplug-findfs)/\1 --timeout=1000/' /usr/share/mkinitfs/initramfs-init && \
    mkinitfs $(basename $(ls -d /lib/modules/*))
RUN BASENAME=$(basename $(ls -d /lib/modules/*)) && \
    mkdir -p /opt/runcvm/kernels/alpine/$BASENAME && \
    cp -a /boot/vmlinuz-virt /opt/runcvm/kernels/alpine/$BASENAME/vmlinuz && \
    cp -a /boot/initramfs-virt /opt/runcvm/kernels/alpine/$BASENAME/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/alpine/$BASENAME/ && \
    cp -a /boot/config-$BASENAME /opt/runcvm/kernels/alpine/$BASENAME/modules/$BASENAME/config && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/alpine

FROM alpine-kernel as openwrt-kernel
RUN mkdir -p /opt/runcvm/kernels/openwrt/$(basename $(ls -d /lib/modules/*))/modules/$(basename $(ls -d /lib/modules/*)) && \
    cd /opt/runcvm/kernels/openwrt/$(basename $(ls -d /lib/modules/*)) && \
    cp -a /boot/vmlinuz-virt vmlinuz && \
    cp -a /boot/initramfs-virt initrd && \
    find /lib/modules/ -type f -name '*.ko*' -exec cp -a {} modules/$(basename $(ls -d /lib/modules/*)) \; && \
    find modules/ -name '*.ko.gz' -exec gunzip {} + && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/openwrt

# --- BUILD STAGE ---
# Build Debian trixie kernel and initramfs with virtiofs module
FROM --platform=$TARGETPLATFORM debian:trixie as debian-kernel

ARG DEBIAN_FRONTEND=noninteractive
ARG KERNEL_MODULE_COMPRESSION
# The initrd holds only the modules listed (MODULES=list), those the VM needs as it boots: its
# virtual devices' drivers (runcvm-vm-init needs the network device from the start) and virtiofs,
# for its root, rather than most of the kernel's modules (initramfs-tools' default). A VM unpacks
# its initrd into memory as it boots, and RunCVM loads any other module the VM needs from the
# kernel's bundled modules once the root is mounted.
RUN apt update && \
    DEB_ARCH=$(dpkg --print-architecture) && \
    apt install -y linux-image-${DEB_ARCH}:${DEB_ARCH} xz-utils && \
    printf '%s\n' virtio_pci virtio_blk virtio_console virtio_net virtio_rng virtio_scsi virtiofs >>/etc/initramfs-tools/modules && \
    echo "MODULES=list" >/etc/initramfs-tools/conf.d/runcvm-modules && \
    echo "RESUME=none" >/etc/initramfs-tools/conf.d/resume && \
    update-initramfs -u
# Debian compresses its kernel modules with xz.
RUN BASENAME=$(basename $(ls -d /lib/modules/*)) && \
    case "$KERNEL_MODULE_COMPRESSION" in \
      xz) ;; \
      none) find /lib/modules/$BASENAME -name '*.ko.xz' -print0 | xargs -0 -r -n 64 -P "$(nproc)" xz -q -d && \
            depmod $BASENAME ;; \
      *) echo "KERNEL_MODULE_COMPRESSION must be 'xz' or 'none'" >&2; exit 1 ;; \
    esac && \
    mkdir -p /opt/runcvm/kernels/debian/$BASENAME && \
    cp -aL /boot/vmlinuz-$BASENAME /opt/runcvm/kernels/debian/$BASENAME/vmlinuz && \
    cp -aL /boot/initrd.img-$BASENAME /opt/runcvm/kernels/debian/$BASENAME/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/debian/$BASENAME/ && \
    cp -a /boot/config-$BASENAME /opt/runcvm/kernels/debian/$BASENAME/modules/$BASENAME/config && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/debian

# --- BUILD STAGE ---
# Build Ubuntu 26.04 (resolute) kernel and initramfs with virtiofs module
FROM --platform=$TARGETPLATFORM ubuntu:resolute as ubuntu-kernel

ARG DEBIAN_FRONTEND=noninteractive
ARG KERNEL_MODULE_COMPRESSION
# The initrd must be built by initramfs-tools, not dracut (Ubuntu's default initrd generator), as
# runcvm-runtime boots the Ubuntu kernel with initramfs-tools' arguments for a virtiofs root
# (rootfstype=virtiofs root=runcvmfs).
# The initrd holds only the modules listed (MODULES=list), those the VM needs as it boots: its
# virtual devices' drivers (runcvm-vm-init needs the network device from the start) and virtiofs,
# for its root, rather than most of the kernel's modules (initramfs-tools' default). A VM unpacks
# its initrd into memory as it boots, and RunCVM loads any other module the VM needs from the
# kernel's bundled modules once the root is mounted.
RUN apt update && \
    DEB_ARCH=$(dpkg --print-architecture) && \
    apt install -y linux-generic:${DEB_ARCH} initramfs-tools zstd xz-utils binutils && \
    printf '%s\n' virtio_pci virtio_blk virtio_console virtio_net virtio_rng virtio_scsi virtiofs >>/etc/initramfs-tools/modules && \
    echo "MODULES=list" >/etc/initramfs-tools/conf.d/runcvm-modules && \
    echo "RESUME=none" >/etc/initramfs-tools/conf.d/resume && \
    update-initramfs -u
# Ubuntu compresses its kernel modules with zstd, which busybox modprobe (used by runcvm-vm-init,
# and by busybox-based images) cannot read, so decompress them, and for 'xz' recompress them with
# xz, which it can, as Debian's, AlmaLinux's and Fedora's modules are compressed, with the options the
# kernel's own build uses for xz.
RUN BASENAME=$(basename $(ls -d /lib/modules/*)) && \
    case "$KERNEL_MODULE_COMPRESSION" in \
      xz|none) ;; \
      *) echo "KERNEL_MODULE_COMPRESSION must be 'xz' or 'none'" >&2; exit 1 ;; \
    esac && \
    find /lib/modules/$BASENAME -name '*.ko.zst' -print0 | \
      xargs -0 -r -n 64 -P "$(nproc)" sh -ec 'm=$1; shift; for f; do zstd -q -d --rm "$f"; [ "$m" = none ] || xz -q --check=crc32 --lzma2=dict=1MiB "${f%.zst}"; done' sh "$KERNEL_MODULE_COMPRESSION" && \
    depmod $BASENAME && \
    mkdir -p /opt/runcvm/kernels/ubuntu/$BASENAME && \
    # On arm64, Ubuntu's vmlinuz is a systemd-stub EFI application, which QEMU cannot boot, holding
    # the kernel in its .linux section, with device trees for particular machines: take the kernel.
    if objdump -h /boot/vmlinuz-$BASENAME 2>/dev/null | grep ' \.linux ' >/dev/null; then \
      objcopy -O binary --only-section=.linux /boot/vmlinuz-$BASENAME /opt/runcvm/kernels/ubuntu/$BASENAME/vmlinuz; \
    else \
      cp -aL /boot/vmlinuz-$BASENAME /opt/runcvm/kernels/ubuntu/$BASENAME/vmlinuz; \
    fi && \
    cp -aL /boot/initrd.img-$BASENAME /opt/runcvm/kernels/ubuntu/$BASENAME/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/ubuntu/$BASENAME/ && \
    cp -a /boot/config-$BASENAME /opt/runcvm/kernels/ubuntu/$BASENAME/modules/$BASENAME/config && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/ubuntu

# --- BUILD STAGE ---
# Build AlmaLinux 10 kernel and initramfs with virtiofs module: the kernel for images of the RHEL
# family (see RUNCVM_KERNEL_RHEL_FAMILY in runcvm-runtime)
FROM --platform=$TARGETPLATFORM almalinux:10 as almalinux-kernel

ARG KERNEL_MODULE_COMPRESSION
# The almalinux image has no /boot, where the kernel package and dracut install the kernel and
# initramfs. kernel-modules-extra provides br_netfilter, which k3s loads, as does dockerd with its
# userland proxy or inter-container communication disabled.
RUN mkdir -p /boot && dnf install -y kernel kernel-modules-extra xz
ADD ./kernels/dracut/addvirtiofs.conf /etc/dracut.conf.d/addvirtiofs.conf
ADD ./kernels/dracut/95virtiofs /usr/lib/dracut/modules.d/95virtiofs
# AlmaLinux's dracut builds host-only initramfses by default, so build a generic one: the build
# container's host is not the VM.
RUN dracut --force --no-hostonly --no-hostonly-cmdline --kver $(basename /lib/modules/*) --kmoddir /lib/modules/*
# AlmaLinux compresses its kernel modules with xz.
RUN BASENAME=$(basename $(ls -d /lib/modules/*)) && \
    case "$KERNEL_MODULE_COMPRESSION" in \
      xz) ;; \
      none) find /lib/modules/$BASENAME -name '*.ko.xz' -print0 | xargs -0 -r -n 64 -P "$(nproc)" xz -q -d && \
            depmod $BASENAME ;; \
      *) echo "KERNEL_MODULE_COMPRESSION must be 'xz' or 'none'" >&2; exit 1 ;; \
    esac && \
    mkdir -p /opt/runcvm/kernels/almalinux/$BASENAME && \
    mv /lib/modules/$BASENAME/vmlinuz /opt/runcvm/kernels/almalinux/$BASENAME/vmlinuz && \
    cp -aL /boot/initramfs-$BASENAME.img /opt/runcvm/kernels/almalinux/$BASENAME/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/almalinux/$BASENAME/ && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/almalinux

# --- BUILD STAGE ---
# Build Fedora 45 kernel and initramfs with virtiofs module
FROM fedora:45 as fedora-kernel

ARG KERNEL_MODULE_COMPRESSION
RUN dnf install -y kernel xz
# Fedora's dracut has a virtiofs module of its own (74virtiofs), which takes precedence over
# RunCVM's (kernels/dracut/95virtiofs), so it is used instead.
ADD ./kernels/dracut/addvirtiofs.conf /etc/dracut.conf.d/addvirtiofs.conf
# Fedora's dracut builds host-only initramfses by default, so build a generic one: the build
# container's host is not the VM.
RUN dracut --force --no-hostonly --no-hostonly-cmdline --kver $(basename /lib/modules/*) --kmoddir /lib/modules/*
# Fedora compresses its kernel modules with xz.
RUN BASENAME=$(basename $(ls -d /lib/modules/*)) && \
    case "$KERNEL_MODULE_COMPRESSION" in \
      xz) ;; \
      none) find /lib/modules/$BASENAME -name '*.ko.xz' -print0 | xargs -0 -r -n 64 -P "$(nproc)" xz -q -d && \
            depmod $BASENAME ;; \
      *) echo "KERNEL_MODULE_COMPRESSION must be 'xz' or 'none'" >&2; exit 1 ;; \
    esac && \
    mkdir -p /opt/runcvm/kernels/fedora/$BASENAME && \
    mv /lib/modules/$BASENAME/vmlinuz /opt/runcvm/kernels/fedora/$BASENAME/vmlinuz && \
    cp -aL /boot/initramfs-$BASENAME.img /opt/runcvm/kernels/fedora/$BASENAME/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/fedora/$BASENAME/ && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/fedora

# --- BUILD STAGE ---
# Build openSUSE Leap 16.1 kernel and initramfs with virtiofs module: the kernel for images of the
# SUSE family (see RUNCVM_KERNEL_SUSE_FAMILY in runcvm-runtime)
FROM opensuse/leap:16.1 as opensuse-kernel

ARG KERNEL_MODULE_COMPRESSION
RUN zypper -n install kernel-default dracut xz zstd
ADD ./kernels/dracut/addvirtiofs.conf /etc/dracut.conf.d/addvirtiofs.conf
ADD ./kernels/dracut/95virtiofs /usr/lib/dracut/modules.d/95virtiofs
# openSUSE's dracut builds host-only initramfses by default, so build a generic one: the build
# container's host is not the VM.
RUN dracut --force --no-hostonly --no-hostonly-cmdline --kver $(basename /lib/modules/*) --kmoddir /lib/modules/*
# openSUSE compresses its kernel modules with zstd, which busybox modprobe (used by
# runcvm-vm-init) cannot read, so decompress them, and for 'xz' recompress them with xz, as the
# Ubuntu stage does.
RUN BASENAME=$(basename $(ls -d /lib/modules/*)) && \
    case "$KERNEL_MODULE_COMPRESSION" in \
      xz|none) ;; \
      *) echo "KERNEL_MODULE_COMPRESSION must be 'xz' or 'none'" >&2; exit 1 ;; \
    esac && \
    find /lib/modules/$BASENAME -name '*.ko.zst' -print0 | \
      xargs -0 -r -n 64 -P "$(nproc)" sh -ec 'm=$1; shift; for f; do zstd -q -d --rm "$f"; [ "$m" = none ] || xz -q --check=crc32 --lzma2=dict=1MiB "${f%.zst}"; done' sh "$KERNEL_MODULE_COMPRESSION" && \
    depmod $BASENAME && \
    mkdir -p /opt/runcvm/kernels/opensuse/$BASENAME && \
    # The kernel image is vmlinuz on x86_64, Image on arm64
    KIMAGE=$(ls /lib/modules/$BASENAME/vmlinuz /lib/modules/$BASENAME/Image 2>/dev/null | head -n 1) && \
    mv "$KIMAGE" /opt/runcvm/kernels/opensuse/$BASENAME/vmlinuz && \
    rm -f /lib/modules/$BASENAME/vmlinux.xz && \
    cp -aL /boot/initrd-$BASENAME /opt/runcvm/kernels/opensuse/$BASENAME/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/opensuse/$BASENAME/ && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/opensuse

# --- BUILD STAGE ---
# Build RunCVM installer
FROM alpine:$ALPINE_VERSION as installer

COPY --from=binaries /opt/runcvm /opt/runcvm
COPY --from=runcvm-init /root/runcvm-init/runcvm-init /opt/runcvm/sbin/
COPY --from=qemu-exit /root/qemu-exit/qemu-exit /opt/runcvm/sbin/

RUN apk update && apk add --no-cache rsync

ADD runcvm-scripts /opt/runcvm/scripts/
ADD runcvm-etc /opt/runcvm/etc/
COPY LICENSE NOTICE /opt/runcvm/

# Files copied from the build context keep the checkout's permissions, which follow the umask of
# whoever checked it out (e.g. group-writable under Ubuntu's default umask for users, 002), so give
# them the package's own (see the check below).
RUN chmod -R a+rX,go-w /opt/runcvm/scripts /opt/runcvm/etc /opt/runcvm/LICENSE /opt/runcvm/NOTICE

ADD build-utils/entrypoint-install.sh /
ENTRYPOINT ["/entrypoint-install.sh"]

# OCI labels. GitHub links the image's package on ghcr.io to the repository named by 'source', and
# shows 'description'. build/build.sh gives the image's index on ghcr.io the same keys as
# annotations, which GitHub reads in place of labels where a tag names an index. 'authors' names
# the maintainer, in place of Docker's deprecated MAINTAINER instruction.
LABEL org.opencontainers.image.source="https://github.com/newsnowlabs/runcvm" \
      org.opencontainers.image.authors="Struan Bartlett (https://github.com/struanb)" \
      org.opencontainers.image.vendor="NewsNow Labs" \
      org.opencontainers.image.description="Experimental open-source container runtime for Linux that launches standard container workloads, and system workloads such as systemd, Docker and OpenWrt, in VMs" \
      org.opencontainers.image.licenses="Apache-2.0"

# Install needed kernels.
# Comment out any kernels that are unneeded.
COPY --from=alpine-kernel /opt/runcvm/kernels/alpine /opt/runcvm/kernels/alpine
COPY --from=debian-kernel /opt/runcvm/kernels/debian /opt/runcvm/kernels/debian
COPY --from=openwrt-kernel /opt/runcvm/kernels/openwrt /opt/runcvm/kernels/openwrt
COPY --from=ubuntu-kernel /opt/runcvm/kernels/ubuntu /opt/runcvm/kernels/ubuntu
COPY --from=almalinux-kernel /opt/runcvm/kernels/almalinux /opt/runcvm/kernels/almalinux
COPY --from=fedora-kernel /opt/runcvm/kernels/fedora /opt/runcvm/kernels/fedora
COPY --from=opensuse-kernel /opt/runcvm/kernels/opensuse /opt/runcvm/kernels/opensuse

# Add 'latest' symlinks for available kernels
RUN for d in /opt/runcvm/kernels/*; do \
      cd "$d" && \
      tgt="$(ls -d */ 2>/dev/null | sed 's:/$::' | grep -v '^latest$' | sort -Vr | head -n 1)"; \
      [ -n "$tgt" ] && ln -sfn "$tgt" latest; \
    done

# Every file in the package must be readable, and every directory searchable, by all users, as
# RunCVM's binaries load their libraries (and Podman may run the runtime) as users other than root;
# and everything writable by root only, as the VM's dropbear, running as root, loads its plugin
# from the package.
RUN bad=$(find /opt/runcvm ! -type l \( ! -perm -o=r -o -type d ! -perm -o=x -o -perm /022 \)) || \
      { echo "Checking permissions in /opt/runcvm failed" >&2; exit 1; } && \
    [ -z "$bad" ] || { echo "Files with the wrong permissions in /opt/runcvm:" >&2; echo "$bad" | head -20 >&2; exit 1; }
