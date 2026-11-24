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

Usage: docker run --rm -v /opt/runcvm:$MNT $REPO[:<tag>] [--quiet] [--sleep]

 - Copies the RunCVM package to the host at /opt/runcvm
   (installation elsewhere is currently unsupported)

   --quiet  Print nothing after a successful copy.
   --sleep  After copying, print '<hostname>: RunCVM package installed.' and sleep, as a
            global Docker service does to copy the package to every node of a swarm
            (also --wait or --pause).

   N.B. This image should normally only be used by the installer, which also registers the
        runtime with Docker, and with --pull pulls the image first:

     curl -s -o - https://raw.githubusercontent.com/newsnowlabs/runcvm/main/runcvm-scripts/runcvm-install-runtime.sh | sudo [REPO=<image>] sh [-s -- --pull]

        See README.md for installation instructions.
_EOE_

  exit 1
fi

rsync -aR --delete /opt/runcvm/./ $MNT/ || exit 1

if [ -z "$QUIET" ]; then

  cat <<_EOE_ >&2
RunCVM install/upgrade successful
=================================

Version: $(cat /opt/runcvm/VERSION 2>/dev/null || echo unknown)

RunCVM is copyright 2022-2026 NewsNow Publishing Limited, Struan Bartlett, and contributors,
and licensed under the Apache License, Version 2.0: see /opt/runcvm/LICENSE and /opt/runcvm/NOTICE.

If this is your first time installing RunCVM on this server/VM, then:

1. Run the following to update /etc/docker/daemon.json and restart docker:

  sudo /opt/runcvm/scripts/runcvm-install-runtime.sh --register-only

   (--register-only registers the package already in /opt/runcvm; without it, the installer
   installs the package from the image REPO=<image>, by default newsnowlabs/runcvm, pulling
   it first with --pull.)

2. Optionally, run the integration tests:

  /opt/runcvm/tests/run

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
