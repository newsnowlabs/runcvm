# A k3s cluster of RunCVM Container/VMs

`compose.yaml` runs a three-node [k3s](https://k3s.io/) cluster, each node a RunCVM Container/VM booted from the stock `rancher/k3s` image: a server (which also runs workloads) and two agents, on one Docker network. Each node is a VM with its own kernel, so its containerd, kube-proxy and flannel use kernel features (overlayfs, netfilter, bridging, VXLAN) as on any other machine, without `--privileged` and without touching the host's firewall.

`test` runs it as an integration test (`tests/run 52-k3s-cluster`); this directory also serves as an example to run by hand.

## Running it

On a host with RunCVM installed:

```sh
cd tests/52-k3s-cluster
docker compose up -d
docker compose exec server kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes
```

The nodes are Ready within a minute or so. The cluster's own images (the pause sandbox and CoreDNS) are pulled by each node on first use, or can be loaded into every node beforehand from the host, as the test does: `docker compose create`, then `docker save $(grep -v '^#' images.txt) | docker run --rm -i -v runcvm-k3s_images:/images busybox:1.37 sh -c 'cat >/images/images.tar'` (k3s imports archives in `/var/lib/rancher/k3s/agent/images` as it starts), then `docker compose up -d`.

Deploy the test's workload, a web server on each node behind a ClusterIP Service and a NodePort Service on port 30080, and reach it from the Docker network:

```sh
docker compose exec -T server kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml apply -f - <manifest.yaml
docker run --rm --network runcvm-k3s_default busybox:1.37 wget -qO- http://agent-1:30080/
```

The volume and network names begin with the Compose project name, `runcvm-k3s` unless `K3S_PROJECT` sets another.

Remove the cluster, with its disks and the images volume:

```sh
docker compose down --volumes
```

## Settings

Environment variables that `compose.yaml` reads, with their defaults:

| Variable | Default | Meaning |
|---|---|---|
| `K3S_PROJECT` | `runcvm-k3s` | Compose project name, which prefixes the containers, network and volume |
| `K3S_VERSION` | `v1.34.1-k3s1` | `rancher/k3s` image tag; `images.txt` lists the images this release needs |
| `K3S_NODE_MEMORY` | `1536m` | Memory limit, and so VM size, of each node |
| `K3S_TOKEN` | `runcvm-k3s-example` | The cluster's join token: set your own for anything but a local example |
| `RUNCVM_QEMU_ACCEL` | `kvm` | RunCVM's QEMU acceleration (`tcg` for software emulation, much slower) |

`RUNCVM_TEST_RUN_ID` and `RUNCVM_TEST_NAME`, which the test runner sets, label the containers, network and volume, so that the runner can remove any it leaves behind; by hand they are empty.

## How the nodes are set up

- **A disk for containerd and kubelet.** `RUNCVM_DISKS` gives each node an ext4 disk holding `/var/lib/rancher/k3s/agent/containerd` and `/var/lib/kubelet`: containerd's overlayfs snapshotter cannot use the VM's virtiofs root as its upper layer, and kubelet reads its directory's filesystem statistics from a block device.
- **RunCVM's Debian kernel.** The `rancher/k3s` image's `os-release` names no distribution, so `RUNCVM_KERNEL=debian` chooses the kernel.
- **Kernel modules.** The VM's kernel loads the modules k3s needs (`overlay`, `br_netfilter`, `vxlan`, netfilter's) on demand, through RunCVM's module loader.
- **No packaged extras.** The server runs with `--disable=traefik,metrics-server,servicelb,local-storage`, so the cluster needs only the images in `images.txt`.
