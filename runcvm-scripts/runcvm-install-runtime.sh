#!/bin/sh

# Installs RunCVM from the image $REPO (default newsnowlabs/runcvm, i.e. the latest release):
# - copies the RunCVM package from the image to /opt/runcvm;
# - then runs the installer in that package, with --no-dockerd, which registers the runtime with
#   Docker. So the host-side steps are always those of the release being installed, whichever
#   version of this script installs it.
#
# With --no-dockerd, it skips the dockerd check and the package copy, and registers the package
# already in /opt/runcvm. Every release from v1.5.0 accepts --no-dockerd in the same way.

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

Usage: sudo [REPO=<image>] $0 [--no-dockerd]

e.g. sudo REPO=newsnowlabs/runcvm:v1.7.0 $0
_EOE_
  exit 1
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
  log "    limactl stop <vm> && limactl edit <vm> --set '.nestedVirtualization=true' && limactl start <vm>"
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

# Install the RunCVM package to /opt/runcvm, which the installer image sees mounted at $MNT
if [ -z "$NO_DOCKERD" ]; then
  log "- Installing RunCVM package to /opt/runcvm ..."
  if $RUNTIME run --rm -v /opt/runcvm:$MNT $REPO --quiet; then
    log "- Installed RunCVM package to /opt/runcvm"
  else
    log "- Failed to install RunCVM package to /opt/runcvm; aborting!"
    exit 1
  fi

  # Hand over to the installed package's own installer, for the host-side steps of its release.
  # Its prompt to restart dockerd reads from the terminal, if there is one; otherwise (e.g. when
  # this script is piped to sh) the prompt reads nothing, which accepts the restart.
  PACKAGE_INSTALLER=$RUNCVM/scripts/runcvm-install-runtime.sh
  if [ -x "$PACKAGE_INSTALLER" ]; then
    log "- Running the installed package's installer, $PACKAGE_INSTALLER --no-dockerd ..."
    if [ -t 0 ]; then
      exec "$PACKAGE_INSTALLER" --no-dockerd
    else
      exec "$PACKAGE_INSTALLER" --no-dockerd </dev/null
    fi
  fi
  log "- No installer in the installed package; continuing with this one"
fi

if [ "$RUNTIME" = "docker" ]; then

  if [ -d "/etc/docker" ]; then

    log "- Detected /etc/docker"

    if ! [ -f "/etc/docker/daemon.json" ]; then
      log "  - Creating empty daemon.json"
      echo '{}' >/etc/docker/daemon.json
    fi

    if [ "$(jq_get "/etc/docker/daemon.json" ".runtimes.runcvm.path")" != "/opt/runcvm/scripts/runcvm-runtime" ]; then
      log "  - Setting runtimes.runcvm.path in /etc/docker/daemon.json to \"/opt/runcvm/scripts/runcvm-runtime\" ..."

      if jq_set  "/etc/docker/daemon.json" '.runtimes.runcvm.path |= "/opt/runcvm/scripts/runcvm-runtime"'; then
        log "    - Done; daemon.json's runtimes property is now:"
        jq '.runtimes' /etc/docker/daemon.json | sed 's/^/        /'
      else
        log "    - Failed: $!"
        exit 1
      fi

      # Attempt restart of dockerd
      # (if dockerd not found, we'll just continue)
      docker_restart

    else
      log "  - runtimes.runcvm.path in /etc/docker/daemon.json is already \"/opt/runcvm/scripts/runcvm-runtime\""
    fi

    if docker info 2>/dev/null | grep -q runcvm; then
      log "  - Verification of RunCVM runtime in Docker completed"
    else
      log "  - Warning: could not verify RunCVM runtime in Docker; perhaps you need to restart Docker manually"
    fi

  else
    log "- No /etc/docker detected; your mileage with RunCVM without Docker may vary!"
  fi

  # Docker took precedence, but podman may also be installed on this host
  if command -v podman >/dev/null 2>&1; then
    log "- Also detected podman binary"
    log "  - To enable experimental RunCVM support for Podman, add the following"
    log "    to /etc/containers/containers.conf in the [engine.runtimes] section:"
    log ""
    log "    runcvm = [ \"/opt/runcvm/scripts/runcvm-runtime\" ]"
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

  # Add runcvm to [engine.runtimes] if not already present.
  # Anchor on the key so comments or unrelated /opt/runcvm paths don't false-match.
  if grep -qE '^[[:space:]]*runcvm[[:space:]]*=' "$CONTAINERS_CONF"; then
    log "  - runcvm already present in $CONTAINERS_CONF"
  else
    log "  - Adding runcvm to [engine.runtimes] in $CONTAINERS_CONF"
    # Ensure [engine.runtimes] section exists; append entry
    if grep -q '^\[engine\.runtimes\]' "$CONTAINERS_CONF"; then
      sed -i '/^\[engine\.runtimes\]/a runcvm = ["/opt/runcvm/scripts/runcvm-runtime"]' "$CONTAINERS_CONF"
    else
      printf '\n[engine.runtimes]\nruncvm = ["/opt/runcvm/scripts/runcvm-runtime"]\n' >>"$CONTAINERS_CONF"
    fi
    log "  - Done (podman reads $CONTAINERS_CONF on each run; restart any running 'podman system service' for it to do so)"
  fi

  log "  - Note: if SELinux is enforcing (Fedora CoreOS / Podman Desktop), add"
  log "    '--security-opt label=disable' to your 'podman run' invocations for RunCVM containers,"
  log "    or set 'label=false' in $CONTAINERS_CONF under [containers]"

fi

log "- RunCVM installation/upgrade complete."
log
log "RunCVM is copyright 2022-2026 NewsNow Publishing Limited, Struan Bartlett, and contributors,"
log "and licensed under the Apache License, Version 2.0: see $RUNCVM/LICENSE and $RUNCVM/NOTICE."
log