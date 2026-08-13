#!/usr/bin/env bash
# pump-lib.sh — shared helpers for the supervisor, its gates, its hooks, and the
# rescue tools.
#
# These read the sourcing script's globals (HEALTH_GATE, HEALTH_WINDOW, JOBS,
# CAP_FILE) at call time, so each tool keeps owning its own configuration; the
# helpers only centralize the logic — which is the point, since every one of
# them existed in two to five diverging copies before it landed here.
#
# This file is sourced, never executed — no `set -e`, no top-level side effects.
#
# It reads the canonical TASKPUMP_* names with the legacy ARACHNE_* ones as a
# fallback, rather than relying on lib/config.sh to promote between them: the
# test harnesses source this file on its own, without the config core.

# apl_render_template <template-file>
# Substitute {{KEY}} placeholders, reading two associative arrays from the
# caller's scope: TPL_VARS maps a key to a scalar, TPL_BLOCKS maps a key to a
# file whose contents replace a line that consists of nothing but that
# placeholder. The block form is why this is bash rather than sed — the values
# it splices are multi-line command output (a git log, a status listing), and
# every sed-based approach to that either mangles newlines or has to escape the
# replacement text. Bash parameter substitution needs no escaping at all.
#
# Conditional sections: the lines between {{#KEY}} and {{/KEY}} (each marker
# alone on its line) render only when KEY resolves to content — a non-empty
# TPL_VARS value or a non-empty TPL_BLOCKS file. The marker lines themselves
# are never emitted. Sections exist for the optional-value case: a template
# sentence built around a value that rendered empty is worse than no sentence
# at all (see the shipped templates' {{VERIFY_CMDS}} sections).

# apl__tpl_has <key> — does <key> resolve to content in the caller's TPL maps?
apl__tpl_has() {
  local key="$1"
  if [[ -n "${TPL_BLOCKS[$key]:-}" ]]; then
    [[ -s "${TPL_BLOCKS[$key]}" ]]
    return
  fi
  [[ -n "${TPL_VARS[$key]:-}" ]]
}

apl_render_template() {
  local tpl="$1" line key trimmed
  local depth=0 skip_at=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [[ "$trimmed" == '{{#'*'}}' ]]; then
      key="${trimmed:3:${#trimmed}-5}"
      depth=$((depth + 1))
      if (( skip_at == 0 )) && ! apl__tpl_has "$key"; then
        skip_at=$depth
      fi
      continue
    fi
    if [[ "$trimmed" == '{{/'*'}}' ]]; then
      (( skip_at == depth )) && skip_at=0
      (( depth > 0 )) && depth=$((depth - 1))
      continue
    fi
    (( skip_at > 0 )) && continue
    if [[ "$trimmed" == '{{'*'}}' ]]; then
      key="${trimmed:2:${#trimmed}-4}"
      if [[ -n "${TPL_BLOCKS[$key]:-}" ]]; then
        cat "${TPL_BLOCKS[$key]}" 2>/dev/null || true
        continue
      fi
    fi
    for key in "${!TPL_VARS[@]}"; do
      line="${line//\{\{$key\}\}/${TPL_VARS[$key]}}"
    done
    printf '%s\n' "$line"
  done < "$tpl"
}

# apl_join_commands <newline-separated-commands>
# Render a list of shell commands as an inline English phrase, each backticked:
# "`a`", "`a` and `b`", "`a`, `b` and `c`". Used where a template mentions the
# project's verification commands mid-sentence.
apl_join_commands() {
  local -a cmds=()
  local c
  while IFS= read -r c; do [[ -n "$c" ]] && cmds+=("\`$c\`"); done <<<"$1"
  local n=${#cmds[@]}
  case "$n" in
    0) return 0 ;;
    1) printf '%s' "${cmds[0]}" ;;
    *)
      local i
      for (( i = 0; i < n - 1; i++ )); do
        printf '%s' "${cmds[$i]}"
        (( i < n - 2 )) && printf ', '
      done
      printf ' and %s' "${cmds[$((n - 1))]}"
      ;;
  esac
}

# apl_help <script> — print a script's leading header comment as its help text.
# Bounded by an explicit `# HELP-END` marker rather than a hardcoded line range:
# three tools used to extract their help with `sed -n '2,40p' "$0"`, which
# silently truncated (or over-ran) the moment anyone edited the header, and
# nothing tested it. Falls back to the end of the comment block when no marker
# is present.
apl_help() {
  awk 'NR == 1 { next }
       /^# HELP-END/ { exit }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "$1"
}

# brcmfmac wedge signatures — the Apple-Silicon WiFi firmware hang that the
# rotating-pool cap exists to avoid (see CLAUDE.md "Parallel runs").
APL_WEDGE_SIGNATURES="${TASKPUMP_HEALTH_SIGNATURES:-Failed to alloc SKB|Firmware reported general error|Timeout on response for query command}"

# apl_network_unhealthy — 0 (true) when the health probe's output shows a wedge
# signature within the last HEALTH_WINDOW seconds. Graceful: 1 (healthy) when the
# gate is off (HEALTH_GATE != 1), the probe command is absent, or nothing
# matches. The probe is configurable (TASKPUMP_HEALTH_PROBE_CMD) because a
# systemd kernel journal is a Linux-and-systemd assumption, not a universal one.
apl_network_unhealthy() {
  [[ "${HEALTH_GATE:-1}" -eq 1 ]] || return 1
  local probe="${TASKPUMP_HEALTH_PROBE_CMD:-}"
  if [[ -z "$probe" ]]; then
    command -v journalctl >/dev/null 2>&1 || return 1
    probe="journalctl -k -b 0 --since '${HEALTH_WINDOW:-120} sec ago'"
  fi
  if eval "$probe" 2>/dev/null | grep -qiE "$APL_WEDGE_SIGNATURES"; then
    return 0
  fi
  return 1
}

# The pool cap a caller that set no JOBS of its own falls back to. Three
# different defaults for one number used to be spread across the pump (4), this
# lib (6) and the disk watchdog (6), so which cap applied depended on whether
# the cap file happened to exist. The pump still passes its own JOBS (4) down;
# this is only for callers that don't — which is exactly what the 6 always
# meant. One constant, two documented consumers.
: "${TASKPUMP_JOBS_FALLBACK:=6}"

# apl_read_cap — the live concurrency cap: CAP_FILE's contents if it holds a
# positive integer (live-retunable mid-run), else the caller's JOBS, else
# TASKPUMP_JOBS_FALLBACK. Lets an operator `echo 3 > .taskpump-pool-cap` without
# restarting the supervisor.
apl_read_cap() {
  local c="${JOBS:-$TASKPUMP_JOBS_FALLBACK}"
  if [[ -n "${CAP_FILE:-}" && -f "$CAP_FILE" ]]; then
    local v; v="$(tr -dc '0-9' < "$CAP_FILE" 2>/dev/null || true)"
    [[ -n "$v" && "$v" -ge 1 ]] && c="$v"
  fi
  echo "$c"
}

# apl_repair_worktree_gitignore — undo the gh-worktree `.worktrees/` ignore
# regression (2026-04-14 incident) so worktrees aren't silently gitignored.
apl_repair_worktree_gitignore() {
  local repo_root="$1"
  local line="${TASKPUMP_WORKTREES_IGNORE_LINE:-.worktrees/}"
  # Anchor the whole line and escape it for both grep and sed, so a base
  # containing dots or slashes matches itself and nothing else.
  local esc; esc="$(printf '%s' "$line" | sed 's/[][\.*^$\/]/\\&/g')"
  if grep -qE "^$esc\$" "$repo_root/.gitignore" 2>/dev/null; then
    sed -i "/^$esc\$/d" "$repo_root/.gitignore"
  fi
}

# apl_ensure_worktrees_visible <repo_root> <path> — make sure <path> (a
# worktree, or a probe under the worktrees dir) is not gitignored by ANY
# source. Two mechanisms, matched to the two kinds of source:
#   * the repo's own .gitignore — the bare re-ignore line the gh-worktree
#     extension appends is deleted (apl_repair_worktree_gitignore, above);
#   * every source BELOW .gitignore in precedence — typically an
#     operator-global core.excludesFile ignoring **/.worktrees/** in every
#     repo (observed 2026-08-13: the dogfood canary launched nothing) — is
#     overridden by negations appended once to the repo's own
#     $GIT_COMMON_DIR/info/exclude, which outranks the global file, is
#     untracked (no dirty tree, no fs-guard noise), and leaves the operator's
#     global config alone.
# Returns 1 when the path is STILL ignored afterwards; the caller owns the
# refusal and its message.
apl_ensure_worktrees_visible() {
  local repo_root="$1" probe="$2"
  apl_repair_worktree_gitignore "$repo_root"
  git -C "$repo_root" check-ignore -q "$probe" 2>/dev/null || return 0
  local line="${TASKPUMP_WORKTREES_IGNORE_LINE:-.worktrees/}"
  local base="${line%/}"
  local common
  common="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ "$common" == /* ]] || common="$repo_root/$common"
  local excl="$common/info/exclude"
  if ! grep -qxF -- "!$base/**" "$excl" 2>/dev/null; then
    mkdir -p "${excl%/*}"
    {
      printf '# TaskPump: worktrees must be visible to git (launch guard);\n'
      printf '# these negations outrank an operator-global excludes file.\n'
      printf '!%s/\n' "$base"
      printf '!%s/**\n' "$base"
    } >> "$excl"
  fi
  ! git -C "$repo_root" check-ignore -q "$probe" 2>/dev/null
}

# ── Agent-container identity ──────────────────────────────────────────────────
# The container-name prefix is this stack's join key: the pump derives a name
# from a branch, both watchdogs count by it, cleanup maps a name back to a
# worktree, and tooling outside this repo greps for it. So it is one knob, read
# through one accessor, and its default must not drift.
apl_agent_prefix() { printf '%s' "${TASKPUMP_AGENT_PREFIX:-tp-agent-}"; }

# apl_docker — the container-runtime binary. TASKPUMP_DOCKER is the canonical
# spelling; DOCKER is the legacy one every existing harness sets.
apl_docker() { printf '%s' "${TASKPUMP_DOCKER:-${DOCKER:-docker}}"; }

# apl_branch_slug_reject_reason <branch> — empty output and exit 0 when the
# branch can carry an agent name; one line saying what is wrong and exit 1 when
# it cannot.
#
# The slug is the branch with `/` → `-` (docs/RUNNERS.md §2), and that map is
# the join key of the whole stack: the pump derives a name from a branch, both
# watchdogs count by it, cleanup maps a name back to a worktree. The encoding is
# frozen — container names already exist on operators' hosts — so a branch the
# encoding cannot carry has to be refused at the door instead.
#
# Refused, and why each one is not pedantry:
#
#   more than one `/`   `feat/a/b` and `feat/a-b` produce the same slug, so the
#                       reverse mapping cannot tell them apart. This is the case
#                       the docs called "does not round-trip cleanly" and then
#                       let through anyway: the branch launches, and the FAILURE
#                       shows up much later somewhere else — an agent whose
#                       container is invisible to liveness, so the pump launches
#                       a second one on the same branch.
#   leading `/`         yields a name starting with `-`, which is not a legal
#                       container name (and reads as a flag to half the CLIs
#                       that will be handed it).
#   trailing `/`        yields a name ending in `-` and a slug that collides
#                       with the branch without it.
#   whitespace          a name that cannot survive being written to a
#                       whitespace-delimited registry (runners/local) or read
#                       back out of `docker ps --format`.
#
# One rule, one place: tp-task refuses the claim, the pump refuses the run at
# startup, and neither gets to have its own opinion about what is legal.
apl_branch_slug_reject_reason() {
  local branch="$1"
  if [[ -z "$branch" ]]; then
    printf 'the branch name is empty\n'; return 1
  fi
  if [[ "$branch" =~ [[:space:]] ]]; then
    printf 'branch %s contains whitespace, which an agent name cannot carry\n' "$branch"; return 1
  fi
  if [[ "$branch" == /* ]]; then
    printf 'branch %s starts with "/", which would make the agent name start with "-"\n' "$branch"; return 1
  fi
  if [[ "$branch" == */ ]]; then
    printf 'branch %s ends with "/", which would make the agent name end with "-"\n' "$branch"; return 1
  fi
  local slashes="${branch//[^\/]/}"
  if (( ${#slashes} > 1 )); then
    printf 'branch %s has %d "/" separators; the agent name maps "/" to "-", so %s cannot be mapped back to one branch\n' \
      "$branch" "${#slashes}" "${branch//\//-}"
    return 1
  fi
  return 0
}

# apl__runtime_ps_names <prefix> — the ONE `docker ps` filter expression in the
# stack. Prints the runtime's answer verbatim, and leaves its exit status and its
# stderr alone: the two callers below differ only in what they do with those.
# `--filter name=` matches as a substring, so every caller still anchors the
# prefix itself.
apl__runtime_ps_names() {
  "$(apl_docker)" ps --filter "name=$1" --format '{{.Names}}'
}

# apl_live_agent_names — the full name of every live agent container, one per
# line. This is THE enumeration: five near-copies of it used to live in the
# pump's lib, cleanup, and both watchdogs, and three of them called `docker`
# literally — so a harness that stubbed the runtime still reached the real
# daemon. Liveness comes from the container runtime, never from task status
# (design D3).
#
# Deliberately tolerant: a runtime that cannot answer reads as "no agents are
# live". That is the right shape for the pump's own tick — a supervisor that
# guesses "none" launches something it will find already running next tick, and
# a tick that died on a transient daemon hiccup would be worse.
apl_live_agent_names() {
  local prefix; prefix="$(apl_agent_prefix)"
  apl__runtime_ps_names "$prefix" 2>/dev/null | grep "^$prefix" || true
}

# apl_live_agent_names_strict — the same set, with the runtime's failure kept
# instead of flattened. Exits 0 with a possibly-empty list, or the runtime's own
# non-zero status with its stderr untouched for the caller to word.
#
# The distinction the tolerant form throws away is the whole point of a runner's
# `list` verb (docs/RUNNERS.md §1.3): its caller must be able to tell "nothing is
# running" from "I could not look", because those two answers demand opposite
# actions — launch, or fall back and do not launch.
apl_live_agent_names_strict() {
  local prefix; prefix="$(apl_agent_prefix)"
  local out rc=0
  out="$(apl__runtime_ps_names "$prefix")" || rc=$?
  [[ $rc -eq 0 ]] || return "$rc"
  [[ -n "$out" ]] || return 0
  grep "^$prefix" <<<"$out" || true
}

# ── Liveness, from the runner when the caller opted into one ──────────────────
# The mechanism is unchanged and non-negotiable: liveness comes from process
# state, never from task status (design D3). What is pluggable now is only where
# that process state is READ. A container runner's agents are visible to
# `docker ps`; a runner that starts something else — a plain process, a VM, a
# remote executor — has agents no `docker ps` will ever show, and the supervisor
# would read them as dead and launch over them.
#
# Opt-in per caller, by variable rather than by config key. APL_LIVENESS_RUNNER
# is set in-process by the supervisor that wants runner-backed liveness; it is
# deliberately NOT derived from TASKPUMP_RUNNER, because every read-only observer
# in this stack (the monitor, cleanup, both watchdogs) loads the same config file
# and would silently switch with it. They keep scraping until each is migrated
# on purpose.

# Cache of the capability probe, for the life of the process:
#   unset  not probed yet        1  runner answers `list`
#   0      v1 runner (no verb)
APL_RUNNER_LIST_CAP="${APL_RUNNER_LIST_CAP-}"

# apl__runner_list <runner> — ask a runner for its live agents. Passes the fleet
# prefix and the container runtime, which are the only inputs `list` may read
# (docs/RUNNERS.md §1.3), and keeps the runner's exit status.
apl__runner_list() {
  TP_AGENT_PREFIX="$(apl_agent_prefix)" \
  TASKPUMP_AGENT_PREFIX="$(apl_agent_prefix)" \
  TASKPUMP_DOCKER="$(apl_docker)" \
  DOCKER="$(apl_docker)" \
  "$1" list
}

# apl_runner_list_supported <runner> — does this runner implement `list`? Probed
# once and cached; a supervisor asks liveness every tick and must not pay a
# capability probe each time.
#
# Exit 2 is the answer that means "I do not have that verb" — it is what a shell
# CLI returns for a usage error, what the reference runner returns, and what a v1
# runner written against the documented skeleton returns. Every OTHER non-zero
# means the runner HAS the verb and could not answer it right now (its runtime is
# unreachable), which is a transient condition, not a missing capability: the
# probe reports supported, and the per-tick path below handles the failure. The
# distinction matters because misreading "runtime blipped at pump start" as "v1
# runner" would silently scrape for the rest of the run — which for a
# non-container runner means every agent is invisible for the rest of the run.
apl_runner_list_supported() {
  local runner="$1"
  [[ -n "${APL_RUNNER_LIST_CAP:-}" ]] && return $(( 1 - APL_RUNNER_LIST_CAP ))
  [[ -n "$runner" && -x "$runner" ]] || { APL_RUNNER_LIST_CAP=0; return 1; }
  local rc=0
  apl__runner_list "$runner" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 2 ]]; then
    APL_RUNNER_LIST_CAP=0
    return 1
  fi
  APL_RUNNER_LIST_CAP=1
  return 0
}

# The exit status that means "this list is the fallback scrape, because the
# runner that should have answered could not". EX_TEMPFAIL, the same code the
# pre-flight hook uses for "the environment was not ready" — the answer is not
# wrong on purpose, it is merely not authoritative.
#
# A status, not a global: every liveness call site in this stack reads the answer
# through `$( )` or `< <( )`, both of which run the function in a SUBSHELL, so a
# variable it sets would never reach the caller. The one signal that does survive
# a subshell is the exit status.
APL_LIVENESS_DEGRADED_RC=75

# apl_live_agents — the pluggable enumeration. The runner's answer when this
# caller opted into a runner that supports `list`, the prefix scrape otherwise.
#
# Fail-open, and this is the important half: when a supporting runner errors, the
# call still PRINTS the scrape rather than failing empty, because liveness going
# dark must never wedge the supervisor. But it exits 75, because for a
# non-container runner that fallback answer is not merely stale — it is empty,
# and "everything died" is the most destructive wrong answer this function can
# give. A caller that would only decline to launch can ignore the status; a
# caller that would ACT on absence (reclaiming claims, tearing something down)
# must not.
apl_live_agents() {
  local runner="${APL_LIVENESS_RUNNER:-}"
  [[ -n "$runner" ]] || { apl_live_agent_names; return 0; }
  apl_runner_list_supported "$runner" || { apl_live_agent_names; return 0; }

  local prefix; prefix="$(apl_agent_prefix)"
  local out rc=0
  out="$(apl__runner_list "$runner" 2>/dev/null)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    apl_live_agent_names
    return "$APL_LIVENESS_DEGRADED_RC"
  fi
  # The prefix filter is applied here as well as inside the runner: a
  # third-party runner's `list` is not obliged to have been asked about only one
  # fleet, and a name outside this pump's prefix cannot be mapped back to one of
  # its branches anyway.
  [[ -n "$out" ]] || return 0
  grep "^$prefix" <<<"$out" || true
}

# apl_live_agent_slugs — the same set, each name reduced to its branch slug
# (name minus the prefix; the slug is the branch with `/` → `-`). Propagates the
# degraded status; a pipe would swallow it.
apl_live_agent_slugs() {
  local prefix; prefix="$(apl_agent_prefix)"
  local out rc=0
  out="$(apl_live_agents)" || rc=$?
  [[ -n "$out" ]] && sed "s|^$prefix||" <<<"$out"
  return "$rc"
}

# apl_count_live_agents — count of live agent containers (optionally only those
# whose slug contains $1).
apl_count_live_agents() {
  local filter="${1:-}" n=0 slug
  while IFS= read -r slug; do
    [[ -z "$slug" ]] && continue
    [[ -n "$filter" && "$slug" != *"$filter"* ]] && continue
    n=$((n + 1))
  done < <(apl_live_agent_slugs)
  echo "$n"
}

# apl_disk_low — one-shot disk-pressure gate for the pump's feed loop, parallel to
# apl_network_unhealthy. Delegates to `arachne-disk-watchdog --gate` (the single
# source of the free-space threshold, so run-parallel.sh's cap-file path and the
# pump's feed-gate path share one knob — PAUSE_THRESHOLD_GB, inherited via env).
# Echoes the watchdog's one-line reason to stdout and returns 10 when free disk
# is below the floor. Graceful: returns 0 (feed OK, no output) when the gate is
# disabled (ARACHNE_DISK_GATE != 1) or the watchdog binary is absent / not
# executable — a missing tool never blocks launches.
apl_disk_low() {
  [[ "${TASKPUMP_DISK_GATE:-${ARACHNE_DISK_GATE:-1}}" -eq 1 ]] || return 0
  local wd="${TASKPUMP_DISK_WATCHDOG:-${ARACHNE_DISK_WATCHDOG:-}}"
  [[ -n "$wd" && -x "$wd" ]] || return 0
  local reason rc
  reason="$("$wd" --gate 2>&1)"; rc=$?
  if [[ "$rc" -eq 10 ]]; then
    printf '%s' "$reason"
    return 10
  fi
  return 0
}

# apl_host_token_stale <credentials_file> [margin_seconds] — feed-gate predicate
# for the access-token-only container model (entrypoint-parallel.sh strips the
# refreshToken, so a container can no longer self-refresh; the HOST owns OAuth
# token rotation). Pauses LAUNCHING — running agents are untouched — when the host
# access token is within <margin> seconds of (or past) its expiry, because a
# container launched then would 401 immediately and burn a relaunch cycle. The
# gate clears once a host-side `claude` writes a fresh token back. Echoes a
# one-line reason and returns 10 when stale; silent + 0 when fresh. Fail-open:
# returns 0 (feed) when disabled (ARACHNE_TOKEN_GATE != 1), jq is absent, or the
# file / expiresAt can't be read — a meter we can't read never wedges the pump.
# `expiresAt` is epoch MILLISECONDS in Claude Code's credentials file.
# ARACHNE_NOW_S overrides "now" (epoch seconds) for tests.
apl_host_token_stale() {
  [[ "${TASKPUMP_TOKEN_GATE:-${ARACHNE_TOKEN_GATE:-1}}" -eq 1 ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local cred="$1" margin="${2:-${TASKPUMP_TOKEN_MARGIN_S:-${ARACHNE_TOKEN_MARGIN_S:-600}}}"
  [[ -f "$cred" ]] || return 0
  local exp_ms exp_s now left
  exp_ms="$(jq -r '.claudeAiOauth.expiresAt // empty' "$cred" 2>/dev/null || true)"
  [[ "$exp_ms" =~ ^[0-9]+$ ]] || return 0
  exp_s=$(( exp_ms / 1000 ))
  now="${TASKPUMP_NOW_S:-${ARACHNE_NOW_S:-$(date +%s)}}"
  left=$(( exp_s - now ))
  if (( left <= margin )); then
    if (( left < 0 )); then
      printf 'host OAuth access token expired %ds ago; refresh by running any `claude` command on the host (containers are access-token-only and cannot self-refresh)' "$(( -left ))"
    else
      printf 'host OAuth access token expires in %ds (≤%ds margin); refresh by running any `claude` command on the host' "$left" "$margin"
    fi
    return 10
  fi
  return 0
}

# ── Autonomous integration trunk (A3 / F65.6) ─────────────────────────────────
# apl_acquire_trunk_lock <lockfile> [wait_seconds] — acquire an flock on the trunk
# merge lock via FD 8 for the lifetime of the calling (sub)shell, mirroring
# arachne-task's acquire_state_lock (FD 9) on a DISTINCT fd + file so the two
# locks never alias. Because every container and the host share the bind-mounted
# repo, an flock on a file under the repo is shared by inode — the "merge queue":
# only one integration holds it; others wait their turn. Degrades to a no-op
# (returns 0) where flock is unavailable, falling back on the singular-pump
# serialization. Returns 0 on success / no-flock; non-zero only on lock timeout.
apl_acquire_trunk_lock() {
  local lockfile="$1" wait="${2:-${TASKPUMP_TRUNK_LOCK_WAIT:-${ARACHNE_TRUNK_LOCK_WAIT:-300}}}"
  command -v flock >/dev/null 2>&1 || return 0
  { exec 8>"$lockfile"; } 2>/dev/null || return 0
  flock -w "$wait" 8 || return 1
  return 0
}

# apl_phase_integrated <repo> <branch> <trunk> — 0 (true) when <branch>'s tip is
# reachable from <trunk> (already integrated). This is the git-graph read that
# keeps integration status out of the ledger (design decision 3): code-true,
# self-healing (a dead agent's committed work still integrates on a later tick),
# and decoupled from arachne-task. Quiet false (non-zero) when the branch or
# trunk is missing.
apl_phase_integrated() {
  local repo="$1" branch="$2" trunk="$3"
  git -C "$repo" merge-base --is-ancestor "$branch" "$trunk" 2>/dev/null
}

# apl_fs_guard <repo_root> — RC-4 contamination detector (A8 / F65.5). With the
# read-only primary mount in place, a container can no longer write the primary
# source tree, so this guard should always be clean; it is the regression
# detector that catches a future mount change re-introducing a blanket RW
# `$REPO_ROOT`. Greps `git status --porcelain` for any dirty path OUTSIDE the
# allowlist {.worktrees/, ops, ops/} — i.e. a primary *source* edit (crates/,
# web/, scripts/, Cargo.*, root files) that should have landed in a worktree.
# `$NF` tolerates `R old -> new` rename rows; the `ops` submodule-pointer line is
# allowlisted (agents are told to leave it). Echoes a `FS-GUARD:` line when dirty,
# nothing when clean. Graceful: silent when the repo can't be read.
# Paths that are allowed to be dirty in the primary checkout: the worktrees the
# agents actually work in, the ledger checkout they commit task state to, and
# the supervisor's own untracked run files. The last two entries are the
# integration trunk's lock and quarantine files — they are created in the repo
# root by the first --integration-trunk run, are not tracked, and without them
# here the contamination guard fires on every single tick for the rest of the
# drain.
APL_FS_GUARD_ALLOWLIST="${TASKPUMP_FS_GUARD_ALLOWLIST:-^(\.worktrees/|ops$|ops/|\.auto-trunk\.lock$|\.auto-trunk-quarantine$)}"
apl_fs_guard() {
  local repo_root="$1" dirty
  dirty=$(git -C "$repo_root" status --porcelain 2>/dev/null \
          | awk '{print $NF}' \
          | grep -Ev "$APL_FS_GUARD_ALLOWLIST" || true)
  [[ -n "$dirty" ]] && printf 'FS-GUARD: primary checkout dirty outside allowlist:\n%s\n' "$dirty"
  # Always succeed: callers assign via $(...) under `set -e`, where a non-zero
  # return on the clean (no-dirt) path would abort the tick.
  return 0
}
