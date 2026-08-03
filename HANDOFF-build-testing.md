# Handoff: build testing `claude/macos-docker-compatibility-InrFB`

**Status:** all code changes are committed and pushed. Nothing has ever been
build-tested — the previous environment had no registry or package-repo egress.
**Your job is to run the builds and fix whatever they surface.**

Branch head at handoff: `1daed0d`. Working tree clean, HEAD == origin.

---

## 1. What this branch does

Makes the RunCVM image build on **linux/arm64** (for Lima / Podman Desktop on
Apple Silicon) without regressing **linux/amd64**. Both architectures must build
and produce a working image from this one branch.

Commits (oldest first):

| Commit | Content |
|---|---|
| `f5fc308` | Plan doc (`PLAN-macos-arm64.md`) |
| `c543a77` | Main multi-arch work: Dockerfile, runtime scripts, install script |
| `cb948f5` | `qemu-exit.c` — `#ifdef __x86_64__`; ARM64 uses `reboot(RB_POWER_OFF)` |
| `f796356` | Split SeaBIOS into `-amd64` / `-arm64` stages (arm64 = no-op) |
| `a4db507` | Explicit `git sparse-checkout` package list |
| `eb19ea6`, `b3ee2bc` | dropbear `nftrules` sed hacks — **later reverted, see below** |
| `1daed0d` | amd64 regression fixes (the audit) |

⚠️ `eb19ea6`/`b3ee2bc` are still in history but their changes were **removed** by
`1daed0d`, which fixed the root cause instead. Don't be confused by the diff history.

---

## 2. Network egress required (this is what blocked the last environment)

A full build needs **all** of these. In the previous environment the ones marked
🔴 returned `Host not in allowlist` and could not be worked around — including via
ghcr.io, whose blob CDN is separately blocked.

| Host | Needed by | Previously |
|---|---|---|
| `production.cloudfront.docker.com` | Docker Hub image **blobs** | 🔴 blocked |
| `pkg-containers.githubusercontent.com` | ghcr.io image **blobs** (fallback) | 🔴 blocked |
| `dl-cdn.alpinelinux.org` | `apk` in every Alpine stage | 🔴 blocked |
| `gitlab.alpinelinux.org` | aports clone (4 stages) | 🔴 blocked |
| `deb.debian.org` | `debian-kernel` stage | 🔴 blocked |
| `github.com`, `codeload.github.com` | dropbear-epka clone | ✅ ok |
| `archive.ubuntu.com` | `ubuntu-kernel` stage | ✅ ok |
| `yum.oracle.com` | `oracle-kernel` stage | ✅ ok |

**Verify egress before starting** — don't burn time on builds that can't pull:

```sh
for h in production.cloudfront.docker.com dl-cdn.alpinelinux.org \
         gitlab.alpinelinux.org deb.debian.org; do
  printf '%-42s ' "$h"
  curl -s "https://$h/" | grep -qi 'not in allowlist' && echo BLOCKED || echo ok
done
```

Registry **manifests** resolved fine even when blocked — only blob downloads
failed. So `docker manifest inspect` succeeding does **not** mean pulls work.
Test with an actual `docker pull alpine:3.19`.

Start the daemon with `dockerd &` (it is not running by default; it was not
managed by systemd in the previous environment).

---

## 3. Build commands

Native arch first, then the other via emulation:

```sh
# Stage-by-stage — the aports stages are the risky ones, do them first
for s in alpine-sdk alpine-seabios-amd64 alpine-dnsmasq alpine-dropbear alpine-mkinitfs; do
  docker buildx build --platform linux/amd64 --target "$s" --progress=plain . \
    || echo "FAILED: $s"
done

# Full builds
docker buildx build --platform linux/amd64 -t runcvm:amd64 .
docker buildx build --platform linux/arm64 -t runcvm:arm64 .   # needs binfmt/qemu
```

For arm64 on an amd64 host: `docker run --privileged --rm tonistiigi/binfmt --install arm64`.

---

## 4. Most likely failure — check this first 🔴

`1daed0d` pinned the aports clone (`Dockerfile:~25`) from **master HEAD** to
**`${ALPINE_VERSION}-stable`** (= `3.19-stable`). This was the root-cause fix for
`nftrules: not found`, which was version skew between aports master and the
`alpine:3.19` base — an arch-independent bug that also hit amd64.

**The risk this introduces:** `patches/seabios/qemu-fw-cfg-fix.patch` was written
against whatever seabios version master had. `3.19-stable` may carry a different
version, so **the patch may no longer apply**. Same theoretically applies to the
dnsmasq / dropbear / mkinitfs patches.

If a patch fails to apply:
1. Check the version: `git -C ~/aports log --oneline -1 main/seabios/APKBUILD`
2. Rebase the patch in `patches/` against that version — **preferred**.
3. Only if that's impractical, revert to master HEAD and instead reinstate a
   targeted fix for the specific breakage (the old `sed` removing
   `$pkgname-nftrules` from `subpackages=` is in `eb19ea6`/`b3ee2bc`).

Also confirm `3.19-stable` exists as a branch — it could not be verified offline:
`git ls-remote --heads https://gitlab.alpinelinux.org/alpine/aports.git '3.19-stable'`

---

## 5. Other things to verify in the built image

```sh
docker run --rm -v /tmp/rcv:/runcvm runcvm:amd64 --quiet

head -1 /tmp/rcv/scripts/runcvm-runtime   # must be: #!/opt/runcvm/lib/ld /opt/runcvm/bin/bash
ls -l /tmp/rcv/lib/ld                     # symlink -> ./ld-musl-x86_64.so.1, must resolve
ls /tmp/rcv/bin/qemu-system-*             # x86_64 on amd64, aarch64 on arm64
ls -d /tmp/rcv/usr/share/OVMF             # AAVMF on arm64
for d in alpine debian ubuntu openwrt ol; do ls -l /tmp/rcv/kernels/$d/latest; done
```

The shebang is the one to watch: `1daed0d` changed it from the hardcoded
`ld-musl-x86_64.so.1` to the arch-independent `/opt/runcvm/lib/ld` symlink that
`make-bundelf-bundle.sh:563` creates, and **deleted** the Dockerfile step that
used to patch it. If `/opt/runcvm/lib/ld` is missing or dangling, `runcvm-runtime`
is unexecutable and every container fails at `create`.

### Runtime smoke tests

```sh
sudo ./runcvm-scripts/runcvm-install-runtime.sh
docker run --runtime=runcvm --rm alpine echo ok
docker run --runtime=runcvm --rm alpine sh -c 'exit 42'; echo "expect 42, got $?"
```

The exit-code test exercises `isa-debug-exit` on amd64 and the
`/.runcvm/exitcode` + `reboot(RB_POWER_OFF)` path on arm64 — these are different
code paths in `qemu-exit/qemu-exit.c`, so run it on **both** arches.

If a host has no `/dev/kvm`, both arches should now fall back to TCG rather than
erroring (`runcvm-ctr-qemu`). Worth testing if you can find/simulate such a host.

---

## 6. Already validated offline (don't redo)

Static checks, all passing at `1daed0d`:

- Stage graph: 16 stages, every `COPY --from=` resolves; `FROM alpine-seabios-${TARGETARCH}`
  resolves for both `amd64` and `arm64`
- `ARG TARGETARCH` / `ARG TARGETPLATFORM` declared globally (lines 8–9) before the
  first `FROM` (line 13) — they were previously stage-scoped no-ops
- All 4 heredoc `RUN` bodies pass `sh -n`
- Arch conditionals: amd64 → `qemu-system-x86_64`/`ovmf`; arm64 → `qemu-system-aarch64`/`aavmf`
- `BUNDELF_BINARIES` sed yields 24 words on both arches (correct substitution, no word-splitting)
- `bash -n` / `sh -n` clean on all modified scripts

Two hypotheses were **tested and disproved** — don't re-flag them:
- `export BUNDELF_BINARIES=$(...)` unquoted does *not* word-split (assignment context)
- GNU `cp -a src/. dest/` *does* create a missing `dest`

---

## 7. Full list of changes in `1daed0d` (the amd64 audit)

Build:
1. aports pinned to `${ALPINE_VERSION}-stable`; `ARG ALPINE_VERSION` redeclared in `alpine-sdk`
2. Both dropbear `nftrules` seds removed (superseded by 1)
3. Intermediate `cp -a <pkgs>/$ARCH/. /tmp/<n>/` steps dropped; `apk` reads package
   paths directly. The mkinitfs one ran in `alpine-kernel`, which has **no coreutils**
4. `ARG TARGETARCH`/`TARGETPLATFORM` hoisted to global scope; 4 strays removed
5. `runcvm-runtime` shebang-patch step deleted; shebang points at `/opt/runcvm/lib/ld`

Runtime:
6. `runcvm-ctr-qemu`: x86_64 now selects KVM vs TCG on `/dev/kvm`, mirroring arm64
   (previously forced `-enable-kvm`/`accel=kvm` while `/dev/kvm` injection had become conditional)
7. `runcvm-runtime`: `/dev/vhost-net` gated on `/dev/vhost-net`, not `/dev/kvm`
8. `runcvm-install-runtime.sh`: podman hint restored when both runtimes present;
   containers.conf grep anchored to the `runcvm =` key

---

## 8. Cleanup

Delete this file and `PLAN-macos-arm64.md` before the branch is merged.
