#!/bin/sh

# Usage: make-seccomp-profile.sh [<package>]
#
# Writes <package>/scripts/seccomp/profile.json (default package /opt/runcvm), the seccomp
# profile runcvm-runtime gives a container under RUNCVM_SECCOMP=minimal: it allows the system calls
# listed in <package>/scripts/seccomp/<arch>, for this machine's architecture, and in
# <package>/scripts/seccomp/virtiofsd, and denies any other with EPERM. runcvm-runtime adds
# io_uring's calls to its first rule, the allow rule, for a Container/VM whose disks may use
# io_uring. As in the engines' default profiles, clone is allowed only without the flags that
# create namespaces, and clone3, whose flags a filter cannot inspect, fails with ENOSYS, so that
# its callers use clone.
#
# Fails, writing nothing, if this architecture has no list, if a list is empty, or if the package's
# virtiofsd is not the version whose own allowlist scripts/seccomp/virtiofsd holds: virtiofsd's
# system calls are those its own filter allows, and another version may need calls the list lacks.
#
# The image build runs this. On a host, run it after changing a list in /opt/runcvm/scripts/seccomp.

set -e

PACKAGE=${1:-/opt/runcvm}
DIR=$PACKAGE/scripts/seccomp
ARCH=$(uname -m)
TMP=$DIR/profile.json.$$

fail() {
  rm -f "$TMP"
  echo "$0: $*" >&2
  exit 1
}

jq() {
  "$PACKAGE/lib/ld" "$PACKAGE/usr/bin/jq" "$@"
}

# Prints the system call names in list $1: one per line, without blank lines, comments (#) and the
# 'virtiofsd-version' line. Fails if the list is missing or names none.
names() {
  local out
  [ -f "$1" ] || fail "$1 missing: no system call list"
  out=$(sed -e '/^#/d' -e '/^virtiofsd-version /d' -e '/^[[:space:]]*$/d' "$1")
  [ -n "$out" ] || fail "$1 lists no system calls"
  printf '%s\n' "$out"
}

# The architectures the engines' default profiles name for this one: the native ABI and the
# compatibility ABIs its kernel also accepts.
case "$ARCH" in
  x86_64) ARCHITECTURES='["SCMP_ARCH_X86_64","SCMP_ARCH_X86","SCMP_ARCH_X32"]' ;;
  aarch64) ARCHITECTURES='["SCMP_ARCH_AARCH64","SCMP_ARCH_ARM"]' ;;
  *) fail "no seccomp profile for architecture '$ARCH'" ;;
esac

VERSION=$("$PACKAGE/lib/ld" "$PACKAGE/usr/lib/qemu/virtiofsd" --version) ||
  fail "$PACKAGE/usr/lib/qemu/virtiofsd --version failed"
BUILT=$(printf '%s\n' "$VERSION" | sed -n 's/^virtiofsd \([^ ]*\).*/\1/p')
LISTED=$(sed -n 's/^virtiofsd-version //p' "$DIR/virtiofsd")
[ -n "$BUILT" ] && [ "$BUILT" = "$LISTED" ] ||
  fail "virtiofsd is version '$BUILT', but $DIR/virtiofsd lists the system calls of version '$LISTED': update the list from that version's src/seccomp.rs"

ARCH_NAMES=$(names "$DIR/$ARCH")
VIRTIOFSD_NAMES=$(names "$DIR/virtiofsd")
NAMES=$(printf '%s\n%s\n' "$ARCH_NAMES" "$VIRTIOFSD_NAMES")

# CLONE_NEWNS, CLONE_NEWCGROUP, CLONE_NEWUTS, CLONE_NEWIPC, CLONE_NEWUSER, CLONE_NEWPID and
# CLONE_NEWNET, in clone's flags, its first argument on x86_64 and aarch64.
printf '%s\n' "$NAMES" | jq -Rs --argjson architectures "$ARCHITECTURES" '{
    "defaultAction": "SCMP_ACT_ERRNO", "defaultErrnoRet": 1, "architectures": $architectures,
    "syscalls": [
      {"names": (split("\n") | map(select(length > 0)) | unique - ["clone", "clone3"]),
       "action": "SCMP_ACT_ALLOW"},
      {"names": ["clone"], "action": "SCMP_ACT_ALLOW",
       "args": [{"index": 0, "value": 2114060288, "valueTwo": 0, "op": "SCMP_CMP_MASKED_EQ"}]},
      {"names": ["clone3"], "action": "SCMP_ACT_ERRNO", "errnoRet": 38}]}' >"$TMP" ||
  fail "writing the profile failed"
[ "$(jq '.syscalls[0].names | length' "$TMP")" -gt 0 ] || fail "the profile allows no system calls"
mv "$TMP" "$DIR/profile.json" || fail "replacing $DIR/profile.json failed"
