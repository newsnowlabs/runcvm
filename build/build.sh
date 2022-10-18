#!/bin/sh -e

REPO=newsnowlabs/runcvm

DOCKER_BUILDKIT=1 docker build -t $REPO .

echo >&2
echo "To install, now run: docker run --rm -v /opt/runcvm:/runcvm $REPO" >&2
echo >&2
