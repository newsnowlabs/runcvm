# syntax=docker/dockerfile:1

# L1: the disposable outer Container/VM in which RunCVM tests itself, launched with stock RunCVM
# as a Container/VM on L0 (the bare-metal host). See README.md in this directory.

# The RunCVM image whose /opt/runcvm is preinstalled: the RunCVM that L1 runs L2s with.
ARG RUNCVM_IMAGE=newsnowlabs/runcvm:v1.7.0

FROM ${RUNCVM_IMAGE} AS runcvm

FROM ubuntu:24.04

SHELL ["/bin/bash", "-e", "-o", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive

# Docker CE packages, from Docker's apt repository, at pinned versions (without the
# "-1~ubuntu.24.04~noble"-style suffix, which is added for the base image's release).
ARG DOCKER_VERSION=29.9.2
ARG CONTAINERD_VERSION=2.4.2-3
ARG BUILDX_VERSION=0.38.1
ARG COMPOSE_VERSION=5.7.0

# The published fingerprint of the signing key of Docker's apt repository.
ARG DOCKER_REPO_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

# Build-time set-up, undone at the end of the build:
# - the base image's docker-clean apt setting is removed, as it would empty the apt cache mount;
# - no systemd is running during the build, so systemctl is diverted to a stand-in,
#   build/systemctl, which passes only the subcommands that edit or read unit files (enable, mask,
#   is-enabled, ...) to the real systemctl, and reports success for the rest. Package scripts that call systemctl
#   directly therefore neither fail nor start services. The diversion must name the path the
#   systemd package lists, /usr/bin/systemctl in Ubuntu 24.04: dpkg ignores a diversion of the
#   other path, even though /bin links to /usr/bin. The check after the packages are installed
#   fails the build if the stand-in was not in place.
COPY --chmod=755 build/systemctl /usr/local/lib/build/systemctl
RUN <<_EOE_
rm -f /etc/apt/apt.conf.d/docker-clean
dpkg-divert --local --rename --add /usr/bin/systemctl
ln -s /usr/local/lib/build/systemctl /usr/bin/systemctl
_EOE_

# The apt cache and package lists are cache mounts. Of /var/lib/apt, only lists/ is, so that apt's
# record of which packages were installed as dependencies stays in the image.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<_EOE_
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  dbus \
  git \
  gpg \
  iproute2 \
  jq \
  kmod \
  less \
  procps \
  psmisc \
  python3 \
  sudo \
  systemd \
  udev

curl -fsSL -o /tmp/docker.asc https://download.docker.com/linux/ubuntu/gpg
fpr=$(gpg --show-keys --with-colons /tmp/docker.asc | awk -F: '$1 == "fpr" { print $10; exit }')
if [ "$fpr" != "$DOCKER_REPO_FINGERPRINT" ]; then
  echo "Docker's apt key has fingerprint '$fpr', expected '$DOCKER_REPO_FINGERPRINT'" >&2
  exit 1
fi
install -d -m 0755 /etc/apt/keyrings
gpg --dearmor </tmp/docker.asc >/etc/apt/keyrings/docker.gpg
rm /tmp/docker.asc

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
  >/etc/apt/sources.list.d/docker.list
suffix="~ubuntu.$VERSION_ID~$VERSION_CODENAME"
apt-get update
apt-get install -y --no-install-recommends \
  containerd.io="$CONTAINERD_VERSION$suffix" \
  docker-buildx-plugin="$BUILDX_VERSION-1$suffix" \
  docker-ce="5:$DOCKER_VERSION-1$suffix" \
  docker-ce-cli="5:$DOCKER_VERSION-1$suffix" \
  docker-compose-plugin="$COMPOSE_VERSION-1$suffix"

[ "$(readlink -f /usr/bin/systemctl)" = /usr/local/lib/build/systemctl ] && [ -x /usr/bin/systemctl.distrib ]
_EOE_

# The dev user, runcvm, takes uid 1000 from the base image's ubuntu user. Its password is locked:
# it is reached with 'docker exec -u runcvm', and has passwordless sudo.
RUN <<_EOE_
userdel --remove ubuntu
useradd --uid 1000 --user-group --create-home --shell /bin/bash --groups sudo,docker runcvm
passwd --lock runcvm
echo 'runcvm ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/runcvm
chmod 0440 /etc/sudoers.d/runcvm
_EOE_

# Stock RunCVM, registered with L1's Docker. The installer restarts dockerd through
# /etc/init.d/docker if that exists, and then waits indefinitely for a dockerd that cannot start
# during a build; systemd's docker.service does not need it.
COPY --from=runcvm /opt/runcvm /opt/runcvm
RUN rm -f /etc/init.d/docker && \
    sh /opt/runcvm/scripts/runcvm-install-runtime.sh --no-dockerd

# Claude Code (optional): installed for the runcvm user when CLAUDE_CODE_VERSION is set, with
# CLAUDE_CODE_SHA256 the SHA-256 of that version's linux-x64 binary (from the version's
# manifest.json; see README.md). It reads its API key from /secrets/anthropic-api-key, a read-only
# mount, and does not update itself.
ARG CLAUDE_CODE_VERSION=
ARG CLAUDE_CODE_SHA256=
RUN <<_EOE_
[ -n "$CLAUDE_CODE_VERSION" ] || exit 0
if [ -z "$CLAUDE_CODE_SHA256" ]; then
  echo "CLAUDE_CODE_VERSION needs CLAUDE_CODE_SHA256" >&2
  exit 1
fi
curl -fsSL -o /tmp/claude \
  "https://downloads.claude.ai/claude-code-releases/$CLAUDE_CODE_VERSION/linux-x64/claude"
echo "$CLAUDE_CODE_SHA256  /tmp/claude" | sha256sum -c -
install -d -o runcvm -g runcvm /home/runcvm/.local /home/runcvm/.local/bin
install -o runcvm -g runcvm -m 0755 /tmp/claude /home/runcvm/.local/bin/claude
rm /tmp/claude
install -d -o runcvm -g runcvm -m 0700 /home/runcvm/.claude
jq -n '{apiKeyHelper: "cat /secrets/anthropic-api-key", env: {DISABLE_AUTOUPDATER: "1"}}' \
  >/home/runcvm/.claude/settings.json
chown runcvm:runcvm /home/runcvm/.claude/settings.json
_EOE_

COPY rootfs/ /
COPY README.md /usr/local/share/doc/runcvm-l1/README.md

# One sparse disk, in the /disks volume, holding the paths that should not be served over
# virtiofs: Docker's and containerd's storage (overlayfs cannot use virtiofs), the RunCVM that
# L1 runs L2s with (which would otherwise be nested virtiofs) and /home.
VOLUME /disks
ENV RUNCVM_DISKS=/disks/l1,/var/lib/docker:/var/lib/containerd:/opt/runcvm:/home,ext4,40G

# IPv6 in L1's kernel, whether or not L1's network on L0 is dual-stack.
ENV RUNCVM_IPV6=1

# The kernel's console is the VM's virtio console, hvc0, which RunCVM connects to the container's
# stdout, so that 'docker logs' on L0 shows systemd's progress through boot and shutdown, kernel
# errors, and the output of units writing to the console.
ENV RUNCVM_KERNEL_APPEND=console=hvc0

# Units, and what must differ per L1 or be absent at run time:
# - tmp.mount, which Ubuntu ships but does not enable, mounts a tmpfs on /tmp, which would
#   otherwise be the container's own /tmp, served over virtiofs;
# - /etc/machine-id is left empty, for systemd to generate one on each L1's first boot, and D-Bus
#   uses it;
# - the build-time systemctl stand-in and the base image's policy-rc.d, which stops package
#   scripts starting services, are removed, so that packages installed in L1 behave as on any
#   systemd host;
# - runcvm-l1-check finds the default RUNCVM_DISKS in /usr/local/share/runcvm-l1/disks, as
#   RunCVM does not pass RUNCVM_DISKS on to L1's processes.
RUN <<_EOE_
systemctl enable runcvm-l1-modules.service
systemctl enable /usr/share/systemd/tmp.mount
: >/etc/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /usr/sbin/policy-rc.d /usr/bin/systemctl
dpkg-divert --local --rename --remove /usr/bin/systemctl
rm -rf /usr/local/lib/build
systemctl --version >/dev/null
mkdir -p /usr/local/share/runcvm-l1
echo "$RUNCVM_DISKS" >/usr/local/share/runcvm-l1/disks
_EOE_

WORKDIR /home/runcvm

# Must run as the VM's PID 1: launch without --init.
ENTRYPOINT ["/usr/local/sbin/runcvm-l1-entrypoint"]

# OCI labels. GitHub links the image's package on ghcr.io to the repository named by 'source', and
# shows 'description'; build.sh in this directory gives each pushed tag's index the
# org.opencontainers.image.* labels as annotations, which GitHub reads in place of labels where a
# tag names an index. 'revision' is the repository commit the image was built from (build
# argument REVISION, which build.sh sets), 'version' the image's first tag (build argument VERSION,
# which build.sh sets; it replaces the base image's own 'version', Ubuntu's release), and
# io.github.newsnowlabs.runcvm.image the RunCVM image preinstalled. They come last, so that a change
# of commit rebuilds no earlier step.
ARG RUNCVM_IMAGE
ARG REVISION=
ARG VERSION=
LABEL org.opencontainers.image.source="https://github.com/newsnowlabs/runcvm" \
      org.opencontainers.image.description="L1: a RunCVM Container/VM, with systemd, Docker and RunCVM preinstalled, for testing and developing RunCVM" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.version="${VERSION}" \
      io.github.newsnowlabs.runcvm.image="${RUNCVM_IMAGE}"
