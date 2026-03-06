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

check_rp_filter() {
  # For RunCVM to work, the following condition on /proc/sys/net/ipv4/conf/ must be met:
  # - the max of all/rp_filter and <bridge>/rp_filter should be 0 or 2
  #   (where <bridge> is the bridge underpinning the Docker network to which RunCVM instances will be attached)
  #
  # This means that:
  # - if all/rp_filter is set to 0, then <bridge>/rp_filter must be set to 0 or 2
  #   (or, if <bridge> is not yet or might not yet have been created, then default/rp_filter must be set to 0 or 2)
  # - if all/rp_filter is set to 1, then <bridge>/rp_filter must be set to 2
  #   (or, if <bridge> is not yet or might not yet have been created, then default/rp_filter must be set to 2)
  # - if all/rp_filter is set to 2, then no further action is needed

  local rp_filter_all rp_filter_default

  log "- Checking rp_filter ..."

  if [ -f "/proc/sys/net/ipv4/conf/all/rp_filter" ]; then
    rp_filter_all=$(cat /proc/sys/net/ipv4/conf/all/rp_filter)
  else
    log "  - Warning: could not find /proc/sys/net/ipv4/conf/all/rp_filter"
  fi

  if [ -f "/proc/sys/net/ipv4/conf/default/rp_filter" ]; then
    rp_filter_default=$(cat /proc/sys/net/ipv4/conf/default/rp_filter)
  else
    log "  - Warning: could not find /proc/sys/net/ipv4/conf/default/rp_filter"
  fi

  if [ -z "$rp_filter_all" ] || [ -z "$rp_filter_default" ]; then
    return
  fi
  
  if [ "$rp_filter_all" = "2" ]; then
    log "  - sys.net.ipv4.conf.all.rp_filter is set to 2; assuming no further action needed"
    return
  elif [ "$rp_filter_all" = "0" ] && [ "$rp_filter_default" = "0" ]; then
    log "  - sys.net.ipv4.conf.all.rp_filter AND sys.net.ipv4.conf.default.rp_filter are set to 0; assuming no further action needed"
    return
  fi
  
  log "  - sys.net.ipv4.conf.all.rp_filter is set to $rp_filter_all; fixing ..."
  log "  - Setting sys.net.ipv4.conf.all.rp_filter and Setting sys.net.ipv4.conf.default.rp_filter to 2 ..."
  echo 2 >/proc/sys/net/ipv4/conf/all/rp_filter
  echo 2 >/proc/sys/net/ipv4/conf/default/rp_filter

  log "  - Patching /etc/sysctl.conf, /etc/sysctl.d/* to make these settings persist after reboot ..."
  find /etc/sysctl.conf /etc/sysctl.d -type f -exec sed -r -i 's/^([ ]*net.ipv4.conf.(all|default).rp_filter)=(1)$/# DISABLED BY RUNCVM\n# \1=\3\n# ADDED BY RUNCVM\n\1=2/' {} \;
}

docker_restart() {
  # docker_restart
  # - With systemd, run: systemctl restart docker
  # - On GitHub Codespaces, run: sudo killall dockerd && sudo /usr/local/share/docker-init.sh

  local cmd init
  
  init=$(ps -o comm,pid 1 | grep ' 1$' | awk '{print $1}')

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
  log "- Error: $0 must be run as root. Please relaunch using sudo."
  usage
fi

# Detect available container runtime: prefer docker, fall back to podman
if command -v docker >/dev/null 2>&1; then
  RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
  RUNTIME="podman"
else
  log "- Error: neither 'docker' nor 'podman' found; please install one and try again"
  usage
fi
log "- Detected runtime: $RUNTIME"

# Detect Lima VM environment
if ls /etc/lima* >/dev/null 2>&1 || [ -n "$LIMA_HOME" ]; then
  log "- Note: Lima environment detected"
  log "  - Ensure nested virtualisation is enabled for your VM:"
  log "    limactl stop <vm> && limactl set --name=<vm> .nestedVirtualization=true && limactl start <vm>"
  log "  - Verify /dev/kvm is accessible before proceeding"
fi

if [ "$1" = "--no-dockerd" ]; then
  NO_DOCKERD="1"
  log "- Skipping daemon check and container-based package install due to '--no-dockerd'"
  shift
elif [ "$RUNTIME" = "docker" ]; then
  log "- Checking dockerd ..."
  if docker info >/dev/null 2>&1; then
    log "  - Detected running dockerd"
  else
    log "  - Error: dockerd not running; please start dockerd; aborting!"
    exit 1
  fi
fi

# Install RunCVM package to $MNT
if [ -z "$NO_DOCKERD" ]; then
  log "- Installing RunCVM package to $MNT ..."
  if $RUNTIME run --rm -v /opt/runcvm:$MNT $REPO --quiet; then
    log "- Installed RunCVM package to /opt/runcvm"
  else
    log "- Failed to install RunCVM package to /opt/runcvm; aborting!"
    exit 1
  fi
fi

if [ "$RUNTIME" = "docker" ]; then

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
      # (if dockerd not found, we'll just continue)
      docker_restart

    else
      log "  - Valid runcvm property already found in daemon.json"
    fi

    if docker info 2>/dev/null | grep -q runcvm; then
      log "  - Verification of RunCVM runtime in Docker completed"
    else
      log "  - Warning: could not verify RunCVM runtime in Docker; perhaps you need to restart Docker manually"
    fi

  else
    log "- No /etc/docker detected; your mileage with RunCVM without Docker may vary!"
  fi

elif [ "$RUNTIME" = "podman" ]; then

  log "- Configuring RunCVM for Podman ..."

  CONTAINERS_CONF="/etc/containers/containers.conf"

  # Create containers.conf if it doesn't exist
  if ! [ -f "$CONTAINERS_CONF" ]; then
    log "  - Creating $CONTAINERS_CONF"
    mkdir -p /etc/containers
    printf '[engine.runtimes]\n' >"$CONTAINERS_CONF"
  fi

  # Add runcvm to [engine.runtimes] if not already present
  if grep -q 'runcvm' "$CONTAINERS_CONF"; then
    log "  - runcvm already present in $CONTAINERS_CONF"
  else
    log "  - Adding runcvm to [engine.runtimes] in $CONTAINERS_CONF"
    # Ensure [engine.runtimes] section exists; append entry
    if grep -q '^\[engine\.runtimes\]' "$CONTAINERS_CONF"; then
      sed -i '/^\[engine\.runtimes\]/a runcvm = ["/opt/runcvm/scripts/runcvm-runtime"]' "$CONTAINERS_CONF"
    else
      printf '\n[engine.runtimes]\nruncvm = ["/opt/runcvm/scripts/runcvm-runtime"]\n' >>"$CONTAINERS_CONF"
    fi
    log "  - Done (Podman is socket-activated; no restart needed)"
  fi

  log "  - Note: if SELinux is enforcing (Fedora CoreOS / Podman Desktop), add"
  log "    '--security-opt label=disable' to your 'podman run' invocations for RunCVM containers,"
  log "    or set 'label=false' in $CONTAINERS_CONF under [containers]"

fi

# Check, correct and make persistent required rp_filter settings
check_rp_filter

log "- RunCVM installation/upgrade complete."
log