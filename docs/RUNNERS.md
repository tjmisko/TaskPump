# Runners

A runner is the thing that actually starts an agent. The pump decides *what*
should run and *whether now is a good time*; the runner decides *how* a process
comes into existence and what it can reach.

Separating them is what lets TaskPump drive something other than a Claude Code
container — a different agent, a VM, a remote executor, a plain local process —
without touching the scheduler.

---

## 1. The runner contract, v2

A runner is **an executable** taking a verb as its first argument.

```
runner.sh launch      # start an agent; print its handle; exit non-zero on failure
runner.sh stop        # stop the agent identified by the environment
runner.sh list        # print every live agent's name; exit non-zero if it cannot look
```

Everything else is passed through the environment, so the interface stays stable
as inputs are added.

`launch` and `stop` are asked about **one** agent, named by the environment.
`list` is asked about the **fleet** and takes no per-agent input at all — the
difference is what §1.3 is about.

### 1.1 `launch`

**Inputs** (environment):

| Variable | Meaning |
|---|---|
| `TP_WORKSPACE` | Absolute path to the workspace the agent works in — a git worktree the pump has already created. The agent's working directory. |
| `TP_BRANCH` | The branch checked out in that workspace. What the ledger records as the claim holder. |
| `TP_CONTAINER_NAME` | The name the agent process must be identifiable by. **Load-bearing** — see §2. |
| `TP_IMAGE` | The image (or equivalent template) to launch from. |
| `TP_ENTRYPOINT` | The in-image entrypoint to execute. |
| `TP_TASK_ID` | The task assigned to this agent, when one is (a resume names a specific task; a fresh phase drain may not). |
| `TP_PHASE` | The phase this agent is draining. |
| `TP_MODEL` | The model alias to run. |
| `TP_MAX_TURNS` | Turn ceiling for the session. |
| `TP_REPO_ROOT` | The primary checkout — the repository the workspace belongs to. |

Every variable also has a **legacy `ARACHNE_*` twin**, promoted in both
directions by the configuration core, so a runner written against either spelling
works. New runners should read `TP_*`.

**Output:** the container id (or equivalent handle) on stdout, one line.

**Exit:** `0` on successful launch, non-zero on failure. A non-zero exit tells
the pump this phase did not start; it will be reconsidered next tick.

A launch is **fire-and-detach**. The runner returns as soon as the agent is
running — it does not wait for the work to finish. A session lasts hours; the
pump ticks in seconds.

### 1.2 `stop`

Stops the agent named by `TP_CONTAINER_NAME`. Idempotent: stopping an agent that
is already gone is success, not an error. Used by housekeeping paths, never by
the feed path — the pump does not stop agents to make room (see
[GATES.md §1.1](GATES.md#11-two-rules-that-are-not-negotiable)).

"Already gone" is **two** conditions, and a runtime words them differently: the
agent never existed or has been reaped, and the agent exists but has already
exited. A runner must treat both as success. The second is the one a real drain
produces — a session that finished on its own between the supervisor deciding to
stop it and the call landing — so a runner that handles only the first looks
correct until it is used.

Tolerating those two is not the same as ignoring failure. Anything else — the
runtime is unreachable, the name is ambiguous — must still exit non-zero, or a
teardown that silently did nothing is indistinguishable from one that worked.
`tests/test-tp-runner-stop.sh` holds the reference runner to both halves.

### 1.3 `list`

**Liveness is askable in v2.** A runner can be asked which of its agents are
alive, instead of the supervisor inferring it by scraping container names.

```
runner.sh list
```

**Inputs:** none per agent. `list` is called once per tick with no task and no
container name in hand, so it may read only what `stop` already reads from
configuration — for the shipped runners, the agent-name prefix
(`TP_AGENT_PREFIX`, or the shared `TASKPUMP_AGENT_PREFIX`) and the workspace
whose fleet is being asked about (`TP_REPO_ROOT`, or `TASKPUMP_REPO_ROOT`). Both
name a *fleet*, not an agent; a runner that demands launch-shaped input is
uncallable at exactly the moment it is needed.

The workspace is there because names are not unique on a host. Agent names are
`<prefix><branch-slug>` (§2), so two projects that share a branch convention
name the same agent, and a runner whose view of its fleet is host-wide will hand
back one that belongs to the other project — which the supervisor then reports
as its own RUNNING phase and never drains (issue #40). A runner that can tell
whose agent is whose should answer for the workspace it was asked about. One
that cannot must still answer, and the supervisor lives with the collision:
never reporting an agent that IS the caller's is the worse failure, because that
is how a live agent gets launched a second time.

**Output:** the name of every live agent, one per line. These must be the names
`launch` created (`<prefix><slug>`, §2), so the existing name→branch mapping
keeps working.

**Exit:**

| Condition | Exit | Output |
|---|---|---|
| Agents are live | `0` | one name per line |
| No agents are live | `0` | **nothing** — not a blank line |
| Cannot enumerate (runtime unreachable) | non-zero | one line on stderr saying why |

The last two rows are the contract. *"Nothing is running"* and *"I could not
look"* are different answers that demand opposite actions, and a runner that
reports the second as the first hands the supervisor a confident wrong answer —
the pump's one non-negotiable safety property is that it never double-launches a
live agent. **The runner never guesses the fallback; the caller decides.**

The empty case is a real trap rather than a pedantic one: printing `"$names"`
unconditionally emits a blank line when there are none, and a caller counting
lines then sees one live agent where there are zero.

#### The prefix scrape remains the fallback

The pump still discovers live agents by listing processes whose name carries the
configured agent prefix
([PUMP-MECHANISMS.md §2](PUMP-MECHANISMS.md#2-liveness-from-process-state-never-task-status)).
That path is the mechanism the whole supervisor rests on, it is proven, and it
stays — `list` is the *preferred* source of liveness, not the only one, and a
runner that does not implement it is still drivable.

Which means **the naming contract is still mandatory**: a runner must name its
agents `<prefix><branch-slug>` and make them visible to the pump's enumeration.
This is the sharpest constraint on writing a non-container runner, and the reason
it is stated twice. Implementing `list` does not buy you out of it — the fallback
has to keep working, and the two answers have to be the same set.

For a container runner that means `list` should share the pump's own enumeration
rather than re-spelling the filter: two copies of one `docker ps --filter` is
precisely how the two answers drift apart. The reference runner sources
`lib/pump-lib.sh` for exactly this reason, and
`tests/test-tp-runner-list.sh` asserts the two agree name for name.

---

## 2. Naming and identity

The agent's name is how the pump recognizes it later, so the mapping must be
mechanical and reversible:

```
container name = TASKPUMP_AGENT_PREFIX + branch with '/' replaced by '-'
```

Two consequences:

- **The prefix must be distinctive.** Enumeration matches on it; a prefix that
  collides with other containers on the host will confuse liveness.
- **A branch name may contain at most one `/`.** `feat/a/b` and `feat/a-b`
  produce the same slug, so the name cannot be mapped back to one branch.

### Enforced, not advisory

The second rule used to be a recommendation, and a branch that broke it launched
normally — the failure surfaced much later and somewhere else, as an agent whose
name liveness could not map back, a phase the pump therefore read as dead, and a
second agent launched on the same branch. That is the one thing the supervisor
must never do, so the rule is now checked at both doors:

| Where | What happens |
|---|---|
| `tp task claim --branch <b>` | Refused, naming the ambiguous slug it would have produced. Nothing is written. |
| `tp pump` startup | The branch the run *would* construct is validated once, before any tick. A bad `TASKPUMP_BRANCH_PREFIX` (`--branch-prefix`) aborts the run naming the key. |

Also refused: a leading `/` (the name would start with `-`, which is not a legal
container name), a trailing `/`, and whitespace (a name that cannot survive a
whitespace-delimited registry or `docker ps --format`).

**The encoding itself is frozen.** Container names already exist on operators'
hosts, so the fix for an unmappable branch is a different branch name, never a
cleverer slug. One rule lives in `lib/pump-lib.sh`
(`apl_branch_slug_reject_reason`) and both tools read it, so neither gets its own
opinion about what is legal.

---

## 3. `runners/local` — the process runner

TaskPump ships two runners. This is the one with nothing underneath it: no image
to build, no daemon to talk to, nothing to install. It starts the agent as a
plain host process.

```bash
TASKPUMP_RUNNER=runners/local/runner.sh
TASKPUMP_LOCAL_AGENT_CMD='my-agent --prompt-file .taskpump-phase-brief.md'
```

That is the whole configuration. `TASKPUMP_LOCAL_AGENT_CMD` is required and has
no default — there is no sane guess at what agent you are driving, and a
plausible-but-wrong one would fail somewhere far from here. The command runs
through `bash -c`, in the workspace, with the run's environment exported
(`TASKPUMP_BRIEF`, `TASKPUMP_PHASE`, `TASKPUMP_TASK_ID`, `TASKPUMP_BRANCH`,
`TASKPUMP_MAX_TURNS`, … and each one's legacy `ARACHNE_*` twin).

### 3.1 It does not sandbox anything

**The agent runs as you, with your permissions, your filesystem, your network
and your credentials.** There is no mount policy, no egress allowlist, no
read-only primary checkout, no memory cap — nothing between the agent and your
machine but the agent's own restraint. Every guarantee in §4 belongs to the
`claude-docker` runner and **none of them apply here**.

That is fine for a supervised experiment, for a repository you would hand a
colleague, or for an agent that isolates itself. It is **not** fine for an
unattended multi-day drain of an untrusted workload. If that is what you are
doing, use a runner that sandboxes, and read §4 first.

### 3.2 How it keeps track

A container runtime remembers the name→process mapping for you. Nothing does
that for a bare process, so this runner writes one itself — `<name> <pgid>
<workspace-root>` per line, in a registry file:

| Knob | Default |
|---|---|
| `TASKPUMP_LOCAL_REGISTRY` | `$TASKPUMP_STATE_DIR/.taskpump-local-agents`, else `$XDG_STATE_HOME/taskpump/local-agents` |
| `TASKPUMP_LOCAL_STOP_GRACE_S` | `10` — seconds between `TERM` and `KILL` |
| `TASKPUMP_AGENT_LOG_NAME` | `.taskpump-agent.log`, inside the workspace |

Three details there are load-bearing, and all of them look like implementation
choices until they bite:

- **The recorded id is a process GROUP, not a pid.** An agent spawns children — a
  language server, a test run, a subagent. Killing only the leader leaves them
  running and holding the workspace, so the agent starts under `setsid` and
  `stop` signals the whole group.
- **A finished agent is dead even while its process-table entry survives.**
  `kill -0` succeeds on a zombie, and an agent whose parent (this short-lived
  runner) has exited is reparented to PID 1 — which, in any minimal container,
  never reaps anything. Liveness therefore reads process *state* and treats `Z`
  as gone. The obvious `kill -0` implementation reports a long-dead agent as
  live forever: `stop` never finishes, `list` never prunes, and the pump never
  relaunches the phase.
- **Every entry records the workspace it was launched for**, and `list` and
  `stop` answer for one workspace at a time. The registry is host-global by
  default and the prefix is shared, so two projects on one host name the same
  agent the moment they share a branch convention — and before this field, the
  second project's pump read the first's live agent as its own RUNNING phase and
  drained nothing for the rest of the run (issue #40), while its `stop` would
  have killed the other project's agent outright. Two workspaces may hold the
  same name at once; that is the collision the field exists to survive, not one
  to resolve. An entry that records *no* workspace — written by an older runner,
  or by a caller that named none — cannot be proven foreign and stays visible to
  everybody, because hiding an agent that IS the caller's is how a live agent
  gets launched twice.

`list` prunes what it walks, so the registry holds the live set and does not
accumulate. `launch` refuses to start a second agent under a live name — the one
guarantee `docker run --name` gives the container runner for free, and the pump's
never-double-launch property leans on it.

### 3.3 What a consumer still has to set

The supervisor's launch prerequisites are container-shaped, and a process runner
does not escape them yet:

```bash
TASKPUMP_IMAGE=unused-by-a-process-runner   # required to be non-empty
TASKPUMP_IMAGE_BUILD=                       # empty ⇒ skip the image build
```

`TASKPUMP_IMAGE` is checked before any launch and deliberately has no default
(§4.0), and an *unset* `TASKPUMP_IMAGE_BUILD` means "docker build the repo root".
Neither applies here, so both need saying out loud. Setting them is the whole
adaptation: `tests/test-tp-runner-local.sh` drives a real `tp-pump --once` this
way with the container runtime pointed at a path that does not exist, and both
the launch and the next tick's liveness work.

### 3.4 Writing your own

The skeleton, if you are adapting to something else entirely:

```bash
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  launch)  # start it, name it, print the handle, detach
    cd "$TP_WORKSPACE"
    setsid my-agent --session-name "$TP_CONTAINER_NAME" \
        > "$TP_WORKSPACE/.taskpump-agent.log" 2>&1 &
    echo "$TP_CONTAINER_NAME"
    ;;
  stop)    # idempotent: already gone is success (§1.2)
    kill -TERM -- "-$(recorded_pgid_of "$TP_CONTAINER_NAME")" || true
    ;;
  list)    # every live agent, one per line; empty is exit 0 and no output (§1.3)
    live_names || true
    ;;
  *) echo "runner: unknown verb: ${1:-}" >&2; exit 2 ;;
esac
```

The two things that are easy to get wrong are both in §1.3: an empty fleet must
print **nothing** (not a blank line), and a failure to enumerate must exit
non-zero rather than look like an empty fleet. And whatever you start, **name it
`<prefix><branch-slug>`** (§2) — the fallback enumeration still depends on it.
That name is not unique on a host, though, so if your runner can record which
workspace an agent belongs to (`TP_REPO_ROOT` is handed to `launch`, and to
`list` and `stop` as configuration), have `list` answer for the workspace it was
asked about; otherwise two projects sharing a branch convention will read each
other's agents as their own.

---

## 4. The `claude-docker` reference runner

The shipped runner launches Claude Code in a Docker container. It is a reference
in both senses: it is what the mechanisms were proven against, and it is the
worked example of what a hardened runner has to handle.

### 4.0 The image contract

TaskPump ships the runner, not the image. **`TASKPUMP_IMAGE` has no default**: a
real run aborts before any launch when it is unset, because a wrong-but-plausible
default would launch the wrong agent silently, and a loud missing name is
strictly better. (`--dry-run` plans without an image.)

The image a consumer names must satisfy this contract:

- **The runner's in-container half is baked at `/entrypoint.sh`.** That path is
  the `TASKPUMP_ENTRYPOINT` default, and the file is the shipped
  `runners/claude-docker/entrypoint.sh`:

  ```dockerfile
  COPY runners/claude-docker/entrypoint.sh /entrypoint.sh
  RUN chmod +x /entrypoint.sh
  ```

  An image that bakes it elsewhere sets `TASKPUMP_ENTRYPOINT` to match. Know
  the trade before pinning it to anything that is not the shipped file: **only
  the shipped entrypoint honors the pre-flight hook (§4.4)**, so pointing this
  key at a pre-hook entrypoint leaves a configured `TASKPUMP_PRE_FLIGHT` read
  by nothing, silently. The reference consumer's historical
  `/entrypoint-parallel.sh` pin was exactly that state — the entrypoint predated
  the hook — which is why `examples/arachne.conf` now shows the
  shipped-entrypoint wiring instead (issue #5).

- **What the entrypoint finds inside:** the `claude` CLI on `PATH`, `git`, `jq`,
  `setpriv` (util-linux — present in any Debian/Ubuntu base), and an
  unprivileged user to drop to (`TASKPUMP_CONTAINER_USER`, default `dev`, home
  `/home/dev`). The container starts as root and hands the session to that user
  with `setpriv`, never `su` — `su` subreaps and leaks the session's orphans as
  zombies (issue #15). See *Why root* in `runners/claude-docker/README.md`.
  For the mounted `tp` to function the image additionally needs `bash` 4+ and
  mikefarah's `yq` v4 — see §4.5.

- **Everything project-shaped stays out of the image contract.** Toolchains,
  smoke tests, and the egress allowlist arrive through the pre-flight hook
  (§4.4), which is what keeps one image contract serving many projects.

Its guarantees:

### 4.1 Access-token-only credentials

The host credential file is bind-mounted **read-only**, and the runner copies it
into the container **with the refresh token stripped**. The container can
authenticate; it cannot refresh.

This is not defense in depth — it is a correctness fix for a specific incident.
OAuth refresh tokens **rotate on use**: refreshing issues a new one and
invalidates the old. A container that refreshed could not write the new token
back across a read-only mount, so the host — and every other client sharing that
credential, including the operator's own interactive sessions — would be left
holding a dead refresh token and forced to log in again. That is exactly what
happened: host sessions were logged out whenever the pump ran.

Removing the refresh token makes rotation **physically impossible** in the
container. The host owns rotation; containers track it by re-copying the host's
freshly-issued access token periodically.

The consequence is a real operational constraint: **a container cannot
self-refresh, so the host must keep its token fresh.** During a long headless run
with no host-side session, the access token's TTL will elapse with nothing to
renew it. That is what the `claude-token-fresh` gate exists to detect, pausing
launches so dead containers are not churned — see
[GATES.md §2](GATES.md#2-the-shipped-gates).

The credential install is an atomic, validated swap: the transform must produce a
file that still carries an access token, or the previous copy is left intact.

### 4.2 Egress allowlist

The container configures an `iptables` allowlist and drops everything else. Only
the agent's API endpoint, the package registries the project needs, and source
hosting are reachable. This is the **hard sandbox**; the agent's own permission
model is a second layer inside it, not a replacement for it.

The allowlist is project-shaped — a Rust project needs crates.io, a Node project
needs npm — so it is part of the consumer's egress profile rather than a fixed
list.

### 4.3 Read-only primary, writable workspace

The primary checkout is mounted read-only; only the agent's own workspace is
writable. An agent that tries to edit the primary source tree fails at the
filesystem rather than silently contaminating a checkout other agents are cutting
branches from. A pre-tick contamination check backs this up, catching a future
mount change that re-widens the mount.

### 4.4 The pre-flight hook

Everything project-shaped that must happen between "container exists" and "agent
starts" goes through one seam:

```bash
TASKPUMP_PRE_FLIGHT=./scripts/taskpump-preflight.sh
```

The runner executes it in the workspace before handing control to the agent. It
is where a consumer puts toolchain setup (`PATH` for a language toolchain),
smoke tests that assert the image is usable, dependency bootstrapping, and
submodule initialization.

This hook is the whole reason the runner is generic. Without it, every
project-specific step would have to live in the runner, and the runner would be
Arachne's. With it, the runner knows how to make a sandbox and start an agent,
and knows nothing about what the agent will build.

A pre-flight that fails should exit **75** (`EX_TEMPFAIL`) if the environment was
merely not ready — the entrypoint exits before claiming anything, so no task
records a failed iteration and nothing burns a tripwire. See
[LEDGER-CONTRACT.md §10](LEDGER-CONTRACT.md#10-the-exit-code-protocol--frozen).

### 4.5 tp inside the container

`launch` bind-mounts the TaskPump installation itself — resolved from the
runner's own realpath, the same way `bin/tp` finds its libexec — **read-only at
`/opt/taskpump`**. The entrypoint prepends `/opt/taskpump/bin` to the agent's
PATH before resolving the task CLI, so the resolution order is:

1. an explicit `TASKPUMP_WORKSPACE_TASK_CLI` — a consumer's pinned shim always
   wins (Arachne's `scripts/arachne-task` pin keeps working unchanged);
2. `tp` on PATH — guaranteed under the shipped runner by the mount;
3. the loud startup error from G1.6 — unreachable with the shipped runner, kept
   for custom runners that mount nothing.

A workspace therefore no longer needs to vendor a task CLI. Two grammars, one
seam, keyed on the resolved CLI's **basename**: anything named `tp` — the bare
mounted default and a pinned-by-path `/opt/taskpump/bin/tp` alike — is invoked
as `<cli> task <verb>` (that is where tp keeps its ledger verbs), while a
pinned shim with any other name keeps the direct `<cli> <verb>` grammar it
always had.

The mount is read-only, and the tools resolve their own siblings
install-relative, so nothing ever writes into the installation; worktree and
ledger resolution still follow the **caller's** cwd, per the wrong-ledger lesson
([CONFIG.md](CONFIG.md)). Read-only is load-bearing in the other direction too:
an agent that could write `/opt/taskpump` could edit the supervisor supervising
it. For the same reason the runner refuses to launch when it cannot resolve its
own installation (a `runner.sh` copied away from its tree) rather than mounting
whatever happens to be two directories up.

**What the image must provide for tp to function:** `bash` 4+, `git`, `jq`, and
mikefarah's `yq` v4 (the ledger is read and written through yq's front-matter
modes — the Python `yq` shares nothing but the name). The pre-flight hook
(§4.4) is where a consumer asserts these before the session starts; a probe
that fails there exits 75, before anything is claimed.

### 4.6 What it hands the agent

The agent starts with a **brief** on stdin: the rendered phase-drain template,
naming the phase, its cross-phase dependencies and their integration state, and
the task's goal. When the pump is resuming a stalled claim, a **resume note** is
prepended ahead of that brief — see
[PUMP-MECHANISMS.md §4](PUMP-MECHANISMS.md#4-resume-with-context-bounded-by-a-no-progress-budget).

Both are files in the workspace, so what an agent was told is inspectable after
the fact. When a run goes wrong, the brief is usually the first thing to read.
