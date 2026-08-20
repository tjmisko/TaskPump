#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Tristan Misko
# lib/config.sh — TaskPump's configuration core. Sourced by every tool, never
# executed on its own.
#
# Two jobs:
#
#   1. Install layout. TP_ROOT and its subdirectories are derived from *this
#      file's* location, so a tool can find its siblings no matter how it was
#      invoked (directly, through bin/tp, or through a symlink on PATH).
#
#   2. Configuration. `tp_load_config` discovers a `taskpump.conf`, sources it,
#      and reconciles the legacy ARACHNE_* environment names with the canonical
#      TASKPUMP_* ones.
#
# ── The resolution rule ──────────────────────────────────────────────────────
#
# Config discovery starts from $PWD's git worktree, NEVER from the script's own
# location. This is the 2026-08-01 wrong-ledger lesson made structural: the
# primary checkout and every worktree each carry their own copy of the tools and
# their own ledger, so a tool that derives its workspace from where the *script*
# lives will happily write a worktree's task state into the primary's ledger.
# Whose work it is, is a property of the caller's directory, not of which copy
# of the script happened to be on PATH. TP_ROOT above is a different question —
# it locates the TaskPump *install*, which really is script-relative.
#
# Precedence, strongest first:
#
#   environment  >  taskpump.conf  >  defaults baked into each tool
#
# ── The hermeticity off-switch ───────────────────────────────────────────────
#
# TASKPUMP_NO_CONF=1 suppresses the discovery walk entirely: no ambient
# taskpump.conf is loaded, and a tool sees its baked defaults plus whatever the
# environment sets — nothing else. An explicit TASKPUMP_CONFIG still loads: the
# switch turns off *ambient* discovery, not deliberate configuration, so a
# caller under the switch can still opt into a named fixture file.
#
# This exists for the test suites (2026-08-12): they claim hermeticity, but the
# tools they invoke discover config from $PWD — so running them from a repo
# that carries a taskpump.conf (TaskPump's own dogfood conf, or any consumer's)
# leaked that conf into every fixture invocation that did not override a key.
# It is environment-only by construction: by the time a config file could say
# anything, the decision it governs has already been made.
#
# ── Legacy alias promotion ───────────────────────────────────────────────────
#
# `tp_load_config` bridges the legacy ARACHNE_* spellings and the canonical
# TASKPUMP_* ones — generically (no hardcoded key table) and in both directions.
# The policy — which spelling wins where, the ARACHNE_NO_CONF loading-order
# exception, and the deprecation horizon (guaranteed through every 0.x release,
# removed at 1.0.0) — lives in the "Legacy names" section of docs/CONFIG.md, not
# here.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf 'config.sh: this file must be sourced, not executed\n' >&2
  exit 2
fi

# ── Install layout ────────────────────────────────────────────────────────────
# Derived from this file's own realpath, so symlinked installs resolve correctly.
TP_LIB_DIR="$(CDPATH='' cd -- "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TP_ROOT="$(CDPATH='' cd -- "$TP_LIB_DIR/.." && pwd)"
TP_LIBEXEC_DIR="$TP_ROOT/libexec"
TP_GATES_DIR="$TP_ROOT/gates"
export TP_ROOT TP_LIB_DIR TP_LIBEXEC_DIR TP_GATES_DIR

# The config filename discovered by the upward walk.
: "${TP_CONFIG_NAME:=taskpump.conf}"

# ── Internals ─────────────────────────────────────────────────────────────────

# tp__names_with_prefix <prefix>
# Print the names of every currently-set shell/environment variable starting
# with <prefix>. Names cannot contain newlines, so line-per-name is unambiguous
# even when the *values* contain newlines or spaces.
tp__names_with_prefix() {
  local prefix=$1 name
  while IFS= read -r name; do
    [[ $name == "$prefix"* && ${#name} -gt ${#prefix} ]] && printf '%s\n' "$name"
  done < <(compgen -v 2>/dev/null || true)
  return 0
}

# tp__is_set <name>
# True when the named variable is set (even to the empty string). Uses bash
# indirect expansion rather than eval, so a value containing shell metacharacters,
# spaces, or newlines is never re-parsed.
tp__is_set() {
  local name=$1
  [[ -n "${!name+set}" ]]
}

# tp__git_toplevel
# The root of $PWD's git worktree, or empty when $PWD is not inside a repo.
tp__git_toplevel() {
  git rev-parse --show-toplevel 2>/dev/null || true
}

# tp__is_taskpump_install <dir>
# True when <dir> is the root of a TaskPump installation — the structural
# marker, independent of which copy of the tools is actually running, so a
# vendored checkout is recognized even when the invoked `tp` is a global one.
tp__is_taskpump_install() {
  [[ -f "$1/lib/config.sh" && -f "$1/libexec/tp-task" ]]
}

# tp__superproject_root <dir>
# The working-tree root of the repository that carries <dir>'s repo as a git
# SUBMODULE, or empty when there is none.
tp__superproject_root() {
  git -C "$1" rev-parse --show-superproject-working-tree 2>/dev/null || true
}

# tp__conf_is_vendored_install <dir> <ceiling>
# True when a taskpump.conf found at <dir> is a vendored TaskPump checkout's
# OWN tracked conf sitting inside an enclosing consumer — never the consumer's
# configuration. Two vendoring shapes are recognizable:
#   * a subtree / plain directory copy: <dir> is a TaskPump install strictly
#     inside someone else's worktree (<dir> != the walk's ceiling);
#   * a submodule: <dir> is its own worktree root but a superproject encloses
#     it.
# A TaskPump checkout that is nobody's vendored copy (the dogfood repo, its
# worktrees) matches neither and keeps its conf.
tp__conf_is_vendored_install() {
  local dir=$1 ceiling=$2
  tp__is_taskpump_install "$dir" || return 1
  [[ -n "$ceiling" && "$dir" != "$ceiling" ]] && return 0
  [[ -n "$(tp__superproject_root "$dir")" ]]
}

# tp__discover_config
# Print the path of the first `taskpump.conf` found walking up from $PWD. The
# walk stops at the enclosing git worktree root when there is one (config is a
# property of a workspace, so it should not leak in from a parent directory),
# and at / otherwise. Prints nothing when none is found — not an error.
#
# One class of conf is skipped: a vendored TaskPump checkout's own tracked
# taskpump.conf (issue #6). That file describes TaskPump's dogfood ledger, and
# letting it capture resolution for a consumer that vendors TaskPump (submodule,
# subtree, or directory copy) silently points the consumer's tooling at the
# vendored G ledger. The consumer's conf must win, so the walk passes over a
# vendored install's conf — and, when the vendored checkout is a submodule,
# continues past its worktree boundary into the superproject.
tp__discover_config() {
  local dir ceiling super
  dir="$(CDPATH='' cd -- "$PWD" 2>/dev/null && pwd)" || return 0
  ceiling="$(tp__git_toplevel)"

  while true; do
    if [[ -f "$dir/$TP_CONFIG_NAME" ]]; then
      if ! tp__conf_is_vendored_install "$dir" "$ceiling"; then
        printf '%s\n' "$dir/$TP_CONFIG_NAME"
        return 0
      fi
      # else: a vendored TaskPump's own conf — keep walking toward the consumer.
    fi
    if [[ -n "$ceiling" && "$dir" == "$ceiling" ]]; then
      # At a submodule boundary of a vendored TaskPump checkout the walk does
      # not stop: the workspace the caller means is the consumer's, so the
      # ceiling extends to the superproject's worktree root.
      super="$(tp__superproject_root "$dir")"
      if [[ -n "$super" ]] && tp__is_taskpump_install "$dir"; then
        ceiling="$super"
      else
        return 0
      fi
    fi
    [[ "$dir" == "/" ]] && return 0
    dir="$(dirname "$dir")"
  done
}

# tp__source_config <path>
# Source a config file with allexport on, so bare `KEY=value` lines become
# exported variables. Restores the caller's allexport state afterwards.
tp__source_config() {
  local path=$1 had_allexport=0
  case $- in *a*) had_allexport=1;; esac
  set -a
  # shellcheck disable=SC1090  # path is discovered at runtime by design
  . "$path"
  [[ $had_allexport -eq 1 ]] || set +a
  return 0
}

# ── Workspace resolution ─────────────────────────────────────────────────────

# tp_workspace_cwd_root
# The caller's workspace root: $PWD's git worktree — except when that worktree
# is itself a vendored TaskPump checkout inside a consumer (a submodule), in
# which case the consumer's root is the workspace the caller means. Empty when
# $PWD is not inside a repo.
tp_workspace_cwd_root() {
  local root super
  root="$(tp__git_toplevel)"
  [[ -z "$root" ]] && return 0
  if tp__is_taskpump_install "$root"; then
    super="$(tp__superproject_root "$root")"
    [[ -n "$super" ]] && root="$super"
  fi
  printf '%s\n' "$root"
}

# tp_resolve_workspace
# Resolve the workspace whose ledger an invocation operates on, one rule for
# every tool that needs it (tp-task and tp-pump must agree, or the supervisor
# hands its agents a different ledger than the CLI reads). Sets:
#   TP_WS_CONF_ROOT  the discovered conf's directory ("" when none / explicit)
#   TP_WS_CWD_ROOT   the caller's workspace root ("" outside any repo)
#   TP_WS_ROOT       the resolved workspace root
#   TP_WS_VIA        which rung answered: conf | cwd | install-root
# Precedence: a DISCOVERED conf's directory when the ledger probe answers
# there, else the caller's worktree when it answers, else the install root —
# which is a fallback, not an answer (tp-task's mutating verbs guard it).
# An EXPLICIT TASKPUMP_CONFIG never anchors: deliberate configuration may live
# anywhere, and saying where the config is is not saying where the ledger is.
# shellcheck disable=SC2034  # the TP_WS_* results are read by the tools that
# source this file (tp-task, tp-pump), not in this file itself.
tp_resolve_workspace() {
  local probe="${TASKPUMP_LEDGER_PROBE:-${TASKPUMP_TASKS_SUBDIR:-tasks}}"
  TP_WS_CONF_ROOT=""
  if [[ -z "${TASKPUMP_CONFIG:-}" && -n "${TP_CONFIG_FILE:-}" ]]; then
    TP_WS_CONF_ROOT="$(CDPATH='' cd -- "$(dirname "$TP_CONFIG_FILE")" 2>/dev/null && pwd || true)"
  fi
  TP_WS_CWD_ROOT="$(tp_workspace_cwd_root)"
  TP_WS_ROOT="$TP_ROOT"
  TP_WS_VIA="install-root"
  if [[ -n "$TP_WS_CONF_ROOT" && -d "$TP_WS_CONF_ROOT/$probe" ]]; then
    TP_WS_ROOT="$TP_WS_CONF_ROOT"
    TP_WS_VIA="conf"
  elif [[ -n "$TP_WS_CWD_ROOT" && -d "$TP_WS_CWD_ROOT/$probe" ]]; then
    TP_WS_ROOT="$TP_WS_CWD_ROOT"
    TP_WS_VIA="cwd"
  fi
}

# ── Conf-relative path anchoring ─────────────────────────────────────────────
# A relative path in taskpump.conf means "relative to the workspace the conf
# describes" — never "relative to wherever the caller happens to stand". Left
# unanchored, TASKPUMP_TASKS_DIR=ops/task-loop/tasks read from a subdirectory
# yields an EMPTY frontier with rc=0: the silent wrong answer of issue #1.
#
# Only values the CONF supplied are anchored. An environment value keeps the
# shell's own convention ($PWD-relative), because the caller typed it where
# they stood; a conf file is checked in and read from anywhere.

# The path-valued keys whose conf-relative values anchor to the workspace.
# Deliberately NOT every path-ish key: the state-file names (PUMP_LOG,
# POOL_CAP_FILE, ...) are relative to the STATE DIR by contract, and
# TASKPUMP_LEDGER_PROBE is relative to a candidate workspace by definition.
TP_ANCHORED_PATH_KEYS=(
  TASKS_DIR TASK_OUT CODE_REPO LEDGER_REPO
  PUMP_TASKS_DIR PUMP_OPS_DIR WORKSPACE_ROOT
  BRIEF_TEMPLATE PHASE_BRIEF_TEMPLATE TASK_BRIEF_TEMPLATE RESUME_TEMPLATE
)

# tp_conf_supplied <KEY_SUFFIX>
# True when TASKPUMP_<KEY_SUFFIX>'s current value came from the loaded conf
# file rather than the environment.
tp_conf_supplied() {
  [[ $'\n'"${TP_CONF_KEYS:-}"$'\n' == *$'\n'"$1"$'\n'* ]]
}

# tp__conf_anchor_dir
# The directory a conf-relative path resolves against: a discovered conf's own
# directory; for an explicit TASKPUMP_CONFIG (which may live anywhere), the
# caller's workspace root. Empty when there is nothing to anchor to.
tp__conf_anchor_dir() {
  if [[ -z "${TASKPUMP_CONFIG:-}" && -n "${TP_CONFIG_FILE:-}" ]]; then
    CDPATH='' cd -- "$(dirname "$TP_CONFIG_FILE")" 2>/dev/null && pwd
    return 0
  fi
  tp_workspace_cwd_root
}

# tp__anchor_conf_paths
# Anchor every conf-supplied relative TP_ANCHORED_PATH_KEYS value. Loud on the
# residual unanchorable case (explicit config, relative value, no workspace):
# resolving it against $PWD would be the silent wrong answer this exists to
# remove, so it is an error that names the key and both fixes.
tp__anchor_conf_paths() {
  local anchor="" key name val
  for key in "${TP_ANCHORED_PATH_KEYS[@]}"; do
    tp_conf_supplied "$key" || continue
    name="TASKPUMP_$key"
    val="${!name-}"
    [[ -z "$val" || "$val" == /* ]] && continue
    [[ -n "$anchor" ]] || anchor="$(tp__conf_anchor_dir)"
    if [[ -z "$anchor" ]]; then
      printf 'config.sh: %s=%s is a relative path from %s,
  and there is no workspace to anchor it to ($PWD is not inside a git worktree,
  and an explicit TASKPUMP_CONFIG may live outside the workspace it describes).
  Resolving it against $PWD would silently pick a different %s per directory.
  fix it with either:
    an absolute path for %s in the conf
    running from inside the workspace the conf describes\n' \
        "$name" "$val" "$TP_CONFIG_FILE" "$name" "$name" >&2
      return 1
    fi
    val="$anchor/$val"
    val="${val%/.}"                       # tidy the CODE_REPO=. spelling
    printf -v "$name" '%s' "$val"
    export "${name?}"
    # Keep the legacy mirror in step; a stale relative ARACHNE_* would win in a
    # child process that still reads the legacy name directly.
    printf -v "ARACHNE_$key" '%s' "$val"
    export "ARACHNE_$key"
  done
  return 0
}

# ── Public entry point ────────────────────────────────────────────────────────

# tp_load_config
# Discover and load configuration, then reconcile the legacy and canonical
# environment-variable spellings. Idempotent: a second call in the same process
# is a no-op. A missing config file is normal, not an error.
tp_load_config() {
  [[ "${TP_CONFIG_LOADED:-0}" == "1" ]] && return 0

  # Snapshot the environment *before* the config file can touch it. These are
  # the values that must outrank whatever the file says.
  local -A pre_legacy=() pre_canon=()
  local name
  while IFS= read -r name; do
    pre_legacy["${name#ARACHNE_}"]="${!name}"
  done < <(tp__names_with_prefix ARACHNE_)
  while IFS= read -r name; do
    pre_canon["${name#TASKPUMP_}"]="${!name}"
  done < <(tp__names_with_prefix TASKPUMP_)

  # Explicit config > the off-switch > the discovery walk. The legacy spelling
  # of the switch is honored inline: the generic ARACHNE_* bridge below runs
  # after this decision, so it cannot bridge a key that governs loading itself.
  if [[ -n "${TASKPUMP_CONFIG:-}" ]]; then
    TP_CONFIG_FILE="$TASKPUMP_CONFIG"
  elif [[ "${TASKPUMP_NO_CONF:-${ARACHNE_NO_CONF:-0}}" == "1" ]]; then
    TP_CONFIG_FILE=""
  else
    TP_CONFIG_FILE="$(tp__discover_config)"
  fi
  local conf_sourced=0
  if [[ -n "$TP_CONFIG_FILE" ]]; then
    if [[ -f "$TP_CONFIG_FILE" ]]; then
      tp__source_config "$TP_CONFIG_FILE"
      conf_sourced=1
    elif [[ -n "${TASKPUMP_CONFIG:-}" ]]; then
      printf 'config.sh: TASKPUMP_CONFIG points at a missing file: %s\n' \
        "$TP_CONFIG_FILE" >&2
      return 1
    fi
  fi
  export TP_CONFIG_FILE

  # Which canonical keys did the CONF supply? A key set now but present in
  # neither pre-load snapshot can only have come from the sourced file. The
  # anchoring pass below is scoped to exactly these: environment values keep
  # the shell's own $PWD-relative convention.
  local key
  TP_CONF_KEYS=""
  if [[ "$conf_sourced" -eq 1 ]]; then
    while IFS= read -r name; do
      key="${name#TASKPUMP_}"
      [[ -n "${pre_canon[$key]+set}" ]] && continue
      [[ -n "${pre_legacy[$key]+set}" ]] && continue
      TP_CONF_KEYS+="$key"$'\n'
    done < <(tp__names_with_prefix TASKPUMP_)
  fi

  # Environment beats config, for the canonical names.
  local key
  for key in "${!pre_canon[@]}"; do
    printf -v "TASKPUMP_$key" '%s' "${pre_canon[$key]}"
    export "TASKPUMP_$key"
  done

  # Environment beats config, for the legacy names — promoted onto the canonical
  # spelling. Skipped where the canonical name was itself in the environment.
  for key in "${!pre_legacy[@]}"; do
    [[ -n "${pre_canon[$key]+set}" ]] && continue
    printf -v "TASKPUMP_$key" '%s' "${pre_legacy[$key]}"
    export "TASKPUMP_$key"
  done

  # Back-promote so a TASKPUMP_*-only config reaches tools that still read the
  # legacy names. Never overwrites an ARACHNE_* that is already set.
  while IFS= read -r name; do
    key="${name#TASKPUMP_}"
    tp__is_set "ARACHNE_$key" && continue
    printf -v "ARACHNE_$key" '%s' "${!name}"
    export "ARACHNE_$key"
  done < <(tp__names_with_prefix TASKPUMP_)

  # Anchor conf-relative paths to the workspace, never to $PWD (issue #1).
  # Runs after both promotion passes so it sees the values that actually won.
  tp__anchor_conf_paths || return 1

  TP_CONFIG_LOADED=1
  return 0
}
