#!/bin/sh

# Usage: make-seccomp-profile.sh [<package>]
#
# Writes <package>/scripts/seccomp/profile.json (default package /opt/runcvm), the seccomp
# profile runcvm-runtime gives a container under RUNCVM_SECCOMP=minimal: it allows the system calls
# listed in <package>/scripts/seccomp/<arch>, for this machine's architecture, and in
# <package>/scripts/seccomp/virtiofsd, and denies any other with EPERM. runcvm-runtime adds
# io_uring's calls to its allow rule for a Container/VM whose disks may use io_uring.
#
# Fails, writing nothing, if this architecture has no list, or if the package's virtiofsd is not the
# version whose own allowlist scripts/seccomp/virtiofsd holds: virtiofsd's system calls are those
# its own filter allows, and another version may need calls the list lacks.
#
# The image build runs this. On a host, run it after changing a list in /opt/runcvm/scripts/seccomp.

set -e

PACKAGE=${1:-/opt/runcvm}
DIR=$PACKAGE/scripts/seccomp
ARCH=$(uname -m)

fail() {
  echo "$0: $*" >&2
  exit 1
}

jq() {
  "$PACKAGE/lib/ld" "$PACKAGE/usr/bin/jq" "$@"
}

# The architectures the engines' default profiles name for this one: the native ABI and the
# compatibility ABIs its kernel also accepts.
case "$ARCH" in
  x86_64) ARCHITECTURES='["SCMP_ARCH_X86_64","SCMP_ARCH_X86","SCMP_ARCH_X32"]' ;;
  aarch64) ARCHITECTURES='["SCMP_ARCH_AARCH64","SCMP_ARCH_ARM"]' ;;
  *) fail "no seccomp profile for architecture '$ARCH'" ;;
esac
[ -f "$DIR/$ARCH" ] || fail "$DIR/$ARCH missing: no system call list for this architecture"

BUILT=$("$PACKAGE/lib/ld" "$PACKAGE/usr/lib/qemu/virtiofsd" --version | sed -n 's/^virtiofsd \([0-9.]*\).*/\1/p')
LISTED=$(sed -n 's/^virtiofsd-version //p' "$DIR/virtiofsd")
[ -n "$BUILT" ] && [ "$BUILT" = "$LISTED" ] ||
  fail "virtiofsd is version '$BUILT', but $DIR/virtiofsd lists the system calls of version '$LISTED': update the list from that version's src/seccomp.rs"

grep -hv -e '^#' -e '^virtiofsd-version ' -e '^$' "$DIR/$ARCH" "$DIR/virtiofsd" |
  jq -R . | jq -s --argjson architectures "$ARCHITECTURES" '{
    "defaultAction": "SCMP_ACT_ERRNO", "defaultErrnoRet": 1, "architectures": $architectures,
    "syscalls": [{"names": unique, "action": "SCMP_ACT_ALLOW"}]}' >"$DIR/profile.json.tmp"
mv "$DIR/profile.json.tmp" "$DIR/profile.json"
