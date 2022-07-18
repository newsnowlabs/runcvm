#!/bin/sh

MNT=/dkvm
REPO=newsnowlabs/dkvm

if mountpoint $MNT >/dev/null; then

  rm -rf $MNT/*
  cp -a /opt/dkvm/* $MNT/

  echo "DKVM install/upgrade successful!" >&2
  echo >&2
else

  cat <<"_EOE_" >&2
Usage: docker run --rm -v /opt/dkvm:$MNT $REPO

 - Installs dkvm package to host:/opt/dkvm
 - N.B. /opt/dkvm is hardcoded and requires a rebuild to be changed

_EOE_

fi

# For installing across a docker swarm:
# - Run: docker service create --name=dkvm --mode=global --mount=type=bind,src=/opt/dkvm,dst=/dkvm dkvm:latest --pause
# - Wait: until the service is created everywhere
# - Run: docker service rm dkvm
if [ "$1" == "--pause" ]; then
  sleep infinity
fi
