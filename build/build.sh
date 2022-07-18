#!/bin/sh -e

REPO=newsnowlabs/dkvm

DOCKER_BUILDKIT=1 docker build -t $REPO .

echo >&2
echo "To install, now run: docker run --rm -v /opt/dkvm:/dkvm $REPO" >&2
echo >&2
