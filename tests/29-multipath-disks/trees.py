"""Sample file trees for the RUNCVM_DISKS tests, and a description of a tree for comparing them.

Run with Python 3 as root, with CAP_SYS_ADMIN for trusted.* xattrs:

  trees.py build DIR...   build the sample tree in each DIR
  trees.py describe DIR   print a JSON description of the tree at DIR

Run in containers and VMs (with the script on stdin, as 'python3 - ARGS'),
so it uses only the standard library.
"""

import hashlib
import json
import os
import stat
import sys

# security.capability, revision 2, effective, permitting cap_net_raw (13).
CAPABILITY = bytes([0x01, 0x00, 0x00, 0x02, 0x00, 0x20, 0x00, 0x00]) + bytes(12)


def build(root):
    os.makedirs(root, exist_ok=True)

    def path(rel):
        return os.path.join(root, rel)

    for rel, mode, uid, gid in [("dir", 0o755, 0, 0), ("dir/sub", 0o700, 1000, 1000),
                                ("sticky", 0o1777, 0, 0), ("empty", 0o750, 2000, 3000)]:
        os.makedirs(path(rel), exist_ok=True)
        os.chown(path(rel), uid, gid)
        os.chmod(path(rel), mode)

    files = [("file", b"file contents\n", 0o644, 0, 0),
             ("empty-file", b"", 0o600, 1000, 1000),
             ("big", bytes(range(256)) * 1200, 0o640, 0, 4000),
             ("dir/setuid", b"#!/bin/sh\n", 0o4750, 1234, 567),
             ("dir/setgid", b"#!/bin/sh\n", 0o2755, 0, 1234),
             ("dir/capability", b"#!/bin/sh\n", 0o755, 0, 0),
             ("dir/sub/name with spaces", b"spaces\n", 0o444, 1000, 1000)]
    for rel, data, mode, uid, gid in files:
        with open(path(rel), "wb") as f:
            f.write(data)
        os.chown(path(rel), uid, gid)
        os.chmod(path(rel), mode)

    os.link(path("file"), path("dir/hard1"))
    os.link(path("file"), path("dir/sub/hard2"))
    os.symlink("dir/sub", path("rel-link"))
    os.symlink("/etc/hostname", path("abs-link"))
    os.symlink("nowhere", path("dangling"))
    os.lchown(path("rel-link"), 1000, 1000)
    os.mkfifo(path("fifo"), 0o640)

    os.setxattr(path("file"), "user.text", b"alpha")
    os.setxattr(path("file"), "user.binary", bytes(range(64)))
    os.setxattr(path("dir"), "user.dir", b"directory")
    os.setxattr(path("dir/capability"), "security.capability", CAPABILITY)
    try:
        os.setxattr(path("file"), "trusted.text", b"trusted")
        os.setxattr(path("dir"), "trusted.dir", b"trusted directory")
    except PermissionError:
        pass

    # Fixed times, set deepest first, so that later entries do not change earlier directories'.
    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        entries += [os.path.join(dirpath, n) for n in dirnames + filenames]
    for i, p in enumerate(sorted(entries, key=lambda p: -p.count("/"))):
        t = 1500000000 + i * 1000
        os.utime(p, (t, t), follow_symlinks=False)
    os.utime(root, (1400000000, 1400000000))


def describe(root):
    entries = []
    inodes = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        if dirpath == root and "lost+found" in dirnames:
            dirnames.remove("lost+found")
        for name in [None] + sorted(dirnames + filenames):
            if name is None:
                if dirpath != root:
                    continue
                p, rel = root, "."
            else:
                p = os.path.join(dirpath, name)
                rel = os.path.relpath(p, root)
            st = os.lstat(p)
            e = {"path": rel, "mode": oct(st.st_mode), "uid": st.st_uid, "gid": st.st_gid}
            if rel != ".":
                e["mtime"] = int(st.st_mtime)
            if stat.S_ISREG(st.st_mode):
                with open(p, "rb") as f:
                    e["sha256"] = hashlib.sha256(f.read()).hexdigest()
                if st.st_nlink > 1:
                    e["hardlink"] = inodes.setdefault(st.st_ino, rel)
            if stat.S_ISLNK(st.st_mode):
                e["target"] = os.readlink(p)
            else:
                e["xattrs"] = {k: os.getxattr(p, k).hex() for k in sorted(os.listxattr(p))}
            entries.append(e)
    return entries


if __name__ == "__main__":
    if sys.argv[1] == "build":
        for d in sys.argv[2:]:
            build(d)
    else:
        print(json.dumps(describe(sys.argv[2])))
