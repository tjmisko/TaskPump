# The `claude-docker` runner

A **runner** is the seam between the supervisor and whatever actually executes an
agent. `libexec/tp-pump` decides *what* should run — which phase, which worktree,
which task is the lead, whether this is a resume — and hands that decision to a
runner, which knows *how* to start it.

This runner starts a detached Docker container running the Claude Code CLI in
headless Auto Mode. It is the reference implementation: everything in it was
lifted from the pump's own inline launch block, so an existing consumer gets
byte-identical container behaviour.

| File | Runs | What it is |
|---|---|---|
| `runner.sh` | on the host | The pump-facing CLI: `launch`, `stop`. |
| `entrypoint.sh` | in the container | The generic in-container half: environment contract, credentials, prompt assembly, the session. Baked into the image. |
| `preflight-example.sh` | in the container | **Example, not wired.** The project-specific half — firewall, agent settings, smoke test — as a working reference. |

---

## The pump ↔ runner interface

### `runner.sh launch`

Starts the agent container detached. Prints the container id on stdout. On
failure: non-zero exit, reason on stderr, nothing on stdout.

All inputs are environment variables, never arguments, so the set can grow
without breaking a caller. Each is read as `TP_<NAME>` first, then the legacy
spelling. `lib/config.sh` promotes `TASKPUMP_X` to `ARACHNE_X`, so a key set in
`taskpump.conf` reaches the runner through the legacy column.

| Canonical | Legacy | Default | Meaning |
|---|---|---|---|
| `TP_WORKSPACE` | `WORKSPACE_PATH` | *(required)* | Agent workspace (a git worktree). Mounted RW, becomes the container workdir. |
| `TP_REPO_ROOT` | `REPO_ROOT` | *(required)* | Primary checkout. Mounted **read-only**. |
| `TP_CONTAINER_NAME` | `ARACHNE_CONTAINER_NAME` | *(required)* | `docker run --name`. |
| `TP_IMAGE` | `ARACHNE_IMAGE` | *(required)* | Image to run. Deliberately has no default. |
| `TP_ENTRYPOINT` | `ARACHNE_ENTRYPOINT` | `/entrypoint-parallel.sh` | In-container entrypoint path. |
| `TP_LEDGER_REPO` | `ARACHNE_PUMP_OPS_DIR` | `$TP_REPO_ROOT/ops` | Ledger checkout. Mounted RW. |
| `TP_BRANCH` | `ARACHNE_BRANCH` | *(empty)* | Informational; forwarded to the agent. |
| `TP_TASK_ID` | `ARACHNE_TASK_ID` | *(empty)* | Lead task the agent is assigned. |
| `TP_PHASE` | `ARACHNE_PHASE` | *(empty)* | Phase the agent drains. |
| `TP_BRIEF` | `ARACHNE_BRIEF` | *(empty)* | Rendered kickoff brief, host path. |
| `TP_RESUME_NOTE` | `ARACHNE_RESUME_NOTE` | *(empty)* | Resume preamble, host path. |
| `TP_MODEL` | `AGENT_MODEL` | `opus` | Model alias. |
| `TP_MAX_TURNS` | `MAX_TURNS` | `600` | Turn cap for the session. |
| `TP_CLAUDE_DIR` | `CLAUDE_DIR` | `$HOME/.claude` | Host agent home. Mounted RO. |
| `TP_CLAUDE_JSON` | `CLAUDE_JSON` | `$HOME/.claude.json` | Host agent config. Mounted RO. |
| `TP_MEMORY_MAX` | `AGENT_MEMORY_MAX` | `3g` | `--memory`. |
| `TP_MEMORY_SWAP` | `AGENT_MEMORY_SWAP` | `5g` | `--memory-swap`. |
| `TP_CONTAINER_RUN_USER` | — | *(unset)* | Emits `--user` when set. See *Why root*. |
| `TP_ENV_PASSTHROUGH` | — | *(a list)* | Names of extra variables to forward **when set**. Both spellings of every key are in the default list — forwarding only one would leave the other silently inert in a caller's hands. |
| `GITHUB_TOKEN` | — | *(empty)* | Forwarded for ledger fetch and `gh`. |
| `DOCKER` | — | `docker` | Container binary override. Test seam. |

`TP_IMAGE` has no default on purpose. A plausible-looking default would launch
the wrong agent silently; a missing name should be loud.

### `runner.sh stop`

Reads `TP_CONTAINER_NAME` and stops that container. **Idempotent**: stopping
something that is already gone exits 0 with a note on stderr, so a supervisor
tearing down does not have to race `docker ps` to find out whether it still has
work to do. Any other `docker stop` failure exits non-zero.

### Not in v1: liveness

"Is this phase still running?" stays in `lib/pump-lib.sh` (`apl_live_branches`),
which asks `docker ps` once. Liveness is a *fleet* question — the pump asks it
about every phase at once, every tick — while launch and stop are per-container.
Routing the fleet query through a per-container CLI would mean N subprocesses per
tick to answer what one `docker ps` already answers, and the pump's most
important safety property (never double-launch a live container) would come to
depend on a fan-out loop rather than a single atomic snapshot. A second runner
will need a liveness verb; v1 is honest that it does not have one.

### The mount set

```
-v $TP_CLAUDE_DIR:/tmp/claude-home:ro
-v $TP_CLAUDE_JSON:/tmp/claude-home-json/.claude.json:ro
-v $TP_REPO_ROOT:$TP_REPO_ROOT:ro          # primary checkout, READ-ONLY
-v $TP_REPO_ROOT/.git:$TP_REPO_ROOT/.git   # RW overlay
-v $TP_WORKSPACE:$TP_WORKSPACE             # RW overlay
-v $TP_LEDGER_REPO:$TP_LEDGER_REPO         # RW overlay
-w $TP_WORKSPACE
```

Host and container paths are identical on purpose: a git worktree's `.git` file
stores an **absolute** gitdir path, so matching paths let git resolve without a
`git worktree repair` inside the container.

The read-only primary with three read-write overlays is load-bearing. A blanket
RW `$TP_REPO_ROOT` lets an agent edit the primary checkout out from under every
other worktree; that regression has happened, so both `tests/test-entrypoint.sh`
and the entrypoint's own startup self-check guard against it.

### Why root, and why no `--user`

The launch does not pass `--user`. The container starts as root because the
pre-flight installs an iptables egress allowlist (hence `--cap-add NET_ADMIN`)
and writes into the agent user's home; the entrypoint drops to the unprivileged
container user with `su` for the session itself. `TP_CONTAINER_RUN_USER` exists
for a consumer whose image needs a `--user`, but setting it breaks any pre-flight
that configures the firewall.

---

## What the entrypoint guarantees

### The environment the container sees

`runner.sh` passes **both** spellings into the container: today's legacy names
(`WORKSPACE_PATH`, `REPO_ROOT`, `ARACHNE_BRIEF`, `ARACHNE_RESUME_NOTE`,
`ARACHNE_TASK_ID`, `ARACHNE_PHASE`, `MAX_TURNS`, `AGENT_MODEL`, `GITHUB_TOKEN`)
and canonical `TASKPUMP_*` twins. `entrypoint.sh` reads canonical-first
(`TASKPUMP_X`, then `TP_X`, then legacy, then a baked default), so a container
launched by an un-migrated caller and one launched by a migrated caller behave
identically. That equivalence is asserted, not assumed — see
*canonical vs legacy environment equivalence* in `tests/test-entrypoint.sh`.

The full table is in the header of `entrypoint.sh`.

### Credentials: access-token-only, host owns rotation

The host agent home is bind-mounted **read-only**, so its credentials file always
reflects the live host token. The entrypoint copies it into the container user's
home **with `.claudeAiOauth.refreshToken` stripped**.

The OAuth refresh token rotates on every refresh: a new one is issued and the old
invalidated. A container that performed a refresh could not write the new token
back across a read-only mount, so the host — and every other client sharing that
token, including the operator's own interactive sessions — would be left holding
a dead refresh token and forced to log in again. This was not hypothetical; host
sessions were being logged out whenever the pump ran (2026-06-24). Removing the
refresh token makes a container *physically unable* to rotate it.

Consequences worth knowing:

- The **host owns rotation.** A container tracks it by re-copying the host's
  freshly-issued access token every `TASKPUMP_CRED_REFRESH_INTERVAL_S` (300s).
- A long *headless* run needs a live host session, or the ~6h access-token TTL
  elapses with nothing to renew it. The pump's stale-token feed gate pauses
  *launching* in that state so dead containers are not churned; running agents
  are untouched.
- The strip happens at **startup as well as** in the refresher. Doing it only in
  the refresher would leave a rotation-capable container for the first 300s.

### Stdin assembly

The session's prompt is `cat`-ed in this order:

1. **goal note** — the lead task's one-line goal, written to
   `$WORKSPACE/.arachne-goal.md` from the task file's frontmatter;
2. **resume note** — present only on a resumed stalled claim;
3. **the brief**.

The order is load-bearing. The goal comes first because it is what the other two
are in service of; a resume note read after the brief would look like an
amendment rather than the premise it is.

The brief resolves as an absolute path, or relative to the ledger checkout, the
repo root, or the workspace — in that order. A resume-note path that does not
exist in the container falls back to `$WORKSPACE/.arachne-resume.md`.

### What the task CLI sees

The entrypoint invokes the **consumer's** task CLI from inside the workspace, at
`TASKPUMP_WORKSPACE_TASK_CLI` (default `scripts/arachne-task`, relative to the
workspace; an absolute value is used as given). That default names Arachne's own
shim, which is correct: the container can only see what is mounted, and the
TaskPump install directory is not among the mounts. A shim that `exec`s a path
outside the mount set will fail at runtime while still passing an `-x` check.

There are exactly three call sites, all in the session script:

- `claim <id> --branch <branch> --turns $TASKPUMP_SAFETY_TURNS` — a safety net,
  idempotent when the branch already holds the claim. The agent re-claims and
  sub-claims as its brief directs.
- `heartbeat <id> --start` before the session.
- `heartbeat <id> --end` after it, **only if** the task is still `in_progress`.

The entrypoint never calls `complete`. `done` requires the agent to have asserted
a green build, green tests, and a PR; a wrapper cannot assert that on its behalf.

Both spellings of the ledger wiring are exported to the session:
`TASKPUMP_TASKS_DIR` / `ARACHNE_TASKS_DIR`, `TASKPUMP_TASK_OUT` /
`ARACHNE_TASK_OUT`, `TASKPUMP_CODE_REPO` / `ARACHNE_CODE_REPO` (the workspace,
so heartbeat measures productivity against *this* branch), and
`TASKPUMP_TASK_PUSH=1` / `ARACHNE_TASK_PUSH=1`.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | The session finished, whatever the agent concluded. |
| `1` | Misconfiguration the operator must fix: no workspace, no brief, brief not found. |
| `75` | `EX_TEMPFAIL` — retryable. Raised **before `heartbeat --start`**, so the failure never consumes an iteration on the task's tripwire counter. Causes: the host agent config never parsed as valid JSON after 6 retries (it is written live by the operator's own session and can be caught mid-write); or the pre-flight hook failed. |
| `124` | The optional wall-clock cap (`TASKPUMP_AGENT_WALL_TIMEOUT_S`) fired. |

The 75-before-heartbeat rule is asserted structurally by the test suite: every
`exit 75` must appear earlier in the file than the `heartbeat --start` call.

---

## The pre-flight hook

`TASKPUMP_PRE_FLIGHT` names an executable **inside the container**. It runs as
root after credentials are installed and before the session starts, with
`WORKSPACE_PATH`, `REPO_ROOT`, `LEDGER_REPO`, `LOG_FILE`,
`TASKPUMP_CONTAINER_USER`, `TASKPUMP_CONTAINER_HOME`, `TASKPUMP_TASK_ID` and
`TASKPUMP_PHASE` exported. A non-zero exit aborts the launch with 75.

Decide *inside* the hook which of its steps are fatal. In the reference hook the
firewall is (an agent with unrestricted egress is not the sandbox anyone agreed
to) and the smoke test is not.

To wire one up:

```dockerfile
COPY preflight.sh /preflight.sh
RUN chmod +x /preflight.sh
```

```conf
# taskpump.conf
TASKPUMP_PRE_FLIGHT=/preflight.sh
```

`preflight-example.sh` is Arachne's pre-flight, verbatim, as a working starting
point. TaskPump never runs it; the test suite asserts that no executable line
anywhere references it.

### Ordering note

In the pre-split entrypoint the firewall was configured first, before
credentials. It now runs after, because the settings merge in the same hook has
to overwrite a `settings.json` the credential copy may have just laid down, and
one hook point cannot be both before and after that copy. Nothing egresses during
the credential copy — it is local file I/O against a read-only bind mount — so
the window this opens carries no traffic.

### The transitional fallback

An image built before the hook existed has no `TASKPUMP_PRE_FLIGHT` to set. So
when the variable is unset **and** the legacy marker `claude-settings-auto.json`
is present in either `REPO_ROOT` or `WORKSPACE_PATH`, the entrypoint runs the old
inline pre-flight instead. This keeps today's containers working across the
transition and is scheduled for deletion once consumers set the hook. Nothing new
should depend on it; a consumer that sets `TASKPUMP_PRE_FLIGHT` never reaches it.

With no hook and no markers, no pre-flight runs at all — the honest default for a
consumer that has not written one.

---

## Testing

`tests/test-entrypoint.sh` never runs `docker` and never starts a session.

- `runner.sh` is driven with `DOCKER=/bin/echo` and compared against a **golden
  launch line**, normalized for paths, plus separate assertions for each
  invariant the line encodes so a failure says which one broke. Recording stubs
  cover `stop` and the failure paths.
- `entrypoint.sh` exposes two test seams. `TASKPUMP_ENTRYPOINT_TEST_MODE=plan`
  resolves the environment, assembles the prompt, prints a `REPORT` block and
  exits — no credentials, no firewall, no session. `=preflight` additionally
  installs credentials and runs the hook, then stops short of the session. Both
  exist so the harness exercises real resolution and ordering logic instead of
  grepping for it.
- The parts that genuinely cannot be executed on a dev host — the permission
  posture, the refresh-token strip, the settings merge — stay static assertions.
