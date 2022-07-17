#!/bin/sh

MNT=/dkvm

if mountpoint $MNT >/dev/null; then

  rm -rf $MNT/*
  cp -a /opt/dkvm/* $MNT/

  cat <<_EOE_ >&2
Now enable DKVM for Docker (and, experimentally, Podman), by running:

/opt/dkvm/scripts/install.sh
_EOE_

else
  cat <<"_EOE_" >&2
Usage: docker run --rm -v /opt/dkvm:$MNT dkvm

 - Installs dkvm package to host:/opt/dkvm
 - N.B. /opt/dkvm is hardcoded and requires a rebuild to be changed

_EOE_

fi
