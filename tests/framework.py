"""Helpers for RunCVM integration tests written in Python.

The Python counterpart of the helpers in framework.sh, with the same names
and behaviour, for tests where Python aids readability (e.g. orchestration
with several nodes, parsing JSON, deadlines and HTTP checks). Standard library
only.

Usage, in a test directory's executable 'test' file:

    #!/usr/bin/env python3
    import os, sys
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    import framework as t

    name = t.unique("web")
    t.docker("run", "-d", "--rm", *t.labels(), "--runtime", t.RUNTIME, "--name", name, "alpine", "sleep", "600")
    t.cleanup_container(name)
    t.check("hostname", name, t.docker("exec", name, "hostname").stdout.strip())
    t.finish()
"""

import atexit
import concurrent.futures
import os
import re
import subprocess
import sys
import threading
import time

RUN_ID = os.environ.get("RUNCVM_TEST_RUN_ID") or "manual-%d" % os.getpid()
TEST_NAME = os.environ.get("RUNCVM_TEST_NAME") or os.path.basename(os.getcwd())
RUNTIME = os.environ.get("RUNTIME") or "runcvm"
MOCK = os.environ.get("RUNCVM_TEST_MOCK") == "1"
ACCEL = os.environ.get("RUNCVM_TEST_ACCEL") or None
# Whether to run checks that launch Container/VMs explicitly under software emulation (TCG),
# which are slow on a host with KVM: as RUNCVM_TEST_TCG_CASES says (see tests/run), or, where
# it is unset, with --accel tcg or without /dev/kvm
TCG_CASES = (os.environ["RUNCVM_TEST_TCG_CASES"] == "1" if os.environ.get("RUNCVM_TEST_TCG_CASES")
             else ACCEL == "tcg" or not os.path.exists("/dev/kvm"))
# Whether tests pull the images they boot before using them, refreshing tags that upstream has
# re-pointed (see tests/run --pull)
PULL = os.environ.get("RUNCVM_TEST_PULL") == "1"
# Options for every RunCVM Container/VM, chosen by the runner (see tests/run --vm-env, --vm-cpus
# and --vm-memory): RunCVM settings, as NAME=VALUE, and the VM's size
VM_ENV = (os.environ.get("RUNCVM_TEST_VM_ENV") or "").split()
# The deadline, in seconds, for each 'docker exec', and each 'docker run' not detached (-d), that a
# test runs through these helpers (docker(), check_cmd, expect_exit, wait_for):
# RUNCVM_TEST_EXEC_TIMEOUT, or 300 (1200 under TCG). A hung command then fails its check, rather
# than holding the test until the runner's time limit.
EXEC_TIMEOUT = int(os.environ.get("RUNCVM_TEST_EXEC_TIMEOUT") or (1200 if ACCEL == "tcg" else 300))
CPUS = os.environ.get("RUNCVM_TEST_CPUS") or None
MEMORY = os.environ.get("RUNCVM_TEST_MEMORY") or None

# The tests directory: in a source checkout, beside runcvm-scripts; in the installed package,
# /opt/runcvm/tests, beside the package's scripts.
TESTS_DIR = os.path.dirname(os.path.abspath(__file__))

errors = 0
_cleanups = []
# The cleanups registered by the current thread's call in parallel(..., remove=True)
_call = threading.local()


def log(msg):
    """Log a message, in the same format as framework.sh's log()."""
    print("> %s" % msg, flush=True)


def log_detail(msg):
    """Log a detail line, as framework.sh's log_detail(): written to the test's log, and to the
    terminal only with 'tests/run --verbose'."""
    print("\x1e> %s" % msg, flush=True)


def unique(name):
    """A Docker object name unique to this run, so runs and tests can proceed concurrently."""
    return re.sub(r"[^a-zA-Z0-9_.-]", "-", "rcvt-%s-%s" % (RUN_ID, name))


def labels():
    """Options labelling a Docker object with this run and test, so the runner can remove leftovers."""
    return ["--label", "runcvm-test.run=%s" % RUN_ID, "--label", "runcvm-test.test=%s" % TEST_NAME]


def vm_opts(size=True):
    """'docker run' options for RunCVM Container/VMs selected by the runner: RunCVM settings
    (VM_ENV), the QEMU acceleration and, unless size is False, the VM's size (CPUS and MEMORY).

    They go before the test's own options, so that a test that sets the same variable or option
    keeps its own value: Docker takes the last --env given for a variable, and the last --cpus or
    --memory. Tests that check the VM's size against its defaults pass size=False.
    """
    opts = ["--env=%s" % e for e in VM_ENV]
    if ACCEL:
        opts.append("--env=RUNCVM_QEMU_ACCEL=%s" % ACCEL)
    if size and CPUS:
        opts.append("--cpus=%s" % CPUS)
    if size and MEMORY:
        opts.append("--memory=%s" % MEMORY)
    return opts


def source_tree():
    """Whether the tests run from a source checkout (the repository's root holding runcvm-scripts
    beside the tests directory), rather than from the installed package's /opt/runcvm/tests."""
    return os.path.isdir(os.path.join(TESTS_DIR, "..", "runcvm-scripts"))


def scripts_dir():
    """RunCVM's scripts, for tests that run or read them without a Container/VM: the checkout's
    runcvm-scripts, from a source tree, or else the package's scripts, beside its tests."""
    return os.path.realpath(os.path.join(TESTS_DIR, "..", "runcvm-scripts" if source_tree() else "scripts"))


def docker(*args, check=False, timeout=None, capture=True, input=None):
    """Run a docker CLI command and return the CompletedProcess (text mode).

    With check=True, raise subprocess.CalledProcessError on a non-zero exit.
    With capture=False, output goes straight to this test's output.
    With input, the text is passed on standard input (e.g. to 'docker run -i').
    With timeout, raise subprocess.TimeoutExpired should the command take longer. Without it,
    'docker exec', and 'docker run' not detached, have EXEC_TIMEOUT, after which the command is
    stopped and its result has exit status 124 (raising subprocess.CalledProcessError with
    check=True), with whatever it had written.
    """
    cmd = ("docker",) + tuple(args)
    out = subprocess.PIPE if capture else None
    if timeout is not None or not _has_deadline(cmd):
        return subprocess.run(cmd, stdout=out, stderr=subprocess.STDOUT if capture else None,
                              universal_newlines=True, check=check, timeout=timeout, input=input)
    r = _run(cmd, stdout=out, stderr=subprocess.STDOUT if capture else None, universal_newlines=True,
             input=input)
    if check and r.returncode != 0:
        raise subprocess.CalledProcessError(r.returncode, cmd, r.stdout)
    return r


def _has_deadline(cmd):
    """Whether cmd, an argument list, is a 'docker exec', or a 'docker run' not detached."""
    cmd = list(cmd)
    if cmd[:2] == ["docker", "exec"]:
        return True
    return cmd[:2] == ["docker", "run"] and not any(a in ("-d", "--detach") or a.startswith("--detach=")
                                                    for a in cmd[2:])


def _run(cmd, timeout=None, **kwargs):
    """subprocess.run(cmd, ...), where a 'docker exec', or a 'docker run' not detached, has a
    deadline: timeout, or EXEC_TIMEOUT. Should it pass, the command is stopped, the timeout is
    logged, and the result has exit status 124, with whatever the command had written."""
    if not _has_deadline(cmd):
        return subprocess.run(cmd, timeout=timeout, **kwargs)
    timeout = EXEC_TIMEOUT if timeout is None else timeout
    try:
        return subprocess.run(cmd, timeout=timeout, **kwargs)
    except subprocess.TimeoutExpired as e:
        log("Timed out after %ds: %s" % (timeout, " ".join(cmd)))
        out = e.stdout
        if isinstance(out, bytes) and kwargs.get("universal_newlines"):
            out = out.decode(errors="replace")
        return subprocess.CompletedProcess(cmd, 124, out if out is not None else
                                           ("" if kwargs.get("universal_newlines") else None))


def parallel(func, items, jobs=None, remove=False):
    """Return [func(item) for item in items], running up to 'jobs' calls at once.

    For tests made of many independent cases, each launching its own
    Container/VM. 'jobs' defaults to RUNCVM_TEST_JOBS, or 3. Results keep the
    order of 'items'; record checks from the results afterwards, in this
    thread, so that the log stays in order.

    With remove=True, the containers and volumes that a call registers with
    cleanup_container and cleanup_volume (in its own thread) are removed as
    soon as it returns, so that no more than 'jobs' of the cases' Container/VMs
    run at once. Its result must then hold all that the checks need.
    """
    jobs = jobs or int(os.environ.get("RUNCVM_TEST_JOBS") or 3)

    def call(item):
        if not remove:
            return func(item)
        _call.cleanups = []
        try:
            return func(item)
        finally:
            _remove(_call.cleanups)
            _call.cleanups = None

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        return list(pool.map(call, items))


def pull_images(images):
    """With --pull (RUNCVM_TEST_PULL=1), pull each image, recording a check for each, so that the
    test boots what each tag points to upstream now; otherwise do nothing, as docker pulls an image
    the host lacks when it is first used. Returns False if any pull failed."""
    if not PULL:
        return True
    images = list(dict.fromkeys(images))
    ok = True
    for image, r in zip(images, parallel(lambda i: docker("pull", "-q", i, timeout=600), images)):
        if not check("pulled %s" % image, 0, r.returncode):
            log(r.stdout)
            ok = False
    return ok


def record_result(status, desc):
    """Record a sub-result (PASS, FAIL or SKIP) for the runner's TAP and JUnit output."""
    path = os.environ.get("RUNCVM_TEST_CHECKS")
    if path:
        with open(path, "a") as f:
            f.write("%s\t%s\n" % (status, desc.replace("\n", " ")))


def param(key, value):
    """Record a parameter of this test run (e.g. 'init', 'yes') in the results."""
    path = os.environ.get("RUNCVM_TEST_PARAMS")
    if path:
        with open(path, "a") as f:
            f.write("%s\t%s\n" % (key, value))


def check(desc, expected, actual):
    """Compare two values; log and record the result; count failures. Returns True on a pass."""
    global errors
    if actual == expected:
        log("%s: expected and received %r - PASS" % (desc, actual))
        record_result("PASS", desc)
        return True
    log("%s: expected %r, but got %r - FAIL" % (desc, expected, actual))
    record_result("FAIL", desc)
    errors += 1
    return False


def check_cmd(desc, cmd):
    """Pass if cmd (a callable returning truthy, or an argument list run as a command) succeeds."""
    global errors
    if callable(cmd):
        ok = bool(cmd())
    else:
        ok = _run(cmd).returncode == 0
    log("%s - %s" % (desc, "PASS" if ok else "FAIL"))
    record_result("PASS" if ok else "FAIL", desc)
    if not ok:
        errors += 1
    return ok


def expect_exit(desc, expected, cmd):
    """Run cmd (an argument list, typically ['docker', 'run', ...]) and check its exit status."""
    rc = _run(cmd).returncode
    return check("%s (exit status)" % desc, expected, rc)


def wait_for(desc, timeout, cmd, interval=1):
    """Poll cmd (callable or argument list) until it succeeds, or give up after timeout seconds."""
    deadline = time.time() + timeout
    while True:
        if callable(cmd):
            ok = bool(cmd())
        else:
            # Each attempt has the time left as its deadline (at least a second), at most EXEC_TIMEOUT
            remaining = max(1, min(EXEC_TIMEOUT, deadline - time.time()))
            try:
                ok = _run(cmd, timeout=remaining, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0
            except subprocess.TimeoutExpired:
                ok = False
        if ok:
            log("Ready: %s" % desc)
            return True
        if time.time() >= deadline:
            log("Timed out after %ss waiting for: %s" % (timeout, desc))
            return False
        time.sleep(interval)


def wait_for_exec(container, timeout):
    """Wait until 'docker exec' into container works (for RunCVM: the VM's exec channel is up)."""
    return wait_for("'docker exec' into %s" % container, timeout, ["docker", "exec", container, "true"])


def volume_create(name):
    """Create a labelled Docker volume (e.g. for a workload to write results to)."""
    docker("volume", "create", *labels(), name, check=True)
    cleanup_volume(name)


def volume_read(volume, path):
    """Return a file's contents from a volume, read with a standard (runc) helper container."""
    r = docker("run", "--rm", "--runtime=runc", "--network=none", *labels(), "-v", "%s:/v:ro" % volume,
               "alpine", "cat", "/v/%s" % path)
    return r.stdout if r.returncode == 0 else None


def _register(kind, name):
    _cleanups.append((kind, name))
    if kind in ("container", "volume") and getattr(_call, "cleanups", None) is not None:
        _call.cleanups.append((kind, name))


def cleanup_container(name):
    """Remove the named container when the test exits (or, in parallel(..., remove=True), when
    the call that registers it returns)."""
    _register("container", name)


def cleanup_network(name):
    """Remove the named network when the test exits."""
    _register("network", name)


def cleanup_volume(name):
    """Remove the named volume when the test exits (or, in parallel(..., remove=True), when the
    call that registers it returns)."""
    _register("volume", name)


def cleanup_image(name):
    """Remove the named image (e.g. one built or committed by the test) when the test exits."""
    _register("image", name)


def _remove(cleanups):
    """Remove the given (kind, name) objects: containers, then networks, volumes and images, each
    kind in the reverse order of registration. Removing one already gone does no harm."""
    order = {"container": 0, "network": 1, "volume": 2, "image": 3}
    for kind, name in sorted(reversed(cleanups), key=lambda c: order[c[0]]):
        if kind == "container":
            docker("rm", "-fv", name)
        elif kind == "network":
            docker("network", "rm", name)
        elif kind == "volume":
            docker("volume", "rm", "-f", name)
        else:
            docker("image", "rm", "-f", name)


def cleanup():
    """Remove registered containers, then networks, volumes and images (also run automatically at exit)."""
    _remove(_cleanups)
    del _cleanups[:]


atexit.register(cleanup)


def skip(reason):
    """End the test as skipped (exit 77), e.g. when a prerequisite is absent."""
    log("SKIP: %s" % reason)
    sys.exit(77)


def finish():
    """End the test: exit 0 if no checks failed, else 1."""
    log("Tests completed with %d errors" % errors)
    sys.exit(0 if errors == 0 else 1)
