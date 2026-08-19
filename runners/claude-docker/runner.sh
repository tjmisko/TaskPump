#!/usr/bin/env bash
# runners/claude-docker/runner.sh — the claude-docker runner. RUNNER CONTRACT v2.
#
# A runner is the seam between the supervisor (libexec/tp-pump) and whatever
# actually executes an agent. The pump decides *what* should run — which phase,
# which worktree, which task is the lead, whether this is a resume — and then
# hands that decision to a runner, which knows *how* to start it. This runner
# starts a detached Docker container running the Claude Code CLI.
#
# Everything in here was lifted verbatim out of the pump's own launch block so
# that container behaviour is byte-identical for an existing consumer: same
# mounts, same capabilities, same memory caps, same environment. The pump keeps
# the parts that are its own business — worktree materialisation, brief
# rendering, resume notes, liveness — and calls this file for the last step.
#
# ── The contract ─────────────────────────────────────────────────────────────
#
#   runner.sh launch    Start the agent container detached. Prints the container
#                       id on stdout. Non-zero exit with a reason on stderr when
#                       the launch fails.
#   runner.sh stop      Stop the named container. Idempotent: stopping something
#                       that is not running succeeds.
#   runner.sh list      Print the name of every live agent this runner knows
#                       about, one per line. No agents is exit 0 and no output;
#                       being unable to look is a non-zero exit and one line on
#                       stderr. Asked about the fleet, not about one container,
#                       so it takes no per-launch input.
#
# Inputs arrive as environment variables, never as arguments, so the set can grow
# without breaking a caller. Each one is read as TP_<NAME> first and falls back
# to the legacy spelling a pre-TaskPump Arachne deployment already exports. Note
# that lib/config.sh promotes TASKPUMP_X to ARACHNE_X, so a key set in
# taskpump.conf reaches this script through the legacy column below.
#
#   TP_WORKSPACE        WORKSPACE_PATH      required — the agent's workspace
#                                           (a git worktree), mounted RW and used
#                                           as the container workdir
#   TP_REPO_ROOT        REPO_ROOT           required — the primary checkout,
#                                           mounted READ-ONLY
#   TP_CONTAINER_NAME   ARACHNE_CONTAINER_NAME  required — `docker run --name`
#   TP_IMAGE            ARACHNE_IMAGE       required — image to run
#   TP_ENTRYPOINT       ARACHNE_ENTRYPOINT  in-container entrypoint path
#                                           (default /entrypoint.sh — where the
#                                           image contract bakes this runner's
#                                           own entrypoint.sh; docs/RUNNERS.md)
#   TP_LEDGER_REPO      ARACHNE_PUMP_OPS_DIR  ledger checkout, mounted RW
#                                           (default $TP_REPO_ROOT/ops)
#   TP_BRANCH           ARACHNE_BRANCH      informational; forwarded to the agent
#   TP_TASK_ID          ARACHNE_TASK_ID     lead task the agent is assigned
#   TP_PHASE            ARACHNE_PHASE       phase the agent drains
#   TP_BRIEF            ARACHNE_BRIEF       rendered kickoff brief (host path)
#   TP_RESUME_NOTE      ARACHNE_RESUME_NOTE resume preamble, or empty
#   TP_MODEL            AGENT_MODEL         model alias (default opus)
#   TP_MAX_TURNS        MAX_TURNS           turn cap for the session (default 600)
#   TP_CLAUDE_DIR       CLAUDE_DIR          host agent home (default ~/.claude)
#   TP_CLAUDE_JSON      CLAUDE_JSON         host agent config (default ~/.claude.json)
#   TP_MEMORY_MAX       AGENT_MEMORY_MAX    --memory (default 3g)
#   TP_MEMORY_SWAP      AGENT_MEMORY_SWAP   --memory-swap (default 5g)
#   TP_CONTAINER_RUN_USER  —                optional `--user`; unset by default,
#                                           see "Why root" below
#   TP_ENV_PASSTHROUGH  —                   extra variable names to forward when
#                                           set (see DEFAULT_PASSTHROUGH)
#   GITHUB_TOKEN        —                   forwarded for ops fetch + gh
#   —                   TASKPUMP_DOCKER / DOCKER
#                                           container binary override (test seam),
#                                           resolved once for every verb — launch,
#                                           stop, list — from apl_docker's two
#                                           keys and no others. The pump also
#                                           passes TP_DOCKER at launch, and this
#                                           runner ignores it on purpose: see the
#                                           resolution below.
#
# `list` reads no per-launch input. Its inputs are configuration the whole fleet
# shares rather than properties of any one launch — the name prefix, and the same
# container runtime `launch` and `stop` use:
#
#   TP_AGENT_PREFIX     TASKPUMP_AGENT_PREFIX / ARACHNE_AGENT_PREFIX
#                                           container-name prefix to enumerate
#                                           (default tp-agent-, via
#                                           lib/pump-lib.sh's one accessor)
#   —                   TASKPUMP_DOCKER / DOCKER
#                                           the runtime, the same value the other
#                                           two verbs resolved (see below)
#
# ── Liveness, and why `list` is shaped the way it is ─────────────────────────
#
# v1 had no liveness verb: "is this phase still running?" lived in
# lib/pump-lib.sh, which asked `docker ps` directly. The objection to moving it
# was never that a runner should not answer it — it was the *shape*. Liveness is
# a FLEET question, asked once per tick about every phase at once, while launch
# and stop are asked about one container at a time. A per-container liveness verb
# would mean N subprocesses per tick to answer what one `docker ps` answers, and
# the pump's most important safety property (never double-launch a live
# container) would rest on a fan-out loop rather than a single atomic snapshot.
#
# So `list` is a fleet verb: one call, one snapshot, every live agent. It takes
# no per-launch input, reads the same configuration `stop` reads, and shares the
# pump's own enumeration (lib/pump-lib.sh) rather than duplicating the filter, so
# the names it prints are by construction the names `launch` created and the pump
# would have scraped.
#
# It refuses to guess. An unreachable runtime is a non-zero exit, never an empty
# list — the caller decides whether to fall back, because "nothing is running"
# and "I could not look" demand opposite actions. The pump does not call this
# yet (that is a separate change); the verb lands first so it is verifiable on
# its own.
#
# ── Why root, and why no --user ──────────────────────────────────────────────
#
# The launch deliberately does not pass `--user`. The container starts as root
# because the entrypoint installs an iptables egress allowlist (hence
# --cap-add NET_ADMIN) and writes into the agent user's home; it drops to the
# unprivileged container user with `su` for the session itself. Setting
# TP_CONTAINER_RUN_USER emits a `--user` flag for a consumer whose image needs
# one, but doing so will break any pre-flight that configures the firewall.

set -euo pipefail

PROG="runner.sh"
CONTRACT_VERSION=2

# Where the shared enumeration lives. Resolved from this file's own location so
# the runner works from a checkout, an install prefix, or a symlink; TP_LIB_DIR
# (exported by lib/config.sh) wins when the caller already resolved it.
RUNNER_DIR="$(CDPATH='' cd -- "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PUMP_LIB="${TP_LIB_DIR:-$RUNNER_DIR/../../lib}/pump-lib.sh"

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# The container runtime, resolved ONCE for every verb, in the SAME order and
# from the SAME keys lib/pump-lib.sh's apl_docker uses. `launch` and `stop` read
# only the bare `DOCKER` seam before, while `list` reached the runtime through
# apl_docker — so a host configured with TASKPUMP_DOCKER alone had one runner
# answering about podman's fleet and starting containers on docker's.
#
# TP_DOCKER is deliberately NOT a rung here, even though it is the launch
# environment's own spelling for this input (docs/RUNNERS.md §1.1). The pump
# passes it at launch (`TP_DOCKER="$DOCKER" DOCKER="$DOCKER"`), but the call that
# asks this runner for the fleet — apl__runner_list — passes TASKPUMP_DOCKER and
# DOCKER only. A rung this runner reads and that caller does not set is a rung an
# AMBIENT TP_DOCKER wins on: the supervisor would launch on the binary it
# resolved and enumerate on the one it never chose, which is the invisible-agent
# split that makes the pump start a second agent on a branch that already has
# one. Resolve exactly what the caller passes, and the two cannot disagree.
DOCKER="${TASKPUMP_DOCKER:-${DOCKER:-docker}}"

# Variables forwarded into the container when — and only when — they are set in
# the runner's own environment. Keeping this list opt-in keeps the launch line
# deterministic: an unset key produces no flag at all.
#
# Both spellings of each key are listed. The entrypoint resolves TASKPUMP_X then
# TP_X, so forwarding only one of them would make the other silently inert in the
# caller's hands — which is exactly what happened: the pump exported TP_TASKS_DIR,
# TP_AGENT_LOG_NAME and TP_GOAL_NOTE_NAME, and nothing carried them across.
DEFAULT_PASSTHROUGH="\
TASKPUMP_PRE_FLIGHT TP_PRE_FLIGHT \
TASKPUMP_WORKSPACE_TASK_CLI TP_WORKSPACE_TASK_CLI \
TASKPUMP_CONTAINER_USER TP_CONTAINER_USER \
TASKPUMP_CONTAINER_HOME TP_CONTAINER_HOME \
TASKPUMP_SAFETY_TURNS TP_SAFETY_TURNS \
TASKPUMP_TASKS_DIR TP_TASKS_DIR \
TASKPUMP_TASK_OUT TP_TASK_OUT \
TASKPUMP_TASK_EXT TASKPUMP_TASK_FILE_EXT TP_TASK_FILE_EXT \
TASKPUMP_AGENT_LOG_NAME TP_AGENT_LOG_NAME \
TASKPUMP_GOAL_NOTE_NAME TP_GOAL_NOTE_NAME \
TASKPUMP_RESUME_NOTE_NAME TP_RESUME_NOTE_NAME \
TASKPUMP_RO_PROBE_FILE TP_RO_PROBE_FILE \
TASKPUMP_HOST_CRED_MOUNT TP_HOST_CRED_MOUNT \
TASKPUMP_HOST_CONFIG_MOUNT TP_HOST_CONFIG_MOUNT \
TASKPUMP_CRED_REFRESH_INTERVAL_S TP_CRED_REFRESH_INTERVAL_S \
TASKPUMP_AGENT_WALL_TIMEOUT_S TP_AGENT_WALL_TIMEOUT_S \
CRED_REFRESH_INTERVAL_S \
AGENT_WALL_TIMEOUT_S"

# first_set <name>... — print the value of the first variable that is set and
# non-empty. Indirect expansion, never eval, so a value containing shell
# metacharacters is not re-parsed.
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

usage() {
  cat <<EOF
$PROG — claude-docker runner (contract v$CONTRACT_VERSION)

  $PROG launch    start the agent container detached; prints its id
  $PROG stop      stop the container named by TP_CONTAINER_NAME
  $PROG list      print every live agent name, one per line
  $PROG contract  print the contract version

All inputs are environment variables; see the header of this file for the table.
EOF
}

do_launch() {
  # Locals are deliberately lower-case. A `local REPO_ROOT` would blank the
  # inherited REPO_ROOT before first_set ever got to read it — the legacy
  # fallback would then silently never fire.
  local wt repo_root ledger_repo cname image entrypoint
  wt="$(first_set TP_WORKSPACE WORKSPACE_PATH)"
  repo_root="$(first_set TP_REPO_ROOT REPO_ROOT)"
  cname="$(first_set TP_CONTAINER_NAME ARACHNE_CONTAINER_NAME)"
  image="$(first_set TP_IMAGE ARACHNE_IMAGE)"
  entrypoint="$(first_set TP_ENTRYPOINT ARACHNE_ENTRYPOINT)"
  : "${entrypoint:=/entrypoint.sh}"

  [[ -n "$wt" ]]        || die "TP_WORKSPACE (or WORKSPACE_PATH) is required"
  [[ -n "$repo_root" ]] || die "TP_REPO_ROOT (or REPO_ROOT) is required"
  [[ -n "$cname" ]]     || die "TP_CONTAINER_NAME is required"
  # No default image on purpose. A wrong-but-plausible default would launch the
  # wrong agent silently; a missing name should be loud.
  [[ -n "$image" ]]     || die "TP_IMAGE is required (no default: an implicit image is a silent wrong launch)"

  ledger_repo="$(first_set TP_LEDGER_REPO ARACHNE_PUMP_OPS_DIR)"
  : "${ledger_repo:=$repo_root/ops}"

  local branch task_id phase brief resume_note model max_turns
  branch="$(first_set TP_BRANCH ARACHNE_BRANCH)"
  task_id="$(first_set TP_TASK_ID ARACHNE_TASK_ID)"
  phase="$(first_set TP_PHASE ARACHNE_PHASE)"
  brief="$(first_set TP_BRIEF ARACHNE_BRIEF)"
  resume_note="$(first_set TP_RESUME_NOTE ARACHNE_RESUME_NOTE)"
  model="$(first_set TP_MODEL AGENT_MODEL)";       : "${model:=opus}"
  max_turns="$(first_set TP_MAX_TURNS MAX_TURNS)"; : "${max_turns:=600}"

  local claude_dir claude_json mem_max mem_swap
  claude_dir="$(first_set TP_CLAUDE_DIR CLAUDE_DIR)";    : "${claude_dir:=$HOME/.claude}"
  claude_json="$(first_set TP_CLAUDE_JSON CLAUDE_JSON)"; : "${claude_json:=$HOME/.claude.json}"
  mem_max="$(first_set TP_MEMORY_MAX AGENT_MEMORY_MAX)"; : "${mem_max:=3g}"
  mem_swap="$(first_set TP_MEMORY_SWAP AGENT_MEMORY_SWAP)"; : "${mem_swap:=5g}"

  # Optional --user. Absent by default; see "Why root" in the header.
  local run_user_args=()
  local run_user; run_user="$(first_set TP_CONTAINER_RUN_USER)"
  [[ -n "$run_user" ]] && run_user_args=(--user "$run_user")

  # Opt-in extra environment, appended in list order so the launch line is
  # stable. Bare -e on purpose: docker reads each value from its own
  # environment, so values (which may be secrets) never enter argv (#14).
  local passthrough_args=() name
  for name in ${TP_ENV_PASSTHROUGH-$DEFAULT_PASSTHROUGH}; do
    [[ -n "${!name-}" ]] && passthrough_args+=(-e "$name")
  done

  # The TaskPump installation itself rides along READ-ONLY at /opt/taskpump, so
  # the entrypoint can put `tp` on the agent's PATH and a workspace no longer
  # needs to vendor a task CLI (G4.3). The source directory is resolved from
  # this file's own realpath — the same way bin/tp finds its libexec — so a
  # checkout, an install prefix, or a symlinked runner each mount their own
  # installation. Validated before the launch: a runner copied away from its
  # tree would otherwise mount a tp-less directory, and that failure would
  # surface much later, inside the container, as a missing task CLI.
  local tp_install_root
  tp_install_root="$(CDPATH='' cd -- "$RUNNER_DIR/../.." && pwd)"
  [[ -x "$tp_install_root/bin/tp" ]] \
    || die "no tp at $tp_install_root/bin/tp — this runner mounts its own TaskPump installation at /opt/taskpump, so it must live at <taskpump>/runners/claude-docker (a relocated copy needs the full installation beside it)"

  # The mount set. Host and container paths are identical on purpose: a git
  # worktree's .git file stores an absolute gitdir path, so matching paths let
  # git resolve without a repair inside the container.
  #
  # When the ledger IS the primary checkout (TaskPump's own dogfood: ledger
  # tasks/ in the code repo, TP_LEDGER_REPO == TP_REPO_ROOT), the read-only
  # primary mount and the read-write ledger mount name the same destination,
  # and docker rejects duplicate mount points outright. The shape collapses to
  # a single RW mount of the checkout — the read-only-primary hardening
  # deliberately does not hold there (the entrypoint's mount self-check warns,
  # by design), and the .git overlay is subsumed by it.
  local mount_args=(
    -v "$claude_dir":/tmp/claude-home:ro
    -v "$claude_json":/tmp/claude-home-json/.claude.json:ro
    -v "$tp_install_root":/opt/taskpump:ro
  )
  if [[ "$ledger_repo" == "$repo_root" ]]; then
    # Spelled as the LEDGER mount on purpose: in this shape the RW mount is the
    # ledger's, it merely coincides with the root — and the static no-blanket-
    # primary-mount guard in tests/test-tp-pump.sh keeps meaning "no source
    # line mounts \$repo_root without :ro".
    mount_args+=(-v "$ledger_repo":"$ledger_repo" -v "$wt":"$wt")
  else
    mount_args+=(
      -v "$repo_root":"$repo_root":ro
      -v "$repo_root/.git":"$repo_root/.git"
      -v "$wt":"$wt"
      -v "$ledger_repo":"$ledger_repo"
    )
  fi

  # A stale container of the same name blocks `--name`. Removing it is the same
  # idempotency the pump had inline; failure here is never fatal because the
  # usual cause is that there is nothing to remove.
  "$DOCKER" rm -f "$cname" >/dev/null 2>&1 || true

  # --init puts tini at PID 1 to adopt and reap orphaned session subprocesses.
  # Necessary but not sufficient on its own: an intermediary that subreaps
  # below PID 1 (su did — issue #15) starves tini, so the entrypoint pairs
  # this with a setpriv privilege drop that execs and leaves no intermediary.
  local cid rc=0
  cid=$("$DOCKER" run --rm -d \
    --init \
    --name "$cname" \
    --cap-add NET_ADMIN \
    --memory "$mem_max" \
    --memory-swap "$mem_swap" \
    ${run_user_args[@]+"${run_user_args[@]}"} \
    -e GITHUB_TOKEN \
    -e WORKSPACE_PATH="$wt" \
    -e REPO_ROOT="$repo_root" \
    -e ARACHNE_BRIEF="$brief" \
    -e ARACHNE_RESUME_NOTE="$resume_note" \
    -e ARACHNE_TASK_ID="$task_id" \
    -e ARACHNE_PHASE="$phase" \
    -e MAX_TURNS="$max_turns" \
    -e AGENT_MODEL="$model" \
    -e TASKPUMP_WORKSPACE_PATH="$wt" \
    -e TASKPUMP_REPO_ROOT="$repo_root" \
    -e TASKPUMP_LEDGER_REPO="$ledger_repo" \
    -e TASKPUMP_BRIEF="$brief" \
    -e TASKPUMP_RESUME_NOTE="$resume_note" \
    -e TASKPUMP_TASK_ID="$task_id" \
    -e TASKPUMP_PHASE="$phase" \
    -e TASKPUMP_BRANCH="$branch" \
    -e TASKPUMP_MAX_TURNS="$max_turns" \
    -e TASKPUMP_AGENT_MODEL="$model" \
    ${passthrough_args[@]+"${passthrough_args[@]}"} \
    "${mount_args[@]}" \
    -w "$wt" \
    "$image" "$entrypoint") || rc=$?

  if [[ $rc -ne 0 ]]; then
    die "docker run failed (rc=$rc) for container $cname from image $image"
  fi
  [[ -n "$cid" ]] || die "docker run produced no container id for $cname"

  printf '%s\n' "$cid"
}

do_stop() {
  local cname; cname="$(first_set TP_CONTAINER_NAME ARACHNE_CONTAINER_NAME)"
  [[ -n "$cname" ]] || die "TP_CONTAINER_NAME is required"

  local out rc=0
  out=$("$DOCKER" stop "$cname" 2>&1) || rc=$?
  if [[ $rc -eq 0 ]]; then
    printf '%s\n' "$cname"
    return 0
  fi
  # Stop is idempotent by contract: a supervisor tearing down should not have to
  # race `docker ps` to find out whether it still has something to stop.
  if grep -qiE 'no such container|is not running' <<<"$out"; then
    warn "container $cname is not running"
    return 0
  fi
  printf '%s\n' "$out" >&2
  die "docker stop failed (rc=$rc) for container $cname"
}

do_list() {
  # The enumeration itself is the pump's, sourced rather than re-spelled: the
  # names `list` prints and the names the pump scrapes have to be the same set,
  # and two copies of one `docker ps --filter` is exactly how they would stop
  # being. A runner relocated away from its lib says so instead of quietly
  # answering from a second implementation.
  [[ -f "$PUMP_LIB" ]] || die "cannot list agents: no pump-lib.sh at $PUMP_LIB (set TP_LIB_DIR)"
  # shellcheck source=../../lib/pump-lib.sh
  . "$PUMP_LIB"

  # The prefix is configuration, not per-launch input, so `list` accepts the
  # runner's own TP_ spelling and both shared ones. Empty means unset here:
  # apl_agent_prefix supplies the default.
  local prefix; prefix="$(first_set TP_AGENT_PREFIX TASKPUMP_AGENT_PREFIX ARACHNE_AGENT_PREFIX)"

  local errs; errs="$(mktemp)"
  local names rc=0
  # The resolved binary is handed over rather than left to a second lookup. It
  # is the same value apl_docker would derive — the resolution above reads its
  # two keys in its order, and that is the point: this line pins the equality
  # instead of assuming it, so a future rung added on either side shows up here
  # rather than as one runner launching on docker and enumerating on podman.
  names="$(TASKPUMP_AGENT_PREFIX="$prefix" TASKPUMP_DOCKER="$DOCKER" \
           apl_live_agent_names_strict 2>"$errs")" || rc=$?

  if [[ $rc -ne 0 ]]; then
    # One line, per the contract: the runtime's first line of complaint is the
    # useful part, and a caller deciding whether to fall back should not have to
    # parse a paragraph. The rest is dropped on purpose.
    local why; why="$(head -n 1 "$errs" 2>/dev/null || true)"
    rm -f "$errs"
    die "cannot list agents (rc=$rc): ${why:-the container runtime did not answer}"
  fi
  rm -f "$errs"

  # An empty fleet is a successful answer, not an absence of one — printf on an
  # empty string would emit a spurious blank line, which a line-counting caller
  # would read as one live agent.
  [[ -n "$names" ]] && printf '%s\n' "$names"
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
