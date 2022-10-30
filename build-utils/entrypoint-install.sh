#!/bin/sh

MNT=/runcvm
REPO=newsnowlabs/runcvm

if mountpoint $MNT >/dev/null; then

  #rm -rf $MNT/*
  #cp -a /opt/runcvm/* $MNT/
  rsync -aR --delete /opt/runcvm/./ $MNT/

  echo "RunCVM install/upgrade successful!" >&2
  echo >&2
else

  cat <<"_EOE_" >&2
Usage: docker run --rm -v /opt/runcvm:$MNT $REPO

 - Installs runcvm package to host:/opt/runcvm
 - N.B. /opt/runcvm is hardcoded and requires a rebuild to be changed

_EOE_

fi

# For installing across a docker swarm:
# - Run: docker service create --name=runcvm --mode=global --mount=type=bind,src=/opt/runcvm,dst=/runcvm runcvm:latest --pause
# - Wait: until the service is created everywhere
# - Run: docker service rm runcvm
if [ "$1" == "--pause" ]; then
  sleep infinity
fi
