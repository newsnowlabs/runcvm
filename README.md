# DKVM Container Runtime

## Introduction

DKVM (DocKer VM) is an open source Docker container runtime, developed by NewsNow Labs, that launches standard container workloads in VMs.

DKVM makes launching containerised workloads in VMs as easy as launching them in containers e.g.:

```console
docker run --runtime=dkvm --rm -it -p 80 nginx
```

DKVM aims to be a secure container runtime with lightweight virtual machines that feel and perform like containers, but provide stronger workload isolation using hardware virtualisation technology as a second layer of defence. In this sense, DKVM has similar aims to [Kata Containers](https://katacontainers.io/).

However, DKVM:

- Uses a lightweight 'wrapper' runtime technology that makes its code footprint and external dependencies extremely small, its internals extremely simple and easy to tailor for specific purposes. Written almost entirely in shell script. Builds very quickly with `docker build`
- Is compatible with `docker run` (with experimental support for `podman run` today)
- Has some [limitations](#limitations) (see below)

DKVM was born out of difficulties experienced getting the Docker and Podman CLIs to launch Kata Containers, and a belief that launching a containerised workload in a VM needn't be so complicated.

## Contents

- [Licence](#licence)
- [Project aims](#project-aims)
- [How DKVM works](#how-dkvm-works)
- [Installation](#installation)
- [Using DKVM](#using-dkvm)
- [Limitations](#limitations)
- [Upgrading](#upgrading)
- [Contributing](#contributing)
- [Uninstallation](#uninstallation)
- [DKVM and Dockside](#dkvm-and-dockside)

## Licence

DKVM is free and open-source, licensed under the Apache Licence, Version 2.0. See the [LICENSE](LICENSE) file for details.

## Project aims

- Run any standard container workload in a VM using `docker run` with almost no command line customisation: no need to create customised container images; just add `--runtime=dkvm`.
- Maintain a similar experience within a DKVM VM as within a container: process table, network interfaces, exit code handling should broadly "look the same"
- Container start/stop/kill semantics respected, where possible providing clean VM shutdown on stop
- VM serial console accessible as one would expect using `docker run -it`, `docker start -ai` and`docker attach`
- Support for `docker exec` (but no `-i` or `-t` for now - see [limitations](#limitations))
- Support for `docker commit`
- Prioritise container/VM start efficiency, by using virtiofs to serve the container's filesystem to the VM
- Improved security compared to the standard container runtime, and as much security as possible without compromising the simplicity of the implementation.
- Command-line and image-embedded options for customising the a container's VM specifications, devices, kernel

Applications for DKVM include:

- Running container workloads that require increased security
- Running container workloads that require a running kernel
- Running applications, like Docker daemon, Docker swarm, and systemd, and kernel modules, that don't play nicely with the default container runtime `runc`
- Automated testing of kernels, kernel modules, or any application that must run in VMs. e.g. A load-balancing Docker swarm.
- Developing applications that require a VM to run. [Dockside](https://dockside.io/) can be used to launch DKVM 'devtainers'. Follow the Dockside instructions for adding the DKVM runtime to your profiles.

## How DKVM works

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

## Installation

Install the DKVM software package at /opt/dkvm (it cannot be installed elsewhere):

```console
docker run --rm -v /opt/dkvm:/dkvm dkvm
```

Enable the DKVM runtime for Docker:

```console
sudo /opt/dkvm/scripts/install.sh
```

The above command adds `"dkvm": {"path": "/opt/dkvm/scripts/dkvm-runtime"}` to the `runtimes` property of `/etc/docker/daemon.json`.

Lastly, restart docker, and confirm DKVM is recognised:

```console
$ docker info | grep -i dkvm
 Runtimes: runc dkvm io.containerd.runc.v2 io.containerd.runtime.v1.linux
```

## Using DKVM

Just append `--runtime=dkvm` to your `docker run` (or, experimentally, `podman run`) command. e.g.

Launch a vanilla ubuntu VM, with interactive terminal, that will be removed on exit:

```console
docker run --runtime=dkvm -it --rm ubuntu
```

Launch a vanilla debian VM, that will be removed on exit:

```console
docker run --runtime=dkvm --name=t1 debian bash -c 'apt update && apt -y install procps'
docker commit -c 'CMD ["/bin/bash"]' t1 debian-t1
docker run --name=t2 --runtime=dkvm -it --rm debian-t1
```

Launch a vanilla debian VM, with interactive terminal, that will be removed on exit:

```console
docker run --runtime=dkvm -it --rm alpine
```

Launch nginx in a VM, listening on port 8080:

```console
docker run --runtime=dkvm --rm -p 8080:80 nginx
```

## Options

Options are specified using `--env=<DKVM_KEY>=<VALUE>` on the `docker run`
command line.

### Memory

- `DKVM_DEV_SHM_SIZE=<size>`

### Kernel

DKVM will examine the image to try and determine a suitable kernel to boot the VM with. The process is as follows:

1. Identify distro from `/etc/os-release`
2. Select an in-image kernel, if found in the following distro-specific location:
   - Debian: `/vmlinuz` and `/initrd.img`
   - Ubuntu: `/boot/vmlinuz` and `/boot/initrd.img`
   - Alpine: `/boot/vmlinuz-virt` `/boot/initramfs-virt`
3. Select the latest DKVM kernel for the distro, if available
4. Select the kernel indicated by setting the `DKVM_KERNEL` environment variable for the container,
   which may be set to `<distro>` (indicating the latest DKVM kernel for that distro)
   or to `<distro>/<version>` (indicating a specific version).
   - Look in `/opt/dkvm/kernels` to see the bundled DKVM kernels
   - Example values for `DKVM_KERNEL` are `alpine/latest`, `alpine/5.15.55-0-virt`, `debian/latest`

- `DKVM_KERNEL_MOUNT_LIB_MODULES=1` - mount DKVM kernel modules over `/lib/modules` instead of (the default) `/lib/modules/<kernel-version>`

### Running Docker in a VM

If running Docker within a VM, it is recommended that `/var/lib/docker` is a dedicated mountpoint. Using DKVM, this can be either a Docker volume, or an ext4, btrfs, or xfs disk.

#### Docker volume mountpoint

To launch a VM with a volume mount, run:

```console
docker run --runtime=dkvm --mount=type=volume,src=mydocker1,dst=/var/lib/docker -it <docker-image>
```

### ext4/btrfs/xfs disk mountpoint

To launch a VM with a disk mount, run:

```console
docker run --runtime=dkvm --mount=type=volume,src=mydocker1,dst=/volume --env=DKVM_DISKS=ext4,5G,/volume/disk1 -it <docker-image>
```

DKVM will check for existence of /volume/disk1, and if it doesn't find it will create a 5G disk with an ext4 filesystem. It will add the disk to `/etc/fstab`.

### Running overlayfs in the VM without a volume mount - NOT RECOMMENDED

`virtiofsd` must be launched with `-o modcaps=+sys_admin` to allow the VM to mount an overlayfs2 filesystem that is backed by the underlying overlayfs2 filesystem. Doing this is _not recommended_, but can be enabled by launching with this option, which also adds `CAP_SYS_ADMIN` capabilities to the container:

- `--env=DKVM_SYS_ADMIN=1`

## Limitations

DKVM currently has the following limitations, which it may be possible to address later:

- `docker run` arguments affecting the container will not all generally have the expected or even a supported effect on the VM. For example, while files and directories can be bind-mounted (and volumes mounted), sockets bind-mounted from the host will not be accessible from within the VM.
- `docker exec` doesn't currently support `-i` or `-t`. This may be fixed in a later version.
- Returning an exit code from the `docker run` entrypoint currently needs application support: your application may either write its exit code to `/.dkvm/exit-code` (supported exit codes 0-255) or call `/opt/dkvm/sbin/qemu-exit <code>` (supported exit codes 0-127). Automatic handling of exit codes from the entrypoint will be provided in a later version.
- The DKVM software package at `/opt/dkvm` is mounted read-only within DKVM containers. Container applications cannot compromise DKVM, but they can execute binaries from within the DKVM package. This may be fixed in a later version.
