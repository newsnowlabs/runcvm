#!/bin/sh

RUNCVM=/opt/runcvm
RUNCVM_LD=$RUNCVM/lib/ld
RUNCVM_JQ=$RUNCVM/usr/bin/jq
MNT=/runcvm
REPO=${REPO:-newsnowlabs/runcvm}

log() {
    echo "$@"
}

jq() {
  $RUNCVM_LD $RUNCVM_JQ "$@"
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

jq_get() {
  local file="$1"
  shift
  
  jq -r "$@" $file
}

usage() {
  cat <<_EOE_ >&2

Usage: sudo $0
_EOE_
  exit 1
}

docker_restart() {
  # docker_restart
  # - With systemd, run: systemctl restart docker
  # - On GitHub Codespaces, run: sudo killall dockerd && sudo /usr/local/share/docker-init.sh

  local init=$(ps -o comm,pid 1 | grep ' 1$' | awk '{print $1}')
  local cmd

  log "  - Preparing to restart dockerd ..."

  if [ "$init" = "systemd" ]; then
    log "    - Detected systemd"
    cmd="systemctl restart docker"

  elif [ -x "/etc/init.d/docker" ]; then
    log "    - Detected sysvinit"
    cmd="/etc/init.d/docker restart"

  elif [ "$init" = "docker-init" ]; then

    if [ -x "/usr/local/share/docker-init.sh" ]; then
      log "    - Detected docker-init on GitHub Codespaces"
      cmd="killall dockerd && /usr/local/share/docker-init.sh"
    fi
  fi

  if [ -n "$cmd" ]; then
    log "    - Preparing to run: $cmd"
    read -p "    - Run this? (Y/n): " yesno

    if [ "$yesno" != "${yesno#[Yy]}" ] || [ -z "$yesno" ]; then
      log "    - Restarting dockerd with: $cmd"
      sh -c "$cmd" 2>&1 | sed 's/^/      - /'

      # Wait for dockerd to restart
      log "    - Waiting for dockerd to restart ..."
      while ! docker ps >/dev/null 2>&1; do
        sleep 0.5
      done
      log "    - Restarted dockerd successfully"

    else
      log "    - Please restart dockerd manually in the usual manner for your system"
    fi

  else
    log "  - Couldn't detect restart mechanism for dockerd, please restart manually in the usual manner for your system"
  fi
}

log
log "RunCVM Runtime Installer"
log "========================"
log

if [ $(id -u) -ne 0 ]; then
  log "Error: $0 must be run as root. Please relaunch using sudo."
  usage
fi

for app in docker dockerd
do
  if [ -z $(which docker) ]; then
    log "Error: $0 currently requires the '$app' binary; please install it and try again"
    usage
  fi
done

# Install RunCVM package to $MNT
if docker run --rm -v /opt/runcvm:$MNT $REPO --quiet; then
  log "- Installed RunCVM package to /opt/runcvm"
else
  log "- Failed to install RunCVM package to /opt/runcvm; aborting!"
  exit 1
fi

if [ -d "/etc/docker" ]; then

  log "- Detected /etc/docker"

  if ! [ -f "/etc/docker/daemon.json" ]; then
    log "  - Creating empty daemon.json"
    echo '{}' >/etc/docker/daemon.json
  fi

  if [ $(jq_get "/etc/docker/daemon.json" ".runtimes.runcvm.path") != "/opt/runcvm/scripts/runcvm-runtime" ]; then
    log "  - Adding runcvm to daemon.json runtimes property ..."

    if jq_set  "/etc/docker/daemon.json" '.runtimes.runcvm.path |= "/opt/runcvm/scripts/runcvm-runtime"'; then
      log "    - Done"
    else
      log "    - Failed: $!"
      exit 1
    fi

    # Attempt restart of dockerd
    docker_restart

  else
    log "  - Valid runcvm property already found in daemon.json"
  fi

  if docker info 2>/dev/null | grep -q runcvm; then
  # if [ $(docker info --format '{{ json .Runtimes.runcvm }}') = "{"path":"/opt/runcvm/scripts/runcvm-runtime"}" ]; then
    log "  - Verification of RunCVM runtime in Docker completed"
  else
    log "  - Warning: could not verify RunCVM runtime in Docker; perhaps you need to restart Docker manually"
  fi

else
  log "- No /etc/docker detected; your mileage with RunCVM without Docker may vary!"
fi

if [ -n "$(which podman)" ]; then
  log "- Detected podman binary"
  cat <<_EOE_ >&2
  - To enable experimental RunCVM support for Podman, add the following
    to /etc/containers/containers.conf in the [engine.runtimes] section:

    runcvm = [ "/opt/runcvm/scripts/runcvm-runtime" ]
_EOE_
fi

log "- RunCVM installation/upgrade complete."
log