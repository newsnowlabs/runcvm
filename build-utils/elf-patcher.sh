#!/bin/sh

# Patches all required binaries and dynamic libraries (ELF libs) for full path-portability.
# - Copies all required binaries and ELF libs to the install location (CODE_PATH).
# - Sets the interpreter for all binaries to the exec location (EXEC_PATH).
# - Sets the RPATH for all binaries and ELF libs to the exec location (EXEC_PATH) (absolute mode)
#   or to a relative path (relative mode).
# - Adds a link to the dynamic linker (ld-musl-*.so.1) in the install location (CODE_PATH/lib/ld).

# Environment variable inputs:
# - BINARIES - list required binaries to be scanned and copied
# - EXTRA_LIBS - list extra libraries to be scanned and copied
# - CODE_PATH - path where binaries and libraries will be copied to
# - EXEC_PATH - path where binaries and libraries will be executed from

# EXEC_PATH defaults to CODE_PATH
EXEC_PATH="${EXEC_PATH:-$CODE_PATH}"

# Determine LD_MUSL filename, which is architecture-dependent
# e.g. ld-musl-aarch64.so.1 (linux/arm64), ld-musl-armhf.so.1 (linux/arm/v7), ld-musl-x86_64.so.1 (linux/amd64)
LD_MUSL_PATH=$(ls -1 /lib/ld-musl-* | head -n 1)
LD_MUSL_BIN=$(basename $LD_MUSL_PATH)

# LIB_PREFIX="/lib64"
LIB_PREFIX=""

# Where to copy binaries and libraries to
CODE_LIBPATH="$CODE_PATH$LIB_PREFIX"

# Where binaries and libraries will be executed from
EXEC_LIBPATH="$EXEC_PATH$LIB_PREFIX"

# Whether to use absolute or relative paths for RPATH
LIBPATH_TYPE="${LIBPATH_TYPE:-relative}"

append() {
  while read line; do echo "${line}${1}"; done
}

# Check that all dynamic library dependencies are correctly being resolved to versions stored within CODE_PATH.
# Prints any 
checkelfs() {
  local status=0

  # Deduce CODE_PATH from elf-patcher.sh execution path, if none provided (useful when called with --checkelfs within an alternative environment).
  [ -z $CODE_PATH ] && CODE_PATH=$(realpath $(dirname $0)/..)

  # Now check the ELF files
  for lib in $(cat $CODE_PATH/.binelfs $CODE_PATH/.libelfs)
  do
    printf "Checking: %s ...\n" "$lib" >&2
    $CODE_LIBPATH$LD_MUSL_PATH --list $lib 2>/dev/null | sed -nr '/=>/!d; s/^\s*(\S+)\s*=>\s*(.*?)(\s*\(0x[0-9a-f]+\))?$/- \2 \1/;/^.+$/p;' | egrep -v "^- ($CODE_PATH/|$EXEC_PATH/.*/$LD_MUSL_BIN)" >&2
  
    # If any libraries do not match the expected pattern, grep returns true
    if [ $? -eq 0 ]; then
      status=1
      echo "BAD" >&2
    else
      echo "GOOD" >&2
    fi
    echo >&2

    sleep 0.02
  done
  
  return $status
}

copy_binaries() {
  # Copy any non-Theia binaries we require to the install location.
  # Write their paths to cmd-elf-bin.

  mkdir -p $CODE_PATH/bin $CODE_PATH/usr/bin
  for bin in "$@"
  do
    local file=$(which $bin)

    if [ -n "$file" ]; then
      tar cv $file 2>/dev/null | tar x -C $CODE_PATH/
      echo "$CODE_PATH$file"
    fi
  done
}

scan_extra_libs() {
  find "$@" ! -type d | while read lib
    do
      local f=$(basename $lib)
      echo "$f $lib"
    done
}

# Using ldd, generate list of resolved library filepaths for each ELF binary and library,
# logging first argument (to be used as $lib) and second argument (to be used as $dest).
# e.g.
# libaio.so.1  /usr/lib/libaio.so.1
# libblkid.so.1  /lib/libblkid.so.1
find_lib_deps() {
  cat "$@" | xargs -n 1 -I '{}' ldd '{}' 2>/dev/null | sed -nr 's/^\s*(.*)=>\s*(.*?)\s.*$/\1 \2/p' | sort -u
}

copy_libs() {
  mkdir -p $CODE_LIBPATH

  # For each resolved library filepath:
  # - Copy $dest to the install location.
  # - If $dest is a symlink, copy the symlink to the install location too.
  # - If needed, add a symlink from $lib to $dest.
  #
  # N.B. These steps are all needed to ensure the Alpine dynamic linker can resolve library filepaths as required.
  #      For more, see https://www.musl-libc.org/doc/1.0.0/manual.html
  #
  sort -u "$@" | while read lib dest
  do
    # Copy $dest; and if $dest is a symlink, copy its target.
    # This could conceivably result in duplicates if multiple symlinks point to the same target,
    # but is much simpler than trying to copy symlinks and targets separately.
    cp -a --parents -L $dest $CODE_LIBPATH

    # If needed, add a symlink from $lib to $(basename $dest)
    [ "$(basename $dest)" != "$lib" ] && cd $CODE_LIBPATH/$(dirname $dest) && ln -s $(basename $dest) $lib && cd -

    if [ "$dest" != "$LD_MUSL_PATH" ]; then
        echo "$CODE_LIBPATH$dest" >>/tmp/cmd-elf-lib
    fi
  done
}

patch_binary() {
  local bin="$1"

  if patchelf --set-interpreter $EXEC_LIBPATH$LD_MUSL_PATH $bin 2>/dev/null; then
    echo patchelf --set-interpreter $EXEC_LIBPATH$LD_MUSL_PATH $bin >>/tmp/patchelf.log
    return 0
  fi

  return 1
}

patch_binaries() {
  # For all ELF binaries, set the interpreter to our own.
  for bin in $(sort -u "$@")
  do
    patch_binary "$bin" || exit 1
  done
}

patch_elf_binaries_and_libs() {
  # For all ELF libs, set the RPATH to our own, and force RPATH use.
  local p
  for lib in $(sort -u "$@")
  do

    if [ "$LIBPATH_TYPE" = "absolute" ]; then
      echo patchelf --force-rpath --set-rpath $CODE_LIBPATH/lib:$CODE_LIBPATH/usr/lib:$CODE_LIBPATH/usr/lib/xtables $lib >>/tmp/patchelf.log
      patchelf --force-rpath --set-rpath $CODE_LIBPATH/lib:$CODE_LIBPATH/usr/lib:$CODE_LIBPATH/usr/lib/xtables $lib >>/tmp/patchelf.log 2>&1
    else
      p=$(dirname "$lib" | sed -r "s|^$CODE_PATH/||; s|[^/]+|..|g")
      echo patchelf --force-rpath --set-rpath \$ORIGIN/$p$LIB_PREFIX/lib:\$ORIGIN/$p$LIB_PREFIX/usr/lib:\$ORIGIN/$p$LIB_PREFIX/usr/lib/xtables $lib >>/tmp/patchelf.log
      patchelf --force-rpath --set-rpath \
        \$ORIGIN/$p$LIB_PREFIX/lib:\$ORIGIN/$p$LIB_PREFIX/usr/lib:\$ORIGIN/$p$LIB_PREFIX/usr/lib/xtables \
        $lib >>/tmp/patchelf.log 2>&1 || exit 1
    fi

    # Fail silently if patchelf fails to set the interpreter: this is a catch-all for add libraries like /usr/lib/libcap.so.2
    # which strangely have an interpreter set.
    patch_binary "$lib"
  done
}

write_digest() {
  # Prepare full and unique list of ELF binaries and libs for reference purposes and for checking
  sort -u /tmp/cmd-elf-bin >$CODE_PATH/.binelfs
  sort -u /tmp/cmd-elf-lib >$CODE_PATH/.libelfs
}

# Run with --checkelfs from within any distribution, to check that all dynamic library dependencies
# are correctly being resolved to versions stored within CODE_PATH.
if [ "$1" = "--checkelfs" ]; then
  checkelfs
  exit $?
fi

# Initialise
>/tmp/cmd-elf-bin
>/tmp/cmd-elf-lib
>/tmp/libs

copy_binaries $BINARIES >>/tmp/cmd-elf-bin # Copy elf binaries to CODE_PATH and generate cmd-elf-bin
find_lib_deps /tmp/cmd-elf-bin >>/tmp/libs # Find library dependencies of these binaries
scan_extra_libs $EXTRA_LIBS >>/tmp/libs # Scan for extra libraries not formally declared as dependencies
copy_libs /tmp/libs # Copy the libraries to CODE_PATH and generate cmd-elf-lib
patch_binaries /tmp/cmd-elf-bin # Patch cmd-elf-bin interpreter
patch_elf_binaries_and_libs /tmp/cmd-elf-bin /tmp/cmd-elf-lib # Patch cmd-elf-bin and cmd-elf-lib rpath
write_digest # Write a summary of binaries and libraries to CODE_PATH

# Check the full list for any library dependencies being inadvertently resolved outside the install location.
# Returns true if OK, false on any problems.
checkelfs

# Symlink ld-musl-*.so.1 to ld
ln -s $LD_MUSL_BIN $CODE_LIBPATH/lib/ld