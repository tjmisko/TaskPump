#!/usr/bin/env bash
# arachne-pump-lib.sh — shared pool-supervisor helpers, sourced by both the
# manifest launcher (run-parallel.sh) and the DAG pump (arachne-pump).
#
# These are the stable, behavior-identical bits the 2026-06-22 design asked to
# EXTRACT rather than fork-copy. They read the sourcing script's globals
# (HEALTH_GATE, HEALTH_WINDOW, JOBS, CAP_FILE) at call time, so each script keeps
# owning its own configuration; the helpers just centralize the logic.
#
# This file is sourced, never executed — no `set -e`, no top-level side effects.

# apl_render_template <template-file>
# Substitute {{KEY}} placeholders, reading two associative arrays from the
# caller's scope: TPL_VARS maps a key to a scalar, TPL_BLOCKS maps a key to a
# file whose contents replace a line that consists of nothing but that
# placeholder. The block form is why this is bash rather than sed — the values
# it splices are multi-line command output (a git log, a status listing), and
# every sed-based approach to that either mangles newlines or has to escape the
# replacement text. Bash parameter substitution needs no escaping at all.
apl_render_template() {
  local tpl="$1" line key trimmed
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
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
# TASKPUMP_JOBS_FALLBACK. Lets an operator `echo 3 > .arachne-pool-cap` without
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
  if grep -qE '^\.worktrees/$' "$repo_root/.gitignore" 2>/dev/null; then
    sed -i '/^\.worktrees\/$/d' "$repo_root/.gitignore"
  fi
}

# ── Agent-container identity ──────────────────────────────────────────────────
# The container-name prefix is this stack's join key: the pump derives a name
# from a branch, both watchdogs count by it, cleanup maps a name back to a
# worktree, and tooling outside this repo greps for it. So it is one knob, read
# through one accessor, and its default must not drift.
apl_agent_prefix() { printf '%s' "${TASKPUMP_AGENT_PREFIX:-arachne-agent-}"; }

# apl_docker — the container-runtime binary. TASKPUMP_DOCKER is the canonical
# spelling; DOCKER is the legacy one every existing harness sets.
apl_docker() { printf '%s' "${TASKPUMP_DOCKER:-${DOCKER:-docker}}"; }

# apl_live_agent_names — the full name of every live agent container, one per
# line. This is THE enumeration: five near-copies of it used to live in the
# pump's lib, cleanup, and both watchdogs, and three of them called `docker`
# literally — so a harness that stubbed the runtime still reached the real
# daemon. Liveness comes from the container runtime, never from task status
# (design D3).
apl_live_agent_names() {
  local prefix; prefix="$(apl_agent_prefix)"
  "$(apl_docker)" ps --filter "name=$prefix" --format '{{.Names}}' 2>/dev/null \
    | grep "^$prefix" || true
}

# apl_live_agent_slugs — the same set, each name reduced to its branch slug
# (name minus the prefix; the slug is the branch with `/` → `-`).
apl_live_agent_slugs() {
  local prefix; prefix="$(apl_agent_prefix)"
  apl_live_agent_names | sed "s|^$prefix||"
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
  [[ "${ARACHNE_DISK_GATE:-1}" -eq 1 ]] || return 0
  local wd="${ARACHNE_DISK_WATCHDOG:-}"
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
  [[ "${ARACHNE_TOKEN_GATE:-1}" -eq 1 ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local cred="$1" margin="${2:-${ARACHNE_TOKEN_MARGIN_S:-600}}"
  [[ -f "$cred" ]] || return 0
  local exp_ms exp_s now left
  exp_ms="$(jq -r '.claudeAiOauth.expiresAt // empty' "$cred" 2>/dev/null || true)"
  [[ "$exp_ms" =~ ^[0-9]+$ ]] || return 0
  exp_s=$(( exp_ms / 1000 ))
  now="${ARACHNE_NOW_S:-$(date +%s)}"
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
  local lockfile="$1" wait="${2:-${ARACHNE_TRUNK_LOCK_WAIT:-300}}"
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
APL_FS_GUARD_ALLOWLIST="${TASKPUMP_FS_GUARD_ALLOWLIST:-^(\.worktrees/|ops$|ops/)}"
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
