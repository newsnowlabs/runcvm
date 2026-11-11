# Repo Notes

RunCVM is an OCI runtime that launches standard container images as VMs. `README.md` documents
its options, architecture and limitations; read its "How RunCVM works" section before changing
the runtime or the scripts.

- `runcvm-scripts/runcvm-runtime` wraps `runc` and intercepts only `create` and `exec`;
  everything else passes straight through.
- `runcvm-ctr-*` scripts run in the container, before and alongside QEMU; `runcvm-vm-*` scripts
  run inside the VM. Both run under the RunCVM package's own bash and tools in
  `/.runcvm/guest` (a read-only bind of `/opt/runcvm`), never the image's.
  `runcvm-ctr-defaults`, sourced by both, defines shared defaults and wraps the tools they use.
- `runcvm-runtime` reports errors with `error()`, which writes them to the log file the caller
  passes with `--log`: containerd shows users only what is written there, not the runtime's
  stderr.
- The variable list in `clean_env` and the command list in `create_aliases`
  (`runcvm-ctr-defaults`) hold one name per line, sorted, so that changes merge cleanly; keep
  them that way.
- `/.runcvm` is a root-only tmpfs (`mode=700`) inside each container; its contents are
  RunCVM's private state, not part of the workload's filesystem.
- Where a script runs under `pipefail` (`runcvm-ctr-qemu`, and `tests/env/Dockerfile`'s `RUN`
  steps), a pipeline whose status matters must end in a command that reads all its input: not
  `grep -q`, `-m` or `-l`, `head`, `sed`'s `q`, `awk`'s `exit` or a single `read`, which can
  exit first and leave the writer killed by SIGPIPE, failing the pipeline at random; the same
  holds for such a reader anywhere in a pipeline. Use e.g. `grep ... >/dev/null`.
  `tests/43-pipefail-readers` checks every file in the repository that turns on `pipefail`.

## Building, installing and testing

- `./build/build.sh` builds the `newsnowlabs/runcvm` image (BuildKit, several minutes);
  `runcvm-scripts/runcvm-install-runtime.sh` installs it to `/opt/runcvm` and registers the
  runtime with Docker. Installation elsewhere than `/opt/runcvm` is unsupported.
- Changes confined to `runcvm-scripts/` can be tried without a rebuild by copying the scripts
  into `/opt/runcvm/scripts/`. They take effect for Container/VMs created afterwards — on that
  host, for every user of RunCVM, so do this only on a development or test host.
- RunCVM is designed for hosts with KVM (`/dev/kvm`). Without it, a Container/VM launched with
  `--env=RUNCVM_QEMU_ACCEL=tcg` runs under QEMU's software emulation (TCG): much slower, but it
  exercises RunCVM itself, so it suits sandboxes and CI hosts without nested virtualisation.
  The integration tests need a Docker daemon with the `runcvm` runtime registered. Check what
  the current environment has before choosing what to test, and say plainly in any report what
  could not be tested there (e.g. "not tested on KVM", "not tested with Podman").

## Integration tests

- `tests/run` runs the suite: `--tier core|extended|all`, or tests by name or pattern; `--list`
  shows what would run. It exits non-zero if any test fails or times out, and writes logs, TAP,
  JUnit and JSON results to `--results` (default `${TMPDIR:-/tmp}/runcvm-tests/<run id>`).
  Its docstring is the reference for options, test metadata and exit codes. The results files
  are rewritten before and after each test, so they show a run's progress, and a run survives
  its terminal going away (SIGHUP is ignored); SIGINT or SIGTERM stops it, writing the results
  so far.
- `tests/run --mock` (stand-in mode) runs the tests with `runc` in place of RunCVM, skipping
  those that require real VMs. Use it to develop tests and the runner where RunCVM can't run.
- `tests/run --accel tcg` runs real RunCVM Container/VMs under software emulation where KVM is
  unavailable; tests requiring `kvm` are skipped. Expect each VM to take tens of seconds to
  start, and allow for that in any wait.
- Checks that launch a Container/VM explicitly under TCG (`RUNCVM_QEMU_ACCEL=tcg`) are slow
  on a KVM host, so they run there only with `tests/run --tcg-cases`. Tests guard them with the
  framework helper `tcg_cases` (`TCG_CASES` in Python), and record them as skipped otherwise.
- After changing `tests/run`, `tests/framework.sh` or `tests/framework.py`, run
  `tests/selftest/run-selftest` (no Docker needed), and with `--docker` where a Docker daemon
  is available.

### Writing tests

- A test is a directory under `tests/` holding an executable `test` file, in bash or Python:
  exit 0 to pass, 77 to skip (after logging `SKIP: <reason>`), anything else to fail. Optional
  files `tier` (`core` or `extended`), `timeout` (seconds) and `requires` (`vm`, `kvm`,
  `ipv6`, `docker>=<major>.<minor>`) describe it to the runner. Numbering follows the tier:
  `1x` core, `5x` extended.
- Use the helpers in `tests/framework.sh` or `tests/framework.py` (same names in both):
  `unique` for every Docker object name and `labels` on every object created, so that runs can
  proceed concurrently and the runner can remove leftovers; `vm_opts` on every RunCVM
  Container/VM; `check`, `check_cmd` and `expect_exit` for results; `wait_for` and
  `wait_for_exec` for every wait, so nothing waits without a deadline; `log_detail` for
  step-by-step progress (e.g. each of many requests' outcomes), which goes to the test's log,
  and to the terminal only with `tests/run --verbose`; `parallel` (Python) to
  run independent cases at once; `skip` and `finish` to end.
- Tests must not download anything at run time beyond pulling images: containers on Docker
  networks may have no outbound access in sandboxed or CI environments.
- Where behaviour should be the same with and without `--init`, test both, recording the mode
  with `param`.

## Language

Use British English spelling in docs, code comments, commit messages and PR descriptions
(e.g. "behaviour", "initialise", "licence" as a noun).

## Writing code and commit comments

Code comments and commit messages must **strictly** describe the current code's behaviour as
if the current code had been the intended end-state all along — never as a diff against, or a
retelling of the journey from, what came before. Strictly avoid narrative about: previous/prior
behaviour ("used to do X", "the old version had Y", "no longer Z"); the process that produced
the change ("refactored to...", "switched from...to...", "fixed a bug where..."); or things
tested/verified along the way ("confirmed live", "tested via...", "verified that..."). None of
that describes what the code *is* — it describes how it got there, and it rots the moment the
prior state is no longer live in anyone's head.

The **only** exception: documenting a specific edge case the current code depends on, where
*without* that documentation there's a real risk a future change silently regresses it — e.g. a
non-obvious kernel/QEMU/Docker quirk, an ordering requirement, or an external contract the code
must keep satisfying. Even then, phrase it as a property of the current code ("X must happen
before Y, because Z" / "must stay a `<foo>` because the caller assumes..."), not as an account of
the bug that revealed it or how it was fixed.

This applies everywhere — inline code comments, doc comments, docs, and commit messages alike.
See "Commit messages" below for the specific, narrower case of branch-provenance/lineage
narrative. Testing done for a change belongs in its pull request description, not in the code
or the commit message.

Scope: this repo only — other repos have their own conventions; don't apply this rule there,
and don't edit their docs when sweeping this one.

## Repo scope: reference only this repo's own files

Docs, code comments and commit messages here should reference only files within this repo —
never a file that happens to exist elsewhere in the workspace (another checked-out repo, a
sibling directory, a scratch or plan file), whatever it is. If something relevant lives outside
this repo, incorporate the point that's actually relevant here directly, in this repo's own
words, rather than gesturing at such non-repo files. Public upstream projects (QEMU, Docker,
Alpine aports, BundELF) may be named, with a URL where useful.

## Sweep for violations of the rules above before committing

Before committing non-trivial work, and always before a branch is merged to `main`, run a
compliance sweep of the changed files against the rules above: British English; no narrative
history in docs or comments; reference only this repo's own files; PR descriptions and commit
messages clear and self-contained, i.e. understandable by a reader who has only the
repository and the pull request (not the conversation, plan or branch history that produced
them).

Use disposable Haiku subagents, parallelised by area if appropriate, to read full files into
their context and judge them by a direct semantic reading — not grep/rg keyword search, which
misses paraphrased narrative and can only catch an external reference whose name is already
known in advance — then submit only a compact findings report (file:line, the text, which
rule, a one-line reason). Reserve a stronger model for adjudicating findings the sweep flags
as uncertain. Exclude vendored, generated and binary content.

- **Sweep `main` separately.** Violations already on `main`, in files a branch never touches,
  are fixed in their own small pull request rather than folded into an unrelated branch.
- **Where the fixes land.** Gather sweep fixes into one dedicated commit (per branch), rather
  than distributing each fix to the commit that introduced it.

## Commit authorship

Every commit's **Author** must be the real human contributor — never
`Claude <noreply@anthropic.com>`. Credit Claude via a `Co-Authored-By:` trailer instead, and
add no other Claude-related trailers or links: in particular, no `Claude-Session:` trailer
(a session link is meaningless to anyone else reading the history). In a
fresh environment, check `git config user.name` and `user.email` before the first commit, and
ask for the contributor's identity if it isn't set to it. Fix an unpushed bad-author commit
with `git commit --amend --author=...`; never rewrite one that's already shared without
explicit sign-off.

## Commit messages

Keep commit messages that land on `main` focused on the current change's *why* — not the
branch's own process history. Drop provenance/lineage narrative that becomes stale or
unreachable once the source branch is deleted, e.g. "Originally authored on `<branch>` (commit
`<hash>`)" or "Rebased directly onto main, reconciling with...". A `Raw-History:` trailer (see
below) is for genuine squash-rewrites, where it points at the one place the discarded pre-squash
history survives; a straight rebase that keeps each commit's own message and hash needs no such
trailer, since nothing is being discarded.

Format: a subject line of at most about 72 characters, in the imperative or as a
`<component>: <summary>` (e.g. `runcvm-runtime: ...`, `tests: ...`); a blank line; a body
wrapped at 72 columns explaining what the change does and why, with user-visible options and
behaviour stated explicitly.

Pull request descriptions, unlike commit messages, are not hard-wrapped: write each paragraph
and list item as a single line. GitHub renders a line break within a paragraph or list item in
a description as a visible break, so wrapped text displays as ragged, broken lines.

A pull request's test steps go in one `bash` code block, which can be copied and run as a
whole. Announce each step with `echo`, and after each command whose outcome matters, `echo`
its exit status alongside the status expected, e.g.
`echo "=== second run exit status: $? (expect 1)"`, so that the output makes sense when pasted
back. Don't use `set -e`: chain with `&&` each step that is meaningless or unsafe after an
earlier one fails (e.g. a test run after its setup), and leave independent steps unchained, so
they run regardless. Where steps differ between KVM and TCG hosts, set the difference in a
variable on the block's first line.

A pull request may be raised while its tests are still running. Its description then says which
results are pending; as they come in, record them there, and push any fixes they call for to
the branch.

## Merging to `main`

Every pull request lands by squash merge, as one commit whose subject ends in the pull
request's number (e.g. `(#60)`), as GitHub's own squash subjects do, so that `git log
--oneline` links each change to its review. The commit message is written for `main` (not
GitHub's default concatenation of the branch's commit subjects):

- **A single-commit branch** lands with that commit's own message, the number added to its
  subject: `gh pr merge <n> --squash --subject "<subject> (#<n>)" --body "<body>"`, taking
  the subject and body from `git log -1 --format=%s` and `%b` of the branch's commit. It needs
  no tag or trailer.
- **A multi-commit branch** lands with the message in its description's "Squash commit
  message" section (below). Before merging, preserve the branch's history with a tag,
  `git tag raw/<branch> origin/<branch> && git push origin raw/<branch>`, which the message's
  trailer cites:
  ```
  Raw-History: raw/<branch> (<original-tip-short-hash>)
  ```

A branch that lands on `main` without a pull request, with the maintainer's agreement, may be
rebased onto `main` and pushed only if it is already clean: every commit is a self-contained,
logically coherent change that builds; every message meets the rules above; there are no merge,
fixup or work-in-progress commits; and every commit has the right author.

Once the changes in a pull request whose branch has more than one commit are complete (its tests
may still be running), its description ends with a "Squash commit message" section, for use when
it is squash-merged. The section holds the subject and body in a fenced block, which keeps the
body's 72-column wrapping. They follow the rules in "Commit messages", with the subject ending
in the pull request's number (e.g. `(#60)`), and the body ending with the `Raw-History:` trailer
for the branch's tip and any `Co-Authored-By:` trailers. The message describes the pull
request's final diff against its base, not the branch's commits one by one, and is updated
whenever the branch changes.

### Stacked pull requests

When one pull request's branch is based on another's, update the dependent branch by merging
the base branch into it, not by rebasing, while both are open. Once the base lands on `main`,
merge `main` into the dependent branch (the squashed content is identical, so this resolves
cleanly) and retarget its pull request to `main`; its squash then contains only its own
change.

## Checking whether a branch already landed

Before concluding a **multi-commit** branch is unmerged, check for the `Raw-History:` trailer
— a squash-merged branch won't show up via a plain `git diff` or
`git merge-base --is-ancestor` check:

```sh
git log origin/main --format='%H %s' | while read hash subject; do
  raw=$(git show -s --format='%B' "$hash" | grep -oP 'Raw-History:\s*\K.*')
  [ -n "$raw" ] && echo "$hash  $subject  ::  $raw"
done
```

A single-commit branch carries no trailer; check whether its content is already on `main`. A
branch rebased onto `main` and pushed without a pull request has landed if its tip is on `main`
(`git merge-base --is-ancestor <tip> origin/main`).
