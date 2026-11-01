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
import os
import re
import subprocess
import sys
import time

RUN_ID = os.environ.get("RUNCVM_TEST_RUN_ID") or "manual-%d" % os.getpid()
TEST_NAME = os.environ.get("RUNCVM_TEST_NAME") or os.path.basename(os.getcwd())
RUNTIME = os.environ.get("RUNTIME") or "runcvm"
MOCK = os.environ.get("RUNCVM_TEST_MOCK") == "1"
ACCEL = os.environ.get("RUNCVM_TEST_ACCEL") or None

errors = 0
_cleanups = []


def log(msg):
    """Log a message, in the same format as framework.sh's log()."""
    print("> %s" % msg, flush=True)


def unique(name):
    """A Docker object name unique to this run, so runs and tests can proceed concurrently."""
    return re.sub(r"[^a-zA-Z0-9_.-]", "-", "rcvt-%s-%s" % (RUN_ID, name))


def labels():
    """Options labelling a Docker object with this run and test, so the runner can remove leftovers."""
    return ["--label", "runcvm-test.run=%s" % RUN_ID, "--label", "runcvm-test.test=%s" % TEST_NAME]


def vm_opts():
    """'docker run' options for RunCVM Container/VMs selected by the runner (QEMU acceleration)."""
    return ["--env=RUNCVM_QEMU_ACCEL=%s" % ACCEL] if ACCEL else []


def docker(*args, check=False, timeout=None, capture=True):
    """Run a docker CLI command and return the CompletedProcess (text mode).

    With check=True, raise subprocess.CalledProcessError on a non-zero exit.
    With capture=False, output goes straight to this test's output.
    """
    out = subprocess.PIPE if capture else None
    return subprocess.run(("docker",) + tuple(args), stdout=out, stderr=subprocess.STDOUT if capture else None,
                          universal_newlines=True, check=check, timeout=timeout)


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
        ok = subprocess.run(cmd).returncode == 0
    log("%s - %s" % (desc, "PASS" if ok else "FAIL"))
    record_result("PASS" if ok else "FAIL", desc)
    if not ok:
        errors += 1
    return ok


def expect_exit(desc, expected, cmd):
    """Run cmd (an argument list, typically ['docker', 'run', ...]) and check its exit status."""
    rc = subprocess.run(cmd).returncode
    return check("%s (exit status)" % desc, expected, rc)


def wait_for(desc, timeout, cmd, interval=1):
    """Poll cmd (callable or argument list) until it succeeds, or give up after timeout seconds."""
    deadline = time.time() + timeout
    while True:
        if callable(cmd):
            ok = bool(cmd())
        else:
            ok = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
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


def cleanup_container(name):
    """Remove the named container when the test exits."""
    _cleanups.append(("container", name))


def cleanup_network(name):
    """Remove the named network when the test exits."""
    _cleanups.append(("network", name))


def cleanup_volume(name):
    """Remove the named volume when the test exits."""
    _cleanups.append(("volume", name))


def cleanup():
    """Remove registered containers, then networks and volumes (also run automatically at exit)."""
    order = {"container": 0, "network": 1, "volume": 2}
    for kind, name in sorted(reversed(_cleanups), key=lambda c: order[c[0]]):
        if kind == "container":
            docker("rm", "-fv", name)
        elif kind == "network":
            docker("network", "rm", name)
        else:
            docker("volume", "rm", "-f", name)
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
