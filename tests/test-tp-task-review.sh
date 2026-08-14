#!/usr/bin/env bash
# test-tp-task-review.sh — review gates: reviewer tasks in the DAG (issue #12).
#
# The mechanism under test is deliberately thin: `review` synthesizes ordinary
# tasks wired with ordinary blockers, and the gating falls out of the existing
# eligibility predicate. So most of what these cases pin is WIRING SHAPE — who
# blocks on whom, and that downstream tasks gain the gate without losing the
# implementation edge — plus the two policy behaviours that keep the mechanism
# honest: the frontier hides review tasks from ordinary pickups (an in-context
# agent must never claim the review of its own work), and the drain count does
# not (a pending review is open work; a range gated on one is stalled, never
# drained).
#
# Fixtures are authored through the CLI, because that is the contract: the CLI
# is the sole writer, and a chain the CLI cannot build is not a chain these
# tests should accept.
#
# Run: ./tests/test-tp-task-review.sh
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
CLI="$TP_ROOT/libexec/tp-task"

# Hermeticity: ignore any taskpump.conf in the repo this suite happens to run
# from. run-all.sh exports the same switch; this covers standalone runs.
export TASKPUMP_NO_CONF=1

PASS=0
FAIL=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }

# Clear both spellings of every config key, so an operator's exported TaskPump
# settings cannot leak in and pre-satisfy (or break) a case here.
for _suffix in TASKS_DIR TASK_OUT CODE_REPO TASK_PUSH PUSH TASK_NOCOMMIT \
               TASK_DEBUG LEDGER_PROBE COMMITTER_NAME COMMITTER_EMAIL \
               ID_PATTERN PHASE_SIGIL TURN_BUDGET_DEFAULT FAILURE_LIMIT \
               CLAIM_STALE_HOURS LOCK_WAIT LOCK_NAME PUSH_RETRIES PROG_NAME \
               CONFIG; do
  unset "ARACHNE_$_suffix" "TASKPUMP_$_suffix" 2>/dev/null || true
done
unset _suffix

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Fixture mode: no ledger commits, no state lock. The audit-commit section
# re-enables committing against its own git repo.
export TASKPUMP_TASK_NOCOMMIT=1

# Read a frontmatter expression from a task file in the active ledger.
fm() { # <ledger-dir> <id> <yq-expr>
  yq --front-matter=extract "$3" "$1/$2.md"
}

assert_fm() { # <ledger-dir> <id> <yq-expr> <expected> <label>
  local got
  got=$(fm "$1" "$2" "$3")
  if [[ "$got" == "$4" ]]; then pass "$5"; else fail "$5 — $2 $3 expected '$4' got '$got'"; fi
}

# ── Section 1: panel of one — the lone reviewer is the gate ──────────────────
echo "--- panel 1: wiring shape ---"

A="$TMPDIR_TEST/a"
mkdir -p "$A/tasks"
export TASKPUMP_TASKS_DIR="$A/tasks"
export TASKPUMP_TASK_OUT="$A/.next-task"
export TASKPUMP_CODE_REPO="$A"

"$CLI" create T1 --title "Impl task" --goal "It works." >/dev/null
"$CLI" create T2 --title "Downstream" --blockers T1 >/dev/null
"$CLI" create T3 --title "Independent" --goal "Also works." >/dev/null

out=$("$CLI" review T1)
grep -q 'gate: T1.1' <<<"$out" && pass "review names the gate" \
  || fail "review output was '$out'"

[[ -f "$A/tasks/T1.1.md" ]] && pass "reviewer T1.1 allocated in the phase namespace (bare-phase impl counts as .0)" \
  || fail "no T1.1.md was created"
assert_fm "$A/tasks" T1.1 '.review_of' "T1" "reviewer carries review_of"
assert_fm "$A/tasks" T1.1 '.review_role' "reviewer" "reviewer carries review_role"
assert_fm "$A/tasks" T1.1 '.review_prompt' "null" "no --prompt records null"
assert_fm "$A/tasks" T1.1 '.status' "open" "reviewer starts open"
assert_fm "$A/tasks" T1.1 '.blockers | join(",")' "T1" "reviewer is blocked by the implementation"
assert_fm "$A/tasks" T2 '.blockers | join(",")' "T1,T1.1" "downstream gains the gate WITHOUT losing the implementation edge"
assert_fm "$A/tasks" T3 '.blockers | join(",")' "" "an unrelated task's blockers are untouched"
assert_fm "$A/tasks" T1 '.review_round' "1" "round 1 is in progress from chain creation"
assert_fm "$A/tasks" T1 '.review_max_rounds' "3" "--max-rounds defaults to 3"
grep -q '## Review chain created' "$A/tasks/T1.md" \
  && pass "the implementation body records the chain" \
  || fail "no chain note appended to T1's body"

# ── Section 1b: the frontier hides reviews; the drain count does not ─────────
echo
echo "--- the frontier skip ---"

# Before the implementation is done: the reviewer is ineligible either way
# (its blocker is open) — the skip is not what is hiding it yet.
got=$("$CLI" ready --count-eligible)
[[ "$got" == "2" ]] && pass "pre-done: T1 and T3 are the frontier" \
  || fail "pre-done count-eligible got '$got', expected 2"

"$CLI" complete T1 --commits 1234abc >/dev/null

got=$("$CLI" ready --count-eligible)
[[ "$got" == "1" ]] && pass "post-done: the eligible reviewer is hidden by default" \
  || fail "post-done count-eligible got '$got', expected 1"
got=$("$CLI" ready --count-eligible --include-reviews)
[[ "$got" == "2" ]] && pass "--include-reviews surfaces it" \
  || fail "count-eligible --include-reviews got '$got', expected 2"
got=$("$CLI" ready --count)
[[ "$got" == "3" ]] && pass "ready --count still counts the review: a pending review is open work" \
  || fail "ready --count got '$got', expected 3"

# T1.1 sorts before T3 (phase 1 < phase 3), so next returning T3 proves the
# skip, not the ordering.
got=$("$CLI" next --branch feat/x | jq -r .id)
[[ "$got" == "T3" ]] && pass "next skips the review task even though it sorts first" \
  || fail "next got '$got', expected T3"
got=$("$CLI" next --branch feat/x --include-reviews | jq -r .id)
[[ "$got" == "T1.1" ]] && pass "next --include-reviews returns the review task" \
  || fail "next --include-reviews got '$got', expected T1.1"

out=$("$CLI" ready)
grep -q 'T1\.1' <<<"$out" && fail "the default ready table listed the review task" \
  || pass "the default ready table hides the review task"
out=$("$CLI" ready --include-reviews)
grep -q 'T1\.1' <<<"$out" && pass "ready --include-reviews lists it" \
  || fail "ready --include-reviews did not list T1.1"

# ── Section 1c: refusals ─────────────────────────────────────────────────────
echo
echo "--- refusals ---"

set +e
out=$("$CLI" review T1 2>&1); rc=$?
set -e
[[ $rc -ne 0 ]] && pass "a second chain for the same task is refused" \
  || fail "duplicate review exited 0"
grep -q 'T1.1' <<<"$out" && pass "and the refusal names the existing chain" \
  || fail "refusal did not name the chain: '$out'"

set +e
"$CLI" review T99 >/dev/null 2>&1 && fail "review of a nonexistent task succeeded" \
  || pass "review of a nonexistent task is refused"
"$CLI" review T1.1 >/dev/null 2>&1 && fail "review of a review task succeeded" \
  || pass "review of a review task is refused"
"$CLI" review T3 --panel 0 >/dev/null 2>&1 && fail "--panel 0 was accepted" \
  || pass "--panel 0 is refused"
"$CLI" review T3 --max-rounds 0 >/dev/null 2>&1 && fail "--max-rounds 0 was accepted" \
  || pass "--max-rounds 0 is refused"
"$CLI" review T3 --prompt "$TMPDIR_TEST/no-such-prompt.md" >/dev/null 2>&1 \
  && fail "a missing --prompt file was accepted" \
  || pass "--prompt is validated at creation time, not at dispatch time"
[[ -f "$A/tasks/T3.1.md" ]] && fail "a refused review left a task file behind" \
  || pass "refused reviews leave no task files behind"
set -e

# ── Section 2: panel of three — adjudicator is the gate ──────────────────────
echo
echo "--- panel 3: adjudicator wiring and the eligibility cascade ---"

B="$TMPDIR_TEST/b"
mkdir -p "$B/tasks" "$B/prompts"
export TASKPUMP_TASKS_DIR="$B/tasks"
export TASKPUMP_TASK_OUT="$B/.next-task"
export TASKPUMP_CODE_REPO="$B"
printf 'Hunt for injection and quoting bugs.\n' >| "$B/prompts/security.md"

"$CLI" create T5.1 --title "Big impl" >/dev/null
"$CLI" create T6.1 --title "Downstream of big" --blockers T5.1 >/dev/null

# Run from an unrelated cwd: the recorded prompt path must be repo-relative to
# the code repo, not to wherever the operator stood.
(cd "$B" && "$CLI" review T5.1 --panel 3 --max-rounds 2 --prompt prompts/security.md >/dev/null)

for rid in T5.2 T5.3 T5.4; do
  assert_fm "$B/tasks" "$rid" '.review_role' "reviewer" "$rid is a reviewer"
  assert_fm "$B/tasks" "$rid" '.blockers | join(",")' "T5.1" "$rid is blocked by the implementation only"
  assert_fm "$B/tasks" "$rid" '.review_prompt' "prompts/security.md" "$rid records the prompt repo-relative"
done
assert_fm "$B/tasks" T5.5 '.review_role' "adjudicator" "T5.5 is the adjudicator"
assert_fm "$B/tasks" T5.5 '.blockers | join(",")' "T5.2,T5.3,T5.4" "the adjudicator is blocked by every reviewer"
assert_fm "$B/tasks" T5.5 '.review_prompt' "null" "the adjudicator carries no reviewer prompt"
assert_fm "$B/tasks" T6.1 '.blockers | join(",")' "T5.1,T5.5" "downstream is rewired onto the adjudicator, not the reviewers"
assert_fm "$B/tasks" T5.1 '.review_max_rounds' "2" "--max-rounds is recorded on the implementation"

# The cascade, driven by ordinary verbs only: reviewers become eligible when
# the implementation is done, the adjudicator when every reviewer is, and
# downstream when the gate is.
got=$("$CLI" ready --count-eligible --include-reviews)
[[ "$got" == "1" ]] && pass "cascade 0: only the implementation is eligible" \
  || fail "cascade 0 got '$got', expected 1"

"$CLI" complete T5.1 --commits beef123 >/dev/null
got=$("$CLI" ready --count-eligible --include-reviews)
[[ "$got" == "3" ]] && pass "cascade 1: implementation done — all three reviewers eligible in parallel" \
  || fail "cascade 1 got '$got', expected 3"
got=$("$CLI" ready --count-eligible)
[[ "$got" == "0" ]] && pass "cascade 1: and none of them is on the default frontier" \
  || fail "cascade 1 default frontier got '$got', expected 0"

"$CLI" complete T5.2 >/dev/null
"$CLI" complete T5.3 >/dev/null
got=$("$CLI" ready --count-eligible --include-reviews)
[[ "$got" == "1" ]] && pass "cascade 2: two reviewers done — adjudicator still waits on the third" \
  || fail "cascade 2 got '$got', expected 1"

"$CLI" complete T5.4 >/dev/null
out=$("$CLI" ready --include-reviews)
grep -q 'T5\.5' <<<"$out" && pass "cascade 3: all reviewers done — the adjudicator is eligible" \
  || fail "cascade 3: adjudicator not eligible: $out"
grep -q 'T6\.1' <<<"$out" && fail "cascade 3: downstream leaked past the gate" \
  || pass "cascade 3: downstream still gated"

"$CLI" complete T5.5 >/dev/null
out=$("$CLI" ready)
grep -q 'T6\.1' <<<"$out" && pass "cascade 4: gate done — downstream is eligible" \
  || fail "cascade 4: downstream not eligible: $out"

# ── Section 3: every mutation is one auditable ledger commit ─────────────────
echo
echo "--- audit trail ---"

D="$TMPDIR_TEST/d"
mkdir -p "$D/tasks"
git -C "$D" init -q
export TASKPUMP_TASKS_DIR="$D/tasks"
export TASKPUMP_TASK_OUT="$D/.next-task"
export TASKPUMP_CODE_REPO="$D"

TASKPUMP_TASK_NOCOMMIT=0 "$CLI" create T1 --title "Impl" >/dev/null
TASKPUMP_TASK_NOCOMMIT=0 "$CLI" create T2 --title "Downstream" --blockers T1 >/dev/null
commits_before=$(git -C "$D" rev-list --count HEAD)
TASKPUMP_TASK_NOCOMMIT=0 "$CLI" review T1 --panel 2 >/dev/null
commits_after=$(git -C "$D" rev-list --count HEAD)
[[ "$commits_after" -eq $((commits_before + 1)) ]] \
  && pass "the whole chain — reviewers, adjudicator, rewiring — is ONE ledger commit" \
  || fail "commit count went $commits_before -> $commits_after"
got=$(git -C "$D" log -1 --format='%s')
[[ "$got" == *"review T1"* ]] && pass "the commit message names the verb and the subject" \
  || fail "commit message was '$got'"
got=$(git -C "$D" log -1 --format='%an')
[[ "$got" == "tp-task" ]] && pass "the commit carries the ledger committer identity" \
  || fail "committer was '$got'"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
