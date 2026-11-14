# virtiofsd patches

RunCVM builds Alpine's own `virtiofsd` package (`community/virtiofsd` in aports, at the version Alpine ships) with these patches, applied in filename order (see the `alpine-virtiofsd` stage in the `Dockerfile`). Each is a `git format-patch` file, one change each, against that version.

| Patch | Origin | Effect | Drop when |
|---|---|---|---|
| `0001-passthrough-Let-the-guest-cache-symbolic-link-target.patch` | RunCVM; to be proposed upstream | Negotiates `FUSE_CACHE_SYMLINKS` unless `--cache=never`: the guest keeps symbolic link targets cached instead of asking for each on every path walk (e.g. one request fewer for each run of a BusyBox applet) | A `virtiofsd` release has it |
| `0002-passthrough-Set-FOPEN_NOFLUSH-on-files-opened-read-o.patch` | RunCVM; to be proposed upstream | Sets `FOPEN_NOFLUSH` on files opened read-only: the guest skips a flush request, which has no effect there, on every `close()` | A `virtiofsd` release has it |
| `0003-passthrough-drop-CAP_FSETID-in-fallocate-and-copy_fi.patch` | Backport of upstream commit `fc18227` (not in 1.13.3) | With `--killpriv-v2`, clears setuid and setgid bits, and file capabilities, on `fallocate` and `copy_file_range` | A `virtiofsd` release that Alpine ships has it |
| `0004-passthrough-Let-the-guest-decide-on-setuid-setgid-in.patch` | RunCVM; to be proposed upstream; needs 0003 | With `--killpriv-v2`, declines `copy_file_range` to a setuid, or setgid and group-executable, file, so that the guest copies with ordinary writes and keeps or clears the bits as on a local file system | A `virtiofsd` release has it, or 0003 is dropped |

Each patch applies, builds and passes `virtiofsd`'s tests without the others, except 0004, which needs 0003. To drop one, delete its file; if a later patch then applies with offsets or fuzz, refresh it.
