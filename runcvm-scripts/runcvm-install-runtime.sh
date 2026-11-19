#!/bin/sh

# Installs RunCVM from the image $REPO (default newsnowlabs/runcvm, i.e. the latest release):
# - with --pull, pulls the image first, so that a tag that moves (e.g. latest) installs its
#   current image rather than an older copy on this host, which is installed instead where the pull
#   fails; without it, a copy on this host is installed as it is, and docker run pulls an image
#   that this host lacks;
# - copies the RunCVM package from the image to /opt/runcvm;
# - then runs the installer in that package, with --no-dockerd (--register-only's other name, the
#   only one that releases before --register-only accept), which registers the runtime with
#   Docker. So the host-side steps are always those of the release being installed, whichever
#   version of this script installs it.
#
# With --register-only (or --no-dockerd), it skips the dockerd check and the package copy, and
# registers the package already in /opt/runcvm, needing no Docker daemon (e.g. in 'docker build').
# Every release from v1.5.0 accepts --no-dockerd in the same way.

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

Usage: sudo [REPO=<image>] $0 [--pull] [--register-only]

  REPO=<image>  Install RunCVM from <image> (default newsnowlabs/runcvm, the latest release).
  --pull        Pull <image> first, so that a tag that has moved (such as latest) installs its
                current image; where the pull fails, the copy on this host, if any, is installed,
                with a warning. Without --pull, a copy of <image> already on this host is
                installed as it is, and one this host lacks is pulled.
  --register-only
                Register the package already in /opt/runcvm with Docker, skipping the dockerd
                check and the package's installation from <image>, so that no Docker daemon is
                needed (e.g. in 'docker build'). Also --no-dockerd, which releases from v1.5.0
                accept.

e.g. sudo REPO=newsnowlabs/runcvm:v1.7.0 $0

Images from v1.7.0 are also on GitHub's container registry, e.g. REPO=ghcr.io/newsnowlabs/runcvm:latest,
for where pulls from Docker Hub are rate-limited or blocked.
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

for app in docker dockerd
do
  if [ -z $(which docker) ]; then
    log "- Error: $0 currently requires the '$app' binary; please install it and try again"
    usage
  fi
done


while [ $# -gt 0 ]
do
  case "$1" in
    --register-only|--no-dockerd) REGISTER_ONLY="1" ;;
    --pull) PULL="1" ;;
    -h|--help) usage ;;
    *) log "- Error: unknown argument '$1'"; usage ;;
  esac
  shift
done

if [ -n "$REGISTER_ONLY" ]; then
  log "- Registering the package already in /opt/runcvm, skipping the dockerd check and the package install, due to '--register-only'"
else
  log "- Checking dockerd ..."
  if docker info >/dev/null 2>&1; then
    log "  - Detected running dockerd"
  else
    log "  - Error: dockerd not running; please start dockerd; aborting!"
    exit 1
  fi
fi

# Install the RunCVM package to /opt/runcvm, which the installer image sees mounted at $MNT
if [ -z "$REGISTER_ONLY" ]; then
  if [ -n "$PULL" ]; then
    log "- Pulling $REPO, due to '--pull' ..."
    if docker pull --quiet "$REPO" >/dev/null; then
      log "  - Pulled $REPO"
    elif docker image inspect "$REPO" >/dev/null 2>&1; then
      log "  - Warning: pulling $REPO failed; installing the copy already on this host"
    else
      log "  - Error: pulling $REPO failed, and this host has no copy of it; aborting!"
      exit 1
    fi
  fi

  log "- Installing RunCVM package to /opt/runcvm ..."
  if docker run --rm -v /opt/runcvm:$MNT $REPO --quiet; then
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

# In a Linux VM run by Apple's Virtualization framework (e.g. Lima's on macOS), Container/VMs start
# much faster with their memory in hugepages (see README.md, "macOS on Apple Silicon"). Where no
# pool is reserved, suggest a pool of about a third of this VM's memory; reserving it is left to the
# administrator, since the pool's memory is lost to everything else.
if grep -qs '^Apple' /sys/class/dmi/id/sys_vendor && grep -qs 'Virtualization' /sys/class/dmi/id/product_name &&
   [ "$(awk '/^HugePages_Total:/ { print $2 }' /proc/meminfo)" = "0" ]; then
  HUGEPAGES=$(awk '/^MemTotal:/ { mem = $2 } /^Hugepagesize:/ { size = $2 } END { if (size) print int(mem / 3 / size) }' /proc/meminfo)
  if [ -n "$HUGEPAGES" ] && [ "$HUGEPAGES" -gt 0 ]; then
    log "- Detected Apple's Virtualization framework, with no hugepages reserved"
    cat <<_EOE_
  - Container/VMs start much faster with their memory in hugepages. To reserve a pool of
    $HUGEPAGES pages (about a third of this VM's memory), kept across restarts, run:

    echo "vm.nr_hugepages = $HUGEPAGES" | sudo tee /etc/sysctl.d/99-hugepages.conf && sudo sysctl -p /etc/sysctl.d/99-hugepages.conf

    and launch Container/VMs with --env=RUNCVM_HUGETLB=auto. The pool's memory is set aside
    for hugepages alone, used or not; to release it, remove /etc/sysctl.d/99-hugepages.conf
    and run: sudo sysctl -w vm.nr_hugepages=0
_EOE_
  fi
fi

if [ -f "$RUNCVM/VERSION" ]; then
  log "- RunCVM installation/upgrade complete: version $(cat "$RUNCVM/VERSION")."
else
  log "- RunCVM installation/upgrade complete."
fi
log
log "RunCVM is copyright 2022-2026 NewsNow Publishing Limited, Struan Bartlett, and contributors,"
log "and licensed under the Apache License, Version 2.0: see $RUNCVM/LICENSE and $RUNCVM/NOTICE."
log