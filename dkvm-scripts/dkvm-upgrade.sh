#!/opt/dkvm/bin/bash

REPO=${REPO:-newsnowlabs/dkvm}

log() {
    echo "$@" >&2
}

usage() {
  cat <<"_EOE_" >&2
Usage: $0
_EOE_
  exit 1
}

# TODO:
# - Check for any running DKVM containers, and if found, throw error

docker run --rm -v /opt/dkvm:/dkvm $REPO
