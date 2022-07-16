# DKVM README

DKVM (DocKer VM) is an open source Docker container runtime, for launching standard container workloads in VMs.

It makes launching containerised workloads in VMs as easy as launching them in containers.

Like Kata Containers, DKVM aims to be a secure container runtime with lightweight virtual machines that feel and perform like containers, but provide stronger

Unlike Kata Containers, DKVM:
- Uses a lightweight 'wrapper' runtime technology, that makes its code footprint and external dependencies extremely low, its internals extremely simple and e
- Is compatible with `docker run` (with experimental support for `podman run` today)
- Has some limitations (see below)

DKVM was born out of difficulties experienced getting the Docker and Podman CLIs to launch Kata Containers, and a belief that launching a containerised worklo

## Aims

- Run any standard container workload in a VM using `docker run`: no need to create customised container images
- Run systemd workloads in a VM using `docker run`, including Docker-in-Docker
- Minimal need for `docker run` command line customisation: just add --runtime=dkvm.
- VM specs, including kernels, can be customised by modifying defaults, or using optional command-line arguments
- Container start/stop/kill semantics respected, where possible providing clean VM shutdown on stop
- Efficient VM launch using the container filesystem, using virtiofs
- Reproduction of container's network configuration in the VM during VM launch
- VM serial console accessible through ‘docker run -it’, ‘docker start -ai’ and`docker attach`
- Support for `docker exec` (no `-i` or `-t`)
- DKVM doesn’t aim for perfect security, but improved security compared to the standard container runtime, and as much security as possible without compromisi

## Use cases

- Running workloads that require increased security
- Running workloads that require a running kernel
- Running or developing applications, like Docker/Docker Swarm, that don't play nicely with containers
- Automated testing of kernels, kernel modules, or applications that must run in VMs

## How DKVM works

- DKVM's 'wrapper' runtime intercepts container create commands, and modifies the specification of the container before calling the standard containerd runc t
- The dkvm-ctr-entrypoint is launched within the standard Docker container. It saves the container's pre-existing entrypoint and command line arguments, envir
- The dkvm-vm-init script runs within the VM. It reproduces the container’s environment variables and network configuration, then launches an init process tha
- DKVM's 'wrapper' runtime also intercepts container exec commands, and modifies the command to execute a wrapper script within the container that uses the QE

## Limitations

DKVM currently has the following limitations, which it may be possible to address later:

- `docker run` arguments affecting the container will not all generally have the expected or even a supported effect on the VM. For example, while files and d
- `docker exec` doesn't currently support `-i` or `-t`.

## Options

Options are specified using `--env=<DKVM_KEY>=<VALUE>` on the `docker run`
command line.

- `--env=DKVM_SYS_ADMIN=1`
- `-—env=DKVM_KERNEL=<dist>/<version>` or -—env=DKVM_KERNEL=<dist>`
- `-—env=DKVM_DEV_SHM_SIZE=<size>`
- `--env=DKVM_KERNEL_MOUNT_LIB_MODULES=1` - mount DKVM kernel modules over `/lib/modules` instead of `/lib/modules/<kernel-version>` (the default)
