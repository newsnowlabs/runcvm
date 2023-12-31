images() { echo; }
nodes() { echo; }
volumes() { echo; }
networks() { echo; }

log() {
  local opts
  if [ "$1" = "-n" ]; then opts="-n"; shift; fi
  echo $opts "> $1"
}

_cleanup() {

  if [ "$(nodes)" != "" ]; then
    log -n "Cleaning up nodes ... "
    docker rm -f $(nodes) 2>&1
  fi

  if [ "$(volumes)" != "" ]; then
    log -n "Cleaning up volumes ... "
    docker volume rm -f $(volumes) 2>&1
  fi

  if [ "$(images)" != "" ] && [ "$NO_CLEAN_IMAGE" != "1" ]; then
    log -n "Cleaning up temporary images ... "
    docker rmi $(images) 2>&1
  fi

  if [ "$(networks)" != "" ]; then
    log -n "Cleaning up networks ... "
    docker network rm $(networks) 2>&1
  fi

  rm -f /tmp/iid
}

cleanup() {
  # Allow this to complete, even if we encounter errors
  set +e

  _cleanup
  
  # Restore setting to fail on error
  set -e
}

quit() {
  local code=$?

  # Don't run a second time
  trap '' TERM INT EXIT
  
  cleanup

  log "Exiting with code $code"
}

term() {
   exit 254
}

# Standard setup

trap quit EXIT
trap term TERM INT QUIT

# Trap for cleanup on exit
trap cleanup EXIT
