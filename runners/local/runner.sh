#!/usr/bin/env bash
# runners/local/runner.sh — the local process runner. RUNNER CONTRACT v2.
#
# Starts an agent as a plain host process. This is the runner that makes "any
# repository" true without a container runtime: no image to build, no daemon to
# talk to, nothing to install. It is the right first thing to build when adapting
# TaskPump to a new agent, and the right thing to keep using when the agent
# already sandboxes itself.
#
# ── IT DOES NOT SANDBOX ANYTHING ─────────────────────────────────────────────
#
# The agent runs as you, with your permissions, your filesystem, your network and
# your credentials. There is no mount policy, no egress allowlist, no read-only
# primary checkout, no memory cap — nothing between the agent and your machine
# but the agent's own restraint. Every guarantee in docs/RUNNERS.md §4 belongs to
# the claude-docker runner and none of them apply here.
#
# That is fine for a supervised experiment, a repo you would hand to a colleague,
# or an agent that isolates itself. It is NOT fine for an unattended multi-day
# drain of an untrusted workload. If that is what you are doing, use a runner
# that sandboxes, and read §4 first.
#
# ── The contract ─────────────────────────────────────────────────────────────
#
#   runner.sh launch    Start the agent detached in its own session. Prints the
#                       agent's name on stdout. Non-zero with a reason on stderr
#                       when the launch fails.
#   runner.sh stop      Stop the agent named by TP_CONTAINER_NAME. Idempotent:
#                       never recorded, and recorded but already dead, are both
#                       success.
#   runner.sh list      Print every live agent's name, one per line. Prunes the
#                       registry of agents that have exited while it is there.
#
# ── Inputs ───────────────────────────────────────────────────────────────────
#
# Environment, never arguments. TP_<NAME> first, then the legacy spelling.
#
#   TASKPUMP_LOCAL_AGENT_CMD  —  REQUIRED for launch. The shell command that runs
#                                one agent session. No default: there is no sane
#                                guess at what agent you are driving, and a
#                                wrong-but-plausible one would fail somewhere far
#                                from here. Run through `bash -c`, in the
#                                workspace, with everything below exported.
#   TP_WORKSPACE      WORKSPACE_PATH      required — the agent's workspace (a git
#                                         worktree); becomes its working directory
#   TP_CONTAINER_NAME ARACHNE_CONTAINER_NAME  required — the agent's NAME. Called
#                                         "container name" for one reason: the
#                                         pump's naming contract is the same for
#                                         every runner (docs/RUNNERS.md §2), and
#                                         renaming the variable per runner would
#                                         break the one thing that must not vary.
#   TP_BRANCH         ARACHNE_BRANCH      branch checked out in the workspace
#   TP_TASK_ID        ARACHNE_TASK_ID     lead task the agent is assigned
#   TP_PHASE          ARACHNE_PHASE       phase the agent drains
#   TP_BRIEF          ARACHNE_BRIEF       rendered kickoff brief (host path)
#   TP_RESUME_NOTE    ARACHNE_RESUME_NOTE resume preamble, or empty
#   TP_MODEL          AGENT_MODEL         model alias, forwarded as-is
#   TP_MAX_TURNS      MAX_TURNS           turn cap, forwarded as-is
#   TP_REPO_ROOT      REPO_ROOT           the primary checkout — and the fleet
#                                         this agent belongs to; see below
#
# Configuration `stop` and `list` read — no per-launch input, because the pump
# asks `list` once per tick with no task in hand (docs/RUNNERS.md §1.3):
#
#   TP_REPO_ROOT      TASKPUMP_REPO_ROOT / REPO_ROOT — the workspace whose fleet
#                                is being asked about. Configuration, not
#                                per-agent input: it names a project, exactly as
#                                the prefix names a fleet.
#   TASKPUMP_LOCAL_REGISTRY   —  the registry file. Default:
#                                $TASKPUMP_STATE_DIR/.taskpump-local-agents when
#                                a state dir is configured, else
#                                $XDG_STATE_HOME/taskpump/local-agents.
#   TASKPUMP_LOCAL_STOP_GRACE_S — seconds between TERM and KILL (default 10).
#   TASKPUMP_AGENT_LOG_NAME   —  log filename inside the workspace
#                                (default .taskpump-agent.log).
#
# ── Why a registry, and why process groups ───────────────────────────────────
#
# A container runtime remembers the name→process mapping for you; nothing does
# that for a bare process, so this runner writes `<name> <pgid>` to a file and
# reads it back in stop and list. Without it `list` would have to guess from the
# process table, and a runner that guesses about liveness is worse than one that
# has none (docs/RUNNERS.md §1.3).
#
# The recorded id is a process GROUP, not a pid. An agent spawns children — a
# language server, a test run, a subagent — and killing only the leader leaves
# them running and holding the workspace. `setsid` puts the session in its own
# group so one signal reaches the whole tree, and so an agent that outlives this
# runner is not attached to its terminal.
#
# ── And why every entry records a workspace ──────────────────────────────────
#
# The registry is host-global by default and the agent prefix is shared, so two
# projects on one host agree on agent NAMES the moment they agree on a branch
# convention: both call it <prefix>feat-f80. Found live in the G4.4 rehearsal
# (issue #40) — the second repo's pump read the first repo's still-running agent
# as its own RUNNING phase, and drained nothing for the rest of the run. A
# `docker ps` fleet has the same shape of collision; here we can simply record
# who an agent belongs to, so each line is `<name> <pgid> <workspace-root>` and
# `list` and `stop` answer for one workspace at a time.
#
# The one thing this must never do is hide an agent that IS ours: the supervisor
# would then launch a second one on the same worktree, which is the destructive
# half of the same bug. So an entry that records no workspace (written before
# this field existed) cannot be proven foreign, and stays visible to everybody.
#
# Two consequences of one name now covering two agents, and both are the same
# rule read from different ends. Removing a line goes by (name, pgid) and never
# by name alone, because a name-matching delete would unregister an agent that is
# still running — hiding it exactly as above. And a `stop` that cannot attribute
# the name it was given refuses (§1.2's ambiguous case) instead of signalling
# whichever entry the file happens to list first.

set -euo pipefail

PROG="runner.sh"
CONTRACT_VERSION=2

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# first_set <name>... — the value of the first set, non-empty variable.
# Indirect expansion, never eval, so a value carrying shell metacharacters is
# not re-parsed.
first_set() {
  local name
  for name in "$@"; do
    if [[ -n "${!name-}" ]]; then
      printf '%s' "${!name}"
      return 0
    fi
  done
  printf ''
}

# workspace_scope — the workspace this invocation speaks for, canonicalised, or
# empty when the caller named none. `launch` is handed it as TP_REPO_ROOT
# already; `list` and `stop` read it as configuration.
workspace_scope() {
  local r; r="$(first_set TP_REPO_ROOT TASKPUMP_REPO_ROOT REPO_ROOT)"
  [[ -n "$r" ]] || return 0
  # One spelling per workspace: a caller reaching the same directory through a
  # symlink must not read as a different project than the one that wrote the
  # entry. Both sides of every comparison below come through here.
  (CDPATH='' cd -- "$r" 2>/dev/null && pwd -P) || printf '%s' "$r"
}

registry_file() {
  local r; r="$(first_set TASKPUMP_LOCAL_REGISTRY TP_LOCAL_REGISTRY)"
  if [[ -z "$r" ]]; then
    local state; state="$(first_set TASKPUMP_STATE_DIR TP_STATE_DIR)"
    if [[ -n "$state" ]]; then
      r="$state/.taskpump-local-agents"
    else
      r="${XDG_STATE_HOME:-$HOME/.local/state}/taskpump/local-agents"
    fi
  fi
  printf '%s' "$r"
}

# ── Registry ──────────────────────────────────────────────────────────────────
# One line per agent: `<name> <pgid> <workspace-root>`. Rewritten through a temp
# file so a reader never sees a half-written registry, and serialised by a mkdir
# lock — mkdir is atomic on every filesystem worth running on, and needs no
# flock.

REG=""; LOCK=""; SCOPE=""

reg_init() {
  REG="$(registry_file)"
  LOCK="$REG.lock"
  SCOPE="$(workspace_scope)"
  mkdir -p "$(dirname "$REG")" 2>/dev/null || true
}

# in_scope <recorded-workspace> — is this entry part of the fleet this
# invocation is asking about? Its own workspace, yes. Anything unknown, also
# yes: an entry from before this field existed cannot be proven foreign, and an
# invocation that was told no workspace cannot prove anything about anyone. Both
# of those fall back to the pre-scope answer (everyone) on purpose — reporting
# somebody else's agent is a wrong answer, but failing to report our own is a
# DOUBLE LAUNCH, and the two are not the same size of mistake.
in_scope() {
  [[ -z "$SCOPE" || -z "$1" || "$1" == "$SCOPE" ]]
}

# reg_line <name> <pgid> [workspace] — one registry line. The workspace field is
# omitted rather than left blank when there is none, so an entry this runner
# only passed through comes back out byte-identical.
reg_line() {
  [[ -n "${3:-}" ]] || { printf '%s %s\n' "$1" "$2"; return 0; }
  printf '%s %s %s\n' "$1" "$2" "$3"
}

reg_lock() {
  local waited=0
  until mkdir "$LOCK" 2>/dev/null; do
    # A lock older than a minute is a crashed writer, not a slow one: every
    # critical section here is a handful of syscalls.
    if [[ -d "$LOCK" ]] && [[ -z "$(find "$LOCK" -maxdepth 0 -mmin -1 2>/dev/null)" ]]; then
      rm -rf "$LOCK" 2>/dev/null || true
      continue
    fi
    sleep 0.1
    waited=$((waited + 1))
    (( waited > 100 )) && die "registry lock at $LOCK is held; giving up"
  done
}
reg_unlock() { rm -rf "$LOCK" 2>/dev/null || true; }

# alive <pgid> — is any RUNNING process still in that group?
#
# Not `kill -0`, which is the obvious implementation and is wrong: signal 0
# succeeds on a ZOMBIE, and a finished agent stays a zombie until someone reaps
# it. Its parent here is this short-lived runner, which has already exited, so
# the agent is reparented to PID 1 — and when PID 1 is not a real init (any
# minimal container, which is exactly where an unattended drain runs) nothing
# ever reaps it. `kill -0` would then report a long-dead agent as live forever:
# stop could never finish, list would never prune, and the pump would refuse to
# relaunch the phase for the rest of the run.
#
# So ask for state, and treat Z as gone. `ps` is a fair dependency for a runner
# whose entire job is host processes; the signal probe stays as the fallback for
# a host without it.
alive() {
  local pgid="$1"
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 1
  if command -v ps >/dev/null 2>&1; then
    ps -eo pgid=,stat= 2>/dev/null \
      | awk -v g="$pgid" '$1 == g && $2 !~ /^Z/ { found = 1 } END { exit found ? 0 : 1 }'
    return
  fi
  kill -0 -- "-$pgid" 2>/dev/null
}

# reg_pgid <name> — the recorded group id of THIS workspace's agent of that
# name, or empty. Another project's agent of the same name is not an answer to
# this question.
reg_pgid() {
  [[ -f "$REG" ]] || return 0
  local n p root inherited=""
  while read -r n p root; do
    [[ "$n" == "$1" ]] || continue
    # An entry that names OUR workspace outranks one that names none, wherever
    # they sit in the file. Taking the first match instead lets a legacy line —
    # another project's, written before this field existed — answer for our
    # agent: stop would signal that project's process and leave ours running,
    # and launch would read its long-dead pgid and start a second agent on our
    # worktree. Order in a file nobody sorts is not evidence of ownership.
    [[ -n "$SCOPE" && "$root" == "$SCOPE" ]] && { printf '%s' "$p"; return 0; }
    in_scope "$root" || continue
    [[ -n "$inherited" ]] || inherited="$p"
  done < "$REG"
  printf '%s' "$inherited"
}

# reg_ambiguous <name> — the entries this invocation could mean, listed for a
# human, and printed ONLY when there is more than one and none of them is
# provably ours. §1.2 makes an ambiguous name a non-zero exit rather than a
# silent guess, and two workspaces holding one name is precisely the state the
# workspace field exists to survive: a teardown that picked by file order would
# stop one live agent, report success for the name, and leave the other running.
reg_ambiguous() {
  [[ -f "$REG" ]] || return 0
  local n p root count=0 list=""
  while read -r n p root; do
    [[ "$n" == "$1" ]] || continue
    [[ -n "$SCOPE" && "$root" == "$SCOPE" ]] && return 0
    in_scope "$root" || continue
    count=$((count + 1))
    [[ -z "$list" ]] || list="$list, "
    if [[ -n "$root" ]]; then
      list="${list}pgid $p in $root"
    else
      list="${list}pgid $p with no workspace recorded"
    fi
  done < "$REG"
  (( count > 1 )) && printf '%s' "$list"
  return 0
}

# reg_owner <name> — the workspace some OTHER project recorded an agent of this
# name against, or empty. Only meaningful once reg_pgid has come back empty, and
# it exists so a refusal can say whose agent it found instead of claiming there
# is none.
reg_owner() {
  [[ -f "$REG" ]] || return 0
  local n p root
  while read -r n p root; do
    [[ "$n" == "$1" && -n "$root" ]] || continue
    in_scope "$root" && continue
    printf '%s' "$root"
    return 0
  done < "$REG"
  return 0
}

# reg_write — replace the registry with stdin, atomically.
reg_write() {
  local tmp; tmp="$(mktemp "$REG.XXXXXX")"
  cat >| "$tmp"
  mv -f "$tmp" "$REG"
}

# reg_without <name> <pgid> — the registry on stdout, minus the ONE entry that
# is exactly that name at exactly that pgid. Every removal here goes by identity
# and never by name alone: two workspaces may hold one name, so a name-matching
# delete unregisters an agent that is still running, and an agent that runs
# unrecorded is one the supervisor launches a second time — the destructive half
# of issue #40, arrived at from the other side. A caller that has no pgid to name
# (nothing was recorded) removes nothing.
reg_without() {
  [[ -f "$REG" ]] || return 0
  local name="$1" pgid="${2:-}" n p root
  while read -r n p root; do
    [[ -z "$n" ]] && continue
    [[ "$n" == "$name" && -n "$pgid" && "$p" == "$pgid" ]] && continue
    reg_line "$n" "$p" "$root"
  done < "$REG"
}

# reg_drop <name> <pgid> — remove the entry stop just dealt with. Any other
# line, this workspace's or another project's, is copied through untouched,
# field for field.
reg_drop() {
  [[ -f "$REG" ]] || return 0
  reg_without "$1" "$2" | reg_write
}

# reg_put <name> <pgid> [stale-pgid] — record an entry against this workspace,
# retiring the stale one launch found and judged dead. Two projects may hold the
# same name at once; that is the collision this field exists to survive, not one
# to resolve.
reg_put() {
  { reg_without "$1" "${3:-}"; reg_line "$1" "$2" "$SCOPE"; } | reg_write
}

usage() {
  cat <<EOF
$PROG — local process runner (contract v$CONTRACT_VERSION)

  $PROG launch    start TASKPUMP_LOCAL_AGENT_CMD detached; prints the agent name
  $PROG stop      stop the agent named by TP_CONTAINER_NAME
  $PROG list      print every live agent name, one per line
  $PROG contract  print the contract version

This runner does NOT sandbox: the agent runs with your full host permissions.
All inputs are environment variables; see the header of this file.
EOF
}

do_launch() {
  local wt name cmd
  wt="$(first_set TP_WORKSPACE WORKSPACE_PATH)"
  name="$(first_set TP_CONTAINER_NAME ARACHNE_CONTAINER_NAME)"
  cmd="$(first_set TASKPUMP_LOCAL_AGENT_CMD TP_LOCAL_AGENT_CMD)"

  [[ -n "$wt" ]]   || die "TP_WORKSPACE (or WORKSPACE_PATH) is required"
  [[ -d "$wt" ]]   || die "TP_WORKSPACE is not a directory: $wt"
  [[ -n "$name" ]] || die "TP_CONTAINER_NAME is required"
  # No default agent, deliberately — the same reasoning as the container
  # runner's missing-image rule: a plausible-but-wrong guess fails far from here.
  [[ -n "$cmd" ]]  || die "TASKPUMP_LOCAL_AGENT_CMD is required (no default: there is no sane guess at your agent)"

  reg_init
  reg_lock
  # A live agent of this name means the supervisor lost track, not that it wants
  # two. Refusing is the same guarantee `docker run --name` gives for free, and
  # the pump's one safety property (never double-launch a live agent) leans on it.
  local existing; existing="$(reg_pgid "$name")"
  if [[ -n "$existing" ]] && alive "$existing"; then
    reg_unlock
    die "an agent named $name is already running (pgid $existing)"
  fi
  reg_unlock

  local log_name; log_name="$(first_set TASKPUMP_AGENT_LOG_NAME TP_AGENT_LOG_NAME)"
  : "${log_name:=.taskpump-agent.log}"
  local log="$wt/$log_name"

  local pgid_file; pgid_file="$(mktemp)"

  # The agent's own environment, in both spellings, so a command written against
  # either reads the same run.
  local branch task_id phase brief resume_note model max_turns repo_root
  branch="$(first_set TP_BRANCH ARACHNE_BRANCH)"
  task_id="$(first_set TP_TASK_ID ARACHNE_TASK_ID)"
  phase="$(first_set TP_PHASE ARACHNE_PHASE)"
  brief="$(first_set TP_BRIEF ARACHNE_BRIEF)"
  resume_note="$(first_set TP_RESUME_NOTE ARACHNE_RESUME_NOTE)"
  model="$(first_set TP_MODEL AGENT_MODEL)"
  max_turns="$(first_set TP_MAX_TURNS MAX_TURNS)"
  repo_root="$(first_set TP_REPO_ROOT REPO_ROOT)"

  # setsid gives the session its own process group, so stop can signal the whole
  # tree and the agent survives this shell. The wrapper records its own pid
  # BEFORE exec'ing the agent: after exec the pid is unchanged, so that pid is
  # the group id, and reading it from the child is exact where inferring it from
  # $! is not (setsid may or may not fork, depending on whether this shell's
  # background child is already a group leader).
  (
    cd "$wt" || exit 1
    export TASKPUMP_WORKSPACE_PATH="$wt"      WORKSPACE_PATH="$wt"
    export TASKPUMP_REPO_ROOT="$repo_root"    REPO_ROOT="$repo_root"
    export TASKPUMP_BRANCH="$branch"          ARACHNE_BRANCH="$branch"
    export TASKPUMP_TASK_ID="$task_id"        ARACHNE_TASK_ID="$task_id"
    export TASKPUMP_PHASE="$phase"            ARACHNE_PHASE="$phase"
    export TASKPUMP_BRIEF="$brief"            ARACHNE_BRIEF="$brief"
    export TASKPUMP_RESUME_NOTE="$resume_note" ARACHNE_RESUME_NOTE="$resume_note"
    export TASKPUMP_AGENT_MODEL="$model"      AGENT_MODEL="$model"
    export TASKPUMP_MAX_TURNS="$max_turns"    MAX_TURNS="$max_turns"
    export TASKPUMP_CONTAINER_NAME="$name"    ARACHNE_CONTAINER_NAME="$name"
    exec setsid bash -c 'printf "%s\n" "$$" >| "$1"; shift; exec bash -c "$1"' \
      _ "$pgid_file" "$cmd" >> "$log" 2>&1 < /dev/null
  ) &
  disown 2>/dev/null || true

  # Wait for the session leader to report its group id. Bounded: a command that
  # cannot even start should fail the launch rather than hang the supervisor.
  local waited=0 pgid=""
  while (( waited < 50 )); do
    pgid="$(tr -dc '0-9' < "$pgid_file" 2>/dev/null || true)"
    [[ -n "$pgid" ]] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  rm -f "$pgid_file"
  [[ -n "$pgid" ]] || die "the agent did not start within 5s (see $log)"

  reg_lock
  # `$existing` is the entry the duplicate check found and proved dead (empty
  # when there was none), and it is the only line this launch may retire.
  reg_put "$name" "$pgid" "$existing"
  reg_unlock

  # The handle is the NAME, not the pid: it is what the pump already knows the
  # agent by, what stop takes, and what list prints.
  printf '%s\n' "$name"
}

do_stop() {
  local name; name="$(first_set TP_CONTAINER_NAME ARACHNE_CONTAINER_NAME)"
  [[ -n "$name" ]] || die "TP_CONTAINER_NAME is required"

  reg_init

  # §1.2's third condition, and the only one this runner can now meet: the name
  # is AMBIGUOUS. Nothing but file order separates two entries this invocation
  # cannot attribute, so signalling one of them would kill an agent chosen at
  # random and report success for the name the other one still answers to.
  local clash; clash="$(reg_ambiguous "$name")"
  [[ -z "$clash" ]] \
    || die "the name $name is recorded against more than one agent ($clash); this invocation cannot tell which one it means, and signalling one by file order could kill another workspace's agent"

  local pgid; pgid="$(reg_pgid "$name")"

  # A name this workspace does not hold, but another one does. Signalling it
  # would tear down a live agent belonging to a different project — the
  # destructive half of the cross-repo name collision — and calling it "not
  # recorded" would be a wrong stated reason for a right refusal. So: neither.
  # This fleet has no agent by that name, which is exactly what §1.2's success
  # means, and the warning says whose it actually is.
  local owner=""
  [[ -n "$pgid" ]] || owner="$(reg_owner "$name")"
  if [[ -n "$owner" ]]; then
    warn "an agent named $name belongs to the workspace $owner, not $SCOPE; refusing to signal another workspace's agent"
    printf '%s\n' "$name"
    return 0
  fi

  # Both "already gone" shapes are success (docs/RUNNERS.md §1.2): never
  # recorded, and recorded but already exited. The entry goes either way — a
  # teardown that leaves a tombstone behind would have list pruning it later, and
  # stop is the one that knows it is gone now.
  if [[ -z "$pgid" ]]; then
    warn "no agent named $name is recorded"
    printf '%s\n' "$name"
    return 0
  fi
  if ! alive "$pgid"; then
    warn "agent $name (pgid $pgid) has already exited"
    reg_lock; reg_drop "$name" "$pgid"; reg_unlock
    printf '%s\n' "$name"
    return 0
  fi

  local grace; grace="$(first_set TASKPUMP_LOCAL_STOP_GRACE_S TP_LOCAL_STOP_GRACE_S)"
  : "${grace:=10}"

  # TERM the group, then KILL what is left. An agent mid-commit deserves the
  # chance to finish the write; an agent ignoring TERM does not get to outlive
  # its teardown.
  kill -TERM -- "-$pgid" 2>/dev/null || true
  local waited=0
  while alive "$pgid" && (( waited < grace * 10 )); do
    sleep 0.1
    waited=$((waited + 1))
  done
  if alive "$pgid"; then
    kill -KILL -- "-$pgid" 2>/dev/null || true
    sleep 0.2
  fi
  if alive "$pgid"; then
    # Not "already gone" and not stopped: reporting success here would make a
    # failed teardown indistinguishable from a real one.
    die "agent $name (pgid $pgid) survived TERM and KILL"
  fi

  reg_lock; reg_drop "$name" "$pgid"; reg_unlock
  printf '%s\n' "$name"
}

do_list() {
  reg_init
  [[ -e "$REG" ]] || return 0
  # A registry that exists and cannot be read is a failure to enumerate, not an
  # empty fleet: one line on stderr, non-zero exit, and the caller decides
  # whether to fall back (docs/RUNNERS.md §1.3).
  [[ -r "$REG" ]] || die "cannot read the agent registry at $REG"

  # Two different sets, and conflating them is the bug this split exists to
  # avoid: what survives PRUNING is every live agent on the host (a dead pgid is
  # dead for everyone, so anyone may reap the line), while what is REPORTED is
  # only this workspace's fleet.
  local live_names=() live_lines=() n p root
  while read -r n p root; do
    [[ -z "$n" ]] && continue
    alive "$p" || continue
    live_lines+=("$(reg_line "$n" "$p" "$root")")
    in_scope "$root" || continue
    live_names+=("$n")
  done < "$REG"

  # Prune while we are here: an agent that exits on its own leaves an entry no
  # one else will ever clean up, and a registry that only grows would eventually
  # make every list slower and every stop ambiguous.
  reg_lock
  if [[ ${#live_lines[@]} -eq 0 ]]; then
    : | reg_write
  else
    printf '%s\n' "${live_lines[@]}" | reg_write
  fi
  reg_unlock

  # Empty is exit 0 with no output — printing an empty array unguarded would
  # emit a blank line, which a line-counting caller reads as one live agent.
  [[ ${#live_names[@]} -gt 0 ]] && printf '%s\n' "${live_names[@]}"
  return 0
}

verb="${1:-}"
case "$verb" in
  launch)         shift; do_launch "$@" ;;
  stop)           shift; do_stop "$@" ;;
  list)           shift; do_list "$@" ;;
  contract)       printf '%s\n' "$CONTRACT_VERSION" ;;
  -h|--help|help) usage ;;
  '')             usage >&2; exit 2 ;;
  *)              printf '%s: unknown verb: %s\n' "$PROG" "$verb" >&2; usage >&2; exit 2 ;;
esac
