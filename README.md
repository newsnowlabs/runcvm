# DKVM README

DKVM (DocKer VM) is an open source Docker container runtime for launching standard container workloads in VMs.

DKVM makes launching containerised workloads in VMs as easy as launching them in containers e.g.:

```console
docker run --runtime=dkvm --rm -it -p 80 nginx
```

Like Kata Containers, DKVM aims to be a secure container runtime with lightweight virtual machines that feel and perform like containers, but provide stronger workload isolation using hardware virtualisation technology as a second layer of defence.

Unlike Kata Containers, DKVM:

- Uses a lightweight 'wrapper' runtime technology that makes its code footprint and external dependencies extremely small, its internals extremely simple and easy to tailor for specific purposes. Written almost entirely in shell script. Builds very quickly with `docker build`
- Is compatible with `docker run` (with experimental support for `podman run` today)
- Has some [limitations](#limitations) (see below)

DKVM was born out of difficulties experienced getting the Docker and Podman CLIs to launch Kata Containers, and a belief that launching a containerised workload in a VM needn't be so complicated.

## Aims

- Run any standard container workload in a VM using `docker run` with almost no command line customisation: no need to create customised container images; just add `--runtime=dkvm`.
- Maintain a similar experience within a DKVM VM as within a container: process table, network interfaces, exit code handling should broadly "look the same"
- Container start/stop/kill semantics respected, where possible providing clean VM shutdown on stop
- VM serial console accessible as one would expect using `docker run -it`, `docker start -ai` and`docker attach`
- Support for `docker exec` (but no `-i` or `-t` for now - see [limitations](#limitations))
- Support for `docker commit`
- Prioritise container/VM start efficiency, by using virtiofs to serve the container's filesystem to the VM
- Improved security compared to the standard container runtime, and as much security as possible without compromising the simplicity of the implementation.
- Command-line and image-embedded options for customising the a container's VM specifications, devices, kernel

## Applications

- Running workloads that require increased security
- Running workloads that require a running kernel
- Running or developing applications, like Docker daemon, Docker Swarm, and systemd, and kernel modules, that don't play nicely with containers
- Automated testing of kernels, kernel modules, or applications that must run in VMs

## Installation

Install the DKVM software package at /opt/dkvm (it cannot be installed elsewhere):

```console
docker run --rm -v /opt/dkvm:/dkvm dkvm
```

Enable the DKVM runtime for Docker, by running the following to add `"dkvm": { "path": "/opt/dkvm/scripts/dkvm" }` to the `runtimes` property of `/etc/docker/daemon.json`:

```console
sudo /opt/dkvm/scripts/install.sh
```

Lastly, restart docker, and confirm DKVM is recognised:

```console
$ docker info | grep -i dkvm
 Runtimes: runc dkvm io.containerd.runc.v2 io.containerd.runtime.v1.linux
```

## Usage

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

Launch nginx, listening on port 80:

```console
docker run --runtime=dkvm --rm -p 80:80 nginx
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

## How DKVM works

1. DKVM's 'wrapper' runtime intercepts container create commands, and modifies the specification of the container before calling the standard containerd runc to actually create the container. It determines a suitable kernel, or detects one inside the image. It arranges to mount required code, devices (`/dev/kvm`, `/dev/net/tun`) and kernel modules into the container. It sets the `/dev/shm` size, and adds necessary capabilities (NET_ADMIN). It prepends the DKVM container entrypoint (`dkvm-ctr-entrypoint`) to the container's pre-existing entrypoint.
2. The `dkvm-ctr-entrypoint` is launched within the standard Docker container as PID1. It saves the container's pre-existing entrypoint and command line arguments, environment variables and network configuration. It creates a bridge for each pre-existing container network interface for joining the interface to a VM network interface. It launches `virtiofsd` to serve up the container's root filesystem. It launches a custom `dkvm-ctr-init` process as a new PID1, which in turn calls `dkvm-ctr-qemu` to launch the VM (using [QEMU](https://www.qemu.org/), with the required kernel and with the container’s root filesystem mounted via virtiofs, with the required network interfaces, and with `dkvm-vm-init` as the VM's init process). `dkvm-ctr-init` waits for a TERM signal and, on receiving one, calls `dkvm-ctr-shutdown` (which sends an ACPI shutdown to the VM and tries also to power it down cleanly). When its child (QEMU) exits, it execs `dkvm-ctr-exit` to retrieve any saved exit code and exit.
3. The `dkvm-vm-init` script runs within the VM. It reproduces the container’s environment variables and network configuration, then either:
   - backgrounds `dkvm-vm-qemu-ga` and execs the `/sbin/init` process from within the image; or
   - execs DKVM's own init process (busybox init), which supervises `dkvm-vm-qemu-ga` and launches `dkvm-vm-start`, which restores the saved container environment, entrypoint and arguments and executes the entrypoint.
4. DKVM's 'wrapper' runtime also intercepts container exec commands, and modifies the command to execute a wrapper script within the container that uses the QEMU Guest Agent protocol to execute the desired command within the VM.

## Limitations

DKVM currently has the following limitations, which it may be possible to address later:

- `docker run` arguments affecting the container will not all generally have the expected or even a supported effect on the VM. For example, while files and directories can be bind-mounted (and volumes mounted), sockets bind-mounted from the host will not be accessible from within the VM.
- `docker exec` doesn't currently support `-i` or `-t`. This may be fixed in a later version.
- Returning an exit code from the `docker run` entrypoint currently needs application support: your application may either write its exit code to `/.dkvm/exitcode` (supported exit codes 0-255) or call `/opt/dkvm/sbin/qemu-exit <code>` (supported exit codes 0-127). Automatic handling of exit codes from the entrypoint will be provided in a later version.
- The DKVM software package at `/opt/dkvm` is mounted read-only within DKVM containers. Container applications cannot compromise DKVM, but they can execute binaries from within the DKVM package. This may be fixed in a later version.

## DKVM with Dockside

[Dockside](https://dockside.io/) can be used to launch DKVM 'devtainers'. Follow the Dockside instructions for adding the DKVM runtime to your profiles.
