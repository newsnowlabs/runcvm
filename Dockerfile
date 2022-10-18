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

RUN <<EOF
apk add --no-cache alpine-sdk
abuild-keygen -an
git clone --depth 1 --single-branch --filter=blob:none --sparse https://gitlab.alpinelinux.org/alpine/aports.git ~/aports
cd ~/aports/
git sparse-checkout set main/seabios main/dnsmasq

# Build patched SeaBIOS packages
# to allow disabling of BIOS output by QEMU
# (without triggering QEMU warnings)
cd /root/aports/main/seabios
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

# Build patched dnsmasq that does not require
# /etc/passwd file to run
cd /root/aports/main/dnsmasq
cat <<_EOE_ >9999-Remove-passwd-requirement.patch
--- a/src/dnsmasq.c.orig
+++ b/src/dnsmasq.c
@@ -481,6 +481,7 @@
     }
 #endif
   
+#if 0
   if (daemon->username && !(ent_pw = getpwnam(daemon->username)))
     baduser = daemon->username;
   else if (daemon->groupname && !(gp = getgrnam(daemon->groupname)))
@@ -488,6 +489,7 @@
 
   if (baduser)
     die(_("unknown user or group: %s"), baduser, EC_BADCONF);
+#endif
 
   /* implement group defaults, "dip" if available, or group associated with uid */
   if (!daemon->group_set && !gp)
_EOE_

echo 'sha512sums="${sha512sums}368572f4c9e702b55367ea49a6cabbbd786e6aaf9708b5e24e624da7eed1c317a55d683656b40b75aaed19c3eac13826eaf81b4ff062df118683149295746863  9999-Remove-passwd-requirement.patch"' >>APKBUILD
echo 'source="${source}9999-Remove-passwd-requirement.patch"' >>APKBUILD
abuild -rFf
apk add --allow-untrusted ~/packages/main/x86_64/dnsmasq-2*.apk ~/packages/main/x86_64/dnsmasq-common*.apk 
EOF

# Patch the binaries and set up symlinks
COPY build-utils/elf-patcher.sh /usr/local/bin/elf-patcher.sh
ENV BINARIES="busybox bash jq ip nc mke2fs blkid findmnt dnsmasq xtables-legacy-multi nft xtables-nft-multi nft mount s6-applyuidgid qemu-system-x86_64 qemu-ga /usr/lib/qemu/* tput stdbuf coreutils strace"
ENV EXTRA_LIBS="/usr/lib/xtables /usr/libexec/coreutils"
ENV CODE_PATH="/opt/runcvm"
RUN /usr/local/bin/elf-patcher.sh && \
    bash -c 'cd /opt/runcvm/bin; for cmd in awk base64 cat chmod cut grep head hostname init ln ls mkdir mount poweroff ps rm route sh sysctl tr touch; do ln -s busybox $cmd; done' && \
    mkdir -p /opt/runcvm/usr/share && cp -a /usr/share/qemu /opt/runcvm/usr/share

# BUILD CONTAINER INIT
FROM alpine:edge as init

RUN apk update && \
    apk add --no-cache gcc musl-dev

ADD runcvm-init /root/runcvm-init
RUN cd /root/runcvm-init && cc -o /root/runcvm-init/runcvm-init -std=gnu99 -static -s -Wall -Werror -O3 dumb-init.c

# Build qemu-exit while we're here

ADD qemu-exit /root/qemu-exit
RUN cd /root/qemu-exit && cc -o /root/qemu-exit/qemu-exit -std=gnu99 -static -s -Wall -Werror -O3 qemu-exit.c

# Build alpine kernel and initramfs with virtiofs module

FROM alpine:edge as alpine-kernel

RUN apk add --no-cache linux-virt
RUN echo 'kernel/fs/fuse/virtiofs*' >>/etc/mkinitfs/features.d/virtio.modules && \
    sed -ri 's/\b(ata|nvme|raid|scsi|usb|cdrom|kms|mmc)\b//g; s/[ ]+/ /g' /etc/mkinitfs/mkinitfs.conf && \
    mkinitfs $(basename $(ls -d /lib/modules/*))
RUN mkdir -p /opt/runcvm/kernels/alpine/$(basename $(ls -d /lib/modules/*)) && \
    cp -a /boot/vmlinuz-virt /opt/runcvm/kernels/alpine/$(basename $(ls -d /lib/modules/*))/vmlinuz && \
    cp -a /boot/initramfs-virt /opt/runcvm/kernels/alpine/$(basename $(ls -d /lib/modules/*))/initrd && \
    cp -a /lib/modules/ /opt/runcvm/kernels/alpine/$(basename $(ls -d /lib/modules/*))/ && \
    chmod -R u+rwX,g+rX,o+rX /opt/runcvm/kernels/alpine

# Build Debian bullseye kernel and initramfs with virtiofs module

FROM amd64/debian:bullseye as debian-kernel

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

# Build Ubuntu bullseye kernel and initramfs with virtiofs module

FROM amd64/ubuntu:latest as ubuntu-kernel

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

# Build RUNCVM installation

FROM alpine

COPY --from=binaries /opt/runcvm /opt/runcvm
COPY --from=init /root/runcvm-init/runcvm-init /root/qemu-exit/qemu-exit /opt/runcvm/sbin/

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
RUN for d in /opt/runcvm/kernels/*; do cd $d && ln -s $(ls -d * | sort | head -n 1) latest; done