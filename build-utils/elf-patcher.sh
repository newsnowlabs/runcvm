#!/bin/sh

# Patches all required binaries, Theia binaries and Theia dynamic libraries (ELF libs) for full portability.

# Environment variable inputs:
# - BINARIES - list of additional system binaries 
# - CODE_PATH - path to Theia version to be scanned and patched

# Determine LD_MUSL filename, which is architecture-dependent
# e.g. ld-musl-aarch64.so.1 (linux/arm64), ld-musl-armhf.so.1 (linux/arm/v7), ld-musl-x86_64.so.1 (linux/amd64)
LD_MUSL_BIN=$(basename /lib/ld-musl-*)

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
    printf "Checking %-60s ... " "$lib" >&2
    $CODE_PATH/lib64/lib/$LD_MUSL_BIN --list $lib 2>/dev/null | sed -nr '/=>/!d; s/^\s*(\S+)\s*=>\s*(.*?)(\s*\(0x[0-9a-f]+\))?$/\1 \2/;/^.+$/p;' | append " in $lib" | egrep -v "$CODE_PATH/lib64"
  
    # If any libraries do not match the expected pattern, grep returns true
    if [ $? -eq 0 ]; then
      status=1
      echo "BAD" >&2
    else
      echo "GOOD" >&2
    fi

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
  mkdir -p $CODE_PATH/lib64

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
    cp -a --parents -L $dest $CODE_PATH/lib64

    # If needed, add a symlink from $lib to $(basename $dest)
    [ "$(basename $dest)" != "$lib" ] && cd $CODE_PATH/lib64/$(dirname $dest) && ln -s $(basename $dest) $lib && cd -

    if [ "$dest" != "/lib/$LD_MUSL_BIN" ]; then
        echo "$CODE_PATH/lib64$dest" >>/tmp/cmd-elf-lib
    fi
  done
}

patch_binaries() {
  # For all ELF binaries, set the interpreter to our own.
  for bin in $(sort -u "$@")
  do
    echo patchelf --set-interpreter $CODE_PATH/lib64/lib/$LD_MUSL_BIN $bin >>/tmp/patchelf.log
    patchelf --set-interpreter $CODE_PATH/lib64/lib/$LD_MUSL_BIN $bin >>/tmp/patchelf.log 2>&1
  done
}

patch_elf_binaries_and_libs() {
  # For all ELF libs, set the RPATH to our own, and force RPATH use.
  for lib in $(sort -u "$@")
  do
    echo patchelf --force-rpath --set-rpath $CODE_PATH/lib64/lib:$CODE_PATH/lib64/usr/lib:$CODE_PATH/lib64/usr/lib/xtables $lib >>/tmp/patchelf.log
    patchelf --force-rpath --set-rpath $CODE_PATH/lib64/lib:$CODE_PATH/lib64/usr/lib:$CODE_PATH/lib64/usr/lib/xtables $lib >>/tmp/patchelf.log 2>&1
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
