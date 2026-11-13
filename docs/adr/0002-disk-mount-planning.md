# ADR 0002: One plan for disks' validation, population and mount order

Status: accepted

## Context

`RUNCVM_DISKS` gives a Container/VM virtual disks, each mounted at one or more destinations. In the VM, those disks share the filesystem tree with the container's own mounts: Docker's volumes and bind mounts (including files such as `/etc/hosts`), which reach the VM through `virtiofsd`, and tmpfs mounts, which `runcvm-runtime` removes from the container and passes to the VM. Any of these may lie above or below a disk's destination, or at it.

Three things depend on how those mounts relate:

- **Validation**, in the container, before anything is created: which specs are acceptable, alone and together.
- **Population** of a new disk, by `mke2fs` in the container (`ext4`) or by `cp` in the VM (other filesystems): what it copies from the image, and what it must leave out because something else is mounted there in the VM.
- **Mount order** in the VM: Docker mounts a deeper mount over a shallower one, whatever order it is given them in, and a Container/VM should look the same.

Each needs the same facts: every destination as a path in the image, with its symbolic links resolved; every container mount; every tmpfs mount; and where each disk's backing file is visible.

## Decision

`runcvm-ctr-qemu` gathers those facts once, into tables, and validation, population and the mount order are all derived from them, in phases:

1. **Parse** each disk spec and each tmpfs mount, and read every container mount from mountinfo. Every destination, whatever the disk's layout, follows one set of rules.
2. **Check** the disks against each other and the tmpfs mounts: no shared destination; no shared backing file (compared by file identity, including for files not yet created, so that paths reaching one file through different mounts or links are caught); no two existing disks with one filesystem UUID.
3. **Plan**: the mounts the VM makes, in order of depth; the container mounts a disk or tmpfs mount would hide (*held* mounts, each with a fixed ID), which the VM holds during boot and mounts again over it; and each new disk's exclusions, checked against `mke2fs`'s limits.
4. **Create** missing destination directories, then the disks.
5. **Write** what the VM reads: `/.runcvm/fstab`, `/.runcvm/held-mounts`, the population lists, and the whole-root disk's files.

Nothing is created until phases 1 to 3 have passed, so an invalid plan anywhere in `RUNCVM_DISKS` leaves nothing behind.

**What a new disk holds.** A new disk holds nothing that is mounted below its destinations in the VM: container mounts, other disks' and tmpfs mounts' destinations, and any disk's backing file the VM sees there, its own included. Each is excluded outermost-first, leaving an empty directory for a directory and nothing for a file (the VM's mount step creates a file mountpoint where it needs one). A container mount *at* a destination is not excluded: a new disk there is populated from it, as `docker:dind`'s `VOLUME /var/lib/docker` needs. Exclusions are by path, not by device, because a nested volume, or a bind-mounted file, can be on the same host filesystem as the directory it is mounted in.

**Backing files are found by file identity.** The container and the VM see different trees: Docker's mounts, other than those at or below `/disks`, are mounted only below `/vm`, and one volume may be mounted at several paths. So a backing file's path in the container is only a candidate for its path in the VM. The candidates (that path, and its paths through every mount of the same filesystem below `/vm`) count only where both views reach the same file, or, for a file not yet created, the same directory.

**Population before the root switch.** `runcvm-vm-init` populates new `xfs` and `btrfs` disks before switching to any whole-root disk, from the image's own tree, masking each exclusion while copying.

**No control characters in mount or backing-file paths.** No mount destination, disk destination or backing file path may contain an ASCII control character (a byte 0x01–0x1F or 0x7F), as given or once symbolic links are resolved: `runcvm-runtime` rejects Docker's mount destinations when the container is created, and `runcvm-ctr-qemu` rejects the resolved paths, and `RUNCVM_DISKS`'s, before creating anything, each shown in bash's `$'…'` notation. A path is compared as bytes, whatever the locale, so UTF-8 characters are allowed. Such paths, which nobody needs, would otherwise have to survive every tool that reads a path as a line or a word (`realpath`, `readlink`, `dirname`, glob patterns, QEMU's arguments) exactly. The files inside an image or a volume are not restricted: a new disk is populated with every name as it is.

**Paths are escaped in every file passed to the VM.** Disk destinations may not contain whitespace or `\`, but container mountpoints and tmpfs destinations may contain spaces and `\`. Every path in those files uses fstab's octal escapes for space and `\` (and, as a safeguard, for tab and newline, which the rule above keeps out), and each reader decodes each field exactly once. `runcvm-runtime` escapes each tmpfs field before joining the fields.

**Held mounts in the VM's fstab: `RUNCVM_FSTAB`.** With `disks`, the default, each held mount appears in `/etc/fstab` only as a comment, and its holding tmpfs is detached after boot, leaving nothing of it behind. With `all`, each appears as a bind mount from its slot in `/.runcvm/submounts`, which stays mounted, so that `mount -a` and systemd can mount it again; an image without `/etc/fstab` is given one. Either way, once held, each mount's original is detached from its path, so the mount table shows one mount at each path, as `mount -a` and systemd's `umount` expect.

## Out of scope: a second boot in one Container/VM

`systemctl kexec`, and anything else that boots the VM's kernel again without restarting the Container/VM, is unsupported. `runcvm-vm-init` assumes one boot per container start: it populates each new disk listed at container start, renames `/.dockerenv`, and switches to a whole-root disk, none of which is safe to repeat; and `systemctl kexec` loads the image's own boot entries, not RunCVM's kernel, initramfs and command line. `RUNCVM_FSTAB=all` lets held mounts be mounted again while their holding mounts remain; it does not support another boot, nor a userspace reboot (`systemctl soft-reboot`), which also stops the processes `runcvm-vm-init` starts, such as the SSH server behind `docker exec`.
