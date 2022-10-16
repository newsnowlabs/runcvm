# DKVM Container Runtime

## Introduction

DKVM (DocKer VM) is an experimental open-source Docker container runtime for Linux, created by Struan Bartlett at NewsNow Labs, that makes launching standard containerised workloads in VMs as easy as launching them in containers e.g.:

Launch an nginx VM listening on port 8080:

```console
docker run --runtime=dkvm --name nginx1 --rm -it -p 8080:80 nginx
```

Launch a MariaDB VM, with 4 cores and 2G memory, listening on port 13306:

```console
docker run --runtime=dkvm --name mariadb1 --rm -it -p 13306:3306 --cpus 2 --memory 2G --env=MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb
```

Launch a vanilla ubuntu VM, with interactive terminal:

```console
docker run --runtime=dkvm --name ubuntu1 --rm -it ubuntu
```

DKVM aims to be a secure container runtime with lightweight virtual machines that feel and perform like containers, but provide stronger workload isolation using hardware virtualisation technology. In this sense, DKVM has similar aims to [Kata Containers](https://katacontainers.io/).

However, DKVM:

- Uses a lightweight 'wrapper-runtime' technology that makes its code footprint and external dependencies extremely small, its internals extremely simple and easy to tailor for specific purposes.
- Is written almost entirely in shell script, for ease of comprehension and modification.
- Is compatible with `docker run` (with experimental support for `podman run` today).
- Has no external dependencies (except for Docker/Podman).

DKVM makes some trade-offs in return for this simplicity. See the full list of [features and limitations](#features-and-limitations).

DKVM was born out of difficulties experienced getting the Docker and Podman CLIs to launch Kata Containers, and a belief that launching containerised workloads in VMs needn't be so complicated.

## Contents

- [Introduction](#introduction)
- [Licence](#licence)
- [Project aims](#project-aims)
- [How DKVM works](#how-dkvm-works)
- [System requirements](#system-requirements)
- [Installation](#installation)
- [Features and Limitations](#features-and-limitations)
- [Kernel selection](#kernel-selection)
- [Option reference](#option-reference)
- [Advanced usage](#advanced-usage)
- [Upgrading](#upgrading)
- [DKVM deep dive](#dkvm-deep-dive)
- [Building](#building)
- [Contributing](#contributing)
- [Support](#support)
- [Uninstallation](#uninstallation)
- [Legals](#Legals)

## Licence

DKVM is free and open-source, licensed under the Apache Licence, Version 2.0. See the [LICENSE](LICENSE) file for details.

## Project aims

- Run any standard container workload in a VM using `docker run` with no need to customise images or the command line (except adding `--runtime=dkvm`)
- Run unusual container workloads, like `dockerd` and `systemd` that will not run in standard container runtimes
- Maintain a similar experience within a DKVM VM as within a container: process table, network interfaces, stdio, exit code handling should broadly similar to maximise compatibility
- Container start/stop/kill semantics respected, where possible providing clean VM shutdown on stop
- VM console accessible as one would expect using `docker run -it`, `docker start -ai` and `docker attach` (but stderr is not yet separated from stdout)
- Support for `docker exec` (but no `-i`, `-t` for now - see [Features and Limitations](#features-and-limitations))
- Good support for most other `docker container` subcommands
- Efficient container startup, by using virtiofs to serve a container's filesystem directly to a VM (instead of unpacking an image into a backing file)
- Improved security compared to the standard container runtime, and as much security as possible without compromising the simplicity of the implementation
- Command-line and image-embedded options for customising the a container's VM specifications, devices, kernel
- Intelligent kernel selection, according to the distribution used in the image being launched
- No external dependencies, except for Docker/Podman

Project ambitions:

- Run foreign-architecture VMs by using QEMU dynamic CPU emulation for the entire VM (instead of the approach used by [https://github.com/multiarch/qemu-user-static](https://github.com/multiarch/qemu-user-static) which uses dynamic CPU emulation for each individual binary)

Applications for DKVM include:

- Running and testing applications, like `dockerd` (Docker daemon), Docker swarm, and `systemd`, that don't work with (or require enhanced privileges to work with) standard container runtimes like `runc`, that require a running kernel, or kernel modules not available on the host
- Running existing container workloads with increased security
- Testing container workloads that are already intended to launch in VM environments, such as on [fly.io](https://fly.io)
- Developing any of the above applications, using [Dockside](https://dockside.io/)

## DKVM and Dockside

DKVM and [Dockside](https://dockside.io/) are designed to work together in two very different ways.

1. Dockside can be used to launch devtainers (development environments) in DKVM VMs, allowing you to provision containerised online IDEs for developing applications like `dockerd`, Docker swarm, and kernel modules. Follow the instructions for adding a runtime to your [Dockside profiles](https://github.com/newsnowlabs/dockside/blob/main/docs/setup.md#profiles).
2. Dockside can be launched inside a DKVM VM with its own `dockerd` to provide increased security and compartmentalisation from the host. e.g. `docker run --rm -it --runtime=dkvm  --memory=2g --name=docksidevm -p 443:443 -p 80:80 --mount=type=volume,src=dockside-data,dst=/data --mount=type=volume,src=dockside-disks,dst=/disks --env=DKVM_DISKS=/disks/disk1,/var/lib/docker,ext4,5G newsnowlabs/dockside --run-dockerd --ssl-builtin`

## How DKVM works

DKVM's 'wrapper' runtime, `dkvm-runtime`, receives container create commands triggered by `docker run`, modifies the configuration of the requested container in such a way that the created container will launch a VM that boots from the container's filesystem, and then passes the request on to the standard container runtime (`runc`) to actually create and start the container.

## System requirements

DKVM should run on any amd64 (x86_64) Linux hardware (or VM) that supports [KVM](https://www.linux-kvm.org/page/Main_Page) and [Docker](https://docker.com). So if your host can already run [KVM](https://www.linux-kvm.org/page/Main_Page) VMs and [Docker](https://docker.com) then it should run DKVM.

DKVM has no host dependencies, apart from Docker (or experimentally, Podman) and comes packaged with all binaries and libraries it needs to run (including its own QEMU binary).

## Installation

Install the DKVM software package at `/opt/dkvm` (installation elsewhere is currently unsupported):

```console
docker run --rm -v /opt/dkvm:/dkvm newsnowlabs/dkvm
```

Patch `/etc/docker/daemon.json` to enable the DKVM runtime:

```console
sudo /opt/dkvm/scripts/dkvm-install-runtime.sh
```

(The above command adds `"dkvm": {"path": "/opt/dkvm/scripts/dkvm-runtime"}` to the `runtimes` property of `/etc/docker/daemon.json`.)

Lastly, restart docker, and confirm DKVM is recognised:

```console
$ docker info | grep -i dkvm
 Runtimes: runc dkvm io.containerd.runc.v2 io.containerd.runtime.v1.linux
```

Then run a test DKVM container:

```console
docker run --runtime=dkvm --rm -it hello-world
```

## Features and limitations

In the below summary of DKVM's current main features and limitations, [+] is used to indicate an area of compatibility with standard container runtimes and [-] is used indicate a feature of standard container runtimes that is unsupported.

> N.B. `docker run` and `docker exec` options not listed below are unsupported and their effect, if used, is unspecified.

- `docker run`
   - Mounts
      - [+] `--mount` (or `-v`) is supported for volume mounts, tmpfs mounts, and host file and directory bind-mounts (the `dst` mount path `/disks` is reserved)
      - [-] Bind-mounting host sockets or devices, and `--device` is unsupported
   - Networking
      - [+] The default bridge network is supported
      - [+] Custom/user-defined networks specified using `--network` are supported, including Docker DNS resolution of container names
      - [+] `--publish` (or `-p`) is supported
      - [+] `--dns`, `--dns-option`, `--dns-search` are supported
      - [+] `--ip` is supported
      - [+] `--hostname` (or `-h`) is supported
      - [-] Only one network (that which is assigned during `docker run`) is supported per container. There is no support for `docker network connect`.
      - [-] `--network=host` and `--network=container:name|id` are not supported
   - Execution environment
      - [+] `--user` (or `-u`) is supported
      - [?] `--workdir` (or `-w`) is supported FIXME
      - [+] `--env` (or `-e`), `--env-file` is supported
      - [+] `--entrypoint` is supported
      - [+] `--init` - is supported (but runs DKVM's own VM init process rather than Docker's default, `tini`)
   - stdio/Terminals
      - [+] `--detach` (or `-d`) is supported
      - [+] `--interactive` (or `-i`) is supported
      - [+] `--tty` (or `-t`) is supported
      - [+] `--attach` (or `-a`) is supported
      - [+] Stdout and Stderr output should be broadly similar to running the same workload in a standard `runc` container
      - [-] Stdout and Stderr are not independently multiplexed so `docker run --runtime=dkvm debian bash -c 'echo stdout; echo stderr >&2' >/tmp/stdout 2>/tmp/stderr` does not produce the expected result
      - [-] Stdout and Stderr sent very soon after VM launch might be corrupted due to serial console issues
      - [-] Stdout and Stderr sent immediately before VM shutdown might not always be fully flushed
   - Resource allocation and limits
      - [+] `--cpus` is supported to specify number of VM CPUs
      - [+] `--memory` (or `-m`) is supported to specify VM memory
      - [-] Other container resource limit options such as (`--cpu-*`), block IO (`--blkio-*`), kernel memory (`--kernel-memory`) are unsupported or untested
   - Exit code
      - [+] Returning the entrypoint's exit code is supported, but it currently requires application support
      - [-] To return an exit code, your entrypoint may either write its exit code to `/.dkvm/exit-code` (supported exit codes 0-255) or call `/opt/dkvm/sbin/qemu-exit <code>` (supported exit codes 0-127). Automatic handling of exit codes from the entrypoint will be provided in a later version.
   - Disk performance
      - [+] No mountpoints are required for basic operation for most applications. Volume or disk mountpoints may be needed for running `dockerd` or to improve disk performance
      - [-] `dockerd` mileage will vary unless a volume or disk is mounted over `/var/lib/docker`
- `docker exec`
   - [+] `--user` (or `-u`), `--workdir` (or `-w`), `--env` (or `-e`), `--env-file`, `--detach` (or `-d`) are supported
   - [-] `--interactive` (or `-i`) and `--tty` (or `-t`) are not currently supported (there currently being no support for interactive terminals other than the container's launch terminal)
- Security
   - The DKVM software package at `/opt/dkvm` is mounted read-only within DKVM containers. Container applications cannot compromise DKVM, but they can execute binaries within the DKVM package. The set of binaries available to the VM may be reduced to a minimum in a later version.
- Kernels
   - [+] Use any kernel, either one pre-packaged with DKVM or roll your own
   - [+] DKVM will try to select an appropriate kernel to use based on examination of `/etc/os-release` within the image being launched.

## Kernel auto-detection

When creating a container, DKVM will examine the image being launched to try to determine a suitable kernel to boot the VM with. Its process is as follows:

1. If `--env=DKVM_KERNEL=<dist>[/<version>]` specified, use the indicated kernel
2. Otherwise, identify distro from `/etc/os-release`
   1. If one is found in the appropriate distro-specific location in the image, select an in-image kernel. The locations are:
      - Debian: `/vmlinuz` and `/initrd.img`
      - Ubuntu: `/boot/vmlinuz` and `/boot/initrd.img`
      - Alpine: `/boot/vmlinuz-virt` `/boot/initramfs-virt`
   2. Otherwise, if found in the DKVM package, select the latest kernel compatible with the distro
   3. Finally, use the Debian kernel from the DKVM package

## Option reference

DKVM options are specified either via standard `docker run` options or via  `--env=<DKVM_KEY>=<VALUE>` options on the `docker run`
command line. The following env options are user-configurable:

### `--env=DKVM_KERNEL=<dist>[/<version>]`

Specify with which DKVM kernel (from `/opt/dkvm/kernels`) to boot the VM. Values must be of the form `<dist>/<version>`, where `<dist>` is a directory under `/opt/dkvm/kernels` and `<version>` is a subdirectory (or symlink to a subdirectory) under that. If `<version>` is omitted, `latest` will be assumed. Here is an example command that will list available values of `<dist>/<version>` on your installation.

```console
$ find /opt/dkvm/kernels/ -maxdepth 2 | sed 's!^/opt/dkvm/kernels/!!; /^$/d'
debian
debian/latest
debian/5.10.0-16-amd64
alpine
alpine/latest
alpine/5.15.59-0-virt
ubuntu
ubuntu/latest
ubuntu/5.15.0-43-generic
ol
ol/5.14.0-70.22.1.0.1.el9_0.x86_64
ol/latest
```

Example:

```console
docker run --rm --runtime=dkvm --env=DKVM_KERNEL=ol hello-world
```

### `--env=DKVM_KERNEL_DEBUG=1`

Enable kernel logging (sets kernel `console=ttyS0`).

### `--env=DKVM_BREAK=<values>`

Enable breakpoints (falling to bash shell) during the DKVM container/VM boot process.

`<values>` must be a comma-separated list of: `prenet`, `postnet`, `preqemu`.

### `--env=DKVM_DISKS=<disk1>[;<disk2>;...]`

Automatically create, format and mount backing files as virtual disks on the VM.

Each `<diskN>` should be a comma-separated list of values of the form: `<src>,<dst>,<filesystem>,<size>`.

- `<src>` is the path _within the container_ where the virtual disk backing file should be located. This may be in the container's overlayfs or within a volume (mounted using `--mount=type=volume`).
- `<dst>` is the path within the VM where the virtual disk should be mounted.
- `<filesystem>` is the filesystem with which the backing disk should be formatted (using `mke2fs`) when first created.
- `<size>` is the size of the backing file (in `truncate` format).

When first created, the backing file will be created as a sparse file to the specified `<size>` and formatted with the specified `<filesystem>` using `mke2fs`. When DKVM creates a container/VM, fstab entries will be drafted. After the VM boots, the fstab entries will be mounted.

#### Example #1

```console
docker run -it --runtime=dkvm --env=DKVM_DISKS=/disk1,/home,ext4,5G <docker-image>
```

In this example, DKVM will check for existence of a file at `/disk1` within <docker-image>, and if not found create a 5G backing file (in the container's filesystem, typically overlay2) with an ext4 filesystem, then add the disk to `/etc/fstab` and mount it within the VM.

#### Example #2

```console
docker run -it --runtime=dkvm --mount=type=volume,src=dkvm-disks,dst=/disks --env=DKVM_DISKS=/disks/disk1,/home,ext4,5G <docker-image>
```

This example behaves similarly, except that the `dkvm-disks` persistent Docker volume is first mounted at `/disks` within the container's filesystem, and therefore the backing file at `/disks/disk1` is stored in the persistent volume (and bypassing overlay2).

> N.B. `/disks` and any paths below it are _reserved mountpoints_. Unlike other mountpoints, these is *NOT* mounted into the VM but only into the container,
and are therefore suitable for use for mounting backing files for use as VM disks.

### `--env=DKVM_QEMU_DISPLAY=<value>`

Select a specific QEMU display. Currently only `curses` is supported, but others may trivially be added by customising the build.

### `--env=DKVM_BIOS_DEBUG=1`

By default BIOS console output is hidden. Enable it with this option.

### `--env=DKVM_SYS_ADMIN=1`

By default, `virtiofsd` is not launched with `-o modcaps=+sys_admin` (and containers are not granted `CAP_SYS_ADMIN`). Use this option if you need to change this.

### `--env=DKVM_KERNEL_MOUNT_LIB_MODULES=1`

If a DKVM kernel (as opposed to an in-image kernel) is chosen to launch a VM, by default that kernel's modules will be mounted at `/lib/modules/<version>` in the VM. If this variables is set, that kernel's modules will instead be mounted over `/lib/modules`.

## Advanced usage

### Running Docker in a VM

If running Docker within a VM, it is recommended that you make `/var/lib/docker` a dedicated mountpoint. Using DKVM, this can be either a Docker volume, or an ext4, btrfs, or xfs disk.

#### Docker volume mountpoint

To launch a VM with a volume mount, run:

```console
docker run --runtime=dkvm --mount=type=volume,src=mydocker1,dst=/var/lib/docker <docker-image>
```

### ext4/btrfs/xfs disk mountpoint

To launch a VM with a disk mount, backed by a 5G file in the `mydocker2` volume, run:

```console
docker run -it --runtime=dkvm --mount=type=volume,src=mydocker2,dst=/volume --env=DKVM_DISKS=/volume/disk1,/var/lib/docker,ext4,5G <docker-image>
```

DKVM will check for existence of /volume/disk1, and if it doesn't find it will create a 5G disk with an ext4 filesystem. It will add the disk to `/etc/fstab`.

### Running overlayfs in the VM without a volume mount - NOT RECOMMENDED

`virtiofsd` must be launched with `-o modcaps=+sys_admin` to allow the VM to mount an overlayfs2 filesystem that is backed by the underlying overlayfs2 filesystem. Doing this is _not recommended_, but can be enabled by launching with this option, which also adds `CAP_SYS_ADMIN` capabilities to the container:

- `--env=DKVM_SYS_ADMIN=1`

## Upgrading

To upgrade, follow this procedure:

1. Stop all DKVM containers.
2. Run `/opt/dkvm/scripts/dkvm-upgrade.sh`
3. Start any DKVM containers.

## DKVM deep dive

### dkvm-runtime

DKVM's 'wrapper' runtime, `dkvm-runtime`, receives container create commands, and modifies the configuration of the requested container before calling the standard container runtime (`runc`) to actually create the container.

The modifications are designed to make the created container launch a VM that boots off the container's filesystem.

The DKVM runtime:
- Determines a suitable kernel, by looking for one inside the container's image, or choosing a stock DKVM kernel matching the image.
- Arranges to mount required code, devices (`/dev/kvm`, `/dev/net/tun`) and kernel modules into the container. 
- Sets `/dev/shm` to the size desired for the VM's memory.
- Adds necessary capabilities, if not already present (`NET_ADMIN`, `NET_RAW`, `MKNOD`, `AUDIT_WRITE`).
- Sets the seccomp profile to 'unconfined'.
- Prepends the DKVM container entrypoint, `dkvm-ctr-entrypoint`, to the container's pre-existing entrypoint.
- Executes the standard container runtime `runc`.

The DKVM runtime also:
- Receives container exec commands, and modifies the requested command line to run `dkvm-ctr-exec` within the container. It uses the QEMU Guest Agent protocol to execute the desired command within the VM and return stdout and stderr.
- Passes all other commands directly through to `runc` unchanged.

The `dkvm-ctr-entrypoint`:
- Is always launched as PID1 within the standard Docker container.
- Saves the container's pre-existing entrypoint and command line arguments, environment variables and network configuration to a tmpfs filesystem.
- Creates a bridge for each container network interface, that will be joined to a VM network interface.
- Launches `virtiofsd` to serve up the container's root filesystem.
- Execs `dkvm-init`.

The `dkvm-init` process:
- Is a custom init process, that takes over as PID1 within the standard Docker container, supervising the launch of the VM.
- Calls `dkvm-ctr-qemu` to launch the VM (using [QEMU](https://www.qemu.org/), with the specified kernel, the required network interfaces, with the container’s root filesystem mounted via virtiofs, with the required network interfaces, and with `dkvm-vm-init` as the VM's init process.
- Waits for a TERM signal. On receiving one, it spawns `dkvm-ctr-shutdown` (which sends an ACPI shutdown to the VM and tries also to power it down cleanly).
- Waits for its child (QEMU) to exit. When it does, execs `dkvm-ctr-exit` to retrieve any saved exit code (written by the application to `/.dkvm/exit-code`) and exits with this code.

The `dkvm-vm-init` process:
- Runs as PID1 within the VM.
- Reproduces the container’s network configuration, restores the saved environment variables, then launches the container's pre-existing entrypoint, in one of two ways.
   1. If that entrypoint is an init process within the container (e.g. `/sbin/init`), it backgrounds `dkvm-vm-qemu-ga` and execs the `/sbin/init`. The new entrypoint becomes the VM's PID1.
   2. Otherwise, it execs `/opt/dkvm/bin/init`, DKVM's own init process (currently busybox init), which becomes the VM's PID1.

The `/opt/dkvm/bin/init` process:
- Runs as PID1 within the VM.
- Supervises `dkvm-vm-qemu-ga`, restarting it if it fails.
- Launches `dkvm-vm-start`, which restores the saved environment variables, and execs the container's pre-existing entrypoint _within the VM_. When it exits, it is respawned to power down the VM.

## Building

Building DKVM requires Docker. To build DKVM, first clone the repo, then run the build script, as follows:

```console
git clone https://github.com/newsnowlabs/dkvm.git
cd dkvm
./build/build.sh
```

The build script creates a Docker image named `newsnowlabs/dkvm:latest`.

Follow the main [installation instructions](#installation) to install your built DKVM from the Docker image.

## Contributing

If you would like to contribute a feature or bugfix, please raise an issue to discuss, or submit a pull request.

## Support

If you are experiencing an issue, please [raise an issue](https://github.com/newsnowlabs/dkvm/issues) or reach out to us on the [NewsNow Labs Slack Workspace](https://join.slack.com/t/newsnowlabs/shared_invite/zt-wp54l05w-0DTxuc_n8uISJRtks3Xw3A).

We are typically available to respond to queries Monday-Friday, 9am-5pm UK time, and will be happy to help.

## Uninstallation

Shut down any DKVM containers.

Then run `sudo rm -f /opt/dkvm`.

## Legals

This project (known as "DKVM"), comprising the files in this Git repository
(but excluding files containing a conflicting copyright notice and licence),
is copyright 2022 NewsNow Publishing Limited and contributors.

DKVM is an open-source project licensed under the Apache License, Version 2.0
(the "License"); you may not use DKVM or its constituent files except in
compliance with the License.

You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0).

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

> N.B. In order to run, DKVM relies upon other third-party open-source software dependencies that are separate to and independent from DKVM and published under their own independent licences.
>
> DKVM Docker images made available at [https://hub.docker.com/repository/docker/newsnowlabs/dkvm](https://hub.docker.com/repository/docker/newsnowlabs/dkvm) are distributions
> designed to run DKVM that comprise: (a) the DKVM project source and/or object code; and
> (b) third-party dependencies that DKVM needs to run; and which are each distributed under the terms
> of their respective licences.
