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

filter="${1:-}"

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
