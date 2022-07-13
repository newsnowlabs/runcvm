#!/bin/sh -x

# Patches all required binaries, Theia binaries and Theia dynamic libraries (ELF libs) for full portability.

# Environment variable inputs:
# - BINARIES - list of additional system binaries 
# - CODE_PATH - path to Theia version to be scanned and patched

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
  for lib in $(cat $CODE_PATH/.elfs)
  do
     $CODE_PATH/lib64/lib/ld-musl-x86_64.so.1 --list $lib 2>/dev/null | sed -nr '/=>/!d; s/^\s*(\S+)\s*=>\s*(.*?)(\s*\(0x[0-9a-f]+\))?$/\1 \2/;/^.+$/p;' | append " in $lib" | egrep -v "$CODE_PATH/lib64"
  
     # If any libraries do not match the expected pattern, grep returns true
     [ $? -eq 0 ] && status=1
  done
  
  return $status
}

scan_app() {
  local APP="$1"

  # Find all Theia ELF files that are dynamically linked.
  # - This should includes all Theia .node files and spawn-helper, but not statically-linked binaries like 'rg'
  # - The only way to tell if a file is an ELF binary (or library) is to check the first 4 bytes for the magic byte sequence.
  
  local app=$(basename "$APP")
  
  mkdir -p $CODE_PATH/apps/$app
  cp -a $APP $CODE_PATH/apps/$app
  find $CODE_PATH/apps/$app -type f ! -name '*.o' -exec hexdump -n 4 -e '4/1 "%2x" " {}\n"' {} \; | sed '/^7f454c46/!d; s/^7f454c46 //' | xargs -n 1 -P 4 file | grep dynamically >/tmp/theia-elf-file

  # Separate out those that do and do not require an interpreter (binaries and libs, respectively) into separate lists.
  grep interpreter /tmp/theia-elf-file | cut -d':' -f1 >>/tmp/theia-elf-bin
  grep -v interpreter /tmp/theia-elf-file | cut -d':' -f1 >>/tmp/theia-elf-lib
  
  # Clean up temporary file
  rm -f /tmp/theia-elf-file
}

scan_binaries() {
  # Copy any non-Theia binaries we require to the install location, and generate an additional list.
  mkdir -p $CODE_PATH/bin $CODE_PATH/usr/bin
  for bin in $BINARIES
  do
    local file=$(which $bin)
    tar cv $file | tar x -C $CODE_PATH/
    echo $CODE_PATH/$file >>/tmp/cmd-elf-bin
  done
}

# Using ldd, generate list of resolved library filepaths for each ELF binary and library,
# logging first argument (to be used as $lib) and second argument (to be used as $dest).
find_lib_deps() {
  cat /tmp/theia-elf-bin /tmp/theia-elf-lib | xargs -n 1 -I '{}' ldd '{}' 2>/dev/null | sed -nr 's/^\s*(.*)=>\s*(.*?)\s.*$/\1 \2/p' | sort -u >/tmp/theia-lib
  cat /tmp/cmd-elf-bin | xargs -n 1 -I '{}' ldd '{}' 2>/dev/null | sed -nr 's/^\s*(.*)=>\s*(.*?)\s.*$/\1 \2/p' | sort -u >/tmp/cmd-lib
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
  sort -u /tmp/theia-lib /tmp/cmd-lib | while read lib dest
  do
    # Copy $dest; and if $dest is a symlink, copy its target.
    # This could conceivably result in duplicates if multiple symlinks point to the same target,
    # but is much simpler than trying to copy symlinks and targets separately.
    cp -a --parents -L $dest $CODE_PATH/lib64

    # If needed, add a symlink from $lib to $(basename $dest)
    [ "$(basename $dest)" != "$lib" ] && cd $CODE_PATH/lib64/$(dirname $dest) && ln -s $(basename $dest) $lib && cd -
  done
}

patch_binaries() {
  # For all ELF binaries, set the interpreter to our own.
  for bin in $(sort -u /tmp/cmd-elf-bin /tmp/theia-elf-bin)
  do
    patchelf --set-interpreter $CODE_PATH/lib64/lib/ld-musl-x86_64.so.1 $bin
  done
}

patch_elf_libs() {
  # For all ELF libs, set the RPATH to our own, and force RPATH use.
  for lib in $(sort -u /tmp/cmd-elf-bin /tmp/theia-elf-bin /tmp/theia-elf-lib)
  do
    patchelf --force-rpath --set-rpath $CODE_PATH/lib64/lib:$CODE_PATH/lib64/usr/lib $lib
  done
}

write_digest() {
  # Prepare full and unique list of ELF binaries and libs for reference purposes and for checking
  sort -u /tmp/cmd-elf-bin /tmp/theia-elf-bin /tmp/theia-elf-lib >$CODE_PATH/.elfs
}

# Run with --checkelfs from within any distribution, to check that all dynamic library dependencies
# are correctly being resolved to versions stored within CODE_PATH.
if [ "$1" = "--checkelfs" ]; then
  checkelfs
  exit $?
fi

# Initialise
>/tmp/theia-elf-bin
>/tmp/theia-elf-lib
>/tmp/cmd-elf-bin

# for app in "${APPS[@]}"; do scan_app "$app"; done
scan_binaries
find_lib_deps
copy_libs
patch_binaries
patch_elf_libs
write_digest

# Check the full list for any library dependencies being inadvertently resolved outside the install location.
# Returns true if OK, false on any problems.
checkelfs
