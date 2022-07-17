#!/opt/dkvm/bin/bash -e

log() {
    echo "$@" >&2
}

jq_set() {
  local file="$1"
  shift
  
  local tmp="/tmp/$$.json"

  if jq "$@" $file >$tmp; then
    mv $tmp $file
  else
    echo "Failed to update $(basename $file); aborting!" 2>&1
    exit 1
  fi
}

usage() {
  cat <<"_EOE_" >&2
Usage: $0 [--install|--uninstall] [--docker] [--podman]

Enables/Disables DKVM for Docker and/or Podman
_EOE_
}

if [ -f "/etc/docker/daemon.json" ]; then
  log "Detected /etc/docker/daemon.json:"
  log -n "Adding dkvm to runtimes property"
  jq_set  "/etc/docker/daemon.json" '.runtimes.dkvm.path |= "/opt/dkvm/scripts/dkvm-runtime"'
  log "Now restart docker in the usual way for your system, e.g.:"
  log "systemctl restart docker"
  log
fi

if [ -n "$(which podman)" ]; then
  cat <<_EOE_
To enable experimental DKVM support for Podman, add the following to
  /etc/containers/containers.conf in the [engine.runtimes] section:

  dkvm = [ "/opt/dkvm/scripts/dkvm-runtime" ]
_EOE_
fi