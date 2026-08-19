#!/usr/bin/env bash
# run-all.sh — run every TaskPump suite and report.
#
# Each tests/test-*.sh is self-contained and exits non-zero on any failure. This
# wrapper runs them in sequence, keeps going after a failure so one broken suite
# does not hide the state of the rest, and prints a summary table at the end.
#
# Hermeticity is centralized in tests/suite-prologue.sh, sourced below:
# notifications stubbed to `true` in both spellings, ambient taskpump.conf
# discovery off, and the inherited TASKPUMP_*/TP_*/ARACHNE_* environment
# scrubbed.
#
# Run: ./tests/run-all.sh          (all suites)
#      ./tests/run-all.sh task     (only suites whose name contains "task")
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

# Hermeticity, both halves, shared with every suite's own prologue: turn off
# ambient taskpump.conf discovery (a leaked conf once made the pump suite
# re-enter this very script unboundedly), and scrub the inherited
# TASKPUMP_*/TP_*/ARACHNE_* environment (issue #18: the pump exports the real
# ledger's TASKPUMP_TASKS_DIR into every agent session, and the canonical
# spelling outranks the legacy one a fixture sets — 64 spurious failures
# across three suites for the 2026-08-13 G3 drain agent). Each suite sources
# the same prologue itself for standalone runs; sourcing it here as well
# guards anything this wrapper does before a suite's own prologue runs.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

filter="${1:-}"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

# ── Hermeticity gate, both halves (issue #20, B16) ────────────────────────────
#
# Suites must not litter the repo they run from (issue #20: a git stub's
# fallthrough answer to --git-common-dir once manufactured <sha>/info/exclude
# trees in the repo root on every run). Snapshot the tree's status up front;
# any delta after the suites ran is itself a failure.
#
# The status diff alone is BLIND to the damage that actually happened, though.
# Every file a TaskPump run drops is listed in .gitignore — that is deliberate,
# TaskPump is itself a repo a pump can be pointed at — so `git status
# --porcelain` cannot see one appear, vanish, or change. On 2026-08-19 a suite
# run deleted and rewrote the operator's live .taskpump-fsguard.notified in the
# primary checkout and this script still printed "All 25 suite(s) passed".
#
# So a second probe runs alongside: a MANIFEST of the run-state files, by
# content. Manifest rather than `git status --ignored` for two reasons.
# `--ignored` reports PATHS, and the observed damage was a content rewrite of a
# file that existed before and after — a diff of zero. And `--ignored` reports
# every ignored path in the tree, so a developer's own .claude/, editor state,
# or build output would fail a run they had nothing to do with. The manifest is
# scoped to the names TaskPump itself writes (the same set .gitignore lists,
# matched as globs so a state file added later is covered without editing this
# line), and it hashes them, so a clobber is as visible as a create.
#
# .git/info/exclude rides along because NO status probe of any width can see
# it: apl_ensure_worktrees_visible appends the worktree negation there, and a
# suite driving that path against the real checkout edits the operator's git
# config with no working-tree trace at all.
state_manifest() {
  local exclude
  exclude="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"
  [[ -n "$exclude" && "$exclude" != /* ]] && exclude="$REPO_ROOT/$exclude"
  (
    cd "$REPO_ROOT" || return 0
    local f
    for f in .taskpump-* .arachne-* .auto-trunk* "${exclude:+$exclude/info/exclude}"; do
      [[ -e "$f" ]] || continue
      if [[ -d "$f" ]]; then
        printf '%s\t<directory>\n' "$f"
      else
        printf '%s\t%s\n' "$f" "$(cksum <"$f" 2>/dev/null)"
      fi
    done | LC_ALL=C sort
  )
}

# Name what moved, one file per line, instead of handing back an opaque diff.
# The two snapshots are TAGGED into one stream rather than handed to awk as two
# files: the usual NR==FNR idiom mis-files the whole second file as "before"
# when the first one is EMPTY, and empty is exactly what the before-snapshot of
# a clean checkout looks like — the one case this gate exists for. awk does the
# tagging because `sed 's/^/B\t/'` writes a literal t outside GNU sed.
state_manifest_delta() {  # $1=before file  $2=after file
  { awk '{ print "B\t" $0 }' "$1"; awk '{ print "A\t" $0 }' "$2"; } | awk -F'\t' '
    $1 == "B" { before[$2] = $3; next }
    { after[$2] = $3
      if (!($2 in before))          printf "  created: %s\n", $2
      else if ($3 != before[$2])    printf "  changed: %s\n", $2 }
    END { for (p in before) if (!(p in after)) printf "  deleted: %s\n", p }
  ' | LC_ALL=C sort
}

REPO_STATUS_BEFORE="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)"
STATE_SNAPSHOT_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_SNAPSHOT_DIR"' EXIT
state_manifest >"$STATE_SNAPSHOT_DIR/before"

suites=()
while IFS= read -r f; do
  [[ "$(basename "$f")" == "run-all.sh" ]] && continue
  [[ -n "$filter" && "$f" != *"$filter"* ]] && continue
  suites+=("$f")
done < <(find "$SCRIPT_DIR" -maxdepth 1 -name 'test-*.sh' | sort)

if [[ ${#suites[@]} -eq 0 ]]; then
  printf 'run-all: no suites matched %s\n' "${filter:-*}" >&2
  exit 1
fi

names=(); results=(); counts=()
failed=0

for suite in "${suites[@]}"; do
  name="$(basename "$suite" .sh)"
  printf '\n=== %s ===\n' "$name"

  out="$(bash "$suite" 2>&1)"
  rc=$?
  printf '%s\n' "$out"

  # Suites print "Tests: N  Passed: N  Failed: N"; fall back to counting PASS/FAIL
  # lines for any that does not.
  tally="$(printf '%s\n' "$out" | grep -E '^Tests: ' | tail -1)"
  if [[ -z "$tally" ]]; then
    tally="Tests: $(printf '%s\n' "$out" | grep -c '^PASS')  Passed: $(printf '%s\n' "$out" | grep -c '^PASS')  Failed: $(printf '%s\n' "$out" | grep -c '^FAIL')"
  fi

  names+=("$name")
  counts+=("$tally")
  if [[ $rc -eq 0 ]]; then
    results+=("ok")
  else
    results+=("FAILED (rc=$rc)")
    failed=$((failed + 1))
  fi
done

REPO_STATUS_AFTER="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)"
if [[ "$REPO_STATUS_AFTER" != "$REPO_STATUS_BEFORE" ]]; then
  printf '\nFAIL: the suites changed this repo'\''s git status (hermeticity, issue #20):\n' >&2
  diff <(printf '%s\n' "$REPO_STATUS_BEFORE") <(printf '%s\n' "$REPO_STATUS_AFTER") >&2
  names+=("(repo hermeticity)")
  results+=("FAILED (littered)")
  counts+=("the run added or removed working-tree entries")
  failed=$((failed + 1))
fi

state_manifest >"$STATE_SNAPSHOT_DIR/after"
STATE_DELTA="$(state_manifest_delta "$STATE_SNAPSHOT_DIR/before" "$STATE_SNAPSHOT_DIR/after")"
if [[ -n "$STATE_DELTA" ]]; then
  printf '\nFAIL: the suites wrote this repo'\''s own run state (hermeticity, B16).\n' >&2
  printf 'These files are gitignored, so the status check above cannot see them:\n' >&2
  printf '%s\n' "$STATE_DELTA" >&2
  printf 'A suite that runs a real tick must pin TASKPUMP_STATE_DIR (or the individual\nfile) into its own temp dir; tests/suite-prologue.sh carries the default.\n' >&2
  names+=("(repo run state)")
  results+=("FAILED (littered)")
  counts+=("$(printf '%s\n' "$STATE_DELTA" | grep -c .) state file(s) created/changed/deleted")
  failed=$((failed + 1))
fi

printf '\n\n==============================================\n'
printf 'Suite summary\n'
printf '==============================================\n'
for i in "${!names[@]}"; do
  printf '%-26s %-14s %s\n' "${names[$i]}" "${results[$i]}" "${counts[$i]}"
done
printf '==============================================\n'

if [[ $failed -eq 0 ]]; then
  printf 'All %d suite(s) passed.\n' "${#names[@]}"
  exit 0
fi

printf '%d of %d suite(s) FAILED.\n' "$failed" "${#names[@]}"
exit 1
