#!/bin/sh

MNT=/runcvm
REPO=newsnowlabs/runcvm

if mountpoint $MNT >/dev/null 2>&1; then

  rsync -aR --delete /opt/runcvm/./ $MNT/

  echo "RunCVM install/upgrade successful!" >&2
  echo >&2
else

  cat <<_EOE_ >&2
ERROR: Host bind-mount not specified, see below for correct usage.

Usage: docker run --rm -v /opt/runcvm:$MNT $REPO

 - Installs runcvm package to the host at /opt/runcvm
   (installation elsewhere is currently unsupported)

_EOE_

fi

# For installing across a docker swarm:
# - Run: docker service create --name=runcvm --mode=global --mount=type=bind,src=/opt/runcvm,dst=/runcvm runcvm:latest --pause
# - Wait: until the service is created everywhere
# - Run: docker service rm runcvm
if [ "$1" == "--pause" ]; then
  sleep infinity
fi
