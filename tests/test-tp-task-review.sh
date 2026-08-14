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

# ── Section 3: verdict guards ────────────────────────────────────────────────
echo
echo "--- verdict: guards ---"

# Ledger A state here: T1 done, T1.1 open+eligible, T2 gated, T3 open.
export TASKPUMP_TASKS_DIR="$A/tasks"
export TASKPUMP_TASK_OUT="$A/.next-task"
export TASKPUMP_CODE_REPO="$A"

set +e
"$CLI" verdict T3 --approve >/dev/null 2>&1 && fail "verdict on a plain task was accepted" \
  || pass "verdict on a plain task is refused"
"$CLI" verdict T1.1 >/dev/null 2>&1 && fail "verdict with no ruling was accepted" \
  || pass "verdict requires --approve or --request-changes"
"$CLI" verdict T1.1 --approve --request-changes >/dev/null 2>&1 \
  && fail "verdict with both rulings was accepted" \
  || pass "verdict refuses both rulings at once"
"$CLI" verdict T1.1 --request-changes >/dev/null 2>&1 \
  && fail "request-changes without findings was accepted" \
  || pass "request-changes requires --findings"
set -e

# A verdict on work that is not done reviews nothing — and `claim` checks
# status, not blockers, so this guard is the only thing refusing it.
C="$TMPDIR_TEST/c"
mkdir -p "$C/tasks"
TASKPUMP_TASKS_DIR="$C/tasks" "$CLI" create T1 --title "Unfinished impl" >/dev/null
TASKPUMP_TASKS_DIR="$C/tasks" "$CLI" review T1 >/dev/null
set +e
out=$(TASKPUMP_TASKS_DIR="$C/tasks" "$CLI" verdict T1.1 --approve 2>&1); rc=$?
set -e
[[ $rc -ne 0 ]] && pass "a verdict while the implementation is open is refused" \
  || fail "verdict on an open implementation exited 0"
grep -q 'while it is open' <<<"$out" && pass "and the refusal names the status" \
  || fail "refusal was '$out'"

# ── Section 4: the change-request loop closes through eligibility ────────────
echo
echo "--- verdict: the change-request loop ---"

"$CLI" claim T1.1 --branch review/t1 --turns 5 >/dev/null
"$CLI" verdict T1.1 --request-changes --findings - <<< "The parser drops the last line." >/dev/null

assert_fm "$A/tasks" T1 '.status' "open" "request-changes reopens the implementation"
assert_fm "$A/tasks" T1 '.review_round' "2" "and advances the round"
assert_fm "$A/tasks" T1 '.completed_at' "null" "completion markers are shed"
assert_fm "$A/tasks" T1 '.completed_by_commits | length' "0" "including the commit list"
grep -q '## Review findings (round 1' "$A/tasks/T1.md" \
  && pass "the findings land on the implementation's body, named by round" \
  || fail "no round-1 findings section on T1"
grep -q 'The parser drops the last line.' "$A/tasks/T1.md" \
  && pass "with the findings text intact" || fail "findings text missing from T1's body"
grep -q 'Prior completion commits: 1234abc' "$A/tasks/T1.md" \
  && pass "and the prior completion commits preserved in the note" \
  || fail "prior commits not preserved in T1's body"
assert_fm "$A/tasks" T1.1 '.status' "open" "the gate re-arms to open"
assert_fm "$A/tasks" T1.1 '.claimed_by' "null" "with its claim cleared"
grep -q '## Verdict: request-changes (round 1' "$A/tasks/T1.1.md" \
  && pass "the gate's body keeps the verdict for the audit trail" \
  || fail "no verdict note on T1.1"

# The loop is closed by the eligibility predicate alone: the re-armed review
# is ineligible (its blocker is open again), and becomes eligible when the
# fix completes.
got=$("$CLI" ready --count-eligible --include-reviews)
[[ "$got" == "2" ]] && pass "re-armed review is ineligible while the fix is open (frontier = T1, T3)" \
  || fail "post-request-changes frontier got '$got', expected 2"

"$CLI" complete T1 --commits 5678def >/dev/null
got=$("$CLI" next --branch feat/x --include-reviews | jq -r .id)
[[ "$got" == "T1.1" ]] && pass "the fix completing re-opens the review's turn" \
  || fail "post-fix next got '$got', expected T1.1"

"$CLI" verdict T1.1 --approve --findings "Clean now." >/dev/null
assert_fm "$A/tasks" T1.1 '.status' "done" "round-2 approve completes the gate"
grep -q '## Verdict: approve (round 2' "$A/tasks/T1.1.md" \
  && pass "and the approval is named by its round" \
  || fail "no round-2 approve note on T1.1"
got=$("$CLI" ready --count-eligible)
[[ "$got" == "2" ]] && pass "downstream unblocks: T2 joins the frontier" \
  || fail "post-approve frontier got '$got', expected 2 (T2, T3)"

set +e
"$CLI" verdict T1.1 --approve >/dev/null 2>&1 \
  && fail "a second verdict on a done review was accepted" \
  || pass "a rendered verdict is final; reopen is the only way back"
set -e

# ── Section 5: panel discipline and the round bound ──────────────────────────
echo
echo "--- verdict: panel discipline, rounds exhaustion ---"

E="$TMPDIR_TEST/e"
mkdir -p "$E/tasks"
export TASKPUMP_TASKS_DIR="$E/tasks"
export TASKPUMP_TASK_OUT="$E/.next-task"
export TASKPUMP_CODE_REPO="$E"

"$CLI" create T8.1 --title "Panel impl" >/dev/null
"$CLI" create T9.1 --title "Panel downstream" --blockers T8.1 >/dev/null
"$CLI" review T8.1 --panel 2 --max-rounds 2 >/dev/null
"$CLI" complete T8.1 --commits aaa1111 >/dev/null

set +e
out=$("$CLI" verdict T8.2 --request-changes --findings "x" 2>&1); rc=$?
set -e
[[ $rc -ne 0 ]] && pass "a panel reviewer's request-changes is refused" \
  || fail "panel reviewer request-changes exited 0"
grep -q 'T8.4' <<<"$out" && pass "and the refusal points at the adjudicator" \
  || fail "refusal did not name the gate: '$out'"

set +e
out=$("$CLI" verdict T8.4 --approve 2>&1); rc=$?
set -e
[[ $rc -ne 0 ]] && pass "an adjudicator verdict before the panel reported is refused" \
  || fail "early adjudicator verdict exited 0"
grep -q 'T8.2' <<<"$out" && pass "and the refusal names the pending reviewers" \
  || fail "refusal did not name pending reviewers: '$out'"

"$CLI" verdict T8.2 --approve --findings "Concern: the naming is off." >/dev/null
"$CLI" verdict T8.3 --approve >/dev/null
grep -q 'Concern: the naming is off.' "$E/tasks/T8.2.md" \
  && pass "a panel reviewer's findings live on its own task" \
  || fail "reviewer findings missing from T8.2"

# Round 1 of 2: the adjudicator may rule over the panel's approvals.
"$CLI" verdict T8.4 --request-changes --findings "Reviewer 1 is right; rename it." >/dev/null
assert_fm "$E/tasks" T8.1 '.status' "open" "adjudicator request-changes reopens the implementation"
assert_fm "$E/tasks" T8.1 '.review_round' "2" "round advances to 2"
assert_fm "$E/tasks" T8.2 '.status' "open" "sibling reviewers re-arm"
assert_fm "$E/tasks" T8.2 '.completed_at' "null" "shedding their done markers"
grep -q '## Re-armed for round 2' "$E/tasks/T8.2.md" \
  && pass "and their body says why the done was shed" \
  || fail "no re-arm note on T8.2"
assert_fm "$E/tasks" T8.4 '.status' "open" "the adjudicator re-arms too"

# Round 2 of 2: a second rejection would need round 3 — past the bound.
"$CLI" complete T8.1 --commits bbb2222 >/dev/null
"$CLI" verdict T8.2 --approve >/dev/null
"$CLI" verdict T8.3 --approve >/dev/null
"$CLI" verdict T8.4 --request-changes --findings "Still wrong; the rename went half way." >/dev/null

assert_fm "$E/tasks" T8.1 '.status' "needs-review" "past max-rounds the implementation parks needs-review"
assert_fm "$E/tasks" T8.1 '.scrub_reason' "review rounds exhausted (2/2)" "with the tripwire named in scrub_reason"
assert_fm "$E/tasks" T8.1 '.completed_at' "null" "completion markers shed on the park too"
grep -q 'Still wrong; the rename went half way.' "$E/tasks/T8.1.md" \
  && pass "the exhausting round's findings are intact on the implementation" \
  || fail "exhaustion findings missing from T8.1"
grep -q 'rounds exhausted' "$E/tasks/T8.1.md" \
  && pass "and the body says the bound fired" || fail "no exhaustion note on T8.1"
assert_fm "$E/tasks" T8.4 '.status' "done" "the gate's verdict is delivered — its task completes"
got=$("$CLI" ready --count-eligible)
[[ "$got" == "0" ]] && pass "downstream stays shut: the parked implementation is not done" \
  || fail "post-exhaustion frontier got '$got', expected 0"

"$CLI" reopen T8.1 --reason "human ruling: proceed with the rename as-is" >/dev/null
assert_fm "$E/tasks" T8.1 '.status' "open" "the human door out of the park is the ordinary reopen"

# ── Section 6: heartbeat honesty — reviewers are kept off the tripwire ───────
echo
echo "--- heartbeat: the commit meter is inert on review tasks ---"

H="$TMPDIR_TEST/h"
mkdir -p "$H/tasks"
git -C "$H" init -q
git -C "$H" -c user.name=test -c user.email=t@e commit --allow-empty -q -m "init code"
export TASKPUMP_TASKS_DIR="$H/tasks"
export TASKPUMP_TASK_OUT="$H/.next-task"
export TASKPUMP_CODE_REPO="$H"

"$CLI" create T1 --title "Impl" >/dev/null
"$CLI" review T1 >/dev/null
"$CLI" complete T1 >/dev/null
"$CLI" claim T1.1 --branch review/t1 --turns 5 >/dev/null

# Control: a PLAIN task with the same no-commit cycles walks toward `stuck`.
"$CLI" create T3 --title "Plain control" >/dev/null
"$CLI" claim T3 --branch feat/t3 --turns 5 >/dev/null

for _i in 1 2 3; do
  "$CLI" heartbeat T1.1 --start >/dev/null
  "$CLI" heartbeat T1.1 --end >/dev/null
  "$CLI" heartbeat T3 --start >/dev/null
  "$CLI" heartbeat T3 --end >/dev/null
done
unset _i

assert_fm "$H/tasks" T3 '.consecutive_failed_iterations' "3" "control: three commit-less cycles push a plain task to the stuck threshold"
assert_fm "$H/tasks" T1.1 '.consecutive_failed_iterations' "0" "the same three cycles leave a reviewer's failure streak untouched"
assert_fm "$H/tasks" T1.1 '.turn_budget_remaining' "2" "while the turn budget still decrements — the reviewer stays bounded"
got=$(fm "$H/tasks" T1.1 '.last_heartbeat_ts')
[[ "$got" != "null" && -n "$got" ]] && pass "and liveness is still stamped for the staleness tripwire" \
  || fail "last_heartbeat_ts was '$got'"

"$CLI" verdict T1.1 --approve --findings "Read it three times; it is sound." >/dev/null
assert_fm "$H/tasks" T1.1 '.status' "done" "the verdict is the productive terminal act"

# ── Section 7: every mutation is one auditable ledger commit ─────────────────
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

TASKPUMP_TASK_NOCOMMIT=0 "$CLI" complete T1 --commits ccc3333 >/dev/null
commits_before=$(git -C "$D" rev-list --count HEAD)
TASKPUMP_TASK_NOCOMMIT=0 "$CLI" verdict T1.1 --approve --findings "Fine." >/dev/null
commits_after=$(git -C "$D" rev-list --count HEAD)
[[ "$commits_after" -eq $((commits_before + 1)) ]] \
  && pass "a verdict is one ledger commit" \
  || fail "verdict commit count went $commits_before -> $commits_after"
got=$(git -C "$D" log -1 --format='%s')
[[ "$got" == *"verdict T1.1"* ]] && pass "and its message names the verdict" \
  || fail "verdict commit message was '$got'"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
