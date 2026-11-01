# RunCVM self-testing: plan

Status: draft for prioritisation. Sequencing below is a suggestion; priorities are to be finalised.

## 1. Goal

Test arbitrary versions of RunCVM automatically, using RunCVM itself:

- A known-good, stock RunCVM on the bare-metal host launches a disposable outer Container/VM.
- The version under test is installed *inside* that outer VM, where the test suite (or Claude Code) runs and launches further nested RunCVM Container/VMs.
- The same outer VM image serves as an interactive development environment (including in Dockside) and as a batch test environment for a self-hosted GitHub runner.

The core innovation is using RunCVM, rather than libvirt, for the outer VM, making test environments quick to launch and trivially disposable.

### Terminology

| Level | What it is | RunCVM version |
|---|---|---|
| **L0** | Bare-metal Linux host (Docker, KVM with nesting enabled) | Stock, known-good; never the version under test |
| **L1** | Disposable outer Container/VM launched on L0 | Version under test, installed inside L1 |
| **L2** | Container/VMs launched inside L1 by tests | Version under test |

### Constraints

- Nothing under test is installed or run on L0. L0 runs only stock RunCVM and a small set of reviewed, pinned scripts.
- Claude Code CLI never runs on L0; it may run inside L1.
- Nested KVM is available on L0. RunCVM already passes the host CPU through (`-cpu host`, `runcvm-scripts/runcvm-ctr-qemu:178`), so vmx/svm reach L1.

### Why this is feasible today

Inside a container, RunCVM already runs entirely from `/.runcvm/guest` (`BUNDELF_EXEC_PATH`, script shebangs, `RUNCVM_GUEST`), bind-mounted read-only from the host's `/opt/runcvm`. L1 has its own root filesystem, so L1's `/opt/runcvm` (the version under test) does not collide with L0's stock install. The README's "Nested RunCVM demo" and "Testing" sections show the pattern in outline; this plan makes it automated, reproducible and trustworthy.

---

## 2. Deliverables

Work is grouped by what it delivers. Each item has a "done when" check.

### A. A test suite you can trust

#### A1. Trustworthy test runner (`tests/run`)

Problem: `tests/run` runs `./test 2>&1 | sed …` under `bash -e` without `pipefail`, so the recorded status is `sed`'s and test failures are reported as 0 errors.

Work:
- `set -o pipefail`; capture `${PIPESTATUS[0]}` per test; non-zero overall exit on any failure.
- Select tests by tier (`core`, `extended`) and by name.
- Per-test timeout.
- Machine-readable results (TAP or JUnit) written to a configurable results directory, plus per-test logs.
- Unique per-run naming helpers in `tests/framework.sh` (names, networks, volumes, ports, temp files) so runs can be concurrent and clean-up is reliable; label everything created by a run.

Done when: a deliberately failing test makes `tests/run` exit non-zero, and results/logs appear in the results directory.

#### A2. Exit-code pass-through check

The CI contract depends on a Container/VM's exit code reaching `docker run`. The mechanism exists (`/.runcvm/exitcode`, `runcvm-scripts/runcvm-ctr-exit`) but is not covered by a test.

Work: core test asserting `docker run --runtime=runcvm … sh -c 'exit N'` returns `N` for several values, including after `docker stop`/`kill`.

Done when: the test passes and is part of the core tier.

#### A3. Core test tier

Small, fast, deterministic tests (one or two VMs each) that gate CI:

- Boot and exit code (A2).
- `--env`/`--env-file`, `--user`, `--workdir` (existing `02-user-workdir`, `03-env`).
- Mounts: volume, bind, tmpfs; `RUNCVM_DISKS` creation, formatting, prepopulation and persistence in a volume.
- Networking: default bridge, custom network, Docker DNS between containers, `-p` publishing, custom MTU.
- `docker exec` (interactive and non-interactive), `docker stop`/`kill` signal handling.
- Docker inside a RunCVM VM (overlay2 on a `RUNCVM_DISKS` disk) and nested RunCVM `hello-world`.
- Kernel selection (`RUNCVM_KERNEL`) for each shipped kernel.

Done when: the core tier runs in L1 in a bounded time (target to be set after first measurements) with no known flaky tests.

#### A4. Extended tier, including a hardened swarm test

The current suite is suggestive, not mandatory. `00-http-docker-swarm` is a demanding test for RunCVM and also hard to run reproducibly regardless of RunCVM's capabilities. It moves to the extended tier (reported, non-gating) and is hardened:

| Weakness | Fix |
|---|---|
| `docker logs -f … /Swarm complete/q0` has no timeout; hangs if neither message appears | Timeouts on every wait, with diagnostics captured on timeout |
| Nodes coordinate via a shared `/swarm` volume (`RUNCVM_VIRTIOFSD_CACHE=none`), mixing swarm timing with virtiofs coherence | Coordinate from the test host via `docker exec` (join tokens, manager address); keep a separate, explicit virtiofs-sharing test if wanted |
| Fixed names, network, volume, host ports 8080+, `/tmp/iid` | Per-run unique names/ports via A1 helpers |
| Docker Hub pulls in every node | Use `REGISTRY_MIRROR` by default in L1, or preload images |
| Fixed 200-iteration poll | Poll with an explicit deadline; distinguish "slow" from "failed" |

`01-mariadb` also moves to the extended tier.

Done when: the swarm test passes N consecutive runs in L1 (N to be agreed) and fails with a clear diagnosis rather than hanging. Promotion to the core tier is a later decision.

---

### B. A disposable test and development environment (L1)

#### B1. L1 image

A Dockerfile in the repository (e.g. `tests/env/Dockerfile`), based on the README "Testing" image, usable in three ways: plain `docker run`, Dockside, and CI.

- Self-configuring: defaults baked in with `ENV`/`VOLUME`, so `docker run --runtime=runcvm <image>` or a Dockside profile works without extra flags:
  - `RUNCVM_DISKS` for `/var/lib/docker`, `/var/lib/containerd` and `/opt/runcvm` (avoids overlay-on-virtiofs and nested virtiofs), plus an optional build-cache disk; once E is available, a single shared data disk covering these and `/home`;
  - `VOLUME /disks`.
- Docker CE, systemd, non-root dev user with sudo and docker group, git and build prerequisites.
- KVM module selection by CPU vendor (`kvm_intel`/`kvm_amd`), replacing the hardcoded `kvm_intel` in the README images, or removed if shown to be unnecessary.
- rp_filter settings correct for inner bridges (the installer already handles this).
- Two modes:
  - **Dev mode** (default): systemd as PID 1, dockerd running; long-lived. For interactive use, Dockside, and Claude Code.
  - **Batch mode**: entrypoint `runcvm-selftest` (B2). Runs *without* systemd as PID 1 so that the entrypoint's exit status becomes the container's exit code via the existing `/.runcvm/exitcode` path; starts dockerd itself (RunCVM's default `RUNCVM_CGROUPFS=hybrid` supports this).
- Optional Claude Code CLI installation for dev mode. API keys supplied via a file on a `/disks` volume or Dockside's secrets mechanism rather than `--env`, which is visible in `docker inspect` on L0.

Done when: the image launches in dev mode on L0 and in Dockside, and `docker run --runtime=runcvm hello-world` works inside it with the stock RunCVM preinstalled.

#### B2. In-L1 tooling: `runcvm-dev` and `runcvm-selftest`

- `runcvm-dev install <git-ref | source-dir | image>`: build (inside L1) and install a RunCVM version. Uses the existing installer's `REPO=<image>` support; once C is in place, installs as a new version alongside others.
- `runcvm-selftest <git-ref> [tier|tests…]`: clone the ref, build, install, run `tests/run`, write results to `/results` (a volume or `/disks` file), power off with the suite's status.
- Building happens inside L1, never on L0, so no branch-controlled Dockerfile `RUN` steps execute on L0.

Done when: `runcvm-selftest main core` run in L1 returns the suite's status as the L1 container's exit code, with results available on L0 after exit.

#### B3. L0 launcher script

A reviewed, pinned script installed on L0 (source kept in the repository, e.g. `tests/launch-l1.sh`; the L0 copy is not taken from the branch under test). It is the only way CI, and preferably people, start L1s on L0.

- Accepts only a ref (validated against a pattern and restricted to the upstream repository) and a test selection.
- Fixed flags: `--runtime=runcvm`, memory, CPUs, `RUNCVM_DISKS`, `RUNCVM_QEMU_NET_VHOST=1` (if proven), batch-mode command.
- Unique name and labels per run (e.g. run ID); hard timeout; no `--rm` — copy results out, then remove the container and its volumes.
- Streams L1's console to stdout; exits with L1's exit code.
- Label-based reaper for anything left behind by cancelled or crashed runs.
- Suitable as an SSH forced command (D3).

Done when: one launcher command on L0 runs the core tier for a given ref, exits with the suite's status, leaves results on L0 and nothing else behind, and two runs can proceed concurrently.

#### B4. Proving L1 on L0 and in Dockside

Manual launches to settle what the documentation does not demonstrate:

- Full core tier at L2 depth; extended tier including the swarm test (memory sizing).
- Current Docker, cgroup v2 and systemd together in L1.
- Exit-code pass-through from L1 (batch mode) to L0.
- Teardown: `docker rm -f` of L1 with L2s running leaves no taps, iptables rules or volumes on L0.
- Concurrency: several L1s on L0 (KVM contention, disk usage in L0's `/var/lib/docker`).
- Performance: `RUNCVM_QEMU_NET_VHOST=1` in L1 (needs `vhost_net` and `/dev/vhost-net` in the L1 guest), `RUNCVM_HUGETLB`, `RUNCVM_QEMU_MEM_PREALLOC`.
- Inner-network MTU and rp_filter in L1.
- Dockside: whether profiles can set the `--memory`/`--cpus` L1 needs; whether Dockside's IDE injection coexists with systemd and `/disks`.
- Where Docker in L1 (and L2) stores images: `/var/lib/containerd` with the containerd image store versus `/var/lib/docker` with the classic store; test both in L2, since users get whichever Docker defaults to.
- Outbound HTTPS and DNS from L1 (for git, registries, Claude Code, the GitHub runner if ever moved into L1).

Done when: each item has a recorded outcome and recommended setting, captured in the README or a `tests/env/README.md`.

---

### C. Side-by-side RunCVM versions on one host

Delivers safe upgrades (no need to stop every Container/VM first, as the README's upgrade procedure currently requires), multiple versions on a Dockside host, and in-L1 testing of known-good and under-test versions together, including upgrade tests. Intended to come relatively early.

#### C1. Versioned layout

```
/opt/runcvm/                  may be a dedicated LV
  bootstrap/                  bootstrap wrapper (self-contained; see C2)
    runcvm-runtime            the path daemon.json points at, for all versions
  default -> 1.2.3            used when RUNCVM_VERSION is unset
  1.2.3/                      one complete, immutable install per version
  1.3.0-dev.g1ec8d38/
  lost+found/                 present on an ext4 LV
```

- Reserved names: `bootstrap`, `default`, `lost+found`. Version names validated, e.g. `^[0-9A-Za-z][0-9A-Za-z._+-]*$`.
- If `/opt/runcvm` is an LV: not mounted `noexec`; `docker.service` gets a `RequiresMountsFor=/opt/runcvm` drop-in so the LV is mounted before dockerd restarts containers at boot.

#### C2. Bootstrap wrapper

Intentionally light: it identifies the requested version and hands over to that version's main wrapper.

- Any command other than `create` and `exec`: run `/usr/bin/runc` directly. (Today only `create` and `exec` are intercepted; everything else is passed to runc, `runcvm-scripts/runcvm-runtime:560`.)
- `create`: read `RUNCVM_VERSION` from `.process.env` in `<bundle>/config.json`, defaulting to `default`; resolve to the real version directory; fail clearly if not installed (no silent fallback); record the resolved version per container ID (e.g. `/run/runcvm/containers/<id>`); hand over to `<version>/scripts/runcvm-runtime` with `RUNCVM=<version dir>`, unchanged arguments.
- `exec`: route to the version recorded for the container, not the current default, because the exec handler rewrites the process to use scripts under `/.runcvm/guest`, which must match the payload mounted at create time. Fallback if the record is missing: recover the version from runc's state (source of the mount whose destination is `/.runcvm/guest`).
- `delete`: remove the record, then pass to runc.
- `RUNCVM_VERSION` can be set by `docker run -e` or by an image's `ENV` (an image can pin its runtime version; such an image fails on hosts without that version — to be documented).

Implementation choice (open decision):

| Option | For | Against |
|---|---|---|
| Static binary (e.g. Go) | No dependency on a bundled dynamic jq, bash or loader; fast; robust if versions are removed | Adds a separate build toolchain and language to the project |
| Bash + jq in an independent BundELF bundle | Project's existing idiom and build tooling | A second BundELF bundle to build, ship and keep independent of any version's binaries |

Either way, the bootstrap must not borrow binaries from `default` or any installed version, and should change rarely. The interface between bootstrap and main wrapper is small (unchanged arguments, `RUNCVM`, resolved `RUNCVM_VERSION`) and should be documented and kept stable.

#### C3. Main wrapper changes

- `RUNCVM=/opt/runcvm` (`runcvm-scripts/runcvm-runtime:23`) becomes `RUNCVM=${RUNCVM:-<derived from its own path>}`; bind-mount source (`:295`) and kernel lookup (`RUNCVM_KERNELS`, `:30`, `:336`, `:399`) already follow `$RUNCVM`.
- Started via its own `lib/ld` and `bin/bash`, so its absolute shebang no longer matters.
- Remains directly invocable, so a version can also be registered under its own runtime name in `daemon.json` (e.g. `runcvm-1.2.3`) for cases where setting an env var is impractical, or to pin a whole host.
- Verify BundELF output is relocatable to `/opt/runcvm/<version>` (host-side jq already runs via `$RUNCVM_LD`, which suggests so).

#### C4. Installer and lifecycle

- Install a version atomically: unpack to `/opt/runcvm/.tmp-<ver>`, rename into place; never modify an installed version in place. Development builds get unique names (e.g. from `git describe`, plus a hash for uncommitted changes).
- Switch `default` atomically (`ln -s` + `mv -T`).
- Install from an image (existing `REPO`), a local directory or a tarball.
- Remove a version only when no container uses it (from the per-container records); list versions and their users.
- Install or update the bootstrap and point `daemon.json` at `bootstrap/runcvm-runtime`.
- One-time migration from the current flat layout: requires RunCVM containers to be stopped (they bind-mount `/opt/runcvm` itself), moves the existing install to `/opt/runcvm/<ver>`, and repoints `daemon.json` once.

#### C5. Tests

- Core tier run against two installed versions in one L1.
- Upgrade test: create a Container/VM on version 1, switch `default` to version 2, confirm `docker exec` and `docker stop` still work on the old container and new containers get version 2.
- Unknown `RUNCVM_VERSION` fails `create` with a clear error.
- Migration from the flat layout.

Done when: C5 passes in L1, and the README's installation and upgrade sections describe the new layout.

---

### D. Automated CI on the bare-metal host

The GitHub runner runs on L0 in a standard (runc) container, not in a RunCVM VM, and launches L1s through the B3 launcher.

#### D1. Runner container (first version)

- Standard container with the host Docker socket bind-mounted, registered with labels specific to this purpose.
- Ephemeral: one job per registration (just-in-time config or `--ephemeral`), recreated by a small loop on L0.
- Job steps only call the B3 launcher with a ref; no branch code is checked out or executed in the runner container.

#### D2. Controls on what jobs can do

A runner executes whatever steps the triggering workflow file lists, and workflow files come from the triggering commit, so anyone who can push a branch can change them. Controls must therefore be enforced outside the workflow file:

- **Job-started hook** (`ACTIONS_RUNNER_HOOK_JOB_STARTED`), configured on the runner: rejects jobs unless `GITHUB_REPOSITORY` is `newsnowlabs/runcvm`, the event and ref are allowed, and (for pull requests) the head repository is not a fork.
- **Workflow pinned to `main`**: use triggers whose definition comes from the default branch (`workflow_dispatch` from `main`, `pull_request_target`, `workflow_run`); the workflow passes only the ref to the launcher. Where the organisation plan supports it, restrict the runner group to that workflow at `refs/heads/main`.
- **Repository settings**: require approval for workflows from all outside contributors' fork pull requests.

#### D3. Hardening

Remove the raw Docker socket from the runner, so that even a compromised runner, action or workflow can only start an L1:

- **SSH variant**: runner (host networking, or via the Docker bridge gateway) holds a key whose `authorized_keys` entry has a forced command: the B3 launcher.
- or a small fixed launcher service exposed to the runner in place of the socket.

Plus: an `if: always()` clean-up step and the B3 reaper for cancelled jobs.

#### D4. Workflows

- `workflow_dispatch` (ref input) first; then pushes to upstream branches; pull request triggers only after D3.
- Core tier gates; extended tier reported separately.
- Results uploaded as workflow artefacts; JUnit/TAP summary in the job.

Done when (D1, D2): a manually triggered run for a branch goes green or red correctly in GitHub. Done when (D3, D4): a workflow pushed from a branch that tries to run its own commands on the runner, and a fork pull request, are both refused.

---

### E. Faster VM storage: one data disk shared by several paths

The VM's root is the container's root filesystem, shared over virtiofs. `RUNCVM_DISKS` gives block-device performance to chosen paths, but needs one disk per path. Each disk has its own size ceiling (one can fill while another is nearly empty, although sparse backing files and `discard=unmap` mean host space is consumed only as written), and declaring a disk per path does not scale.

Impact on this plan:
- **CI (batch mode): low**, provided both Docker storage paths are on disks. Most heavy I/O in L1 is under `/var/lib/docker` (images, builds, L2 root filesystems, L2 backing files). With the containerd image store, which recent Docker Engine releases are understood to enable by default on fresh installs, image content and snapshots live in `/var/lib/containerd` instead (checked in B4).
- **Dev mode and Dockside: significant.** Home directories, source trees, toolchain and package caches, and Claude Code workspaces are write-heavy and spread across the root filesystem.

A block-device root is not proposed: the virtiofs root also carries `/.runcvm` (config, network set-up, fstab, dropbear keys, `exitcode`), `/.runcvm/guest` (including the kernel's `init=`), user volumes and bind mounts, and Docker's `/etc/hosts`/`resolv.conf`/`hostname` bind mounts; and it would break Docker's image-plus-writable-layer model (`docker diff`, `docker cp`, `docker commit`, image updates).

#### E1. Multi-path disk specs

Extend `RUNCVM_DISKS` so one disk can serve several destinations, separated by `:`:

```
RUNCVM_DISKS=/disks/data,/var/lib/docker:/var/lib/containerd:/home:/opt/runcvm,ext4,40G
```

- A spec with one destination keeps today's behaviour exactly (`mke2fs -d <dst>`, disk mounted directly at the destination).
- A spec with several destinations creates one filesystem with a subdirectory per destination (e.g. `var-lib-docker`, `home`), mounts the disk at a hidden mountpoint (e.g. `/.runcvm/disks/<n>`) and bind-mounts each subdirectory over its destination on every boot. Changes are confined to `do_disk` in `runcvm-ctr-qemu` and the fstab handling in `runcvm-vm-init` (`:105`).
- Overlapping destinations within one spec (e.g. `/var/lib` and `/var/lib/docker`) are rejected.

#### E2. Populating a multi-path disk in one pass (option 3)

The container side cannot mount the image (no `CAP_SYS_ADMIN`, so no loop or FUSE mounts), and `mke2fs -d <dir>` takes a single source directory. Instead, stream all destinations, already renamed to their subdirectories, as a tarball into `mke2fs -d -`:

```sh
LC_ALL=C.UTF-8 tar -C /vm --xattrs --xattrs-include='*' --numeric-owner -cf - \
    --transform='s,^var/lib/docker,var-lib-docker,;s,^home,home,' \
    var/lib/docker home \
  | LC_ALL=C.UTF-8 mke2fs -q -F -t ext4 -d - "$src"
```

No staging copy, so no temporary second copy of the data.

Tested in a development sandbox (e2fsprogs 1.47.2 built from source with libarchive; GNU tar 1.35):

| Check | Result |
|---|---|
| Paths renamed into subdirectories by `--transform` | Correct |
| Ownership (numeric uid/gid), modes including setuid | Preserved |
| Hard links within a tree | Preserved (same inode, link count 2) |
| Symlinks | Preserved |
| `security.capability` | Preserved |
| Other xattrs (`user.*`; by the same code path also `trusted.*`, `security.selinux`, POSIX ACLs) | **Dropped.** The tarball importer copies only `security.capability` and `gnu.translator` (`misc/create_inode_libarchive.c`, `set_inode_xattr_tar`; unchanged on e2fsprogs master as of September 2026). Directory mode (`mke2fs -d <dir>`) copies all xattrs. |
| Non-ASCII file names | Fail unless run under a UTF-8 locale (`LC_ALL=C.UTF-8`); musl may behave differently, to be checked |
| Speed, `/usr/lib` (2.3 GB, ~40k files) into a 20 GB sparse file | Tarball: ~17 s; directory mode: ~7 s |
| Speed vs staging copy (`/usr/share` + `/usr/lib`, 2.7 GB) | Tarball: ~13 s; `cp -a` to staging then `mke2fs -d`: ~87 s |

The xattr limitation matters where a destination is pre-populated with content that relies on xattrs. The important case is a `/var/lib/docker` or `/var/lib/containerd` pre-loaded in an image (e.g. an L1 image with test images baked in for offline speed): overlay2 relies on `trusted.overlay.*` xattrs (e.g. opaque directories), so losing them would silently corrupt layers. Empty destinations, and typical `/home` and `/opt/runcvm` contents, are unaffected. Options:
1. Patch e2fsprogs so the tarball importer copies all xattrs (or add an option to do so), and propose the change upstream. RunCVM would build e2fsprogs itself anyway (E3).
2. Fall back to VM-side copying (E4) for destinations needing full xattr fidelity.
3. Document the limitation and recommend a single-destination disk (directory mode) for pre-populated Docker storage.

#### E3. Build and bundling changes

- e2fsprogs ≥ 1.47.1 built with libarchive. RunCVM builds on Alpine 3.19 (`Dockerfile:4`), which is believed to ship 1.47.0 (no tarball support). Either move to a newer Alpine release (and check its package is built with libarchive) or build e2fsprogs in its own Dockerfile stage, as is done for SeaBIOS and dnsmasq; the latter also allows the E2 xattr patch.
- libarchive bundled explicitly via `BUNDELF_EXTRA_LIBS`: it is loaded with `dlopen`, so BundELF's dependency scan will not find it.
- A tar that can rename paths and write xattrs: GNU tar (`--transform`) or bsdtar (`-s`, from libarchive). busybox tar supports neither.
- A UTF-8 locale for both tar and mke2fs.

#### E4. Adding a destination to an existing disk

The tarball method only populates a disk when it is created. For a destination added to an existing multi-path disk (and optionally for the xattr fallback in E2), the VM populates it on boot, before bind-mounting:

```
[ -d $M/<sub> ] || { rm -rf $M/<sub>.tmp && cp -a <dst> $M/<sub>.tmp && mv $M/<sub>.tmp $M/<sub>; }
```

The rename makes `<sub>`'s existence the completion marker; an interrupted copy is discarded and retried. GNU coreutils is already bundled and virtiofsd runs with `-o xattr` (`runcvm-ctr-virtiofsd:11`), so `cp -a` preserves all xattrs. This can be deferred: initially, adding a destination later may simply be unsupported.

#### E5. Tests

- Core: a multi-path disk with sample trees; compare ownership, modes, hard links, symlinks, `security.capability`, and (once E2 option 1 or 2 is chosen) other xattrs between source and disk.
- Core: Docker in the VM using a multi-path disk for `/var/lib/docker` and `/var/lib/containerd`, with both the containerd image store and the classic store.
- Single-destination specs behave exactly as before.

Done when: the L1 image (B1) uses one data disk for `/var/lib/docker`, `/var/lib/containerd`, `/opt/runcvm` and `/home`, and E5 passes.

---

### F. Deferred and possible future work

- **Overlay root with a block-backed upper layer**: in the VM, root becomes an overlayfs with the image (virtiofs) as the read-only lower layer and the upper layer on the data disk, so writes anywhere under `/` go to the block device. `/var/lib/docker` and containerd storage would still be bind-mounted directly from the data disk (overlay2 cannot run on overlayfs). Needs the root switch moved into the initramfs, and `docker diff`/`docker commit` would no longer see VM-side changes. Worth considering for dev mode after E.

- **Named-volume payload**: the wrapper detects a user-supplied mount at a reserved destination (e.g. `--mount type=volume,src=runcvm-1.2.3,dst=/.runcvm/guest`) and uses it instead of its own bind mount. Benefits: install a payload without host filesystem writes, `daemon.json` edits or dockerd restarts; per-container selection; `docker volume rm` to remove. Costs: wrapper/payload version skew becomes a compatibility contract needing an interface version; only covers payload changes, not wrapper changes. Revisit after C, once the wrapper–payload interface is documented.
- **GitHub runner inside a RunCVM VM**: not initially. Note that RunCVM does not support bind-mounting host sockets, so such a runner could only nest everything.
- **Claude Code-driven test runs in L1** (headless, triggered by the launcher), once B and D are proven.

---

## 3. Dependencies

```
A1 ──► A2, A3, A4, B2
B1 ──► B2 ──► B3 ──► B4 ──► D1 ──► D2 ──► D3 ──► D4
B1 (dev mode) ──► C (developed and tested in L1)
A3 ──► C5
C4 ──► B2 (runcvm-dev install as a new version, once C exists)
E3 ──► E1/E2 ──► E5 ──► B1 (shared data disk in the L1 image)
```

- A1 is small and unblocks everything; it can be done in the existing libvirt development VM.
- C needs only B1 in dev mode, so it can proceed alongside A3/A4 and B2/B3.
- D needs B3 and enough of A3 to be meaningful.
- E can start at any time; E3 (e2fsprogs/libarchive/tar build) comes first. B1 can use per-path disks until E lands.

## 4. Suggested sequence (for prioritisation)

1. A1, A2 — trustworthy runner and exit-code check.
2. B1 (dev mode) — L1 image, proven by manual launch on L0 and in Dockside.
3. C — versioned layout, bootstrap and main wrapper changes, developed in L1. Decide the bootstrap implementation (static binary vs BundELF bundle) at the start.
4. B1 (batch mode), B2, B3 — self-test entrypoint and launcher.
5. B4 — proving runs; record settings.
6. A3, A4 — core tier and hardened swarm test, developed in L1.
7. D1, D2, D4 (`workflow_dispatch` only) — first CI runs.
8. D3, then widen D4 triggers.
9. E — shared data disk; can run alongside 2–6, starting with E3. B1 switches to it when ready.
10. F — as needed.

## 5. Open decisions

- Bootstrap implementation: static binary (e.g. Go) or independent BundELF bundle (C2).
- Location of the L1 image and tooling in the repository (`tests/env/` proposed).
- Results format: TAP or JUnit.
- Core tier time budget; swarm-test reliability threshold for promotion.
- Socket variant with D2 controls only, or go straight to D3.
- Registry for prebuilt images (if any), or always build inside L1.
- Whether people should also be required to use the launcher on L0, or only CI.
- Tarball importer xattr limitation (E2): patch e2fsprogs, fall back to VM-side copying, or document.
- Newer Alpine release versus building e2fsprogs in its own stage (E3); GNU tar versus bsdtar.
- Whether adding a destination to an existing multi-path disk (E4) is supported initially.

## 6. Risks and unproven areas

- Nesting depth and performance at L2 (memory, network throughput, boot time).
- Swarm test may remain unreliable for reasons unrelated to RunCVM.
- Exit-code pass-through in batch mode depends on not running systemd as PID 1 in L1.
- Dockside profile capabilities (memory/CPU limits, interaction with `/disks`).
- BundELF relocatability to `/opt/runcvm/<version>` is assumed, not yet verified.
- Exec routing after bootstrap updates or host reboots (records in `/run` are lost at reboot; containers are recreated by `create`, which rewrites them).
- Runner security depends on controls outside workflow files (D2/D3); misconfiguration exposes L0.
- Tarball population drops xattrs other than `security.capability`; pre-populated Docker storage would be silently corrupted unless addressed (E2).
- Tarball population tested on glibc/Ubuntu only; behaviour under musl/Alpine within RunCVM (locale, libarchive loading) to be confirmed.
