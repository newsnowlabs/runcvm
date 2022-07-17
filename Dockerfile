# Build the package of distribution-independent binaries and libraries

FROM alpine:edge as binaries

RUN apk update && \
    apk add --no-cache file bash qemu-system-x86_64 qemu-virtiofsd qemu-ui-curses qemu-guest-agent jq iproute2 netcat-openbsd

RUN apk add --no-cache patchelf --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community

# See also https://universe2.us/epoch.html
# RUN apk add --no-cache klibc-utils --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing

# Patch all binaries and dynamic libraries for full portability.
COPY build-utils/elf-patcher.sh /usr/local/bin/elf-patcher.sh

ENV BINARIES="busybox bash jq ip nc qemu-system-x86_64 qemu-ga /usr/lib/qemu/*"
ENV CODE_PATH="/opt/dkvm"
RUN /usr/local/bin/elf-patcher.sh
RUN bash -c 'cd /opt/dkvm/bin; for cmd in sh cat cut awk chmod grep head mount route sysctl ps init poweroff mkdir ls hostname tr getty login touch rm base64; do ln -s busybox $cmd; done'

RUN mkdir -p /opt/dkvm/usr/share && cp -a /usr/share/qemu /opt/dkvm/usr/share

# BUILD CONTAINER INIT
FROM alpine:edge as init

RUN apk update && \
    apk add --no-cache gcc musl-dev

ADD dumb-init /root/init
RUN cd /root/init && cc -o /root/dumb-init -std=gnu99 -static -s -Wall -Werror -O3 dumb-init.c

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

# Build DKVM installation

FROM alpine

COPY --from=binaries /opt/dkvm /opt/dkvm
COPY --from=alpine-kernel /opt/dkvm/kernels/alpine /opt/dkvm/kernels/alpine
COPY --from=debian-kernel /opt/dkvm/kernels/debian /opt/dkvm/kernels/debian
COPY --from=init /root/dumb-init /opt/dkvm/sbin/dumb-init

RUN for d in /opt/dkvm/kernels/*; do cd $d && ln -s $(ls -d * | sort | head -n 1) latest; done

ADD dkvm-scripts/* /opt/dkvm/scripts/

ADD build-utils/entrypoint-install.sh /
ENTRYPOINT ["/entrypoint-install.sh"]
