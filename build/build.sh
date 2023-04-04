#!/bin/sh -e

REPO=newsnowlabs/runcvm

DOCKER_BUILDKIT=1 docker build -t $REPO .

cat <<_EOE_

RunCVM build successful
=======================

To install or upgrade, now run:

  sudo ./runcvm-scripts/runcvm-install-runtime.sh
_EOE_


echo