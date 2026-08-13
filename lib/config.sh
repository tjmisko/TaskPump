#!/usr/bin/env bash
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

# tp__discover_config
# Print the path of the first `taskpump.conf` found walking up from $PWD. The
# walk stops at the enclosing git worktree root when there is one (config is a
# property of a workspace, so it should not leak in from a parent directory),
# and at / otherwise. Prints nothing when none is found — not an error.
tp__discover_config() {
  local dir ceiling
  dir="$(CDPATH='' cd -- "$PWD" 2>/dev/null && pwd)" || return 0
  ceiling="$(tp__git_toplevel)"

  while true; do
    if [[ -f "$dir/$TP_CONFIG_NAME" ]]; then
      printf '%s\n' "$dir/$TP_CONFIG_NAME"
      return 0
    fi
    [[ -n "$ceiling" && "$dir" == "$ceiling" ]] && return 0
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
  if [[ -n "$TP_CONFIG_FILE" ]]; then
    if [[ -f "$TP_CONFIG_FILE" ]]; then
      tp__source_config "$TP_CONFIG_FILE"
    elif [[ -n "${TASKPUMP_CONFIG:-}" ]]; then
      printf 'config.sh: TASKPUMP_CONFIG points at a missing file: %s\n' \
        "$TP_CONFIG_FILE" >&2
      return 1
    fi
  fi
  export TP_CONFIG_FILE

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

  TP_CONFIG_LOADED=1
  return 0
}
