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
#   TP_REPO_ROOT      REPO_ROOT           the primary checkout
#
# Configuration `stop` and `list` read — no per-launch input, because the pump
# asks `list` once per tick with no task in hand (docs/RUNNERS.md §1.3):
#
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
# One line per agent: `<name> <pgid>`. Rewritten through a temp file so a reader
# never sees a half-written registry, and serialised by a mkdir lock — mkdir is
# atomic on every filesystem worth running on, and needs no flock.

REG=""; LOCK=""

reg_init() {
  REG="$(registry_file)"
  LOCK="$REG.lock"
  mkdir -p "$(dirname "$REG")" 2>/dev/null || true
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

# reg_pgid <name> — the recorded group id, or empty.
reg_pgid() {
  [[ -f "$REG" ]] || return 0
  local n p
  while read -r n p _rest; do
    [[ "$n" == "$1" ]] && { printf '%s' "$p"; return 0; }
  done < "$REG"
  return 0
}

# reg_write — replace the registry with stdin, atomically.
reg_write() {
  local tmp; tmp="$(mktemp "$REG.XXXXXX")"
  cat >| "$tmp"
  mv -f "$tmp" "$REG"
}

# reg_drop <name> — remove one entry.
reg_drop() {
  [[ -f "$REG" ]] || return 0
  local name="$1" n p
  { while read -r n p _rest; do
      [[ -z "$n" || "$n" == "$name" ]] && continue
      printf '%s %s\n' "$n" "$p"
    done < "$REG"
  } | reg_write
}

# reg_put <name> <pgid> — record an entry, replacing any stale one of that name.
reg_put() {
  local name="$1" pgid="$2" n p
  { if [[ -f "$REG" ]]; then
      while read -r n p _rest; do
        [[ -z "$n" || "$n" == "$name" ]] && continue
        printf '%s %s\n' "$n" "$p"
      done < "$REG"
    fi
    printf '%s %s\n' "$name" "$pgid"
  } | reg_write
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
  reg_put "$name" "$pgid"
  reg_unlock

  # The handle is the NAME, not the pid: it is what the pump already knows the
  # agent by, what stop takes, and what list prints.
  printf '%s\n' "$name"
}

do_stop() {
  local name; name="$(first_set TP_CONTAINER_NAME ARACHNE_CONTAINER_NAME)"
  [[ -n "$name" ]] || die "TP_CONTAINER_NAME is required"

  reg_init
  local pgid; pgid="$(reg_pgid "$name")"

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
    reg_lock; reg_drop "$name"; reg_unlock
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

  reg_lock; reg_drop "$name"; reg_unlock
  printf '%s\n' "$name"
}

do_list() {
  reg_init
  [[ -e "$REG" ]] || return 0
  # A registry that exists and cannot be read is a failure to enumerate, not an
  # empty fleet: one line on stderr, non-zero exit, and the caller decides
  # whether to fall back (docs/RUNNERS.md §1.3).
  [[ -r "$REG" ]] || die "cannot read the agent registry at $REG"

  local live_names=() live_lines=() n p
  while read -r n p _rest; do
    [[ -z "$n" ]] && continue
    if alive "$p"; then
      live_names+=("$n")
      live_lines+=("$n $p")
    fi
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
