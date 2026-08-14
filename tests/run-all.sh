#!/usr/bin/env bash
# run-all.sh — run every TaskPump suite and report.
#
# Each tests/test-*.sh is self-contained and exits non-zero on any failure. This
# wrapper runs them in sequence, keeps going after a failure so one broken suite
# does not hide the state of the rest, and prints a summary table at the end.
#
# Notifications are stubbed to `true` in both spellings: several suites drive
# code paths that would otherwise fire a real desktop notification per tick.
#
# Run: ./tests/run-all.sh          (all suites)
#      ./tests/run-all.sh task     (only suites whose name contains "task")
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

export ARACHNE_NOTIFY_CMD=true
export TASKPUMP_NOTIFY_CMD=true

# Hermeticity: the tools discover taskpump.conf by walking up from $PWD, so a
# conf in whatever repo these suites happen to run from (TaskPump's own dogfood
# conf included) would leak into every fixture invocation that does not override
# a key — a foreign sigil failing range parses, and a TASKPUMP_BUILD_GATE of
# './tests/run-all.sh' that once made the pump suite re-enter this very script
# unboundedly. Each suite exports this itself for standalone runs; a suite that
# tests conf discovery opts back in per-invocation (TASKPUMP_NO_CONF=0 or an
# explicit TASKPUMP_CONFIG, which outranks the switch).
export TASKPUMP_NO_CONF=1

filter="${1:-}"

# Suites must not litter the repo they run from (issue #20: a git stub's
# fallthrough answer to --git-common-dir once manufactured <sha>/info/exclude
# trees in the repo root on every run). Snapshot the tree's status up front;
# any delta after the suites ran is itself a failure.
REPO_STATUS_BEFORE="$(git -C "$SCRIPT_DIR/.." status --porcelain 2>/dev/null)"

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

REPO_STATUS_AFTER="$(git -C "$SCRIPT_DIR/.." status --porcelain 2>/dev/null)"
if [[ "$REPO_STATUS_AFTER" != "$REPO_STATUS_BEFORE" ]]; then
  printf '\nFAIL: the suites changed this repo'\''s git status (hermeticity, issue #20):\n' >&2
  diff <(printf '%s\n' "$REPO_STATUS_BEFORE") <(printf '%s\n' "$REPO_STATUS_AFTER") >&2
  names+=("(repo hermeticity)")
  results+=("FAILED (littered)")
  counts+=("the run added or removed working-tree entries")
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
