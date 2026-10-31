# Non-terminal stdin bridge

Experimental implementation; real QEMU/virtio-serial and VM shutdown validation
is still required. The local suite exercises the actual C host/guest relays over
Unix sockets, not a replacement implementation.

See [PLAN.md](PLAN.md) for the aims, proposed multiple-channel transport,
KVM handoff, and stretch goal of a shared execution agent replacing Dropbear.
The single-port protocol below describes the current implementation, not that
proposal. Init roles and potential replacements are discussed separately in
[RUNCVM-INIT.md](../RUNCVM-INIT.md).

Plain `docker run -i` automatically selects RunCVM's existing BusyBox guest init
and the pipe bridge. The application runs as its descendant, with a new session
and process group, no controlling terminal, and ordinary stdin/stdout/stderr pipes.
`-it`, `-t`, and containers with no open stdin retain their existing selection.
The existing patched dumb-init still supervises the container side. No new init
or general service supervisor is introduced.

## Selection

Docker 28.4/containerd on the onboarding host supplies a pipe as fd 0 with `-i`,
`/dev/null` without it, and a PTY with `-t`. Selection happens in the container
entrypoint, before saving the environment; OCI has no portable OpenStdin field.
This heuristic must be checked on other engines/versions. It does not consume
input and still detects an already-closed upstream pipe.

- `RUNCVM_STDIO=auto` (default): bridge a non-terminal pipe on fd 0.
- `RUNCVM_STDIO=pipe`: explicitly request the bridge, including with `/dev/null`
  or a regular-file fd 0; reject terminal stdin.
- `RUNCVM_STDIO=legacy`: use the existing path.
- `RUNCVM_LEGACY_STDIO=1`: compatibility override; disables the bridge and
  implicit init even if `RUNCVM_STDIO=pipe`. Explicit `--init`/`RUNCVM_INIT=1`
  remains effective.

System-init workloads requiring PID 1 should use the existing terminal path or
the legacy override. Kernel provenance does not determine the workload's role.
Mode selection is separate from transport setup so future policies can differ.

## Transport and lifetime

QEMU exposes `org.runcvm.stdio` as a dedicated virtio-serial port, backed by
`/.runcvm/stdio.sock`. The host launcher starts QEMU, connects to that socket,
and retains Docker's stdio descriptors. QEMU diagnostics go to the private
`/.runcvm/qemu.log`; its console is disconnected from application output.

The guest locates the named port through sysfs, creating a device node only at
`/.runcvm/stdio-port` if no udev is running. A version handshake precedes data.
All frames contain a type byte, a network-order 32-bit length, and at most 4096
payload bytes. Types are:

| Type | Direction | Meaning |
| --- | --- | --- |
| R | Both | Version `RCS1` |
| 0 / I | Host to guest | Input data / persistent input EOF |
| 1 / O | Guest to host | Output data / EOF |
| 2 / E | Guest to host | Error data / EOF |
| S | Host to guest | One-byte signal number, delivered to the application group |
| X | Guest to host | One-byte application exit status, after both output EOFs |
| A | Host to guest | All preceding output written to Docker's descriptors |

EOF closes only the guest application's stdin writer. It neither shuts down
the VM nor discards output. An application that closes stdin early does not
prevent the bridge from draining its output. Output/error pipes are serviced
concurrently with input; memory queues are bounded and apply backpressure.

After application exit, output may drain for up to five seconds. The host
acknowledges receipt into Docker's output descriptors (not downstream consumption).
The guest launcher then writes `/.runcvm/exitcode` and requests the existing
BusyBox poweroff path. The host allows ten seconds for QEMU shutdown after status.
The host also saves its final result there, including failures, so the outer
init does not reinterpret the bridge's status as QEMU's isa-debug-exit encoding.
Startup/handshake has a thirty-second deadline. Transport/protocol failures and
timeouts return 125, rather than silently reporting success. QEMU receives a
parent-death kill safeguard; guest failure cleanup kills the application group.
Descendants that escape that group are left to the existing init/VM shutdown.

Container SIGTERM continues through patched dumb-init's existing guest-shutdown
hook. Signals delivered directly to the host bridge are sent over the transport.
This implementation does not add terminal bridging or change docker exec.

The bridge adds files only under the existing private tmpfs. It does not remove
pre-existing RunCVM filesystem modifications, including BusyBox's `/etc/inittab`.
The existing newline-separated entrypoint serialization also remains unchanged.

## Validation

From the repository root:

```sh
python3 -m unittest discover -s tests -p test_stdio_bridge.py -v
```

The suite compiles with warnings treated as errors and tests real relay processes:
the original sed example, empty and binary input, missing final newline, repeated
EOF reads, work after EOF, simultaneous input/output backpressure, distinct output
streams, early stdin closure, status/signals, invalid protocol, disconnects,
fragmented framing, host launch/shutdown, application sessions, and mode selection.
It needs normal Unix-socket and process-group permissions; restrictive command
sandboxes may require running outside that sandbox. Set `RUNCVM_STDIO_BINARY` to
exercise a separately built binary, such as an Alpine/musl build.

Build/install the runtime image normally on a suitable host. Then run:

```sh
cd tests/04-stdio
./test
```

This requires KVM, TUN, the installed runcvm runtime, and a Debian image (override
with `RUNCVM_TEST_IMAGE`). It uses fresh container names and cleans up only its own
containers. Also validate `-it` Ctrl-D, systemd/OpenWrt console operation, explicit
`--init`, the compatibility override, and `docker stop` on that host before release.
