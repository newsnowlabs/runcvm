#!/bin/sh

MNT=/runcvm
REPO=newsnowlabs/runcvm

while [ -n "$1" ];
do
  case "$1" in
    --quiet) QUIET=1; shift; continue; ;;
    --sleep|--wait|--pause) SLEEP=1; shift; continue; ;;
    *) echo "$0: Unknown argument '$1'; aborting!"; exit 2; ;;
  esac
done

if ! mountpoint $MNT >/dev/null 2>&1; then

  cat <<_EOE_ >&2
ERROR: Host bind-mount not specified, see below for correct usage.

Usage: docker run --rm -v /opt/runcvm:$MNT $REPO [--quiet] [--sleep]

 - Installs runcvm package to the host at /opt/runcvm
   (installation elsewhere is currently unsupported)

   N.B. This image should normally only be used by the install script.
        See README.md for installation instructions.
_EOE_

  exit 1
fi

rsync -aR --delete /opt/runcvm/./ $MNT/ || exit 1

if [ -z "$QUIET" ]; then

  cat <<"_EOE_" >&2
RunCVM install/upgrade successful
=================================

If this is your first time installing RunCVM on this server/VM, then:

1. Run the following to update /etc/docker/daemon.conf and restart docker:

  sudo /opt/runcvm/scripts/runcvm-install-runtime.sh

2. Optionally, run the integration tests:

  ./tests/run

_EOE_
fi

# For installing across a docker swarm:
# - Run: docker service create --name=runcvm --mode=global --mount=type=bind,src=/opt/runcvm,dst=/runcvm newsnowlabs/runcvm:latest --sleep
# - Wait: until the service is created everywhere
# - Run: docker service rm runcvm
if [ -n "$SLEEP" ]; then
  echo "$(hostname): RunCVM package installed."
  sleep infinity
else
  exit 0
fi
