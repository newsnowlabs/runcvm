#!/bin/sh

MNT=/dkvm

if mountpoint $MNT >/dev/null; then

  rm -rf $MNT/*
  cp -a /opt/dkvm/* $MNT/

else
  echo "Usage: docker run --rm -v /opt/dkvm:$MNT dkvm" >&2
  echo >&2
  echo " - Installs dkvm to host:/opt/dkvm" >&2
  echo " - N.B. /opt/dkvm is hardcoded and requires a rebuild to be changed" >&2
  
fi
