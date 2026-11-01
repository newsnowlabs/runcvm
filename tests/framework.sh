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

# ---------------------------------------------------------------------------
# Helpers for tests run by tests/run (all optional: a test may use only the
# functions above)
# ---------------------------------------------------------------------------

# Run identity: set by tests/run; defaults allow running a test directly.
RUNCVM_TEST_RUN_ID="${RUNCVM_TEST_RUN_ID:-manual-$$}"
RUNCVM_TEST_NAME="${RUNCVM_TEST_NAME:-$(basename "$PWD")}"

ERRORS=${ERRORS:-0}

# unique NAME
# Print a Docker object name that is unique to this run, so that runs (and
# tests) can proceed concurrently without name clashes.
unique() {
  echo "rcvt-$RUNCVM_TEST_RUN_ID-$1" | tr -c 'a-zA-Z0-9_.\n-' '-'
}

# labels
# Print 'docker run'/'docker network create'/'docker volume create' options
# labelling an object with this run and test, so that tests/run can remove
# anything left behind. Usage: docker run $(labels) ...
labels() {
  echo "--label runcvm-test.run=$RUNCVM_TEST_RUN_ID --label runcvm-test.test=$RUNCVM_TEST_NAME"
}

# vm_opts
# Print 'docker run' options for RunCVM Container/VMs selected by the runner,
# currently the QEMU acceleration (--accel kvm|auto|tcg, as RUNCVM_QEMU_ACCEL).
# Usage: docker run $(labels) $(vm_opts) --runtime=$RUNTIME ...
vm_opts() {
  if [ -n "$RUNCVM_TEST_ACCEL" ]; then
    echo "--env=RUNCVM_QEMU_ACCEL=$RUNCVM_TEST_ACCEL"
  fi
}

# record_result STATUS DESCRIPTION
# Record a sub-result (PASS, FAIL or SKIP) for inclusion in the runner's
# TAP and JUnit output.
record_result() {
  [ -n "$RUNCVM_TEST_CHECKS" ] && printf '%s\t%s\n' "$1" "$2" >>"$RUNCVM_TEST_CHECKS"
  return 0
}

# param KEY VALUE
# Record a parameter of this test run (e.g. 'init' 'yes') in the results.
param() {
  [ -n "$RUNCVM_TEST_PARAMS" ] && printf '%s\t%s\n' "$1" "$2" >>"$RUNCVM_TEST_PARAMS"
  return 0
}

# check DESCRIPTION EXPECTED ACTUAL
# Compare two values; log and record the result; count failures in ERRORS.
check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    log "$desc: expected and received '$actual' - PASS"
    record_result PASS "$desc"
    return 0
  fi
  log "$desc: expected '$expected', but got '$actual' - FAIL"
  record_result FAIL "$desc"
  ERRORS=$((ERRORS+1))
  return 1
}

# check_cmd DESCRIPTION COMMAND [ARGS...]
# Pass if COMMAND succeeds; log and record the result; count failures in ERRORS.
check_cmd() {
  local desc="$1"; shift
  if "$@"; then
    log "$desc - PASS"
    record_result PASS "$desc"
    return 0
  fi
  log "$desc - FAIL"
  record_result FAIL "$desc"
  ERRORS=$((ERRORS+1))
  return 1
}

# expect_exit DESCRIPTION EXPECTED_CODE COMMAND [ARGS...]
# Run COMMAND (typically 'docker run ...') and check its exit status.
expect_exit() {
  local desc="$1" expected="$2" rc=0; shift 2
  "$@" || rc=$?
  check "$desc (exit status)" "$expected" "$rc"
}

# wait_for DESCRIPTION TIMEOUT_SECS COMMAND [ARGS...]
# Poll COMMAND once a second until it succeeds, or fail after TIMEOUT_SECS.
wait_for() {
  local desc="$1" timeout="$2" deadline; shift 2
  deadline=$(( $(date +%s) + timeout ))
  while ! "$@" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "Timed out after ${timeout}s waiting for: $desc"
      return 1
    fi
    sleep 1
  done
  log "Ready: $desc"
  return 0
}

# wait_for_exec CONTAINER TIMEOUT_SECS
# Wait until 'docker exec' into CONTAINER works (for RunCVM: the VM has booted
# and its SSH-based exec channel is up).
wait_for_exec() {
  wait_for "'docker exec' into $1" "$2" docker exec "$1" true
}

# volume_create NAME
# Create a labelled Docker volume (e.g. for a workload to write results to).
volume_create() {
  docker volume create $(labels) "$1" >/dev/null
}

# volume_read VOLUME PATH
# Print a file from VOLUME, read using a standard (runc) helper container, so
# that the runtime under test is not also the observer.
volume_read() {
  docker run --rm --runtime=runc --network=none $(labels) -v "$1:/v:ro" alpine cat "/v/$2"
}

# skip REASON
# End the test as skipped (exit 77), e.g. when a prerequisite is absent.
skip() {
  log "SKIP: $1"
  exit 77
}

# finish
# End the test: exit 0 if no checks failed, else 1. Use this rather than
# 'exit $ERRORS': exit statuses wrap modulo 256, so 256 errors would exit 0.
finish() {
  log "Tests completed with $ERRORS errors"
  [ "$ERRORS" -eq 0 ] && exit 0
  exit 1
}
