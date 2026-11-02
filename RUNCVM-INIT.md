# Init and supervision in RunCVM

This is a design discussion, not an implemented init replacement. PR #31 keeps
the existing BusyBox init and patched dumb-init while developing non-terminal
stdio. See [the stdio plan](runcvm-stdio/PLAN.md) for the primary goal and the
stretch goal of replacing Dropbear's exec service.

## Existing roles: complementary implementations

RunCVM needs both implementations because neither currently supplies all the
behavior supplied by the other. They are not simply interchangeable tiny inits.

| Component/path | Current role |
| --- | --- |
| Patched dumb-init as container PID 1 | Reap children, including adopted orphans, supervise the QEMU launch path, forward signals, invoke RunCVM's guest-shutdown hook on SIGTERM, and hand completion to the exit-status script |
| BusyBox init as guest PID 1 when RunCVM init is selected | Run/respawn the workload wrapper, Dropbear and qemu-ga; reap children; handle guest shutdown actions |
| Patched dumb-init guest `--no-fork` path | Establish terminal/session relationships and exec the entrypoint launcher, preserving entrypoint PID 1 identity; it does not remain as a supervisor |
| Image-provided init such as systemd/OpenWrt init | Own the guest system lifecycle when the entrypoint is intended to be PID 1 |

Container-side entrypoint starts virtiofsd before execing `runcvm-init -c`.
Virtiofsd is therefore not a second named service with an independently configured
restart/failure policy. Before the bridge, QEMU is the main supervised child;
in the PR's bridge path the host launcher sits between the outer init and QEMU.

The dumb-init fork's SIGTERM hook runs `runcvm-ctr-shutdown`, trying ACPI poweroff
and guest commands through the existing exec path. Its completion hook runs
`runcvm-ctr-exit`, which prefers the saved guest exit code and otherwise handles
QEMU's encoded status. These behaviors must survive any replacement, or receive
explicitly tested equivalents.

BusyBox guest init is configured through generated `/etc/inittab`. The workload
is a respawn action, but `runcvm-vm-start` uses a once marker to request poweroff
rather than restart the application. Dropbear and qemu-ga have independent
respawn entries. The PR's bridge launcher records status and requests poweroff
after output delivery. This behavior is more limited than a general service
dependency/readiness/shutdown policy model.

In the non-RunCVM-init path, the bootstrap starts supporting daemons and ultimately
execs the application/native init as PID 1. That path does not gain BusyBox's
ongoing service supervision just because dumb-init briefly sets up a terminal.

## There is no single definitive init contract

Linux specifies PID 1 signal behavior and orphan adoption/reaping. Sessions,
process groups, controlling terminals, and foreground groups have their own
rules. Restart policies, signal targets, output draining, and completion
authority are additional choices, not consequences of being PID 1.

Container namespace PID 1 may exit to end the namespace. Guest system PID 1 must
arrange actual shutdown; simply exiting it generally panics the guest kernel.
Subreaper mode outside PID 1 is another distinct deployment case.

Important distinctions when evaluating replacements:

- `setsid()` creates a session; `setpgid()` creates/changes a process group.
  Neither alone allocates a PTY or defines controlling-terminal ownership.
- `TIOCSCTTY` and terminal foreground-group selection address different needs.
  Avoid inheriting a guest console through `/dev/tty` into pipe-mode applications.
- Terminal-generated signals and forwarded signals must not be delivered twice.
  Job-control stop/continue behavior needs its own tests.
- Signalling a process group does not reach all descendants: children may create
  new groups/sessions. Reaping zombies does not imply orderly termination of all
  living descendants.
- Preserve child signal dispositions/masks and descriptor inheritance correctly.
  Do not treat service readiness as equivalent to a successful fork.

## Guest process structure: the workload in a child namespace

The guest-side requirements converge on one RunCVM process as guest PID 1:
the stdio bridge's completion authority, exact exit status, syncing and powering
off the VM, `docker stop` handling, and supervising Dropbear and qemu-ga. In the
current structure that is not possible for every workload. When an image's own
init (systemd, OpenWrt's procd) or the entrypoint itself must be PID 1, it is the
guest's real PID 1, and RunCVM's guest processes run only before it or alongside
it, unsupervised.

Linux namespaces remove that conflict. RunCVM's init remains guest PID 1 in the
initial namespaces, and starts the workload as PID 1 of a new PID namespace,
with its own mount namespace. The workload, native init or entrypoint alike, is
then a container-namespace PID 1 inside the guest: it may exit to end its
namespace, while RunCVM's init alone arranges guest shutdown. No user namespace
is involved, so the workload's root remains real root in the guest, and kernel
modules, sysctls and devices work as before.

| Goal | How the structure provides it |
| --- | --- |
| Exact exit status | RunCVM's init reaps the child namespace's PID 1 and reports its status, whatever user the workload runs as, without `/.runcvm/exitcode` or `qemu-exit`; an entrypoint that is not found can report 127, and one that cannot be executed 126, as runc does |
| Data integrity at exit | Syncing and unmounting filesystems precede poweroff in every mode, including when the entrypoint exits without `--init` |
| Signal semantics | The entrypoint has container PID 1 semantics, as under runc, rather than guest PID 1 semantics (its exit panicking the kernel) |
| `docker stop` | RunCVM's init sends the stop signal suited to the workload (SIGRTMIN+4 for systemd, SIGTERM otherwise), then powers off after a deadline |
| Reboot | `reboot(2)` in the child namespace ends that namespace instead of rebooting the guest: its PID 1 is terminated by SIGHUP for a restart or SIGINT for a poweroff, which RunCVM's init sees when reaping it, and so chooses between restarting the workload and powering off |
| Stdio bridge | The bridge, application status and output draining belong to one process, which also performs the final poweroff |
| Supporting services | Dropbear, qemu-ga or a future execution agent run in the initial namespaces, supervised by RunCVM's init and invisible to the workload |
| Hiding `/.runcvm` | The child mount namespace omits `/.runcvm`, or covers it with an empty read-only tmpfs, once RunCVM has configured the guest; RunCVM's processes keep their view |

Hiding `/.runcvm` relies on the PID namespace as well as the mount namespace:
with RunCVM's processes visible, root in the workload could rejoin their mount
namespace through `/proc/<pid>/ns/mnt`. The VM remains the security boundary;
hiding `/.runcvm` protects RunCVM's state from accidental use, and removes its
files from the workload's view of the filesystem.

Costs and risks:

- systemd may detect a container, through markers such as `/run/systemd/container`
  or `container=` in PID 1's environment, and then skip units conditioned on
  `ConditionVirtualization=!container`. RunCVM already renames `/.dockerenv` for
  this reason. Test with real systemd images, and keep such markers absent.
- Some workloads may require the guest's real PID 1, for example ones that read
  `/proc/1` expecting themselves, or OpenWrt's procd. Check each case.
- `docker exec` must enter the workload's PID and mount namespaces. Dropbear
  would need an `nsenter` step; an execution agent can call `setns()` itself,
  forking after joining the PID namespace, since only the caller's children
  enter it.
- The console, controlling terminal and foreground process group must be passed
  to the child namespace's PID 1 under the session rules above.
- Exit status, signal and `/.runcvm` behaviour change for existing users, so the
  structure starts as an option, alongside the current one.

The current structure remains available for workloads that must be the guest's
real PID 1. The namespace structure is a mode of the guest init rather than a
separate implementation, and a prototype needs no new tools: RunCVM's BusyBox
includes `unshare` and `nsenter`, so an inittab entry running the workload under
`unshare -f --pid --mount-proc` (`--mount-proc` implies a mount namespace) can
exercise it before any init replacement. The integration tests that record
current exit-status, shutdown and disk-persistence behaviour serve as its
acceptance tests, run in each mode with the expected values for that mode.

## Possible benefit of replacing BusyBox init

A richer guest supervisor could offer:

- A primary-workload policy distinct from supporting-service policies: completion
  ends the application container, while optional daemon failure need not do so.
- Per-service restart modes, backoff/rate limits, required-versus-optional service
  behavior, readiness notifications, and bounded ordered shutdown.
- Explicit coordination with bridge output completion and application status,
  rather than using respawn plus a once-marker convention.
- Private generated configuration/state under `/.runcvm`, avoiding overwriting
  the image's `/etc/inittab` merely to configure RunCVM services.

Those are benefits to demonstrate, not claims that BusyBox cannot be used to
build a working bridge. Supporting Dropbear/qemu-ga until replacements exist,
preserving guest poweroff, and maintaining console behavior are prerequisites.
Replacing BusyBox init also does not necessarily remove BusyBox itself: RunCVM
uses its other utilities.

## Possible benefit of replacing/evolving patched dumb-init

A richer container supervisor could make QEMU and virtiofsd explicit services:

- Define whether virtiofsd failure ends the VM, and whether restart is safe;
  restarting a daemon does not itself prove QEMU can reconnect without data loss.
- Gate QEMU launch on actual filesystem-service readiness.
- Coordinate bridge, QEMU, and filesystem-service completion and cleanup.
- Preserve graceful guest shutdown, then apply bounded escalation if it fails.
- Separate generic reaping/signalling from RunCVM-specific shutdown/status hooks.

The existing fork has valuable session/terminal handling, signal rewriting,
single-child mode, and a no-fork terminal-setup path. A replacement must preserve
the needed behaviors, possibly through a small separate launcher; a feature-rich
service manager is not automatically a substitute for that launcher.

## Candidate approaches

| Candidate | Useful capabilities / limitations for this investigation |
| --- | --- |
| Tini | Single primary child, reaping and optional subreaping; child process group/terminal foreground handling; no multi-service restart/dependency policy |
| Upstream dumb-init / current fork | Single-primary-child forwarding and session/job-control handling; current RunCVM hooks/no-fork extension are additional requirements; multi-service policy would be a substantial extension |
| Catatonit | Small container init with subreaping, signal forwarding, and descriptor-based signal handling; no general multi-service policy |
| s6 | Mature supervision, restart/finish actions, readiness and service controls; directory/state model fits private tmpfs; full PID 1 boot/shutdown integration still needs arranging |
| runit | Established service-directory supervision; boot/shutdown and application completion need integration |
| Dinit | Integrated dependencies, restart limits/policies and console-service choices; evaluate footprint, guest/container modes, and shutdown integration |
| multirun | Multiple commands from argv without service directories, but intentionally uniform stop-on-child-exit behavior and no restarts; insufficient by itself for distinct RunCVM service policies |

Upstream terminal policies differ. Tini establishes a child process group in the
existing session and attempts foreground ownership; dumb-init normally creates a
new session and reacquires a terminal; s6-supervise starts services in new
sessions. Choose behavior for each RunCVM role explicitly, rather than assuming
one project's defaults are universally correct.

Sources: [Tini](https://github.com/krallin/tini),
[dumb-init](https://github.com/Yelp/dumb-init),
[Catatonit](https://github.com/openSUSE/catatonit),
[s6](https://github.com/skarnet/s6), [runit](https://smarden.org/runit/),
[Dinit](https://github.com/davmac314/dinit),
[multirun](https://github.com/nicolas-van/multirun).

The original no-filesystem-footprint constraint concerned unexpected image-layer
files and `docker commit`, not a ban on runtime files in private mounts. RunCVM
already provides `/.runcvm` tmpfs. Ordinary supervisor configuration and state
can live there, so neither argv-only configuration nor a custom supervisor is a
requirement. Keep application-layer writes out of both startup and shutdown;
deleting generated files later does not protect a commit taken while running.
For reuse in Dockside, supply equivalent private runtime storage or evaluate
the writable-layer consequences separately.

With that constraint relaxed, prototype an established supervisor (s6 first,
with Dinit a useful comparison) before deciding a bespoke implementation is
worth its maintenance. Do not embed general service supervision into the stdio
bridge or execution agent merely to avoid evaluating an existing tool.

## Unification is an unproven option

One executable could conceivably serve both container and guest roles, with
shared process/reaping/timer machinery and explicit role-specific configuration.
Potential benefits include one maintained implementation, fewer independent
signal-handling paths, a common service-policy model, and shared tests.

There are real differences to preserve:

| Requirement | Container side | Guest side |
| --- | --- | --- |
| Primary lifetime | QEMU/host bridge and supporting filesystem service | Application plus guest services, or native system init |
| Final action | Return the correct status to Docker | Complete output/status delivery and power off |
| Graceful stop | Request guest shutdown; escalate QEMU termination if necessary | Terminate services/workload and perform guest shutdown |
| Terminal responsibility | Preserve Docker-facing signal/descriptor behavior | Console/PTY ownership or pipe-mode application isolation |
| Native-init compatibility | Still supervise the VM externally | Preserve systemd/OpenWrt as guest PID 1 where selected |

Unify only if these contracts sufficiently converge, or if measured maintenance
cost makes one bespoke implementation preferable to two bespoke implementations.
Sharing an executable does not require identical policies, a single process,
or merging the guest execution agent with init. Replacing each init independently
with an established tool may be simpler than unifying them.

## Evaluation sequence

1. Validate the primary stdio bridge on KVM/TUN hardware with existing inits.
2. Record required policies, signal/session behavior and shutdown/status paths
   for both roles; distinguish requirements from incidental current behavior.
3. Prototype guest and container supervisor replacements separately, using
   private runtime configuration. Measure readiness, failure recovery, shutdown,
   startup cost, binary/dependency footprint, and process-tree changes.
4. Test primary completion, supporting-daemon crashes, rapid restart loops,
   stuck shutdown, console job control, exact status, output draining, and
   native-init workloads. Inspect `docker diff`/commit results.
5. Consider unification only after evidence identifies useful common machinery
   and acceptable role differences. Document any bespoke-code justification.

Dropbear replacement can change guest service requirements and the current
shutdown hook's dependence on exec. Reassess those dependencies when that stretch
goal is reached; do not make either init replacement a prerequisite of stdio.
