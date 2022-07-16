#!/bin/sh -e

DOCKER_BUILDKIT=1 docker build -t dkvm:latest .

echo >&2
echo "To install, now run: docker run --rm -v /opt/dkvm:/dkvm dkvm" >&2
echo >&2

