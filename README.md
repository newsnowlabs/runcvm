# RunCVM Container Runtime

## Introduction

RunCVM (Run Container Virtual Machine) is an experimental open-source Docker container runtime for Linux, created by Struan Bartlett at NewsNow Labs, that makes launching standard containerised workloads in VMs as easy as launching them in containers e.g.:

## Quick start

Install:

```sh
curl -s -o - https://raw.githubusercontent.com/newsnowlabs/runcvm/main/runcvm-scripts/runcvm-install-runtime.sh | sudo sh
```

Now launch an nginx VM listening on port 8080:

```console
docker run --runtime=runcvm --name nginx1 --rm -p 8080:80 nginx
```

Launch a MariaDB VM, with 2 cpus and 2G memory, listening on port 3306:

```console
docker run --runtime=runcvm --name mariadb1 --rm -p 3306:3306 --cpus 2 --memory 2G --env=MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb
```

Launch a vanilla ubuntu VM, with interactive terminal:

```console
docker run --runtime=runcvm --name ubuntu1 --rm -it ubuntu
```

Gain another interactive console on `ubuntu1`:

```console
docker exec -it ubuntu1 bash
```

## Why?

RunCVM was born out of difficulties experienced using the Docker and Podman CLIs to launch [Kata Containers v2](https://katacontainers.io/), and a belief that launching containerised workloads in VMs using Docker needn't be so complicated (see the ongoing effort to [re-add OCI CLI commands for docker/podman](https://github.com/kata-containers/kata-containers/issues/722) to Kata v2 to support Docker & Podman; other Kata issues [#3358](https://github.com/kata-containers/kata-containers/issues/3358), [#1123](https://github.com/kata-containers/kata-containers/issues/1123), [#1133](https://github.com/kata-containers/kata-containers/issues/1133), [#3038](https://github.com/kata-containers/runtime/issues/3038); Podman issues [#8579](https://github.com/containers/podman/issues/8579) and [#17070](https://github.com/containers/podman/issues/17070); and Kubernetes issue [#40114](https://github.com/kubernetes/website/issues/40114)).

Like Kata, RunCVM aims to be a secure container runtime with lightweight virtual machines that feel and perform like containers, but provide stronger workload isolation using hardware virtualisation technology.

However, unlike Kata, RunCVM:

- Is compatible with `docker run` *today* (with experimental support for `podman run`).
- Is written almost entirely in shell script, for simplicity, portability and ease of development.
- Uses a lightweight 'wrapper-runtime' technology that subverts the behaviour of the standard container runtime `runc`, making its code footprint and external dependencies extremely small, and its internals extremely simple and easy to understand and tailor for specific purposes.
- Is highly portable among Linux distributions and development platforms providing KVM. It even installs on [GitHub Codespaces](https://github.com/features/codespaces)!

> RunCVM makes some trade-offs in return for this simplicity. See the full list of [features and limitations](#features-and-limitations).

## Contents

- [Introduction](#introduction)
- [Licence](#licence)
- [Project aims](#project-aims)
- [Project ambitions](#project-ambitions)
- [Applications for RunCVM](#applications-for-runcvm)
- [How RunCVM works](#how-runcvm-works)
- [System requirements](#system-requirements)
- [Installation](#installation)
- [Upgrading](#upgrading)
- [Features and Limitations](#features-and-limitations)
- [Kernel selection](#kernel-selection)
- [Option reference](#option-reference)
- [Advanced usage](#advanced-usage)
- [Developing](#developing)
- [Building](#building)
- [Contributing](#contributing)
- [Support](#support)
- [Uninstallation](#uninstallation)
- [Legals](#Legals)

## Licence

RunCVM is free and open-source, licensed under the Apache Licence, Version 2.0. See the [LICENSE](LICENSE) file for details.

## Project aims

- Run any standard container workload in a VM using `docker run` with no need to customise images or the command line (except adding `--runtime=runcvm`)
- Run unusual container workloads, like `dockerd` and `systemd` that will not run in standard container runtimes
- Maintain a similar experience within a RunCVM VM as within a container: process table, network interfaces, stdio, exit code handling should broadly similar to maximise compatibility
- Container start/stop/kill semantics respected, where possible providing clean VM shutdown on stop
- VM console accessible as one would expect using `docker run -it`, `docker start -ai` and `docker attach` (but stderr is not yet separated from stdout)
- Support for `docker exec`
- Good support for most other `docker container` subcommands
- Efficient container startup, by using virtiofs to serve a container's filesystem directly to a VM (instead of unpacking an image into a backing file)
- Improved security compared to the standard container runtime, and as much security as possible without compromising the simplicity of the implementation
- Command-line and image-embedded options for customising the a container's VM specifications, devices, kernel
- Intelligent kernel selection, according to the distribution used in the image being launched
- No external dependencies, except for Docker/Podman and relevant Linux kernel modules (`kvm` and `tun`)

## Project ambitions

- Support multiple network interfaces, when attached to a created (but not yet running) container using `docker network connect`
- Support running foreign-architecture VMs by using QEMU dynamic CPU emulation for the entire VM (instead of the approach used by [https://github.com/multiarch/qemu-user-static](https://github.com/multiarch/qemu-user-static) which uses dynamic CPU emulation for each individual binary)
- Support for QEMU [microvm](https://qemu.readthedocs.io/en/latest/system/i386/microvm.html) or Amazon Firecracker
- More natural console support with independent stdout and stderr channels for `docker run -it`
- Improve VM boot time and other behaviours using custom kernel
- Support for specific hardware e.g. graphics display served via VNC

## Applications for RunCVM

The main applications for RunCVM are:

1. Running and testing applications that:
   - don't work with (or require enhanced privileges to work with) standard container runtimes (e.g. `systemd`, `dockerd`, Docker swarm services, [Kubernetes](https://kubernetes.io/))
   - require a running kernel, or a kernel version or modules not available on the host
   - require specific hardware that can be emulated e.g. disks, graphics displays
2. Running existing container workloads with increased security
3. Testing container workloads that are already intended to launch in VM environments, such as on [fly.io](https://fly.io)
4. Developing any of the above applications in [Dockside](https://dockside.io/) (see [RunCVM and Dockside](#runcvm-and-dockside))

## How RunCVM works

RunCVM's 'wrapper' runtime, `runcvm-runtime`, receives container create commands triggered by `docker` `run`/`create` commands, modifies the configuration of the requested container in such a way that the created container will launch a VM that boots from the container's filesystem, and then passes the request on to the standard container runtime (`runc`) to actually create and start the container.

For a deep dive into RunCVM's internals, see the section on [Developing RunCVM](#developing).

## System requirements

RunCVM should run on any amd64 (x86_64) hardware (or VM) running Linux Kernel >= 5.10, and that supports [KVM](https://www.linux-kvm.org/page/Main_Page) and [Docker](https://docker.com). So if your host can already run [KVM](https://www.linux-kvm.org/page/Main_Page) VMs and [Docker](https://docker.com) then it should run RunCVM.

RunCVM has no other host dependencies, apart from Docker (or experimentally, Podman) and the `kvm` and `tun` kernel modules.

Apart from the above, RunCVM comes packaged with all binaries and libraries it needs to run (including its own QEMU binary).

RunCVM is tested on Debian Bullseye and [GitHub Codespaces](https://github.com/codespaces/new?hide_repo_select=true&ref=main&repo=514606231).

## Installation

Run:

```sh
curl -s -o - https://raw.githubusercontent.com/newsnowlabs/runcvm/main/runcvm-scripts/runcvm-install-runtime.sh | sudo sh
```

This will:
- Install the RunCVM software package to `/opt/runcvm` (installation elsewhere is currently unsupported)
- For Docker support:
  - Enable the RunCVM runtime, by patching `/etc/docker/daemon.json` to add `runcvm` to the `runtimes` property
  - Restart `dockerd`, if it can be detected how for your system (e.g. `systemctl restart docker`)
  - Verify that RunCVM is recognised via `docker info`
- For Podman support (experimental)
  - Display instructions on patching `/etc/containers/containers.conf`

Following installation, launch a basic test RunCVM container/VM:

```console
docker run --runtime=runcvm --rm -it hello-world
```

## Upgrading

To upgrade, follow this procedure:

1. Stop all RunCVM containers.
2. Run `/opt/runcvm/scripts/runcvm-install-runtime.sh` (or rerun the installation command - which runs the same script)
3. Start any RunCVM containers.

## Features and limitations

In the below summary of RunCVM's current main features and limitations, [+] is used to indicate an area of compatibility with standard container runtimes and [-] is used indicate a feature of standard container runtimes that is unsupported.

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
      - [?] `--workdir` (or `-w`) is supported
      - [+] `--env` (or `-e`), `--env-file` is supported
      - [+] `--entrypoint` is supported
      - [+] `--init` - is supported (but runs RunCVM's own VM init process rather than Docker's default, `tini`)
   - stdio/Terminals
      - [+] `--detach` (or `-d`) is supported
      - [+] `--interactive` (or `-i`) is supported
      - [+] `--tty` (or `-t`) is supported (but to enter CTRL-A one must press CTRL-A twice)
      - [+] `--attach` (or `-a`) is supported
      - [+] Stdout and Stderr output should be broadly similar to running the same workload in a standard `runc` container
      - [-] Stdout and Stderr are not independently multiplexed so `docker run --runtime=runcvm debian bash -c 'echo stdout; echo stderr >&2' >/tmp/stdout 2>/tmp/stderr` does not produce the expected result
      - [-] Stdout and Stderr sent very soon after VM launch might be corrupted due to serial console issues
      - [-] Stdout and Stderr sent immediately before VM shutdown might not always be fully flushed
   - Resource allocation and limits
      - [+] `--cpus` is supported to specify number of VM CPUs
      - [+] `--memory` (or `-m`) is supported to specify VM memory
      - [-] Other container resource limit options such as (`--cpu-*`), block IO (`--blkio-*`), kernel memory (`--kernel-memory`) are unsupported or untested
   - Exit code
      - [+] Returning the entrypoint's exit code is supported, but it currently requires application support
      - [-] To return an exit code, your entrypoint may either write its exit code to `/.runcvm/exit-code` (supported exit codes 0-255) or call `/opt/runcvm/sbin/qemu-exit <code>` (supported exit codes 0-127). Automatic handling of exit codes from the entrypoint will be provided in a later version.
   - Disk performance
      - [+] No mountpoints are required for basic operation for most applications. Volume or disk mountpoints may be needed for running `dockerd` or to improve disk performance
      - [-] `dockerd` mileage will vary unless a volume or disk is mounted over `/var/lib/docker`
- `docker exec`
   - [+] `--user` (or `-u`), `--workdir` (or `-w`), `--env` (or `-e`), `--env-file`, `--detach` (or `-d`), `--interactive` (or `-i`) and `--tty` (or `-t`) are all supported
   - [+] Stdout and Stderr _are_ independently multiplexed so `docker exec <container> bash -c 'echo stdout; echo stderr >&2' >/tmp/stdout 2>/tmp/stderr` _does_ produce the expected result
- Security
   - The RunCVM software package at `/opt/runcvm` is mounted read-only within RunCVM containers. Container applications cannot compromise RunCVM, but they can execute binaries from within the RunCVM package. The set of binaries available to the VM may be reduced to a minimum in a later version.
- Kernels
   - [+] Use any kernel, either one pre-packaged with RunCVM or roll your own
   - [+] RunCVM will try to select an appropriate kernel to use based on examination of `/etc/os-release` within the image being launched.

## Kernel auto-detection

When creating a container, RunCVM will examine the image being launched to try to determine a suitable kernel to boot the VM with. Its process is as follows:

1. If `--env=RUNCVM_KERNEL=<dist>[/<version>]` specified, use the indicated kernel
2. Otherwise, identify distro from `/etc/os-release`
   1. If one is found in the appropriate distro-specific location in the image, select an in-image kernel. The locations are:
      - Debian: `/vmlinuz` and `/initrd.img`
      - Ubuntu: `/boot/vmlinuz` and `/boot/initrd.img`
      - Alpine: `/boot/vmlinuz-virt` `/boot/initramfs-virt`
   2. Otherwise, if found in the RunCVM package, select the latest kernel compatible with the distro
   3. Finally, use the Debian kernel from the RunCVM package

## Option reference

RunCVM options are specified either via standard `docker run` options or via  `--env=<RUNCVM_KEY>=<VALUE>` options on the `docker run`
command line. The following env options are user-configurable:

### `--env=RUNCVM_KERNEL=<dist>[/<version>]`

Specify with which RunCVM kernel (from `/opt/runcvm/kernels`) to boot the VM. Values must be of the form `<dist>/<version>`, where `<dist>` is a directory under `/opt/runcvm/kernels` and `<version>` is a subdirectory (or symlink to a subdirectory) under that. If `<version>` is omitted, `latest` will be assumed. Here is an example command that will list available values of `<dist>/<version>` on your installation.

```console
$ find /opt/runcvm/kernels/ -maxdepth 2 | sed 's!^/opt/runcvm/kernels/!!; /^$/d'
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
docker run --rm --runtime=runcvm --env=RUNCVM_KERNEL=ol hello-world
```

### `--env=RUNCVM_KERNEL_APPEND=1`

Any custom kernel command line options e.g. `apparmor=0` or `systemd.unified_cgroup_hierarchy=0`.

### `--env='RUNCVM_DISKS=<disk1>[;<disk2>;...]'`

Automatically create, format and mount backing files as virtual disks on the VM.

Each `<diskN>` should be a comma-separated list of values of the form: `<src>,<dst>,<filesystem>[,<size>]`.

- `<src>` is the path _within the container_ where the virtual disk backing file should be located. This may be in the container's overlayfs or within a volume (mounted using `--mount=type=volume`).
- `<dst>` is the path within the VM where the virtual disk should be mounted.
- `<filesystem>` is the filesystem with which the backing disk should be formatted (using `mke2fs`) when first created.
- `<size>` is the size of the backing file (in `truncate` format), and must be specified if `<src>` does not exist.

When first created, the backing file will be created as a sparse file to the specified `<size>` and formatted with the specified `<filesystem>` using `mke2fs`. When RunCVM creates a container/VM, fstab entries will be drafted. After the VM boots, the fstab entries will be mounted. Typically, the first disk will be mounted as `/dev/vda`, the second as `/dev/vdb`, and so on.

#### Example #1

```console
docker run -it --runtime=runcvm --env=RUNCVM_DISKS=/disk1,/home,ext4,5G <docker-image>
```

In this example, RunCVM will check for existence of a file at `/disk1` within `<docker-image>`, and if not found create a 5G backing file (in the container's filesystem, typically overlay2) with an ext4 filesystem, then add the disk to `/etc/fstab` and mount it within the VM at `/home`.

#### Example #2

```console
docker run -it --runtime=runcvm --mount=type=volume,src=runcvm-disks,dst=/disks --env='RUNCVM_DISKS=/disks/disk1,/home,ext4,5G;/disks/disk2,/opt,ext4,2G' <docker-image>
```

This example behaves similarly, except that the `runcvm-disks` persistent Docker volume is first mounted at `/disks` within the container's filesystem, and therefore the backing files at `/disks/disk1` and `/disks/disk2` (mounted in the VM at `/home` and `/opt` respectively) are stored in the _persistent volume_ (typically stored in `/var/lib/docker` on the host, bypassing overlay2).

> N.B. `/disks` and any paths below it are _reserved mountpoints_. Unlike other mountpoints,
these are *NOT* mounted into the VM but only into the container,
and are therefore suitable for use for mounting backing files for use as VM disks.

### `--env=RUNCVM_QEMU_DISPLAY=<value>`

Select a specific QEMU display. Currently only `curses` is supported, but others may trivially be added by customising the build.

### `--env=RUNCVM_SYS_ADMIN=1`

By default, `virtiofsd` is not launched with `-o modcaps=+sys_admin` (and containers are not granted `CAP_SYS_ADMIN`). Use this option if you need to change this.

### `--env=RUNCVM_KERNEL_MOUNT_LIB_MODULES=1`

If a RunCVM kernel (as opposed to an in-image kernel) is chosen to launch a VM, by default that kernel's modules will be mounted at `/lib/modules/<version>` in the VM. If this variables is set, that kernel's modules will instead be mounted over `/lib/modules`.

### `--env=RUNCVM_KERNEL_DEBUG=1`

Enable kernel logging (sets kernel `console=ttyS0`).

### `--env=RUNCVM_BIOS_DEBUG=1`

By default BIOS console output is hidden. Enable it with this option.

### `--env=RUNCVM_RUNTIME_DEBUG=1`

Enable debug logging for the runtime (the portion of RunCVM directly invoked by `docker run`, `docker exec` etc).
Debug logs are written to files in `/tmp`.

### `--env=RUNCVM_BREAK=<values>`

Enable breakpoints (falling to bash shell) during the RunCVM container/VM boot process.

`<values>` must be a comma-separated list of: `prenet`, `postnet`, `preqemu`.

## Advanced usage

### Running Docker in a RunCVM container/VM

#### ext4 disk backing file mounted at `/var/lib/docker`

If running Docker within a VM, it is recommended that you make `/var/lib/docker` a dedicated disk mountpoint (currently only ext4), to avoid `dockerd` electing to use the extremely sub-performant `vfs` storage driver.

e.g. To launch a VM with a disk mount, backed by a 5G file in the `runcvm-disks` volume, run:

```sh
docker run -it --runtime=runcvm --mount=type=volume,src=runcvm-disks,dst=/disks --env=RUNCVM_DISKS=/disks/docker,/var/lib/docker,ext4,5G <docker-image>
```

RunCVM will check for existence of a file `/disks/docker` in the `runcvm-disks` volume, and if not found will create a 5G file-backed disk with an ext4 filesystem. It will add the disk to `/etc/fstab`.

For full documentation of `RUNCVM_DISKS`, see above.

#### Docker volume mounted at `/var/lib/docker` (NOT RECOMMENDED)

Doing this is _not recommended_, but support for this can be enabled (at the cost of security) by launching with `--env=RUNCVM_SYS_ADMIN=1`.

e.g. 

```sh
docker run --runtime=runcvm --mount=type=volume,src=mydocker1,dst=/var/lib/docker --env=RUNCVM_SYS_ADMIN=1 <docker-image>
```

> N.B. This option adds `CAP_SYS_ADMIN` capabilities to the container and then launches `virtiofsd` with `-o modcaps=+sys_admin`. 

## Developing

The following deep dive should help explain the inner workings of RunCVM, and which files to modify to implement fixes, improvements and extensions.

### runcvm-runtime

RunCVM's 'wrapper' runtime, `runcvm-runtime`, intercepts container `create` and `exec` commands and their specifications in JSON format (`config.json` and `process.json` respectively) that are normally provided (by `docker` `run`/`create` and `docker exec` respectively) to a standard container runtime like `runc`.

The JSON file is parsed to retrieve properties of the command, and is modified to allow RunCVM to piggyback by overriding the originally intended behaviour with new behaviour.

The modifications to `create` are designed to make the created container launch a VM that boots off the container's filesystem, served using `virtiofsd`.

The modifications to `exec` are designed to run commands within the VM instead of the container.

#### `runcvm-runtime` - `create` command

In more detail, the RunCVM runtime `create` process:
- Modifies the `config.json` file to:
   - Modify the container's entrypoint, to prepend `runcvm-ctr-entrypoint` to the container's original entrypoint and if an `--init` argument was detected, remove any init process and set the container env var `RUNCVM_INIT` to `1`
   - Set the container env var `RUNCVM_UIDGID` to `<uid>:<gid>:<additionalGids>` as intended for the container, then resets both the `<uid>` and `<gid>` to `0`.
   - Set the container env var `RUNCVM_CPUS` to the intended `--cpus` count so it can be passed to the VM
   - Extract and delete all requested tmpfs mounts (these will be independently mounted by the VM).
   - Add a bind mount from `/` to `/vm` that will recursively mount the following preceding mounts:
      - A bind mount from `/opt/runcvm` on the host to `/opt/runcvm` in the container.
      - A tmpfs mounted at `/.runcvm`
   - Add a tmpfs at `/run` in the container only.
   - Map all requested bind mounts from their original mountpoint `<mnt>` to `/vm/<mnt>` (except where `<mnt>` is at or below `/disks`).
   - Determine a suitable VM launch kernel by looking for one inside the container's image, choosing a stock RunCVM kernel matching the image, or according to an env var argument.
      - Add a bind mount to `/vm/lib/modules/<version>` for the kernel's modules
      - Set container env vars `RUNCVM_KERNEL_PATH`, `RUNCVM_KERNEL_INITRAMFS_PATH` and `RUNCVM_KERNEL_ROOT`
   - Add device mounts for `/dev/kvm` and `/dev/net/tun`.
   - Set the seccomp profile to 'unconfined'.
   - Set `/dev/shm` to the size desired for the VM's memory and set container env var accordingly.
   - Add necessary capabilities, if not already present (`NET_ADMIN`, `NET_RAW`, `MKNOD`, `AUDIT_WRITE`).
   - Only if requested by `--env=SYS_ADMIN=1`, add the `SYS_ADMIN` capability.
- Executes the standard container runtime `runc` with the modified `config.json`.

The `runcvm-ctr-entrypoint`:
- Is always launched as PID1 within the standard Docker container.
- Saves the container's originally-intended entrypoint and command line, environment variables and network configuration to files inside `/.runcvm`.
- Creates a bridge for the primary container network interface, that will be joined to a VM network interface.
- Launches `virtiofsd` to serve the container's root filesystem.
- Configures `/etc/resolv.conf` in the container.
- Adds container firewall rules, launches `dnsmasq` and modifies `/vm/etc/resolv.conf` to proxy DNS requests from the VM to Docker's DNS.
- Execs RunCVM's own `runcvm-init` init process to supervise `runcvm-ctr-qemu` to launch the VM.

The `runcvm-init` process:
- Is RunCVM's custom init process, that takes over as PID1 within the container, supervising `runcvm-ctr-qemu` to launch the VM.
- Waits for a TERM signal. On receiving one, it spawns `runcvm-ctr-shutdown`, which cycles through a number of methods to try to shut down the VM cleanly.
- Waits for its child (QEMU) to exit. When it does, execs `runcvm-ctr-exit` to retrieve any saved exit code (written by the application to `/.runcvm/exit-code`) and exit with this code.

The `runcvm-ctr-qemu` script:
- Prepares disk backing files as specified by `--env=RUNCVM_DISKS=<disks>`
- Launches [QEMU](https://www.qemu.org/) with the required kernel, network interfaces, disks, display, and with a root filesystem mounted via virtiofs from the container and with `runcvm-vm-init` as the VM's init process.

The `runcvm-vm-init` process:
- Runs as PID1 within the VM.
- Retrieves the container configuration - network, environment, disk and tmpfs mounts - saved by `runcvm-ctr-entrypoint` to `/.runcvm`, and reproduces it within the VM
- Launches the container's pre-existing entrypoint, in one of two ways.
   1. If `RUNCVM_INIT` is `1` (i.e. the container was originally intended to be launched with Docker's own init process) then it configures and execs busybox `init`, which becomes the VM's PID1, to supervise `dropbear`, run `runcvm-vm-start` and `poweroff` the VM if signalled to do so.
   2. Else, it backgrounds `dropbear`, then execs (via `runcvm-init`, purely to create a controlling tty) `runcvm-vm-start`, which runs as the VM's PID1.

The `runcvm-vm-start` script:
- Restores the container's originally-intended environment variables, `<uid>`, `<gid>`, `<additionalGids>` and `<cwd>`, and execs that entrypoint.

#### `runcvm-runtime` - `exec` command

The RunCVM runtime `exec` process:

- Modifies the `process.json` file to:
   - Retrieve the intended `<uid>`, `<gid>`, `<additionalGids>`, `<terminal>` and `<cwd>` for the command, as well as <hasHome> indicating the existence of a HOME environment variable.
   - Resets both the `<uid>` and `<gid>` to `0` and the `<cwd>` to `/`.
   - Prepend `runcvm-ctr-exec '<uid>:<gid>:<additionalGids>' '<cwd>' '<hasHome>' '<terminal>'` to the originally intended command.
- Executes the standard container runtime `runc` with the modified `process.json`.

The `runcvm-ctr-exec` script:
- Uses the Dropbear `dbclient` SSH client to execute the intended command, with the intended arguments within the VM, via the `runcvm-vm-exec` process, propagate the returned stdout and stderr and return the command's exit code.

## Building

Building RunCVM requires Docker. To build RunCVM, first clone the repo, then run the build script, as follows:

```console
cd runcvm
./build/build.sh
```

The build script creates a Docker image named `newsnowlabs/runcvm:latest`.

Now follow the main [installation instructions](#installation) to install your built RunCVM from the Docker image.

## Support

**Support launching images:** If you encounter any Docker image that launches in a standard container runtime that does not launch in RunCVM, or launches but with unexpected behaviour, please [raise an issue](https://github.com/newsnowlabs/runcvm/issues) titled _Launch failure for image `<image>`_ or _Unexpected behaviour for image `<image>`_ and include log excerpts and an explanation of the failure, or expected and unexpected behaviour.

**For all other issues:** please still [raise an issue](https://github.com/newsnowlabs/runcvm/issues)

You can also reach out to us on the [NewsNow Labs Slack Workspace](https://join.slack.com/t/newsnowlabs/shared_invite/zt-wp54l05w-0DTxuc_n8uISJRtks3Xw3A).

We are typically available to respond to queries Monday-Friday, 9am-5pm UK time, and will be happy to help.

## Contributing

If you would like to contribute a feature suggestion or code, please raise an issue or submit a pull request.

## Uninstallation

Shut down any RunCVM containers.

Then run `sudo rm -f /opt/runcvm`.

## RunCVM and Dockside

RunCVM and [Dockside](https://dockside.io/) are designed to work together in two alternative ways.

1. Dockside can be used to launch devtainers (development environments) in RunCVM VMs, allowing you to provision containerised online IDEs for developing applications like `dockerd`, Docker swarm, `systemd`, applications that require a running kernel, or kernel modules not available on the host, or specific hardware e.g. a graphics display. Follow the instructions for adding a runtime to your [Dockside profiles](https://github.com/newsnowlabs/dockside/blob/main/docs/setup.md#profiles).
2. Dockside can itself be launched inside a RunCVM VM with its own `dockerd` to provide increased security and compartmentalisation from a host. e.g.

```
docker run --rm -it --runtime=runcvm  --memory=2g --name=docksidevm -p 443:443 -p 80:80 --mount=type=volume,src=dockside-data,dst=/data --mount=type=volume,src=dockside-disks,dst=/disks --env=RUNCVM_DISKS=/disks/disk1,/var/lib/docker,ext4,5G newsnowlabs/dockside --run-dockerd --ssl-builtin
```

## Legals

This project (known as "RunCVM"), comprising the files in this Git repository
(but excluding files containing a conflicting copyright notice and licence),
is copyright 2023 NewsNow Publishing Limited, Struan Bartlett, and contributors.

RunCVM is an open-source project licensed under the Apache License, Version 2.0
(the "License"); you may not use RunCVM or its constituent files except in
compliance with the License.

You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0).

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

> N.B. In order to run, RunCVM relies upon other third-party open-source software dependencies that are separate to and independent from RunCVM and published under their own independent licences.
>
> RunCVM Docker images made available at [https://hub.docker.com/repository/docker/newsnowlabs/runcvm](https://hub.docker.com/repository/docker/newsnowlabs/runcvm) are distributions
> designed to run RunCVM that comprise: (a) the RunCVM project source and/or object code; and
> (b) third-party dependencies that RunCVM needs to run; and which are each distributed under the terms
> of their respective licences.
