#!/opt/runcvm/bin/bash

log() {
    echo "$@" >&2
}

jq_set() {
  local file="$1"
  shift
  
  local tmp="/tmp/$$.json"

  if /opt/runcvm/usr/bin/jq "$@" $file >$tmp; then
    mv $tmp $file
  else
    echo "Failed to update $(basename $file); aborting!" 2>&1
    exit 1
  fi
}

usage() {
  cat <<"_EOE_" >&2
Usage: sudo $0

Installs RUNCVM runtime for Docker / Podman
_EOE_
  exit 1
}

if [ $(id -u) -ne 0 ]; then
  cat <<_EOE_ >&2
Error: $0 must be run as root. Please relaunch using sudo.

_EOE_

  usage
fi

log "RunCVM Runtime Installer"
log "========================"
log

if [ -f "/etc/docker/daemon.json" ]; then
  log "1 Detected /etc/docker/daemon.json:"
  log "  - Adding runcvm to runtimes property ..."

  if jq_set  "/etc/docker/daemon.json" '.runtimes.runcvm.path |= "/opt/runcvm/scripts/runcvm-runtime"'; then
    log "  - Done"
    log "  - Now restart docker in the usual way for your system, e.g."
    log
    log "    systemctl restart docker"
  else
    log "  - Failed: $!"
    exit 1
  fi

  log
fi

if [ -n "$(which podman)" ]; then
  log "2 Detected podman binary"
  cat <<_EOE_ >&2
  - To enable experimental RUNCVM support for Podman, add the following
    to /etc/containers/containers.conf in the [engine.runtimes] section:

    runcvm = [ "/opt/runcvm/scripts/runcvm-runtime" ]
_EOE_
fi