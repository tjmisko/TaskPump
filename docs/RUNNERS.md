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

**Inputs:** none per agent. `list` is called once per tick with no task, no
workspace and no container name in hand, so it may read only what `stop` already
reads from configuration — for the shipped runner, the agent-name prefix
(`TP_AGENT_PREFIX`, or the shared `TASKPUMP_AGENT_PREFIX`). A runner that demands
launch-shaped input is uncallable at exactly the moment it is needed.

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
- **Branch names with more than one `/` do not round-trip cleanly** back to a
  branch. Keep branch names to one separator (`feat/t12`), which is what the
  default branch prefix produces.

---

## 3. Writing a runner

The minimum viable runner starts a local process:

```bash
#!/usr/bin/env bash
# runners/local/runner.sh — run an agent as a plain host process.
set -euo pipefail

case "${1:-}" in
  launch)
    cd "$TP_WORKSPACE"
    # The name is load-bearing: `stop` and `list` below both find the process by
    # it, so it has to survive into the process table (here, as argv).
    setsid my-agent \
        --session-name "$TP_CONTAINER_NAME" \
        --prompt-file "$TP_WORKSPACE/.taskpump-brief.md" \
        --max-turns "$TP_MAX_TURNS" \
        > "$TP_WORKSPACE/.taskpump-agent.log" 2>&1 &
    echo "$!"                      # the handle
    ;;
  stop)
    pkill -f "$TP_CONTAINER_NAME" || true
    ;;
  list)
    # Exit 0 with no output when nothing matches — pgrep's own exit 1 for "no
    # match" would be read as "I could not look" (§1.3).
    pgrep -a -f "${TP_AGENT_PREFIX:-tp-agent-}" \
      | grep -o "${TP_AGENT_PREFIX:-tp-agent-}[^ ]*" || true
    ;;
  *)
    echo "runner: unknown verb: ${1:-}" >&2
    exit 2
    ;;
esac
```

This is enough to drive a real drain, and it is the right thing to build first
when adapting TaskPump to a new agent. It provides no isolation whatsoever — the
agent has your whole machine — which is fine for a supervised experiment and not
fine for an unattended multi-day run.

Note what `list` costs a process runner: the agent's name has to be recoverable
from the running process. A container runtime keeps that mapping for you; a bare
process does not, so the runner has to put the name somewhere durable — argv, as
above, or a pid file it writes at launch and reads back here.

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

  An image that bakes it elsewhere sets `TASKPUMP_ENTRYPOINT` to match — that is
  how the reference consumer runs: `examples/arachne.conf` pins its historical
  `/entrypoint-parallel.sh` layout.

- **What the entrypoint finds inside:** the `claude` CLI on `PATH`, `git`, `jq`,
  and an unprivileged user to drop to (`TASKPUMP_CONTAINER_USER`, default `dev`,
  home `/home/dev`). The container starts as root and hands the session to that
  user with `su` — see *Why root* in `runners/claude-docker/README.md`.

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

### 4.5 What it hands the agent

The agent starts with a **brief** on stdin: the rendered phase-drain template,
naming the phase, its cross-phase dependencies and their integration state, and
the task's goal. When the pump is resuming a stalled claim, a **resume note** is
prepended ahead of that brief — see
[PUMP-MECHANISMS.md §4](PUMP-MECHANISMS.md#4-resume-with-context-bounded-by-a-no-progress-budget).

Both are files in the workspace, so what an agent was told is inspectable after
the fact. When a run goes wrong, the brief is usually the first thing to read.
