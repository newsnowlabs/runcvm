# syntax=docker/dockerfile:1.3-labs

# BUILD DIST-INDEPENDENT BINARIES AND LIBRARIES

FROM alpine:edge as binaries

RUN apk update && \
    apk add --no-cache file bash qemu-system-x86_64 qemu-virtiofsd qemu-ui-curses qemu-guest-agent \
        jq iproute2 netcat-openbsd e2fsprogs blkid util-linux \
        s6 dnsmasq iptables nftables \
        ncurses coreutils && \
    apk add --no-cache patchelf --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community

RUN apk add --no-cache strace

# Build patched SeaBIOS packages
# to allow disabling of BIOS output by QEMU
# (without triggering QEMU warnings)
ARG SEABIOS_PATH=/root/aports/main/seabios
RUN <<EOF
apk add --no-cache alpine-sdk
abuild-keygen -an
git clone --depth 1 --single-branch --filter=blob:none --sparse https://gitlab.alpinelinux.org/alpine/aports.git ~/aports
cd ~/aports/
git sparse-checkout set main/seabios
cd $SEABIOS_PATH
cat <<_EOE_ >0003-qemu-fw-cfg-fix.patch
diff --git a/src/sercon.c b/src/sercon.c
index 3019d9b..988c2a2 100644
--- a/src/sercon.c
+++ b/src/sercon.c
@@ -516,7 +516,7 @@ void sercon_setup(void)
     struct segoff_s seabios, vgabios;
     u16 addr;
 
-    addr = romfile_loadint("etc/sercon-port", 0);
+    addr = romfile_loadint("opt/org.seabios/etc/sercon-port", 0);
     if (!addr)
         return;
     dprintf(1, "sercon: using ioport 0x%x\n", addr);
diff --git a/src/fw/paravirt.c b/src/fw/paravirt.c
index fba4e52..9a346d9 100644
--- a/src/fw/paravirt.c
+++ b/src/fw/paravirt.c
diff --git a/src/fw/paravirt.c b/src/fw/paravirt.c
index fba4e52..9a346d9 100644
--- a/src/fw/paravirt.c
+++ b/src/fw/paravirt.c
@@ -652,9 +652,9 @@ void qemu_cfg_init(void)
     // serial console
     u16 nogfx = 0;
     qemu_cfg_read_entry(&nogfx, QEMU_CFG_NOGRAPHIC, sizeof(nogfx));
-    if (nogfx && !romfile_find("etc/sercon-port")
+    if (nogfx && !romfile_find("opt/org.seabios/etc/sercon-port")
         && !romfile_find("vgaroms/sgabios.bin"))
-        const_romfile_add_int("etc/sercon-port", PORT_SERIAL1);
+        const_romfile_add_int("opt/org.seabios/etc/sercon-port", PORT_SERIAL1);
 }
 
 /*
_EOE_
echo 'sha512sums="${sha512sums}7bab39dfbe442da27b37728179283ba97fff32db8ecfc51cd950daf4f463234efba7080a304edb0800ca9008e66c257c7d48f46c09044655dc3e0ff563d3734f  0003-qemu-fw-cfg-fix.patch"' >>APKBUILD
echo 'source="${source}0003-qemu-fw-cfg-fix.patch"' >>APKBUILD
abuild -rFf
apk add --allow-untrusted ~/packages/main/x86_64/*.apk
cp -a /usr/share/seabios/bios*.bin /usr/share/qemu/
EOF

# Patch the binaries and set up symlinks
COPY build-utils/elf-patcher.sh /usr/local/bin/elf-patcher.sh
ENV BINARIES="busybox bash jq ip nc mke2fs blkid findmnt dnsmasq xtables-legacy-multi nft xtables-nft-multi nft mount s6-applyuidgid qemu-system-x86_64 qemu-ga /usr/lib/qemu/* tput stdbuf coreutils strace"
ENV EXTRA_LIBS="/usr/lib/xtables /usr/libexec/coreutils"
ENV CODE_PATH="/opt/dkvm"
RUN /usr/local/bin/elf-patcher.sh && \
    bash -c 'cd /opt/dkvm/bin; for cmd in awk base64 cat chmod cut grep head hostname init ln ls mkdir mount poweroff ps rm route sh sysctl tr touch; do ln -s busybox $cmd; done' && \
    mkdir -p /opt/dkvm/usr/share && cp -a /usr/share/qemu /opt/dkvm/usr/share

# BUILD CONTAINER INIT
FROM alpine:edge as init

RUN apk update && \
    apk add --no-cache gcc musl-dev

ADD dkvm-init /root/dkvm-init
RUN cd /root/dkvm-init && cc -o /root/dkvm-init/dkvm-init -std=gnu99 -static -s -Wall -Werror -O3 dumb-init.c

# Build qemu-exit while we're here

ADD qemu-exit /root/qemu-exit
RUN cd /root/qemu-exit && cc -o /root/qemu-exit/qemu-exit -std=gnu99 -static -s -Wall -Werror -O3 qemu-exit.c

# Build alpine kernel and initramfs with virtiofs module

FROM alpine:edge as alpine-kernel

RUN apk add --no-cache linux-virt
RUN echo 'kernel/fs/fuse/virtiofs*' >>/etc/mkinitfs/features.d/virtio.modules && \
    sed -ri 's/\b(ata|nvme|raid|scsi|usb|cdrom|kms|mmc)\b//g; s/[ ]+/ /g' /etc/mkinitfs/mkinitfs.conf && \
    mkinitfs $(basename $(ls -d /lib/modules/*))
RUN mkdir -p /opt/dkvm/kernels/alpine/$(basename $(ls -d /lib/modules/*)) && \
    cp -a /boot/vmlinuz-virt /opt/dkvm/kernels/alpine/$(basename $(ls -d /lib/modules/*))/vmlinuz && \
    cp -a /boot/initramfs-virt /opt/dkvm/kernels/alpine/$(basename $(ls -d /lib/modules/*))/initrd && \
    cp -a /lib/modules/ /opt/dkvm/kernels/alpine/$(basename $(ls -d /lib/modules/*))/ && \
    chmod -R u+rwX,g+rX,o+rX /opt/dkvm/kernels/alpine

# Build Debian bullseye kernel and initramfs with virtiofs module

FROM amd64/debian:bullseye as debian-kernel

ARG DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install -y linux-image-amd64:amd64 && \
    echo 'virtiofs' >>/etc/initramfs-tools/modules && \
    echo 'virtio_console' >>/etc/initramfs-tools/modules && \
    echo "RESUME=none" >/etc/initramfs-tools/conf.d/resume && \
    update-initramfs -u
RUN mkdir -p /opt/dkvm/kernels/debian/$(basename $(ls -d /lib/modules/*)) && \
    cp -aL /vmlinuz /opt/dkvm/kernels/debian/$(basename $(ls -d /lib/modules/*))/vmlinuz && \
    cp -aL /initrd.img /opt/dkvm/kernels/debian/$(basename $(ls -d /lib/modules/*))/initrd && \
    cp -a /lib/modules/ /opt/dkvm/kernels/debian/$(basename $(ls -d /lib/modules/*))/ && \
    chmod -R u+rwX,g+rX,o+rX /opt/dkvm/kernels/debian

# Build Ubuntu bullseye kernel and initramfs with virtiofs module

FROM amd64/ubuntu:latest as ubuntu-kernel

ARG DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install -y linux-generic:amd64 && \
    echo 'virtiofs' >>/etc/initramfs-tools/modules && \
    echo 'virtio_console' >>/etc/initramfs-tools/modules && \
    echo "RESUME=none" >/etc/initramfs-tools/conf.d/resume && \
    update-initramfs -u
RUN mkdir -p /opt/dkvm/kernels/ubuntu/$(basename $(ls -d /lib/modules/*)) && \
    cp -aL /boot/vmlinuz /opt/dkvm/kernels/ubuntu/$(basename $(ls -d /lib/modules/*))/vmlinuz && \
    cp -aL /boot/initrd.img /opt/dkvm/kernels/ubuntu/$(basename $(ls -d /lib/modules/*))/initrd && \
    cp -a /lib/modules/ /opt/dkvm/kernels/ubuntu/$(basename $(ls -d /lib/modules/*))/ && \
    chmod -R u+rwX,g+rX,o+rX /opt/dkvm/kernels/ubuntu

# Build Oracle Linux kernel and initramfs with virtiofs module

FROM oraclelinux:9 as oracle-kernel

RUN dnf install -y kernel
ADD ./kernels/oraclelinux/addvirtiofs.conf /etc/dracut.conf.d/addvirtiofs.conf
ADD ./kernels/oraclelinux/95virtiofs /usr/lib/dracut/modules.d/95virtiofs
RUN dracut --force --kver $(basename /lib/modules/*) --kmoddir /lib/modules/*
RUN mkdir -p /opt/dkvm/kernels/ol/$(basename $(ls -d /lib/modules/*)) && \
    mv /lib/modules/*/vmlinuz /opt/dkvm/kernels/ol/$(basename $(ls -d /lib/modules/*))/vmlinuz && \
    cp -aL /boot/initramfs* /opt/dkvm/kernels/ol/$(basename $(ls -d /lib/modules/*))/initrd && \
    cp -a /lib/modules/ /opt/dkvm/kernels/ol/$(basename $(ls -d /lib/modules/*))/ && \
    chmod -R u+rwX,g+rX,o+rX /opt/dkvm/kernels/ol

# Build DKVM installation

FROM alpine

COPY --from=binaries /opt/dkvm /opt/dkvm
COPY --from=alpine-kernel /opt/dkvm/kernels/alpine /opt/dkvm/kernels/alpine
COPY --from=debian-kernel /opt/dkvm/kernels/debian /opt/dkvm/kernels/debian
COPY --from=ubuntu-kernel /opt/dkvm/kernels/ubuntu /opt/dkvm/kernels/ubuntu
COPY --from=oracle-kernel /opt/dkvm/kernels/ol     /opt/dkvm/kernels/ol
COPY --from=init /root/dkvm-init/dkvm-init /root/qemu-exit/qemu-exit /opt/dkvm/sbin/

RUN for d in /opt/dkvm/kernels/*; do cd $d && ln -s $(ls -d * | sort | head -n 1) latest; done

ADD dkvm-scripts/* /opt/dkvm/scripts/

ADD build-utils/entrypoint-install.sh /
ENTRYPOINT ["/entrypoint-install.sh"]