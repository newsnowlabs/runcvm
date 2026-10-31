# Stdio bridge development plan

## Executive summary

The primary goal is faithful non-terminal stdin/stdout/stderr for the initial
workload. In particular, `echo hello | docker run --rm --runtime=runcvm -i
--entrypoint sed debian 's/^/XXX /; s/$/YYY/;'` must produce only
`XXX helloYYY`, receive persistent EOF, and terminate with the application's
status without requiring Ctrl-C.

PR #31 currently implements a single-port framed bridge, retaining BusyBox guest
init and the patched dumb-init. It has passed 21 local tests, including tests of
the actual host/guest C relays over Unix sockets. Real QEMU transport, guest
shutdown, and a full image build remain unverified. The Alpine/musl compilation
attempt was blocked by access to Alpine's package CDN.

The proposed next experiment is separate raw data channels and a small control
channel. Compare virtio-serial with vsock on a KVM/TUN-capable host before
rewriting the transport. The current implementation and tests are a baseline;
the design below is a proposal, not a description of code already implemented.

The stretch goal is to reuse the launch and I/O machinery for `docker exec`,
eventually replacing Dropbear with a small guest execution agent. That goal
must not delay or complicate validation of the primary stdio fix. Replacing or
unifying init implementations is a separate investigation: see
[RUNCVM-INIT.md](../RUNCVM-INIT.md).

## Scope and compatibility

| Launch request | Initial policy |
| --- | --- |
| Plain `-i`, without `-t` | Imply RunCVM guest init and use application pipes through the bridge |
| `-it`, including native system-init images | Preserve existing init selection and terminal-console path |
| `-t` without `-i`, or neither flag | Preserve existing behavior |
| Legacy stdio override | Restore existing I/O and disable implicit init; preserve explicitly requested init |

The current overrides and descriptor-based detection are documented in
[README.md](README.md). Docker's open-stdin setting is not a standard OCI field;
repeat the detection checks on the target Docker/containerd versions.

This deliberately trades entrypoint PID 1 identity for pipe semantics in plain
`-i` mode. Native system inits such as systemd and OpenWrt's init retain their
existing terminal path. Plain `-i` with such an entrypoint requires the legacy
override. A RunCVM-supplied kernel does not imply the absence of a native system
init. Any future implicit-init policy for selected `-it` workloads is deferred.

## Proposed multiple bidirectional channels

One candidate uses three ports/connections:

| Channel | Container to VM | VM to container |
| --- | --- | --- |
| Application I/O | Raw stdin bytes | Raw stdout bytes |
| Application errors | Unused | Raw stderr bytes |
| Control | Handshake, explicit stdin EOF, signals, final acknowledgement | Readiness, stream completion, application status, launch/transport errors |

The transport may be bidirectional even when a channel uses only one direction.
Another candidate uses distinct stdin, stdout, stderr, and control channels.
Neither a single port nor a particular channel count is a hard requirement.

Benefits to measure against the current single-port bridge:

- No framing or shared application-data queue is needed for raw data channels.
- Stdout and stderr have independent buffering/backpressure.
- Blocked application stdin cannot prevent the control path receiving a signal.
- Control processing remains responsive when an output consumer is slow.

Independent channels still require concurrent, bounded I/O handling; separate
ports alone do not guarantee those properties. The current multiplexed reader
can hold a partially delivered data frame and thereby delay following control
frames. Include that case in the comparison, rather than treating successful
bulk transfer as sufficient evidence.

### EOF, completion, and failure

EOF is directional and persistent. Closing input must close the guest pipe's
writer after previously accepted input has been delivered, while output remains
usable. Closing the combined stdin/stdout transport cannot express that.

Dedicated input-only virtio-serial ports may use host disconnection as EOF: QEMU
propagates backend connection changes and Linux can return zero after buffered
input is exhausted. Test both directions and startup behavior; do not assume
guest port close becomes host socket EOF, or that socket half-close survives
QEMU's chardev layer. Vsock offers socket-style closure, subject to testing.

Prefer explicit intended EOF on the control channel when transport loss must
remain distinguishable from normal input completion. Ctrl-D injection is not a
replacement: its behavior depends on terminal settings and it is valid binary
input in pipe mode.

There is no ordering guarantee between data and control channels. In particular:

1. Input EOF may arrive on control before the final input bytes arrive on data.
2. Application status may arrive before the final output/error bytes arrive.
3. Guest shutdown may otherwise discard output that is still buffered.

A candidate control contract includes final per-stream byte counts: close input
after delivering the declared number of bytes, and acknowledge output completion
after receiving and writing each declared output count to Docker's descriptors.
Native stream closure could supply some of these boundaries if testing proves
its semantics sufficient. Counts, ordering barriers, and framing are design
choices to validate, not an already-agreed wire protocol. An acknowledgement
means delivery to Docker's descriptors, not consumption by a downstream process.

Application exit, normal EOF, transport failure, and timeout must remain distinct.
Specify what happens when the application closes stdin early, the Docker client
disconnects, descendants retain output descriptors, or the VM shuts down before
acknowledgement. Revisit the current fixed drain/shutdown deadlines with real
backpressure tests. Preserve the existing RunCVM exit-code path without applying
QEMU's isa-debug-exit decoding to an already-decoded application status.

## Transport experiment on KVM hardware

First build and test the existing branch to establish which problems actually
occur. Then compare the candidate transports with the smallest useful harness.

| Candidate | What to establish |
| --- | --- |
| Multiple virtio-serial ports | Named-port discovery without udev; backend and guest open/close behavior; independent backpressure; connection/startup races; nested operation |
| Vsock | Guest kernel support; QEMU backend and `/dev/vhost-vsock` availability where applicable; CID allocation and collisions; access from the runtime's container namespaces; nesting; connection isolation and closure |

Keep an alternative if a device/backend is unavailable. A normal host/VM vsock
example does not prove it works in RunCVM's container and nested-VM topology.
Select the simplest transport that passes the primary-workload tests; retain
notes on exec extensibility without building a full agent first.

Audit other port consumers when adding ports: `runcvm-vm-qemu-ga` currently has
a fallback that selects the first `/dev/vport*`. Ensure it cannot mistake a
stdio/control port for the guest-agent port, particularly without udev.

## Stretch goal: a small execution agent replacing Dropbear

SSH is prior art for directional EOF, separate stderr, terminal requests,
signals, and status. Reusing Dropbear for primary stdio would also introduce SSH
readiness, authentication, networking, and remote-command translation into a path
that should be available as soon as the guest can launch an application. Avoid
making primary workload startup depend on a listening SSH service.

A purpose-built session engine can accept an argument vector, environment,
credentials, working directory, and terminal mode directly. The guest bootstrap
could invoke it for the primary workload without waiting for a daemon. A listener
could later expose the same engine for exec requests. Keeping them separable
allows stdio work to ship without the listener or removal of Dropbear.

| Requirement | Initial workload | `docker exec` |
| --- | --- | --- |
| Launch description | Available from RunCVM bootstrap | Supplied anew for each request |
| Arguments/environment | Preserve vector boundaries and values; current bootstrap serialization remains a known limit | Preserve vector boundaries and values without SSH command-string encoding |
| Identity and cwd | Requested UID/GID, supplementary groups, cwd and HOME behavior | Same, with per-request overrides and OCI-compatible launch errors |
| Non-terminal I/O | Three logical streams, persistent stdin EOF, backpressure | Same per execution session |
| Terminal I/O | Existing console path retained initially | PTY allocation, controlling terminal, window resizing and signals when requested |
| Completion authority | Ends the application container after output drains | Ends only this exec request; must not shut down the VM |
| Availability | Needed at workload launch | Available throughout VM lifetime, including during startup/shutdown races |
| Concurrency | One primary workload | Multiple simultaneous, independently cancellable sessions |
| Failure/restart | Coordinate workload status and VM shutdown | Do not kill existing sessions or the VM accidentally on listener failure/restart |
| Access control | Private bootstrap-owned transport | Restrict who may request guest commands, particularly privileged commands |

Current exec scripts perform character substitution and command-string encoding
to pass argv, environment, and cwd through SSH. Direct structured requests could
remove that layer, but need their own limits, versioning, validation, and tests
for empty arguments, newlines, quotes, high bytes, and environment values. Neither
argv nor environment entries can contain NUL at the `execve` boundary.

A fixed set of virtio-serial ports suits one workload; concurrent exec sessions
would require session multiplexing or a tested channel-allocation mechanism.
Vsock may instead permit connections per session. Associate all data/control
connections with the correct request and prevent cross-session attachment.

Removing SSH does not remove authorization requirements. Establish the actual
host/container/guest access boundary for the selected transport. Avoid exposing
a root execution service to arbitrary guest processes, other containers, or
other VMs. Host socket permissions alone do not necessarily protect a guest
vsock listener. Authentication may be unnecessary only if transport isolation
provides the required authorization boundary.

Dropbear replacement, removal of its key/authentication setup, PTY exec parity,
and changes to shutdown paths that currently use exec are stretch work. Keep
Dropbear and qemu-ga until their consumers have been checked and replacements
are independently validated. The execution agent does not need to become init
or a general service supervisor.

## Handoff and acceptance gates

Use a disposable test host with KVM, TUN, Docker, sufficient device/admin access,
and build network access, including Alpine's package CDN. Provide vhost-vsock
access if evaluating that backend. From the PR branch:

```sh
./build/build.sh
sudo ./runcvm-scripts/runcvm-install-runtime.sh
python3 -m unittest discover -s tests -p test_stdio_bridge.py -v
(cd tests/04-stdio && ./test)
```

Record tool/kernel versions and the exact commands/results. These commands are
handoff instructions, not evidence that the image/VM tests have already passed.

Before selecting/releasing a transport:

- Pass the original sed case, empty input, missing final newline, binary data,
  repeated reads after EOF, separate stdout/stderr, and exact exit status.
- Test output before input consumption, simultaneous saturated streams, early
  stdin closure, slow/closed output consumers, and signals while stdin is blocked.
- Exercise startup/disconnect races, malformed/truncated control messages,
  application exec failure, lingering descendants, and shutdown before completion.
- Preserve explicit `--init`, the legacy override, no-open-stdin behavior, `-it`
  Ctrl-D, native systemd/OpenWrt consoles, and `docker stop` behavior.
- Confirm new runtime state remains in `/.runcvm` and inspect `docker diff` and
  `docker commit` results against existing RunCVM modifications.

Only after the primary bridge is validated should shared session machinery be
extended into an exec listener. Init replacement is a separately reviewable step.
