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
- Machine-readable results (TAP or JUnit) written to a configurable results directory, plus per-test logs. Each result records the test's parameters (e.g. `--init` or not, user, kernel) so the same test run in several modes reports separately.
- Helpers in `tests/framework.sh` for each way a test observes L2 (see F3): expected exit status, results volume, `docker exec` probe, stdout capture.
- Unique per-run naming helpers in `tests/framework.sh` (names, networks, volumes, ports, temp files) so runs can be concurrent and clean-up is reliable; label everything created by a run.

Done when: a deliberately failing test makes `tests/run` exit non-zero, and results/logs appear in the results directory.

Status: implemented in PR #34 (`a1-test-runner`). `tests/run` is a standard-library Python runner; tests stay language-neutral (any executable `test`; exit 0 pass, 77 skip, other fail) with metadata files `tier`, `timeout` and `requires` (`vm`, `kvm`, `ipv6`). It writes TAP, JUnit, JSON and a summary, runs each test in its own process group with a timeout, and removes leftovers by label. Helpers exist in both `tests/framework.sh` and `tests/framework.py`. Tests are numbered by tier (`1x` core, `5x` extended). `--mock` runs the suite with `runc` in place of RunCVM (tests requiring `vm` skip), and `--accel kvm|auto|tcg` selects QEMU acceleration via `RUNCVM_QEMU_ACCEL` (PR #33), so the suite also runs under TCG emulation in environments without `/dev/kvm`. `tests/selftest/run-selftest` tests the runner itself.

#### A2. Exit-code and shutdown behaviour: baseline tests

RunCVM does not currently pass the entrypoint's exit status through automatically. Per the README, an application must write `/.runcvm/exitcode` (0–255) or call `qemu-exit` (0–127); otherwise `runcvm-ctr-exit` derives a code from QEMU's exit status. Behaviour also differs by init mode:

- Without `--init`, the entrypoint is exec'd as the VM's PID 1; when it exits the kernel panics and QEMU exits (`-no-reboot`), with no clean shutdown.
- With `--init`, busybox init is PID 1 and runs the entrypoint as a descendant via `runcvm-vm-start-wrapper`; when the entrypoint exits, init respawns the wrapper, which finds `/.runcvm/once` and powers off cleanly. The entrypoint's status is discarded.

Work: core tests that record current behaviour precisely, reading `docker run`'s exit status directly (no wrapper, since this is the behaviour under test), across:
- `--init` and without;
- entrypoint exits normally (various codes), writes `/.runcvm/exitcode`, calls `qemu-exit`;
- root and `-u <non-root>` (`/.runcvm` is a root-only tmpfs, `mode=700`);
- `docker stop` and `docker kill`;
- whether data written to a `RUNCVM_DISKS` disk survives each kind of shutdown.

These are regression tests for the separate project upgrading RunCVM's VM and container init processes; expected values are updated when that project changes the contract.

Done when: the tests pass against current behaviour and are part of the core tier.

#### A3. Core test tier

Small, fast, deterministic tests (one or two VMs each) that gate CI. Each test declares which RunCVM options it exercises and observes L2 by the method appropriate to them (F3). Where behaviour is meant to be the same with and without `--init`, the test runs in both modes.

- Exit codes and shutdown (A2).
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

Status: in PR #34, the tests are renumbered `50-http-docker-swarm` (requires `vm kvm`) and `51-mariadb` (passes under TCG); the hardening above is still to do.

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
- systemd as PID 1 in all modes, with dockerd and `systemd-logind` (needed for ACPI power-down on `docker stop`).
- Entrypoint wrapper: a small script saves its arguments (NUL-separated) and relevant environment variables (as a systemd `EnvironmentFile`) to the root filesystem (e.g. `/etc/runcvm-l1/`; not `/run`, which systemd replaces with a fresh tmpfs), then execs systemd with no arguments. Needed because systemd as PID 1 does not treat its arguments as instructions for us, and services do not inherit PID 1's environment.
- Mode chosen from the saved arguments:
  - **Dev mode** (no arguments): long-lived. For interactive use, Dockside, and Claude Code.
  - **Batch mode** (`selftest <ref> [tier|tests…]`): a systemd unit runs `runcvm-selftest` (B2), then powers off (`SuccessAction=`/`FailureAction=poweroff`). See F2.
- Optional Claude Code CLI installation for dev mode. API keys supplied via a file on a `/disks` volume or Dockside's secrets mechanism rather than `--env`, which is visible in `docker inspect` on L0.

Done when: the image launches in dev mode on L0 and in Dockside, and `docker run --runtime=runcvm hello-world` works inside it with the stock RunCVM preinstalled.

#### B2. In-L1 tooling: `runcvm-dev` and `runcvm-selftest`

- `runcvm-dev install <git-ref | source-dir | image>`: build (inside L1) and install a RunCVM version. Uses the existing installer's `REPO=<image>` support; once C is in place, installs as a new version alongside others.
- `runcvm-selftest <git-ref> [tier|tests…]`: clone the ref, build, install, run `tests/run`, write results to the `/results` mount (F2).
- Building happens inside L1, never on L0, so no branch-controlled Dockerfile `RUN` steps execute on L0.

Done when: `selftest main core` launched as L1's command leaves complete results and a `done` marker in the results mount, and L1's exit code matches the recorded harness status.

#### B3. L0 launcher script

A reviewed, pinned script installed on L0 (source kept in the repository, e.g. `tests/launch-l1.sh`; the L0 copy is not taken from the branch under test). It is the only way CI, and preferably people, start L1s on L0.

- Accepts only a ref (validated against a pattern and restricted to the upstream repository) and a test selection.
- Fixed flags: `--runtime=runcvm`, memory, CPUs, `RUNCVM_DISKS`, `RUNCVM_QEMU_NET_VHOST=1` (if proven), batch-mode command.
- Unique name and labels per run (e.g. run ID); hard timeout; no `--rm` — copy results out, then remove the container and its volumes.
- Mounts a fresh results volume or directory per run at `/results`; after L1 exits, reads `status` and the `done` marker, cross-checks L1's exit code, and exits with the result (F2 conventions). A missing `done` marker is an infrastructure failure, whatever the exit code.
- Streams L1's console to stdout for live progress only.
- Generous `--stop-timeout`; on timeout, collects diagnostics with `docker exec` (e.g. `journalctl`) before `docker stop -t N`, then `docker kill`.
- Label-based reaper for anything left behind by cancelled or crashed runs.
- Suitable as an SSH forced command (D3).

Done when: one launcher command on L0 runs the core tier for a given ref, exits with the suite's status, leaves results on L0 and nothing else behind, and two runs can proceed concurrently.

#### B4. Proving L1 on L0 and in Dockside

Manual launches to settle what the documentation does not demonstrate:

- Full core tier at L2 depth; extended tier including the swarm test (memory sizing).
- Current Docker, cgroup v2 and systemd together in L1.
- Results mount, `done` marker and `/.runcvm/exitcode` from L1's `ExecStopPost` reach L0 as designed (F2); `docker stop` of a systemd L1 powers off via ACPI and `systemd-logind`.
- Teardown: `docker rm -f` of L1 with L2s running leaves no taps, iptables rules or volumes on L0.
- Concurrency: several L1s on L0 (KVM contention, disk usage in L0's `/var/lib/docker`).
- Disk layout for L1: for each of per-path disks, multi-path disk (both E1 flavours) and whole-root disk (E6), measure disk set-up time at first boot, boot time, and the duration of a representative batch run (build of RunCVM, core tier, extended tier) and of typical dev-mode operations (git, builds). Choose the L1 default from the results.
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

Booting from a block-device root (kernel `root=`) is not proposed: the virtiofs root also carries `/.runcvm` (config, network set-up, fstab, dropbear keys, `exitcode`), `/.runcvm/guest` (including the kernel's `init=`), user volumes and bind mounts, and Docker's `/etc/hosts`/`resolv.conf`/`hostname` bind mounts; and it would break Docker's image-plus-writable-layer model (`docker diff`, `docker cp`, `docker commit`, image updates). An optional whole-root disk that the VM switches to after booting from virtiofs is feasible, though, with the same semantic trade-offs (E6).

#### E1. Multi-path disk specs

Extend `RUNCVM_DISKS` so one disk can serve several destinations, separated by `:`:

```
RUNCVM_DISKS=/disks/data,/var/lib/docker:/var/lib/containerd:/home:/opt/runcvm,ext4,40G
```

- A spec with one destination keeps today's behaviour exactly (`mke2fs -d <dst>`, disk mounted directly at the destination).
- A spec with several destinations creates one filesystem with a subdirectory per destination (e.g. `var-lib-docker`, `home`), mounts the disk at a hidden mountpoint (e.g. `/.runcvm/disks/<n>`) and bind-mounts each subdirectory over its destination on every boot. Changes are confined to `do_disk` in `runcvm-ctr-qemu` and the fstab handling in `runcvm-vm-init` (`:105`).
- Overlapping destinations within one spec (e.g. `/var/lib` and `/var/lib/docker`) are rejected.

Two flavours, both using the E2/E6 mke2fs patch:
- **Listed destinations** (as above): the disk holds one subdirectory per listed path (`-d SRC=SUBDIR`).
- **Exclusion list**: the disk holds a copy of the whole root minus exclusions (`-d /vm -X -x …`), laid out as in `/`, and every non-excluded top-level directory on the disk is bind-mounted over its counterpart in the virtiofs root. Nothing about the contents of `/` needs specifying. Live mounts beneath a bind-mounted directory (e.g. Docker's `/etc/hosts`, volumes under `/home`, kernel modules under `/lib/modules`) must be re-attached on top after binding (moved or re-bound from their original locations). The root itself stays virtiofs, so no `pivot_root`.

#### E2. Populating a multi-path disk in one pass: repeated `-d SRC=SUBDIR`

The container side cannot mount the image (no `CAP_SYS_ADMIN`, so no loop or FUSE mounts), and `mke2fs -d <dir>` takes a single source directory. A small patch to mke2fs makes `-d` repeatable, with each `-d SRC=SUBDIR` copying directory SRC into a new top-level directory SUBDIR using the existing directory-mode code (`__populate_fs()`). SUBDIR takes SRC's own owner, mode, times and xattrs. A plain `-d SRC` (no `=`) behaves exactly as today and may be given at most once.

```sh
mke2fs -q -F -t ext4 -d /vm/var/lib/docker=var-lib-docker -d /vm/home=home "$src"
```

Prototype: `patches/e2fsprogs/mke2fs-populate.patch`, against e2fsprogs v1.47.2 (about 170 lines in `misc/create_inode.c` and `misc/mke2fs.c`; also adds `-x`/`-X`, see E6). Not yet wired into the build, and the man page is not yet updated. SUBDIR must be a single path component; duplicate SUBDIRs are rejected. The patch restores the working directory between sources, because `__populate_fs()` calls `chdir()`.

Tested in a development sandbox (patched e2fsprogs 1.47.2, glibc):

| Check | Result |
|---|---|
| Each source copied into its subdirectory | Correct |
| Subdirectory's own owner and mode (e.g. `1000:1000`, `0751`) | Taken from SRC |
| Ownership, modes including setuid | Preserved |
| Hard links within a tree | Preserved (same inode, link count 2) |
| Symlinks | Preserved |
| `security.capability` and `user.*` xattrs | Preserved (directory mode copies all xattrs, so also `trusted.*`, `security.selinux`, POSIX ACLs) |
| Non-ASCII file names | Correct with no locale set |
| `e2fsck -fn` on the result | Clean |
| Invalid SUBDIR (`a/b`), duplicate SUBDIR | Rejected with a clear error, non-zero exit |
| Speed, `/usr/share` + `/usr/lib` (2.7 GB, ~48k files) into a 20 GB sparse file, warm cache | ~11–13 s, against ~29–36 s for the tarball method below; repeated runs varied, but the ratio was consistent |

Full xattr fidelity matters for pre-populated Docker storage: overlay2 relies on `trusted.overlay.*` xattrs (e.g. opaque directories), so an image shipping a pre-loaded `/var/lib/docker` or `/var/lib/containerd` must keep them.

Upstreaming: propose the change to e2fsprogs. Until accepted, RunCVM carries the patch (E3).

**Alternative considered: tarball into `mke2fs -d -`.** e2fsprogs ≥ 1.47.1 built with libarchive accepts a tarball, so all destinations can be streamed, renamed with GNU tar `--transform`, with no patch. Rejected as the primary method because, as tested:
- it drops all xattrs except `security.capability` and `gnu.translator` (`set_inode_xattr_tar` in `misc/create_inode_libarchive.c`; unchanged on e2fsprogs master as of September 2026), which would silently corrupt pre-populated overlay2 storage;
- it fails on non-ASCII file names unless run under a UTF-8 locale;
- it is about 2.5 times slower than repeated `-d`;
- it needs libarchive (loaded with `dlopen`, so bundled explicitly) and GNU tar or bsdtar in the RunCVM bundle.

#### E3. Build and bundling changes

- Build e2fsprogs in its own Dockerfile stage with `patches/e2fsprogs/mke2fs-populate.patch` applied, as is done for SeaBIOS and dnsmasq, and bundle the resulting `mke2fs` in place of Alpine's. No libarchive, tar or locale requirements.
- Confirm the patched build under musl/Alpine.

#### E4. Adding a destination to an existing disk

mke2fs only populates a disk when it is created. For a destination added to an existing multi-path disk, the VM populates it on boot, before bind-mounting:

```
[ -d $M/<sub> ] || { rm -rf $M/<sub>.tmp && cp -a <dst> $M/<sub>.tmp && mv $M/<sub>.tmp $M/<sub>; }
```

The rename makes `<sub>`'s existence the completion marker; an interrupted copy is discarded and retried. GNU coreutils is already bundled and virtiofsd runs with `-o xattr` (`runcvm-ctr-virtiofsd:11`), so `cp -a` preserves all xattrs. This can be deferred: initially, adding a destination later may simply be unsupported.

#### E5. Tests

- Core: a multi-path disk with sample trees; compare ownership, modes, hard links, symlinks and xattrs (`security.capability`, `user.*`, `trusted.*`) between source and disk.
- Core: Docker in the VM with a `/var/lib/docker` pre-populated in the image, on a multi-path disk.
- Core: Docker in the VM using a multi-path disk for `/var/lib/docker` and `/var/lib/containerd`, with both the containerd image store and the classic store.
- Single-destination specs behave exactly as before.

Done when: the L1 image (B1) uses one data disk for `/var/lib/docker`, `/var/lib/containerd`, `/opt/runcvm` and `/home`, and E5 passes.

#### E6. Optional whole-root disk

A variation that needs no knowledge of what is in `/`: copy the whole root, minus what must stay live, onto one disk, and have the VM run from it. Proposed syntax: `RUNCVM_DISKS=/disks/root,/,ext4,40G` (destination `/`, which today would be unsafe and should be rejected until this exists).

**Populating: `-x` and `-X` in the same mke2fs patch.**
- `-x PATTERN` (repeatable): skip paths matching a shell pattern (`fnmatch`, `FNM_PATHNAME`), relative to the source root, e.g. `-x /disks/root -x '/var/cache/*'`. An excluded directory is still created, empty, with its own attributes; excluded files are omitted.
- `-X`: do not cross filesystem boundaries, like `tar --one-file-system`. Mountpoint directories are created empty; files on other filesystems are omitted.

```sh
mke2fs -q -F -t ext4 -d /vm -X -x '/disks/*' "$src"
```

In the container, `/vm` is an rbind of the container's root filesystem, and everything that must stay live in the VM is a separate mount: the `/.runcvm` tmpfs, `/.runcvm/guest` (host `/opt/runcvm`), user volumes and bind mounts, Docker's `/etc/hosts`/`resolv.conf`/`hostname` bind mounts, and kernel modules. So `-X` excludes exactly those, and RunCVM only needs to add `-x` for a backing file stored in the container's own filesystem. `-X` relies on device numbers, so a bind mount from the same filesystem is not detected (as with tar and rsync); in RunCVM's case the root is overlayfs and all bind sources are host paths, so device numbers differ.

Tested in a development sandbox against a mock `/vm` (tmpfs "volume", tmpfs `/.runcvm`, `/etc/hosts` bind-mounted from a tmpfs, backing file inside the tree): the volume, `/.runcvm` and `/disks` arrived as empty directories, `/etc/hosts` was omitted, `/var/cache/*` was excluded while `/var/cache` itself was kept, everything else was copied, and `e2fsck -fn` was clean. Without `-X`, the volume's contents were copied, as expected.

Possible refinement: with `-X`, create empty placeholder files for file mountpoints (e.g. `/etc/hosts`) rather than omitting them, so the VM need not create them before re-attaching the bind mounts.

**VM side: switch to the disk early in `runcvm-vm-init`, without initramfs changes.** The VM still boots from virtiofs, so the kernel's `init=` (`/.runcvm/guest/scripts/runcvm-vm-init`) and the initramfs are unchanged. Before anything else starts, `runcvm-vm-init` (PID 1, running from `/.runcvm/guest`):
1. mounts the disk at a temporary mountpoint;
2. moves each live mount (`/proc`, `/sys`, `/dev`, `/.runcvm` with `/.runcvm/guest`, user volumes, Docker's file bind mounts, kernel modules) onto the matching empty path on the disk (`mount --move`);
3. `pivot_root`s to the disk, keeping the virtiofs root at a hidden path (e.g. `/.runcvm/vmroot`) or detaching it;
4. carries on as today (network, fstab, cgroups, dropbear, then the entrypoint).

The process structure inside the VM is unchanged: `runcvm-vm-init` remains PID 1 and execs as today.

**Trade-offs compared with multi-path disks (E1, E2):**

| | Multi-path disk | Whole-root disk |
|---|---|---|
| What must be specified | Each heavy path | Only the disk and its size |
| I/O on the block device | Listed paths | Everything except live mounts |
| Creation cost | Listed paths' contents (often nearly empty) | Whole image plus container layer |
| Host space | Small | Image contents duplicated on the disk |
| `docker diff`/`cp`/`commit`/`export` | Unaffected except listed paths | Do not see VM-side changes |
| If the disk outlives the image (e.g. in a named volume) | Listed paths stale | Whole root stale; image updates not seen |
| VM-side work | Mount and bind-mount | Mount, move live mounts, `pivot_root` |

Recommendation: whole-root is a candidate for long-lived L1s in both dev and batch mode, since L1 needs none of the Docker subcommands it affects; multi-path disks remain the default for general RunCVM use and for short-lived L2s, where Docker's semantics matter and creation must be cheap. Whether whole-root pays off for L1 depends on disk set-up time against runtime saved by faster disk throughput over the L1's lifetime, and is to be measured (B4). One mke2fs patch serves all approaches.

Tests: a whole-root L2 boots and runs its entrypoint; volumes, bind mounts, `/etc/hosts` and `docker exec` work; `docker stop` shuts down cleanly; writes outside volumes land on the disk; a backing file inside the container's filesystem is not copied into itself.

---

### F. Communication and control between levels

How each level is launched, reports results and is controlled. L0↔L1 and L1↔L2 follow the same principles.

#### F1. What RunCVM provides, and how it behaves

| Channel | How RunCVM implements it | systemd as PID 1 | `--init` (busybox init as PID 1) | No init (entrypoint as PID 1) |
|---|---|---|---|---|
| Command line | Saved to `/.runcvm/entrypoint`; exec'd in the VM | Arguments go to systemd, not to us; use an entrypoint wrapper (B1) | Passed to the entrypoint | Passed to the entrypoint |
| Environment | Saved to `/.runcvm/config`; restored for the entrypoint | Not inherited by services; wrapper saves an `EnvironmentFile` | Passed | Passed |
| stdin/stdout | VM console (`hvc0`/`ttyS0`) is QEMU's stdio | Owned by systemd: status output, possibly a getty; not usable for stdin | Console with controlling tty | Console |
| Exit code | `runcvm-ctr-exit` reads `/.runcvm/exitcode` after QEMU exits, else derives one from QEMU's status; `qemu-exit` exits QEMU immediately | Only if a unit writes `/.runcvm/exitcode` before power-off | Status discarded; clean power-off | Status lost; kernel panic, no clean shutdown |
| `docker exec` | dropbear in the VM, reached via `dbclient`; exit codes and separate stdout/stderr preserved | Works | Works; dropbear respawned | Works |
| `docker stop` | `runcvm-ctr-shutdown`: ACPI power-down, then `busybox poweroff`, then `kill 1` | ACPI only (needs `systemd-logind`); the fallbacks do not work on systemd (SIGTERM makes systemd re-execute) | `busybox poweroff` fallback | `kill 1` |
| Mounts | Volumes and bind mounts served over virtiofs | Work | Work | Work |

README caveats apply to the console: stdout and stderr are not separated, and output just after boot or just before shutdown may be corrupted or lost.

#### F2. L1 to L0

L1 runs systemd, so L1's exit code cannot carry the results of individual L2 tests.

- **Results mount (authoritative)**: a per-run volume or directory at `/results`. The self-test writes per-test results and logs, aggregate JUnit/TAP, a `status` file, and a `done` marker last.
- **L1 exit code (cross-check of harness outcome only)**: the self-test unit's `ExecStopPost=` (given `$EXIT_STATUS` and `$SERVICE_RESULT` by systemd) writes the harness status to `/results/status` and `/.runcvm/exitcode`, runs `sync`, and the unit powers off. Not `qemu-exit`, which skips a clean shutdown and risks unflushed `RUNCVM_DISKS` data.
- **Codes**: 0 all gating tests passed; 1 test failures; 2 harness error; 124 timeout. No `done` marker means infrastructure failure.
- **Console (live progress only)**: the self-test unit writes to the console (`StandardOutput=tty`, `TTYPath=/dev/hvc0`) with a recognisable prefix. Batch mode reduces noise with `RUNCVM_KERNEL_APPEND=systemd.show_status=0` and a masked console getty. Nothing is parsed from it.
- **Control**: launch parameters via L1's command line and environment (B1 wrapper); `docker exec` for status and diagnostics; `docker stop` with a generous timeout. stdin is not used.

#### F3. L2 to L1

L2 tests span RunCVM's behaviours, with and without `--init` and with systemd images, so each test reports by a method that suits the options under test rather than a single uniform mechanism:

- **Exit status of `docker run`**: only where exit-code behaviour is itself under test (A2), or where the test's options make it reliable.
- **Results volume**: a volume mounted into L2 to which the workload writes results; works in every init mode and for non-root users (given suitable permissions). Preferred for most behaviour tests (environment, mounts, disks).
- **`docker exec` probe**: run L2 detached with a long-lived entrypoint, check state with `docker exec` (which preserves exit codes), then stop it. Suits networking, services and anything needing a running VM.
- **Exit-code wrapper** (`run_vm` helper): `--entrypoint=/.runcvm/guest/bin/bash … -c '"$@"; echo $? >/.runcvm/exitcode'`. Only for tests run as root that are not about the entrypoint, PID 1 or init (without `--init` it makes bash PID 1, changing what is tested). Relies on RunCVM's internal `/.runcvm/guest` path, acceptable for RunCVM's own suite only.
- **stdout**: only where stdout is itself under test, allowing for the console caveats.
- **systemd L2s** (nested Docker, swarm nodes): as F2 — results volume and `docker exec`.

#### F4. RunCVM extension: systemd-aware shutdown

`runcvm-ctr-shutdown` falls back to `busybox poweroff` and `kill 1`, neither of which shuts down systemd. When PID 1 in the VM is systemd, fall back instead to `systemctl poweroff` via the exec channel, or systemd's power-off signal (`SIGRTMIN+4`) to PID 1. Test: `docker stop` of a systemd L2 without `systemd-logind` powers off cleanly.

Automatic pass-through of the entrypoint's exit status is out of scope here: it touches the process structure inside the VM, which is a deliberate RunCVM feature, and belongs to the separate init-process project. One candidate for that project, confined to the `--init` path: `runcvm-vm-start-wrapper` (root, not PID 1) runs `runcvm-vm-start` as a child rather than exec'ing it and writes the status to `/.runcvm/exitcode` unless the application already has, taking care over signal handlers, waiting until the child has gone, and keeping the entrypoint in the console's foreground process group.

---

### G. Deferred and possible future work

- **Overlay root with a block-backed upper layer**: in the VM, root becomes an overlayfs with the image (virtiofs) as the read-only lower layer and the upper layer on the data disk, so writes anywhere under `/` go to the block device without copying the whole image. `/var/lib/docker` and containerd storage would still be bind-mounted directly from the data disk (overlay2 cannot run on overlayfs). The switch could be done in `runcvm-vm-init` as in E6; `docker diff`/`docker commit` would no longer see VM-side changes. An alternative to E6 if copying the whole image proves too costly.

- **Named-volume payload**: the wrapper detects a user-supplied mount at a reserved destination (e.g. `--mount type=volume,src=runcvm-1.2.3,dst=/.runcvm/guest`) and uses it instead of its own bind mount. Benefits: install a payload without host filesystem writes, `daemon.json` edits or dockerd restarts; per-container selection; `docker volume rm` to remove. Costs: wrapper/payload version skew becomes a compatibility contract needing an interface version; only covers payload changes, not wrapper changes. Revisit after C, once the wrapper–payload interface is documented.
- **GitHub runner inside a RunCVM VM**: not initially. Note that RunCVM does not support bind-mounting host sockets, so such a runner could only nest everything.
- **Claude Code-driven test runs in L1** (headless, triggered by the launcher), once B and D are proven.

---

## 3. Dependencies

```
A1 ──► A2, A3, A4, B2
B1 ──► B2 ──► B3 ──► B4 ──► D1 ──► D2 ──► D3 ──► D4
B1 (dev mode) ──► C (developed and tested in L1)
F1/F2 ──► B1 (batch mode), B2, B3;  F3 ──► A1 helpers, A2, A3
A3 ──► C5
C4 ──► B2 (runcvm-dev install as a new version, once C exists)
E3 ──► E1/E2 ──► E5 ──► B1 (shared data disk in the L1 image)
```

- A1 is small and unblocks everything; it can be done in the existing libvirt development VM.
- C needs only B1 in dev mode, so it can proceed alongside A3/A4 and B2/B3.
- D needs B3 and enough of A3 to be meaningful.
- E can start at any time; E3 (patched e2fsprogs build) comes first. B1 can use per-path disks until E lands.

## 4. Suggested sequence (for prioritisation)

0. **A buildable `main`**
   - PR #32: pin aports to `${ALPINE_VERSION}-stable` (with dropbear patch paths for Alpine 3.19's dropbear 2022.83). `main` currently fails to build (`nftrules: not found`); B2 depends on this. Check `docker exec` (patched dropbear) on a KVM host before merging.
1. **Trustworthy results**
   - A1. Trustworthy test runner (`tests/run`)
   - A2. Exit-code and shutdown behaviour: baseline tests

   Small, and unblocks everything; can be done in the existing libvirt development VM.

   Then merge the open PRs in stack order (section 4a), each tested in the libvirt development VM with the trustworthy runner: #34 (A1), #33 (explicit QEMU acceleration modes), #30 (dual-stack IPv6; also fixes VM boot failure for containers with a second network), then #28 (ARM64, Podman, installer). All land before A3 (needs #30's fix), B2, C3/C4, E3 and E6 (which touch the same code). #33 provides the check that L2s really run under KVM: `RUNCVM_QEMU_ACCEL=kvm` fails at creation if `/dev/kvm` is absent, rather than silently falling back to TCG. Follow-ups: multi-interface and overlay-network tests in A3.
2. **First L1 environment**
   - B1. L1 image — dev mode, proven by manual launch on L0 and in Dockside
3. **Side-by-side versions**, developed in L1
   - C1. Versioned layout
   - C2. Bootstrap wrapper — decide static binary or BundELF bundle at the start
   - C3. Main wrapper changes
   - C4. Installer and lifecycle
   - C5. Tests
4. **Batch runs and the launcher**
   - B1. L1 image — batch mode
   - B2. In-L1 tooling: `runcvm-dev` and `runcvm-selftest`
   - B3. L0 launcher script
   - F2. L1 to L0 (results mount, exit-code conventions, console, control)
5. **Proving runs**
   - B4. Proving L1 on L0 and in Dockside — record outcomes and settings, including the disk layout measurements
   - Then: upgrade Alpine from 3.19 (out of support) to a current stable release as its own pull request, with the dropbear patch paths back to the `src/` layout; compare full-suite results before and after in L1.
6. **The test suite proper**, developed in L1
   - A3. Core test tier
   - A4. Extended tier, including a hardened swarm test
   - F3. L2 to L1 (how each test observes L2)
   - F4. RunCVM extension: systemd-aware shutdown
7. **First CI runs**
   - D1. Runner container (first version)
   - D2. Controls on what jobs can do
   - D4. Workflows — `workflow_dispatch` only
8. **CI hardening and wider triggers**
   - D3. Hardening
   - D4. Workflows — pushes, then pull requests
9. **Faster VM storage**, alongside steps 2–6, on its own branches (section 4a)
   - E3. Build and bundling changes (patched mke2fs) — first
   - E1. Multi-path disk specs (both flavours)
   - E2. Populating a multi-path disk in one pass: repeated `-d SRC=SUBDIR`
   - E4. Adding a destination to an existing disk — if wanted
   - E5. Tests
   - E6. Optional whole-root disk — second branch

   B1 adopts whichever layout B4's measurements favour.
10. **As needed**
    - G. Deferred and possible future work

F1 (what RunCVM provides, and how it behaves) is reference material for steps 4 and 6 rather than work in itself.

## 4a. Implementation branches and pull requests

Implementation is split into independent branches, each with its own pull request against `main`, separate from this plan's branch:

| Branch (pull request) | Contents | Depends on |
|---|---|---|
| 1. Patched mke2fs and multi-path disks | E3 (e2fsprogs build stage with `patches/e2fsprogs/mke2fs-populate.patch`), E1 (both flavours: listed destinations and exclusion list), E2, E4 if wanted, E5 | A1 for the tests |
| 2. Whole-root disk | E6: `RUNCVM_DISKS` destination `/`, `pivot_root` in `runcvm-vm-init`, tests | The patched mke2fs from branch 1 |

Branch 2 needs only the mke2fs part of branch 1. If branch 1 is not yet merged, branch 2 is based on it (or the mke2fs build stage is split into a small first pull request that both build on). Other deliverables (A, B, C, D, F) get their own branches as they are started.

### Open pull requests (stack)

| Pull request | Branch | Based on | Contents |
|---|---|---|---|
| #32 | `fix/pin-aports-stable` | `main` | Pin aports to `${ALPINE_VERSION}-stable`; dropbear patch paths. Makes `main` build. |
| #34 | `a1-test-runner` | `main` | A1 runner, helpers, self-test; tests regrouped by tier. |
| #33 | `qemu-accel` | #34 | `RUNCVM_QEMU_ACCEL` (`kvm` default and fails without `/dev/kvm`, `auto`, `tcg`); `RUNCVM_QEMU_TCG_TB_MEM_SIZE` (TCG translation cache, added to the container's memory allowance); runtime errors reported through containerd's log; `tests/13-qemu-accel`; `clean_env` and `create_aliases` lists one name per line. |
| #30 | `claude/runcvm-ipv6-support-iwotel` | #33 | Dual-stack IPv6; multi-network boot fix; `tests/12-ipv6`. |
| #28 | `claude/macos-docker-compatibility-InrFB` | #30 | ARM64, Podman, installer. |

#32 and #34 are independent; test them merged together on a KVM host. Changes lower in the stack are merged upwards (#34 → #33 → #30 → #28), never rebased. The lists in `runcvm-ctr-defaults` are one name per line, sorted, so that branches adding names merge cleanly.

## 5. Open decisions

- Bootstrap implementation: static binary (e.g. Go) or independent BundELF bundle (C2).
- Location of the L1 image and tooling in the repository (`tests/env/` proposed).
- ~~Results format: TAP or JUnit.~~ Both, plus JSON (A1).
- Core tier time budget; swarm-test reliability threshold for promotion.
- Socket variant with D2 controls only, or go straight to D3.
- Registry for prebuilt images (if any), or always build inside L1.
- Whether people should also be required to use the launcher on L0, or only CI.
- Syntax for repeated `-d` (`SRC=SUBDIR`) and for `-x`/`-X`; whether to propose them upstream before or after RunCVM adopts them (E2, E6).
- Default disk layout for L1 (per-path, multi-path or whole-root), from B4's measurements.
- Whether the mke2fs build stage is a separate small pull request shared by branches 1 and 2 (section 4a).
- Whether adding a destination to an existing multi-path disk (E4) is supported initially.

## 6. Risks and unproven areas

- Nesting depth and performance at L2 (memory, network throughput, boot time).
- Swarm test may remain unreliable for reasons unrelated to RunCVM.
- L1's results depend on the results mount and `ExecStopPost` writing `/.runcvm/exitcode` before power-off; `docker stop` of L1 depends on `systemd-logind` handling ACPI power-down until F4 lands.
- RunCVM's exit-code contract will change under the separate init-process project; A2's expected values must be updated with it.
- Dockside profile capabilities (memory/CPU limits, interaction with `/disks`).
- BundELF relocatability to `/opt/runcvm/<version>` is assumed, not yet verified.
- Exec routing after bootstrap updates or host reboots (records in `/run` are lost at reboot; containers are recreated by `create`, which rewrites them).
- Runner security depends on controls outside workflow files (D2/D3); misconfiguration exposes L0.
- QEMU 8.1.5 under TCG occasionally segfaults (exit 139, reported as container exit code 70), seen only in full-suite runs; recorded in #33. KVM runs are unaffected; a QEMU upgrade may fix it.
- `RUNCVM_QEMU_DEBUG` reads `memory.events`, which exists only under cgroup v2.
- RunCVM carries an e2fsprogs patch (E2) until accepted upstream; tested on glibc only so far, musl/Alpine build to be confirmed.
