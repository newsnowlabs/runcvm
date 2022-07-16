# DKVM README

DKVM (DocKer VM) is an open source Docker container runtime, for launching standard container workloads in VMs.

It makes launching containerised workloads in VMs as easy as launching them in containers.

Like Kata Containers, DKVM aims to be a secure container runtime with lightweight virtual machines that feel and perform like containers, but provide stronger workload isolation using hardware virtualization technology as a second layer of defense.

Unlike Kata Containers, DKVM:
- Uses a lightweight 'wrapper' runtime technology, that makes its code footprint and external dependencies extremely low, its internals extremely simple and easy to tailor for specific purposes. Written almost entirely in shell script. Builds very quickly `docker build`.
- Is compatible with `docker run` (with experimental support for `podman run` today)
- Has some [limitations](#limitations) (see below)

DKVM was born out of difficulties experienced getting the Docker and Podman CLIs to launch Kata Containers, and a belief that launching a containerised workload in a VM shouldn’t need to be so complicated.

## Aims

- Run any standard container workload in a VM using `docker run`: no need to create customised container images
- Run systemd workloads in a VM using `docker run`, including Docker-in-Docker
- Minimal need for `docker run` command line customisation: just add `--runtime=dkvm`.
- VM specs, including kernels, can be customised by modifying defaults, or using optional command-line arguments
- Container start/stop/kill semantics respected, where possible providing clean VM shutdown on stop
- Efficient VM launch using the container filesystem, using virtiofs
- Reproduction of container's network configuration in the VM during VM launch
- VM serial console accessible through `docker run -it`, `docker start -ai` and`docker attach`
- Support for `docker exec` (no `-i` or `-t`)
- DKVM doesn’t aim for perfect security, but improved security compared to the standard container runtime, and as much security as possible without compromising the simplicity of the implementation.

## Use cases

- Running workloads that require increased security
- Running workloads that require a running kernel
- Running or developing applications, like Docker/Docker Swarm, that don't play nicely with containers
- Automated testing of kernels, kernel modules, or applications that must run in VMs

## Install

```
docker run --rm -v /opt/dkvm:/dkvm dkvm
```

## Usage

Just append `--runtime=dkvm` to your `docker run` (or, experimentally, `podman run`) command. e.g.

Launch a vanilla ubuntu VM, with interactive terminal, that will be removed on exit:

```
docker run --runtime=dkvm -it --rm ubuntu
```

Launch a vanilla debian VM, with interactive terminal, that will be removed on exit:

```
docker run --runtime=dkvm -it --rm debian
```

Launch a vanilla debian VM, with interactive terminal, that will be removed on exit:

```
docker run --runtime=dkvm -it --rm alpine
```

Launch nginx, listening on port 80:

```
docker run --runtime=dkvm --rm -p 80:80 nginx
```

## Options

Options are specified using `--env=<DKVM_KEY>=<VALUE>` on the `docker run`
command line.

### Memory

- `-—env=DKVM_DEV_SHM_SIZE=<size>`

### Kernel

- `-—env=DKVM_KERNEL=<dist>/<version>` or -—env=DKVM_KERNEL=<dist>`
- `--env=DKVM_KERNEL_MOUNT_LIB_MODULES=1` - mount DKVM kernel modules over `/lib/modules` instead of `/lib/modules/<kernel-version>` (the default)

### Running Docker in a VM

If running Docker within a VM, it is recommended that `/var/lib/docker` is a dedicated mountpoint. Using DKVM, this can be either a Docker volume, or an ext4, btrfs, or xfs disk.

#### Docker volume mountpoint

To launch a VM with a volume mount, run:

```
docker run --runtime=dkvm --mount=type=volume,src=mydocker1,dst=/var/lib/docker -it <docker-image>
```

### ext4/btrfs/xfs disk mountpoint

To launch a VM with a disk mount, run:

```
docker run --runtime=dkvm --mount=type=volume,src=mydocker1,dst=/volume --env=DKVM_DISKS=ext4,5G,/volume/disk1 -it <docker-image>
```

DKVM will check for existence of /volume/disk1, and if it doesn't find it will create a 5G disk with an ext4 filesystem. It will add the disk to `/etc/fstab`.

### Running overlayfs in the VM without a volume mount - NOT RECOMMENDED

`virtiofsd` must be launched with `-o modcaps=+sys_admin` to allow the VM to mount an overlayfs2 filesystem that is backed by the underlying overlayfs2 filesystem. Doing this is _not recommended_, but can be enabled by launching with this option, which also adds `CAP_SYS_ADMIN` capabilities to the container:

- `--env=DKVM_SYS_ADMIN=1`

## How DKVM works

1. DKVM's 'wrapper' runtime intercepts container create commands, and modifies the specification of the container before calling the standard containerd runc to actually create the container. It determines a suitable kernel, or detects one inside the image. It arranges to mount required code, devices (`/dev/kvm`, `/dev/net/tun`) and kernel modules into the container. It sets the `/dev/shm` size, and adds necessary capabilities (NET_ADMIN). It prepends the DKVM container entrypoint (`dkvm-ctr-entrypoint`) to the container's pre-existing entrypoint.
2. The `dkvm-ctr-entrypoint` is launched within the standard Docker container as PID1. It saves the container's pre-existing entrypoint and command line arguments, environment variables and network configuration. It creates a bridge for each pre-existing container network interface for joining the interface to a VM network interface. It launches `virtiofsd` to serve up the container's root filesystem. It launches a custom `dkvm-ctr-init` process as a new PID1, which in turn calls `dkvm-ctr-qemu` to launch the VM (using [QEMU](https://www.qemu.org/), with the required kernel and with the container’s root filesystem mounted via virtiofs, with the required network interfaces, and with `dkvm-vm-init` as the VM's init process). `dkvm-ctr-init` waits for a TERM signal and, on receiving one, calls `dkvm-ctr-shutdown` (which sends an ACPI shutdown to the VM and tries also to power it down cleanly).
3. The `dkvm-vm-init` script runs within the VM. It reproduces the container’s environment variables and network configuration, then either:
   - backgrounds `dkvm-vm-qemu-ga` and execs the `/sbin/init` process from within the image; or
   - execs DKVM's own init process (busybox init), which supervises `dkvm-vm-qemu-ga` and launches `dkvm-vm-start`, which restores the saved container environment, entrypoint and arguments and executes the entrypoint.
4. DKVM's 'wrapper' runtime also intercepts container exec commands, and modifies the command to execute a wrapper script within the container that uses the QEMU Guest Agent protocol to execute the desired command within the VM.

## Limitations

DKVM currently has the following limitations, which it may be possible to address later:

- `docker run` arguments affecting the container will not all generally have the expected or even a supported effect on the VM. For example, while files and directories can be bind-mounted (and volumes mounted), sockets bind-mounted from the host will not be accessible from within the VM.
- `docker exec` doesn't currently support `-i` or `-t`.
- The exit code of the `docker run` entrypoint is not currently returned.

## DKVM with Dockside

[Dockside](https://dockside.io/) can be used to launch DKVM 'devtainers'. Follow the Dockside instructions for adding the DKVM runtime to your profiles.
