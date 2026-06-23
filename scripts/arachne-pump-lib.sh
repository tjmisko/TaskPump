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

# brcmfmac wedge signatures — the Apple-Silicon WiFi firmware hang that the
# rotating-pool cap exists to avoid (see CLAUDE.md "Parallel runs").
APL_WEDGE_SIGNATURES='Failed to alloc SKB|Firmware reported general error|Timeout on response for query command'

# apl_network_unhealthy — 0 (true) when the kernel journal shows a brcmfmac wedge
# signature within the last HEALTH_WINDOW seconds. Graceful: 1 (healthy) when the
# gate is off (HEALTH_GATE != 1), journalctl is absent, or nothing matches.
apl_network_unhealthy() {
  [[ "${HEALTH_GATE:-1}" -eq 1 ]] || return 1
  command -v journalctl >/dev/null 2>&1 || return 1
  if journalctl -k -b 0 --since "${HEALTH_WINDOW:-120} sec ago" 2>/dev/null \
      | grep -qiE "$APL_WEDGE_SIGNATURES"; then
    return 0
  fi
  return 1
}

# apl_read_cap — the live concurrency cap: CAP_FILE's contents if it holds a
# positive integer (live-retunable mid-run), else JOBS. Lets an operator
# `echo 3 > .arachne-pool-cap` without restarting the supervisor.
apl_read_cap() {
  local c="${JOBS:-6}"
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

# apl_live_agent_slugs — echo the branch-slug of every live `arachne-agent-*`
# container, one per line (slug = container name minus the `arachne-agent-`
# prefix = branch with `/` → `-`). Liveness comes from `docker ps`, never from
# task status (design D3). Honors a DOCKER override for testing.
apl_live_agent_slugs() {
  local docker_bin="${DOCKER:-docker}"
  "$docker_bin" ps --filter 'name=arachne-agent' --format '{{.Names}}' 2>/dev/null \
    | sed -n 's/^arachne-agent-//p'
}

# apl_count_live_agents — count of live arachne-agent containers (optionally
# only those whose slug contains $1).
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
apl_fs_guard() {
  local repo_root="$1" dirty
  dirty=$(git -C "$repo_root" status --porcelain 2>/dev/null \
          | awk '{print $NF}' \
          | grep -Ev '^(\.worktrees/|ops$|ops/)' || true)
  [[ -n "$dirty" ]] && printf 'FS-GUARD: primary checkout dirty outside allowlist:\n%s\n' "$dirty"
  # Always succeed: callers assign via $(...) under `set -e`, where a non-zero
  # return on the clean (no-dirt) path would abort the tick.
  return 0
}
