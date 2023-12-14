# syntax=docker/dockerfile:1.3-labs

# Alpine version to build with
ARG ALPINE_VERSION=3.18

# --- BUILD STAGE ---
# Build base alpine-sdk image for later build stages
FROM alpine:$ALPINE_VERSION as alpine-sdk

RUN apk update && apk add --no-cache alpine-sdk coreutils && \
    abuild-keygen -an && \
    git clone --depth 1 --single-branch --filter=blob:none --sparse https://gitlab.alpinelinux.org/alpine/aports.git ~/aports && \
    cd ~/aports/ && \
    git sparse-checkout set main/seabios main/

# --- BUILD STAGE ---
# Build patched SeaBIOS packages
# to allow disabling of BIOS output by QEMU
# (without triggering QEMU warnings)
FROM alpine-sdk as alpine-seabios

ADD patches/seabios/qemu-fw-cfg-fix.patch /root/aports/main/seabios/0003-qemu-fw-cfg-fix.patch

RUN <<EOF
cd /root/aports/main/seabios
echo 'sha512sums="${sha512sums}$(sha512sum 0003-qemu-fw-cfg-fix.patch)"' >>APKBUILD
echo 'source="${source}0003-qemu-fw-cfg-fix.patch"' >>APKBUILD
abuild -rFf
EOF

# --- BUILD STAGE ---
# Build patched dnsmasq
# that does not require /etc/passwd file to run
# (needed for images such as hello-world)
FROM alpine-sdk as alpine-dnsmasq

ADD patches/dnsmasq/remove-passwd-requirement.patch /root/aports/main/dnsmasq/remove-passwd-requirement.patch

RUN <<EOF
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
autoheader
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
cd /root/aports/main/mkinitfs
echo 'sha512sums="${sha512sums}$(sha512sum nlplug-findfs.patch)"' >>APKBUILD
echo 'source="${source} nlplug-findfs.patch"' >>APKBUILD
abuild -rFf
EOF

# --- BUILD STAGE ---
# Build dist-independent dynamic binaries and libraries
FROM alpine:$ALPINE_VERSION as binaries

RUN apk update && \
    apk add --no-cache file bash qemu-system-x86_64 qemu-virtiofsd qemu-ui-curses qemu-guest-agent \
        jq iproute2 netcat-openbsd e2fsprogs blkid util-linux \
        s6 dnsmasq iptables nftables \
        ncurses coreutils \
        patchelf

# Install patched SeaBIOS
COPY --from=alpine-seabios /root/packages/main/x86_64 /tmp/seabios/
RUN apk add --allow-untrusted /tmp/seabios/*.apk && cp -a /usr/share/seabios/bios*.bin /usr/share/qemu/

# Install patched dnsmasq
COPY --from=alpine-dnsmasq /root/packages/main/x86_64 /tmp/dnsmasq/
RUN apk add --allow-untrusted /tmp/dnsmasq/dnsmasq-2*.apk /tmp/dnsmasq/dnsmasq-common*.apk

# Install patched dropbear
COPY --from=alpine-dropbear /root/packages/main/x86_64 /usr/local/lib/libepka_file.so /tmp/dropbear/
RUN apk add --allow-untrusted /tmp/dropbear/dropbear-ssh*.apk /tmp/dropbear/dropbear-dbclient*.apk /tmp/dropbear/dropbear-2*.apk

# Patch the binaries and set up symlinks
COPY build-utils/elf-patcher.sh /usr/local/bin/elf-patcher.sh
ENV BINARIES="busybox bash jq ip nc mke2fs blkid findmnt dnsmasq xtables-legacy-multi nft xtables-nft-multi nft mount s6-applyuidgid qemu-system-x86_64 qemu-ga /usr/lib/qemu/virtiofsd tput stdbuf coreutils getent dropbear dbclient dropbearkey"
ENV EXTRA_LIBS="/usr/lib/xtables /usr/libexec/coreutils /tmp/dropbear/libepka_file.so /usr/lib/qemu/*.so"
ENV CODE_PATH="/opt/runcvm"
RUN /usr/local/bin/elf-patcher.sh && \
    cd $CODE_PATH/bin && \
    for cmd in \
        awk base64 cat chgrp chmod cut grep head hostname init ln ls \
        mkdir poweroff ps rm route sh sysctl tr touch; \
    do \
        ln -s busybox $cmd; \
    done && \
    mkdir -p $CODE_PATH/usr/share && \
    cp -a /usr/share/qemu $CODE_PATH/usr/share

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
FROM alpine:3.18 as alpine-kernel

# Install patched mkinitfs
COPY --from=alpine-mkinitfs /root/packages/main/x86_64 /tmp/mkinitfs/
RUN apk add --allow-untrusted /tmp/mkinitfs/*.apk
RUN apk add --no-cache linux-virt
RUN echo 'kernel/fs/fuse/virtiofs*' >>/etc/mkinitfs/features.d/virtio.modules && \
    sed -ri 's/\b(ata|nvme|raid|scsi|usb|cdrom|kms|mmc)\b//g; s/[ ]+/ /g' /etc/mkinitfs/mkinitfs.conf && \
    sed -ri 's/(nlplug-findfs)/\1 --timeout=1000/' /usr/share/mkinitfs/initramfs-init && \
    mkinitfs $(basename $(ls -d /lib/modules/*))
RUN mkdir -p /opt/runcvm/kernels/alpine/$(basename $(ls -d /lib/modules/*)) && \
    cp -a /boot/vmlinuz-virt /opt/runcvm/kernels/alpine/$(basename $(ls -d /lib/modules/*))/vmlinuz && \
    cp -a /boot/initramfs-virt /opt/runcvm/kernels/alpine/$(basename $(ls -d /lib/modules/*))/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/alpine/$(basename $(ls -d /lib/modules/*))/ && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/alpine

# --- BUILD STAGE ---
# Build Debian bookworm kernel and initramfs with virtiofs module
FROM amd64/debian:bookworm as debian-kernel

ARG DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install -y linux-image-amd64:amd64 && \
    echo 'virtiofs' >>/etc/initramfs-tools/modules && \
    echo 'virtio_console' >>/etc/initramfs-tools/modules && \
    echo "RESUME=none" >/etc/initramfs-tools/conf.d/resume && \
    update-initramfs -u
RUN mkdir -p /opt/runcvm/kernels/debian/$(basename $(ls -d /lib/modules/*)) && \
    cp -aL /vmlinuz /opt/runcvm/kernels/debian/$(basename $(ls -d /lib/modules/*))/vmlinuz && \
    cp -aL /initrd.img /opt/runcvm/kernels/debian/$(basename $(ls -d /lib/modules/*))/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/debian/$(basename $(ls -d /lib/modules/*))/ && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/debian

# --- BUILD STAGE ---
# Build Ubuntu bullseye kernel and initramfs with virtiofs module
FROM amd64/ubuntu:jammy as ubuntu-kernel

ARG DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install -y linux-generic:amd64 && \
    echo 'virtiofs' >>/etc/initramfs-tools/modules && \
    echo 'virtio_console' >>/etc/initramfs-tools/modules && \
    echo "RESUME=none" >/etc/initramfs-tools/conf.d/resume && \
    update-initramfs -u
RUN mkdir -p /opt/runcvm/kernels/ubuntu/$(basename $(ls -d /lib/modules/*)) && \
    cp -aL /boot/vmlinuz /opt/runcvm/kernels/ubuntu/$(basename $(ls -d /lib/modules/*))/vmlinuz && \
    cp -aL /boot/initrd.img /opt/runcvm/kernels/ubuntu/$(basename $(ls -d /lib/modules/*))/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/ubuntu/$(basename $(ls -d /lib/modules/*))/ && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/ubuntu

# --- BUILD STAGE ---
# Build Oracle Linux kernel and initramfs with virtiofs module
FROM oraclelinux:9 as oracle-kernel

RUN dnf install -y kernel
ADD ./kernels/oraclelinux/addvirtiofs.conf /etc/dracut.conf.d/addvirtiofs.conf
ADD ./kernels/oraclelinux/95virtiofs /usr/lib/dracut/modules.d/95virtiofs
RUN dracut --force --kver $(basename /lib/modules/*) --kmoddir /lib/modules/*
RUN mkdir -p /opt/runcvm/kernels/ol/$(basename $(ls -d /lib/modules/*)) && \
    mv /lib/modules/*/vmlinuz /opt/runcvm/kernels/ol/$(basename $(ls -d /lib/modules/*))/vmlinuz && \
    cp -aL /boot/initramfs* /opt/runcvm/kernels/ol/$(basename $(ls -d /lib/modules/*))/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/ol/$(basename $(ls -d /lib/modules/*))/ && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/ol

# --- BUILD STAGE ---
# Build RunCVM installer
FROM alpine:$ALPINE_VERSION as installer

COPY --from=binaries /opt/runcvm /opt/runcvm
COPY --from=runcvm-init /root/runcvm-init/runcvm-init /opt/runcvm/sbin/
COPY --from=qemu-exit /root/qemu-exit/qemu-exit /opt/runcvm/sbin/

RUN apk update && apk add --no-cache rsync

ADD runcvm-scripts/* /opt/runcvm/scripts/

ADD build-utils/entrypoint-install.sh /
ENTRYPOINT ["/entrypoint-install.sh"]

# Install needed kernels.
# Comment out any kernels that are unneeded.
COPY --from=alpine-kernel /opt/runcvm/kernels/alpine /opt/runcvm/kernels/alpine
COPY --from=debian-kernel /opt/runcvm/kernels/debian /opt/runcvm/kernels/debian
COPY --from=ubuntu-kernel /opt/runcvm/kernels/ubuntu /opt/runcvm/kernels/ubuntu
COPY --from=oracle-kernel /opt/runcvm/kernels/ol     /opt/runcvm/kernels/ol

# Add 'latest' symlinks for available kernels
RUN for d in /opt/runcvm/kernels/*; do cd $d && ln -s $(ls -d * | sort | head -n 1) latest; done