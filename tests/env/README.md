# L1: an environment for testing and developing RunCVM

This directory builds the image for _L1_, a disposable Container/VM in which RunCVM is tested and developed, using RunCVM itself:

| Level | What it is |
|---|---|
| L0 | The host: Docker, KVM with nested virtualisation, and a stock, known-good RunCVM |
| L1 | A RunCVM Container/VM launched on L0 from this image: systemd, Docker and a RunCVM of its own |
| L2 | Container/VMs that L1's RunCVM launches, e.g. by `tests/run` |

L1 has its own root filesystem, so the RunCVM installed in L1's `/opt/runcvm` is independent of L0's. Nothing that L1 runs, builds or installs touches L0's RunCVM or Docker.

The image runs in _dev mode_ when launched with no arguments: a long-lived L1 for interactive use, e.g. with `docker exec`. When launched with arguments, it reports that it does not implement _batch mode_ and powers off with exit status 2 (see [Modes](#modes)).

## Published images

The image is published on GitHub's container registry as `ghcr.io/newsnowlabs/runcvm/images/test-l1`, with these tags:

- `<release>`, e.g. `v1.7.0`: the RunCVM release preinstalled;
- `latest`: published alongside a release's tag, so the most recent of those;
- `sha-<commit>`: the repository commit (its first 12 hex digits) each image was built from.

Each image's labels name its commit (`org.opencontainers.image.revision`) and the RunCVM image preinstalled (`io.github.newsnowlabs.runcvm.image`). Published images do not include [Claude Code](#claude-code).

To launch a published image, give its name in place of `runcvm-l1` in [Launching](#launching), e.g. `ghcr.io/newsnowlabs/runcvm/images/test-l1:v1.7.0`.

## Building

```sh
docker build -t runcvm-l1 tests/env
```

Alternatively, to tag the image as published, `ghcr.io/newsnowlabs/runcvm/images/test-l1:<tag>`, and optionally push it, run:

```sh
tests/env/build.sh [--tag <tag>]... [--runcvm-image <image>] [--push] [-- <docker build option>...]
```

- `--tag` may be given more than once; without it, the tag is `latest`.
- `--runcvm-image` sets the build argument `RUNCVM_IMAGE` (below).
- `--push` also tags the image `sha-<commit>`, and pushes each tag. It requires git and a checkout whose working tree has no uncommitted changes or untracked files, `docker login ghcr.io`, Docker's containerd image store (see the RunCVM README's Building section), and no `CLAUDE_CODE_VERSION`, `REVISION` or `VERSION` build argument. Each pushed tag's index is given the image's `org.opencontainers.image.*` labels as annotations, which GitHub reads to link the package to this repository.
- Arguments after `--` are passed to `docker build`.

`tests/env/build.sh --help` describes the options. To use another image name, e.g. to publish from a fork, set `RUNCVM_L1_IMAGE`. The script sets the build arguments `VERSION`, to the first tag, and `REVISION`, to the repository's commit where there is one, for the image's labels.

Build arguments:

| Argument | Default | Meaning |
|---|---|---|
| `RUNCVM_IMAGE` | `newsnowlabs/runcvm:v1.7.0` | The RunCVM image whose `/opt/runcvm` is preinstalled in L1, for running L2s: the RunCVM a new L1 starts with (see [Limitations](#limitations)). Any image built by `./build/build.sh` may be given, e.g. a local build tagged `newsnowlabs/runcvm:dev`. |
| `DOCKER_VERSION` | `29.9.2` | The version of `docker-ce` and `docker-ce-cli` |
| `CONTAINERD_VERSION` | `2.4.2-3` | The version of `containerd.io` |
| `BUILDX_VERSION` | `0.38.1` | The version of `docker-buildx-plugin` |
| `COMPOSE_VERSION` | `5.7.0` | The version of `docker-compose-plugin` |
| `DOCKER_REPO_FINGERPRINT` | `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`, without spaces | The published fingerprint of the key that signs Docker's apt repository; the build fails if the downloaded key's differs |
| `CLAUDE_CODE_VERSION` | (empty) | If set, the version of Claude Code to install (see [Claude Code](#claude-code)) |
| `CLAUDE_CODE_SHA256` | (empty) | The SHA-256 checksum of that version's `linux-x64` binary; required with `CLAUDE_CODE_VERSION` |
| `REVISION` | (empty) | The repository commit the image is built from, recorded in its `org.opencontainers.image.revision` label; `build.sh` sets it |
| `VERSION` | (empty) | The image's version, recorded in its `org.opencontainers.image.version` label in place of the base image's (Ubuntu's release); `build.sh` sets it to the first tag |

The Docker packages are pinned to versions available in Docker's apt repository for Ubuntu 24.04 (`https://download.docker.com/linux/ubuntu/dists/noble/stable/`), and installed with their `-1~ubuntu.24.04~noble` suffix added.

## Launching

```sh
docker run -d --runtime=runcvm -m 4g --cpus=4 --stop-timeout=120 --name=runcvm-l1 runcvm-l1
docker exec -it -u runcvm runcvm-l1 bash
```

- Launch L1 **without `--init`**: its entrypoint must run as the VM's PID 1, so that it can exec systemd as PID 1. With `--init`, it exits at once with an error and status 2.
- `-m` sets L1's memory, which must accommodate L1's own Docker and every L2 it runs at once. `--cpus` sets its CPUs.
- `--stop-timeout=120` gives L1's systemd time to stop its services, and any L2s, on `docker stop`.
- L0 must have KVM with nested virtualisation enabled (e.g. `/sys/module/kvm_intel/parameters/nested` is `Y`), for L2s to use KVM.

`docker exec` reaches L1 as `root` by default, or as the dev user with `-u runcvm`.

To check that L1 is working, run:

```sh
docker exec runcvm-l1 runcvm-l1-check
```

`runcvm-l1-check` prints `PASS`, `FAIL`, `SKIP` or `NOTE` for each of these, and exits non-zero if any check fails:

- systemd is PID 1;
- the system has finished starting, with no failed units;
- the mode;
- the number of `RUNCVM_L1_*` variables `runcvm-l1-entrypoint` saved to `/etc/runcvm-l1/env` (a `NOTE`);
- dockerd is running, with the `runcvm` runtime;
- `/dev/kvm` exists, or else a notice that L2s must use software emulation;
- the verdict of the unit that loads the KVM modules;
- the destinations of each `RUNCVM_DISKS` disk are mounted from one ext4 filesystem;
- Docker's storage driver is overlayfs, not `vfs`;
- `docker network create --ipv6` works;
- `docker run --rm --runtime=runcvm hello-world` works;
- the `runcvm` user's groups and passwordless sudo.

Its options are:

- `--no-l2`, which skips the `hello-world` check;
- `--disks=<spec>`, which names the `RUNCVM_DISKS` that L1 was launched with, if that isn't the image's default. RunCVM does not pass `RUNCVM_DISKS` on to L1's processes.

`docker stop runcvm-l1` powers L1 off cleanly, and `docker start runcvm-l1` boots it again with its disk (see [Disks](#disks)) as it was. `docker rm -fv runcvm-l1` removes it and its disk.

### Passing settings to L1's services

The image's entrypoint, `runcvm-l1-entrypoint`, saves the environment variables whose names begin `RUNCVM_L1_` to `/etc/runcvm-l1/env`, as a systemd `EnvironmentFile`. A unit reads them with:

```ini
[Service]
EnvironmentFile=/etc/runcvm-l1/env
```

systemd's services do not otherwise see the variables given with `docker run --env`. Each value is saved exactly. A value containing a newline or bytes that are not valid UTF-8, or a variable whose name is not an identifier, cannot be held in an `EnvironmentFile`: such a variable stops L1 from booting, with an error on L1's console and exit status 2.

The entrypoint also saves its arguments to `/etc/runcvm-l1/args`, each followed by a NUL byte (the file is empty when there are none). Both files are root-only (mode `0600`). They are rewritten on every boot, so a file never holds the settings of an earlier `docker run`. They are kept under `/etc`, not `/run`, because systemd mounts a fresh tmpfs on `/run` as it starts.

## Modes

A systemd generator, `runcvm-l1-mode-generator`, chooses L1's mode from `/etc/runcvm-l1/args` as systemd starts, before any ordinary unit:

- **Dev mode** (no arguments): the normal default target, `graphical.target`.
- **Any arguments**: `runcvm-l1-unsupported.target` replaces the default target, so none of the dev-mode services (e.g. Docker) start. Its one service prints a message on L1's console, which `docker logs` shows (see [The console and `docker logs`](#the-console-and-docker-logs)). It writes `2` to `/.runcvm/exitcode`, which RunCVM takes as the Container/VM's exit status, and powers L1 off.

A generator decides the mode before any unit starts. For each further mode it needs only its own case, target and service.

## What the image configures, and why

### Packages

- **Base:** Ubuntu 24.04 LTS (`ubuntu:24.04`).
- **Everyday tools:** systemd, udev, D-Bus, git, Python 3 (for `tests/run`), kmod, iproute2, jq, curl, sudo, procps, psmisc and less.
- **Docker:** Docker CE from Docker's own repository (see [Building](#building)), with the buildx and compose plugins. buildx provides the BuildKit that `./build/build.sh` needs.

During the build, `systemctl` is diverted to a stand-in, `build/systemctl`. No systemd is running, so the stand-in:

- passes the subcommands that edit or read unit files (`enable`, `mask`, `is-enabled`, ...) to the real `systemctl`;
- reports success, doing nothing, for those that need a running systemd.

The base image's `/usr/sbin/policy-rc.d` stops package scripts from starting services. The stand-in, its diversion and `policy-rc.d` are all removed at the end of the build, so packages installed in a running L1 behave as on any systemd host. The apt cache and package lists are cache mounts, for faster rebuilds, and are not in the image.

### RunCVM

The `/opt/runcvm` of `RUNCVM_IMAGE` is copied into the image, and its `runcvm-install-runtime.sh --no-dockerd` registers it in `/etc/docker/daemon.json`.

Before the installer runs, `/etc/init.d/docker` is removed. Otherwise the installer restarts dockerd through it, and then waits indefinitely for a dockerd that cannot run during a build. systemd uses `docker.service`, so L1 does not need the script.

### The dev user

The dev user is `runcvm`:

- uid 1000, in the `sudo` and `docker` groups, with passwordless sudo;
- its password is locked, so it is reached with `docker exec -u runcvm`;
- it replaces the base image's `ubuntu` user, which had uid 1000.

### Disks

```
VOLUME /disks
ENV RUNCVM_DISKS=/disks/l1,/var/lib/docker:/var/lib/containerd:/opt/runcvm:/home,ext4,40G
```

A single disk holds `/var/lib/docker`, `/var/lib/containerd`, `/opt/runcvm` and `/home`, in the default `subdirs` layout (see the RunCVM README's `RUNCVM_DISKS`). Without the disk, these paths would be served over virtiofs:

- `/var/lib/docker` and `/var/lib/containerd`: Docker would fall back to its slow `vfs` storage driver, as overlayfs cannot use virtiofs;
- `/opt/runcvm`: L2s would see L1's RunCVM over a second, nested, virtiofs;
- `/home`: builds and checkouts would be slower than on a block device.

The disk's backing file, `/disks/l1`, is sparse: 40G is a ceiling, and it takes only as much of L0's storage as L1 writes.

Being sparse, the backing file can outgrow the free space on L0's filesystem while L1 runs, and L1's writes to the disk then fail with I/O errors. To reserve the disk's full size on L0 from the start, launch L1 with `prealloc=on` added to the disk's spec (see the RunCVM README's "Preallocated disks"), which also keeps L1's discards (e.g. Ubuntu's weekly `fstrim.timer`) from freeing its blocks again:

```sh
docker run -d --runtime=runcvm -m 4g --cpus=4 --stop-timeout=120 --name=runcvm-l1 \
  --env=RUNCVM_DISKS=/disks/l1,/var/lib/docker:/var/lib/containerd:/opt/runcvm:/home,ext4,40G,prealloc=on runcvm-l1
docker exec runcvm-l1 runcvm-l1-check --disks=/disks/l1,/var/lib/docker:/var/lib/containerd:/opt/runcvm:/home,ext4,40G,prealloc=on
```

`prealloc=on` also applies to an existing disk, which it allocates in full when L1 next starts.

The disk has these consequences:

- **Populated once:** the disk is populated from the image only when it is created, on L1's first boot.
- **Stale after a rebuild:** while the disk exists, an L1 container does not see a rebuilt image's `/opt/runcvm` or `/home`; a new container from the rebuilt image does.
- **Removed by `docker rm -v`:** `VOLUME /disks` gives each L1 container an anonymous volume, which `docker rm -v` (or `-fv`) removes along with the disk. To keep a disk beyond its container, mount a named volume instead: `--mount=type=volume,src=runcvm-l1-disks,dst=/disks`.

Alternatively, a whole-root disk holds the whole of L1's root filesystem, so that everything L1 writes outside volumes goes to the block device:

```sh
docker run -d --runtime=runcvm -m 4g --cpus=4 --stop-timeout=120 --name=runcvm-l1 \
  --env=RUNCVM_DISKS=/disks/root,/,ext4,40G runcvm-l1
docker exec runcvm-l1 runcvm-l1-check --disks=/disks/root,/,ext4,40G
```

A whole-root disk copies the whole image when it is created, and its root, not just the four paths, is stale after an image rebuild. `docker diff`, `docker cp` and `docker commit` on L0 then do not see L1's changes.

### Kernel modules

`runcvm-l1-modules.service` runs early in boot, before Docker. It:

- loads `kvm_intel` or `kvm_amd`, according to the CPU's `vmx` or `svm` flag;
- loads `vhost_net` (needed for `RUNCVM_QEMU_NET_VHOST=1` in L2s) and `tun`, unless already loaded or built in;
- logs each module's state beforehand, after udev has processed its start-up events, which shows whether udev had loaded it already;
- logs a warning, and succeeds, if the CPU has neither flag, i.e. L0 does not offer nested virtualisation.

It does not run where systemd finds itself in a container (`ConditionVirtualization=!container`). `runcvm-l1-check` shows its log.

It does not load `br_netfilter`, which RunCVM does not need ([docs/adr/0001-container-firewall-without-br-netfilter.md](../../docs/adr/0001-container-firewall-without-br-netfilter.md)), so L2s run as on a host without it. Docker loads it in L1 only if L1's dockerd is configured to need it, e.g. with `"userland-proxy": false`. To test RunCVM with it loaded, run `sudo modprobe br_netfilter` in L1; `sudo modprobe -r br_netfilter` unloads it again, once no dockerd configuration needs it.

### IPv6

`ENV RUNCVM_IPV6=1` enables IPv6 in L1's kernel whether or not L1's network on L0 is dual-stack. Without it, RunCVM boots L1's kernel with `ipv6.disable=1` unless L1 has a global IPv6 address. Then L1's dockerd cannot create IPv6 networks, and `tests/run` skips `12-ipv6`.

With IPv6 enabled, L1's dockerd creates IPv6 networks for L2s on an IPv4-only L1 network as well. L2s on such a network reach each other over IPv6, but not beyond L1.

### /tmp

`tmp.mount`, which Ubuntu ships but does not enable, is enabled: systemd mounts a tmpfs on `/tmp` early in boot, holding up to half of L1's memory. Otherwise `/tmp` would be the container's own, served over virtiofs, which is slow for the many small, short-lived files that builds and tests write there, and would load virtiofs. The tmpfs hides anything mounted below `/tmp` in the container, such as a bind mount given with `docker run`.

### Machine ID

`/etc/machine-id` is left empty in the image, so systemd generates a distinct one on each L1's first boot; D-Bus uses the same ID. Without this, every L1 would share the ID of the machine that built the image.

### `docker stop`

On `docker stop`, RunCVM sends L1 an ACPI power-button event. `systemd-logind` handles it with an orderly power-off (`HandlePowerKey=poweroff`, set explicitly in `/etc/systemd/logind.conf.d/90-runcvm-l1.conf`), which stops L1's services and syncs its disk. logind runs in dev mode; it needs D-Bus, udev and the kernel's ACPI power button, all of which L1 has. RunCVM's other ways of stopping a VM, `busybox poweroff` and `kill 1`, do not stop systemd.

### The console and `docker logs`

RunCVM connects the VM's virtio console, `hvc0`, to the container's stdout, so whatever L1 writes to `hvc0` appears in `docker logs` on L0:

- `ENV RUNCVM_KERNEL_APPEND=console=hvc0` makes `hvc0` the kernel's console. `docker logs` then shows kernel errors, systemd's progress through boot and shutdown (`[  OK  ] Started ...`, `[FAILED] Failed to start ...`), and the output of units that write to the console.
- journald forwards messages of level `warning` and above, from every service and the kernel, to `hvc0` (`/etc/systemd/journald.conf.d/90-runcvm-l1.conf`). Lower levels stay in L1's journal (`journalctl`).
- A getty on `hvc0` offers a login prompt, which marks the end of boot.

Two settings override the console:

- **`--env=RUNCVM_KERNEL_APPEND=...`** replaces the image's value, so include `console=hvc0` in it to keep this output.
- **`--env=RUNCVM_DISPLAY_MODE=serial`** puts the VM's console on `ttyS0` instead. Then give `--env=RUNCVM_KERNEL_APPEND=console=ttyS0`.

## Claude Code

Claude Code is installed only when the build is given a version and that version's checksum. The checksum is the `checksum` of `platforms["linux-x64"]` in `https://downloads.claude.ai/claude-code-releases/<version>/manifest.json`:

```sh
v=<version>
sha=$(curl -fsSL https://downloads.claude.ai/claude-code-releases/$v/manifest.json | jq -r '.platforms["linux-x64"].checksum')
docker build -t runcvm-l1 --build-arg CLAUDE_CODE_VERSION=$v --build-arg CLAUDE_CODE_SHA256=$sha tests/env
```

The build checks the downloaded binary against the checksum, installs it as the `runcvm` user's `~/.local/bin/claude`, and configures it to:

- read its API key with `cat /secrets/anthropic-api-key`;
- not update itself.

Supply the key in a file on a read-only bind mount at `/secrets`, readable by uid 1000, never in the image or with `--env`, which `docker inspect` on L0 shows:

```sh
install -d -m 0700 ~/.config/runcvm-l1/secrets
install -m 0400 /dev/null ~/.config/runcvm-l1/secrets/anthropic-api-key   # then write the key into it
docker run -d --runtime=runcvm ... \
  --mount=type=bind,src=$HOME/.config/runcvm-l1/secrets,dst=/secrets,readonly runcvm-l1
```

Run these as a user with uid 1000 on L0, or `chown 1000` the directory and file, so that `runcvm` in L1 can read them. The mount must not be under `/disks`, whose mounts RunCVM makes in the container only, not in the VM.

## Limitations

- **The RunCVM under test:** `tests/run`, from whichever checkout of the repository it is run, exercises the RunCVM installed in L1's `/opt/runcvm`. `RUNCVM_IMAGE` (default: release `v1.7.0`) sets only the RunCVM a new L1 starts with, as `/opt/runcvm` is on L1's disk, which is populated once (see [Disks](#disks)). Tests of behaviour added since the installed RunCVM was built fail or are skipped against it. To test another build, install it in L1: build it with `./build/build.sh --tag <tag>` and install it with `sudo REPO=newsnowlabs/runcvm:<tag> ./runcvm-scripts/runcvm-install-runtime.sh`; or, where only `runcvm-scripts/` differ, copy them into `/opt/runcvm/scripts/`, which affects Container/VMs created afterwards.
- **Batch mode:** this image does not implement it. An L1 launched with arguments powers off with exit status 2.
- **L1's kernel:** this is L0's RunCVM's Ubuntu kernel, as RunCVM chooses for an Ubuntu image.
- **Dockside:** launching L1 from Dockside has not been tested.
