#!/usr/bin/env bash
# test-tp-task.sh — fixture-based tests for libexec/tp-task.
#
# Creates a temp directory with fixture task files, runs CLI subcommands
# against it, asserts expected state transitions.
#
# The fixtures deliberately drive the CLI through the LEGACY ARACHNE_* spellings
# throughout, so this whole suite doubles as the compatibility guarantee: if
# lib/config.sh ever stopped promoting a legacy name onto its canonical
# TASKPUMP_* twin, these 177 assertions would be the ones to notice. The
# canonical spellings, and the equivalence of the two, are covered in the
# dual-invocation section near the end.
#
# Run: ./tests/test-tp-task.sh
# Exit non-zero on any failure; prints a PASS/FAIL line per test.

set -euo pipefail

# CDPATH= guards against a caller's exported CDPATH making `cd` to the relative
# dirname echo the target dir into the command substitution (corrupts SCRIPT_DIR).
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CLI="$TP_ROOT/libexec/tp-task"

# Hermeticity: the shared prologue ignores any taskpump.conf in the repo this
# suite happens to run from (a leaked conf reconfigures every fixture
# invocation below) and scrubs the pump-exported TASKPUMP_*/TP_*/ARACHNE_*
# environment (issue #18 — this suite configures itself in the legacy
# spellings, which an inherited canonical twin would silently outrank). The
# dual-invocation section is the one part of this suite that TESTS discovery,
# and it opts back in per-invocation with TASKPUMP_NO_CONF=0. run-all.sh
# sources the same prologue; this one covers standalone runs.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

# ── Environment hermeticity ──────────────────────────────────────────────────
# Every config key tp-task reads, by suffix. Both spellings of each are cleared
# from the environment before any fixture is set up, and TP_ENV_UNSET carries
# the `env -u` arguments that re-establish that clean slate for a subshell.
#
# Clearing BOTH spellings is the load-bearing part. lib/config.sh promotes in
# both directions and gives the canonical TASKPUMP_X precedence when the
# environment carries both — so an operator with TASKPUMP_TASKS_DIR exported
# would silently outrank every ARACHNE_TASKS_DIR this suite sets, and the tests
# would run against their real ledger. For the same reason `env -u ARACHNE_X`
# alone cannot isolate the default-resolution cases below: the canonical twin
# has to go too, or it simply takes over from the name that was unset.
TP_CONFIG_SUFFIXES=(
  TASKS_DIR TASK_OUT CODE_REPO TASK_PUSH PUSH TASK_NOCOMMIT TASK_DEBUG
  LEDGER_PROBE COMMITTER_NAME COMMITTER_EMAIL ID_PATTERN PHASE_SIGIL
  TURN_BUDGET_DEFAULT FAILURE_LIMIT CLAIM_STALE_HOURS LOCK_WAIT LOCK_NAME
  PUSH_RETRIES PROG_NAME CONFIG
)
TP_ENV_UNSET=()
for _suffix in "${TP_CONFIG_SUFFIXES[@]}"; do
  TP_ENV_UNSET+=(-u "ARACHNE_$_suffix" -u "TASKPUMP_$_suffix")
  unset "ARACHNE_$_suffix" "TASKPUMP_$_suffix" 2>/dev/null || true
done
unset _suffix

PASS=0
FAIL=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAIL=$((FAIL + 1))
}

pass() {
  printf 'PASS: %s\n' "$*"
  PASS=$((PASS + 1))
}

# Write a fixture task file.
# Args: <dir> <id> <phase> <status> <title> [claimed_by] [blockers_csv]
make_task() {
  local dir=$1 id=$2 phase=$3 status=$4 title=$5
  local claimed_by=${6:-null}
  local blockers_csv=${7:-}
  local blockers_yaml="[]"
  if [[ -n "$blockers_csv" ]]; then
    blockers_yaml="[$(printf '%s' "$blockers_csv" | sed 's/,/, /g')]"
  fi
  local cb_yaml="null"
  [[ "$claimed_by" != "null" ]] && cb_yaml="\"$claimed_by\""
  cat >| "$dir/$id.md" <<EOF
---
id: $id
phase: $phase
title: $title
status: $status
claimed_by: $cb_yaml
claimed_at: null
turn_budget_remaining: null
consecutive_failed_iterations: 0
blockers: $blockers_yaml
completed_by_commits: []
milestone: milestone/$(echo "$phase" | tr 'A-Z' 'a-z')
files: []
created: 2026-04-17
---

# $id — $title

## Acceptance criteria
- Test fixture.
EOF
}

# Assert frontmatter field equals expected value.
# Args: <file> <yq-expr> <expected>
assert_fm() {
  local file=$1 expr=$2 expected=$3
  local actual
  actual=$(yq --front-matter=extract "$expr" "$file")
  if [[ "$actual" == "$expected" ]]; then
    pass "$file: $expr == $expected"
  else
    fail "$file: $expr expected '$expected' got '$actual'"
  fi
}

# ── Setup ─────────────────────────────────────────────────────────────────────
# Use two separate git repos to mirror production (code repo + tasks submodule).
# Sharing a single repo would conflate task-state commits with "productive code
# work" in the heartbeat logic.
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

CODE_REPO="$TMPDIR_TEST/code"
TASKS_REPO="$TMPDIR_TEST/ops"
TASKS="$TASKS_REPO/task-loop/tasks"
mkdir -p "$CODE_REPO" "$TASKS"
git -C "$CODE_REPO" init -q
git -C "$CODE_REPO" -c user.name=test -c user.email=t@e commit --allow-empty -q -m "init code"
git -C "$TASKS_REPO" init -q
git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit --allow-empty -q -m "init ops"

export ARACHNE_TASKS_DIR="$TASKS"
export ARACHNE_TASK_OUT="$TASKS_REPO/task-loop/.next-task"
export ARACHNE_CODE_REPO="$CODE_REPO"
export ARACHNE_TASK_PUSH=0

# Reference pins (G1.2): this suite is the Arachne-shaped half of the pair —
# test-tp-task-generic.sh drives a deliberately different shape. Its F grammar
# used to arrive silently through the tools' baked defaults; the v0.1.0 flips
# (G1.6) retire those defaults, so the shape is pinned here explicitly, with
# the same values examples/arachne.conf pins for the reference consumer. The
# legacy spellings, deliberately, like every other key this suite sets. The
# TP_ENV_UNSET cases below still clear these: what those cases exercise is
# resolution mechanics, with the probe re-pinned per invocation.
export ARACHNE_ID_PATTERN='^F[0-9]+(\.[0-9]+)?$'
export ARACHNE_PHASE_SIGIL=F

# Fixtures:
#   F17.1 — status=done (a satisfied blocker)
#   F17.2 — open, no blockers → eligible
#   F17.3 — open, blocked-by F17.4 (F17.4 is open → not eligible)
#   F17.4 — open, no blockers → eligible, but later than F17.2
#   F17.5 — in_progress, claimed_by feat/other → visible via list but not via next
#   F17.6 — open, blocked-by F17.1 (done) → eligible (dep satisfied)
#   F17.7 — blocked (explicit status) → not eligible
#   F15.11 — open, no blockers, higher phase number than F17 → should lose ordering
make_task "$TASKS" F17.1 F17 done "First trigger task"
make_task "$TASKS" F17.2 F17 open "Second trigger task"
make_task "$TASKS" F17.3 F17 open "Third depends on F17.4" null "F17.4"
make_task "$TASKS" F17.4 F17 open "Fourth trigger task"
make_task "$TASKS" F17.5 F17 in_progress "Fifth (claimed by other)" "feat/other"
make_task "$TASKS" F17.6 F17 open "Sixth depends on F17.1" null "F17.1"
make_task "$TASKS" F17.7 F17 blocked "Seventh is blocked"
make_task "$TASKS" F15.11 F15 open "Flow library reset"

# ── Test 1: next picks the lowest-phase lowest-number eligible task ──────────
echo
echo "--- Test 1: next ordering ---"
if ! "$CLI" next --branch feat/mine >/dev/null; then
  fail "next returned non-zero"
else
  got=$(jq -r '.id' < "$ARACHNE_TASK_OUT")
  if [[ "$got" == "F15.11" ]]; then
    pass "next picked F15.11 (lowest phase)"
  else
    fail "next picked '$got'; expected F15.11"
  fi
fi

# ── Test 1b: --phase scopes next to one epic (ignores lower-phase tasks) ──────
# Mirrors the F51 bug: plain next returns the global-lowest-phase task
# (F15.11), but a parallel worktree scoped to one epic must stay in-epic.
echo
echo "--- Test 1b: next --phase scoping ---"
if ! "$CLI" next --branch feat/mine --phase F17 >/dev/null; then
  fail "next --phase F17 returned non-zero"
else
  got=$(jq -r '.id' < "$ARACHNE_TASK_OUT")
  if [[ "$got" == "F17.2" ]]; then
    pass "next --phase F17 picked F17.2 (lower-phase F15.11 correctly ignored)"
  else
    fail "next --phase F17 picked '$got'; expected F17.2"
  fi
fi
# Bare-number form normalises to the same scope.
"$CLI" next --branch feat/mine --phase 17 >/dev/null
got=$(jq -r '.id' < "$ARACHNE_TASK_OUT")
[[ "$got" == "F17.2" ]] && pass "next --phase 17 normalises to F17 (got F17.2)" \
  || fail "next --phase 17 picked '$got'; expected F17.2"
# A different epic returns that epic's task.
"$CLI" next --branch feat/mine --phase F15 >/dev/null
got=$(jq -r '.id' < "$ARACHNE_TASK_OUT")
[[ "$got" == "F15.11" ]] && pass "next --phase F15 picked F15.11" \
  || fail "next --phase F15 picked '$got'; expected F15.11"

# ── Test 2: after F15.11 claimed, next picks F17.2 (not blocked F17.3) ───────
echo
echo "--- Test 2: claim + next advances ---"
"$CLI" claim F15.11 --branch feat/mine --turns 10 >/dev/null
assert_fm "$TASKS/F15.11.md" '.status' 'in_progress'
assert_fm "$TASKS/F15.11.md" '.claimed_by' 'feat/mine'
assert_fm "$TASKS/F15.11.md" '.turn_budget_remaining' '10'

if ! "$CLI" next --branch feat/mine >/dev/null; then
  fail "next returned non-zero after claim"
else
  got=$(jq -r '.id' < "$ARACHNE_TASK_OUT")
  if [[ "$got" == "F17.2" ]]; then
    pass "next picked F17.2 (F17.3 correctly skipped due to F17.4 blocker)"
  else
    fail "next picked '$got'; expected F17.2"
  fi
fi

# ── Test 3: F17.5 (claimed by other) is not picked ───────────────────────────
echo
echo "--- Test 3: next skips tasks claimed by other branches ---"
# Claim all the in-between tasks to force next to pick F17.5 if it's visible.
"$CLI" claim F17.2 --branch feat/mine --turns 10 >/dev/null
# Also need to get F17.3 (blocked) and F17.4 out of the way.
# We'll claim F17.4 so F17.3's blocker still isn't done; should stay blocked.
"$CLI" claim F17.4 --branch feat/mine --turns 10 >/dev/null
# F17.6's blocker F17.1 is done, so it's eligible.
if ! "$CLI" next --branch feat/mine >/dev/null; then
  fail "next returned non-zero"
else
  got=$(jq -r '.id' < "$ARACHNE_TASK_OUT")
  # F17.6 should surface (its dep F17.1 is done); F17.5 should NOT (claimed by other)
  if [[ "$got" == "F17.6" ]]; then
    pass "next picked F17.6 (F17.5 correctly skipped — claimed by other branch)"
  else
    fail "next picked '$got'; expected F17.6"
  fi
fi

# ── Test 4: complete transitions a task to done + records commits ────────────
echo
echo "--- Test 4: complete ---"
echo "Shipped F15.11 via commits deadbeef and cafebabe." | \
  "$CLI" complete F15.11 --commits "deadbeef,cafebabe" >/dev/null
assert_fm "$TASKS/F15.11.md" '.status' 'done'
assert_fm "$TASKS/F15.11.md" '.claimed_by' 'null'
assert_fm "$TASKS/F15.11.md" '.completed_by_commits[0]' 'deadbeef'
assert_fm "$TASKS/F15.11.md" '.completed_by_commits[1]' 'cafebabe'
if grep -q "Completion notes" "$TASKS/F15.11.md" && grep -q "Shipped F15.11" "$TASKS/F15.11.md"; then
  pass "F15.11 completion notes appended to body"
else
  fail "F15.11 completion notes missing from body"
fi

# ── Test 5: block transitions a task to blocked + records reason ─────────────
echo
echo "--- Test 5: block ---"
"$CLI" block F17.4 --reason "waiting on external API spec" >/dev/null
assert_fm "$TASKS/F17.4.md" '.status' 'blocked'
assert_fm "$TASKS/F17.4.md" '.claimed_by' 'null'
assert_fm "$TASKS/F17.4.md" '.blocked_reason' 'waiting on external API spec'

# ── Test 6: heartbeat mechanics ──────────────────────────────────────────────
echo
echo "--- Test 6: heartbeat ---"
"$CLI" heartbeat F17.2 --start >/dev/null
# Simulate a productive code commit (touches anything)
touch "$CODE_REPO/dummy.rs"
git -C "$CODE_REPO" add dummy.rs
git -C "$CODE_REPO" -c user.name=test -c user.email=t@e commit -q -m "productive work"
"$CLI" heartbeat F17.2 --end >/dev/null
assert_fm "$TASKS/F17.2.md" '.turn_budget_remaining' '9'
assert_fm "$TASKS/F17.2.md" '.consecutive_failed_iterations' '0'

# Now a non-productive iteration (no new commits)
"$CLI" heartbeat F17.2 --start >/dev/null
"$CLI" heartbeat F17.2 --end >/dev/null
assert_fm "$TASKS/F17.2.md" '.turn_budget_remaining' '8'
assert_fm "$TASKS/F17.2.md" '.consecutive_failed_iterations' '1'

# ── Test 7: scrub unclaims tasks with budget=0 ───────────────────────────────
echo
echo "--- Test 7: scrub (budget exhausted) ---"
# Claim a fresh task with turns=1; burn it to 0 via two heartbeat ends.
make_task "$TASKS" F18.1 F18 open "Scrub-test task"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add scrub fixture" || true
"$CLI" claim F18.1 --branch feat/mine --turns 1 >/dev/null
"$CLI" heartbeat F18.1 --start >/dev/null
"$CLI" heartbeat F18.1 --end >/dev/null
assert_fm "$TASKS/F18.1.md" '.turn_budget_remaining' '0'
"$CLI" scrub >/dev/null
assert_fm "$TASKS/F18.1.md" '.status' 'needs-review'
assert_fm "$TASKS/F18.1.md" '.claimed_by' 'null'

# ── Test 8: scrub (consecutive failures) ─────────────────────────────────────
echo
echo "--- Test 8: scrub (consecutive failures) ---"
make_task "$TASKS" F18.2 F18 open "Stuck-test task"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add stuck fixture" || true
"$CLI" claim F18.2 --branch feat/mine --turns 100 >/dev/null
for i in 1 2 3; do
  "$CLI" heartbeat F18.2 --start >/dev/null
  "$CLI" heartbeat F18.2 --end >/dev/null
done
assert_fm "$TASKS/F18.2.md" '.consecutive_failed_iterations' '3'
"$CLI" scrub >/dev/null
assert_fm "$TASKS/F18.2.md" '.status' 'stuck'
assert_fm "$TASKS/F18.2.md" '.claimed_by' 'null'

# ── Test 9: release returns a claim to status=open ───────────────────────────
echo
echo "--- Test 9: release ---"
make_task "$TASKS" F18.3 F18 open "Release-test task"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add release fixture" || true
"$CLI" claim F18.3 --branch feat/mine --turns 25 >/dev/null
assert_fm "$TASKS/F18.3.md" '.status' 'in_progress'
assert_fm "$TASKS/F18.3.md" '.claimed_by' 'feat/mine'
"$CLI" release F18.3 --reason "wrong scope for this iteration" >/dev/null
assert_fm "$TASKS/F18.3.md" '.status' 'open'
assert_fm "$TASKS/F18.3.md" '.claimed_by' 'null'
assert_fm "$TASKS/F18.3.md" '.turn_budget_remaining' 'null'
if grep -q "Released" "$TASKS/F18.3.md" && grep -q "wrong scope for this iteration" "$TASKS/F18.3.md"; then
  pass "F18.3 release reason appended to body"
else
  fail "F18.3 release reason missing from body"
fi
# Cannot release an open task.
if "$CLI" release F18.3 --reason "second try" >/dev/null 2>&1; then
  fail "release should reject already-open task"
else
  pass "release rejects task with status != in_progress"
fi
# Reason is required.
"$CLI" claim F18.3 --branch feat/mine --turns 25 >/dev/null
if "$CLI" release F18.3 >/dev/null 2>&1; then
  fail "release should require --reason"
else
  pass "release requires --reason"
fi

# ── Test 9b: needs-review flags a live claim for human inspection ─────────────
# Sanctioned setter for status=needs-review (the pump uses it to quarantine a
# phase whose auto/trunk merge conflicted). Records the reason in scrub_reason so
# monitors surface it like a scrub-driven quarantine.
echo
echo "--- Test 9b: needs-review ---"
make_task "$TASKS" F18.4 F18 open "Needs-review-test task"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add needs-review fixture" || true
"$CLI" claim F18.4 --branch feat/mine --turns 25 >/dev/null
"$CLI" needs-review F18.4 --reason "auto/trunk merge conflicted" >/dev/null
assert_fm "$TASKS/F18.4.md" '.status' 'needs-review'
assert_fm "$TASKS/F18.4.md" '.claimed_by' 'null'
assert_fm "$TASKS/F18.4.md" '.scrub_reason' 'auto/trunk merge conflicted'
if grep -q "Needs review" "$TASKS/F18.4.md" && grep -q "auto/trunk merge conflicted" "$TASKS/F18.4.md"; then
  pass "F18.4 needs-review reason appended to body"
else
  fail "F18.4 needs-review reason missing from body"
fi
# Reason is required.
if "$CLI" needs-review F18.4 >/dev/null 2>&1; then
  fail "needs-review should require --reason"
else
  pass "needs-review requires --reason"
fi

# ── Test 9c: reopen returns a blocked task to status=open ─────────────────────
# Distinct from release (which relinquishes a LIVE claim on an in_progress task):
# a blocked task carries no claim. Use reopen when a blocker turns out to have
# been a transient/environment issue rather than a genuine feature gap.
echo
echo "--- Test 9c: reopen ---"
make_task "$TASKS" F18.5 F18 open "Reopen-test task"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add reopen fixture" || true
"$CLI" block F18.5 --reason "waiting on flaky external dep" >/dev/null
assert_fm "$TASKS/F18.5.md" '.status' 'blocked'
assert_fm "$TASKS/F18.5.md" '.blocked_reason' 'waiting on flaky external dep'
"$CLI" reopen F18.5 --reason "dep was transient; re-queueing" >/dev/null
assert_fm "$TASKS/F18.5.md" '.status' 'open'
assert_fm "$TASKS/F18.5.md" '.claimed_by' 'null'
assert_fm "$TASKS/F18.5.md" '.blocked_reason' 'null'
assert_fm "$TASKS/F18.5.md" '.blocked_at' 'null'
if grep -q "Reopened" "$TASKS/F18.5.md" && grep -q "dep was transient" "$TASKS/F18.5.md"; then
  pass "F18.5 reopen reason appended to body"
else
  fail "F18.5 reopen reason missing from body"
fi
# Cannot reopen a non-blocked task (it is now open).
if "$CLI" reopen F18.5 --reason "second try" >/dev/null 2>&1; then
  fail "reopen should reject a task whose status != blocked"
else
  pass "reopen rejects task with status != blocked"
fi
# Reason is required.
"$CLI" block F18.5 --reason "re-block for the reason test" >/dev/null
if "$CLI" reopen F18.5 >/dev/null 2>&1; then
  fail "reopen should require --reason"
else
  pass "reopen requires --reason"
fi

# ── Test 10: heartbeat lenient+alarm — ambiguous attribution refused ─────────
echo
echo "--- Test 10: heartbeat ambiguous productivity ---"
# Two tasks both list shared.rs in their files. F19.1 claims first, F19.2
# claims second. A commit touches shared.rs while both are in_progress.
# Heartbeat-end on F19.1 should refuse to credit (productive=0) and warn,
# because F19.2 also matches the same file.
cat >| "$TASKS/F19.1.md" <<'EOF'
---
id: F19.1
phase: F19
title: First task with shared file
status: open
claimed_by: null
claimed_at: null
turn_budget_remaining: null
consecutive_failed_iterations: 0
blockers: []
completed_by_commits: []
milestone: milestone/f19
files:
  - shared.rs
created: 2026-04-28
---

# F19.1 — fixture
EOF
cat >| "$TASKS/F19.2.md" <<'EOF'
---
id: F19.2
phase: F19
title: Second task with shared file
status: open
claimed_by: null
claimed_at: null
turn_budget_remaining: null
consecutive_failed_iterations: 0
blockers: []
completed_by_commits: []
milestone: milestone/f19
files:
  - shared.rs
created: 2026-04-28
---

# F19.2 — fixture
EOF
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add ambiguity fixtures" || true
"$CLI" claim F19.1 --branch feat/mine --turns 10 >/dev/null
"$CLI" claim F19.2 --branch feat/mine --turns 10 >/dev/null
"$CLI" heartbeat F19.1 --start >/dev/null
"$CLI" heartbeat F19.2 --start >/dev/null
echo "fn x() {}" >| "$CODE_REPO/shared.rs"
git -C "$CODE_REPO" add shared.rs
git -C "$CODE_REPO" -c user.name=test -c user.email=t@e commit -q -m "touch shared.rs"
ALARM_OUT=$("$CLI" heartbeat F19.1 --end 2>&1 1>/dev/null || true)
if printf '%s' "$ALARM_OUT" | grep -q "WARNING: heartbeat F19.1 productivity ambiguous"; then
  pass "ambiguous-productivity WARNING emitted on stderr"
else
  fail "expected WARNING on stderr; got: $ALARM_OUT"
fi
# Productivity should NOT be credited; failure counter should increment.
assert_fm "$TASKS/F19.1.md" '.consecutive_failed_iterations' '1'

# Now make F19.2 not in_progress (release it). Re-do the heartbeat cycle on
# F19.1; since no other in_progress task overlaps shared.rs anymore, the
# next productive commit should credit cleanly.
"$CLI" release F19.2 --reason "test cleanup" >/dev/null
"$CLI" heartbeat F19.1 --start >/dev/null
echo "fn y() {}" >| "$CODE_REPO/shared.rs"
git -C "$CODE_REPO" add shared.rs
git -C "$CODE_REPO" -c user.name=test -c user.email=t@e commit -q -m "second touch shared.rs"
"$CLI" heartbeat F19.1 --end 2>/dev/null
# consecutive_failed_iterations should reset to 0 (productive=1 again).
assert_fm "$TASKS/F19.1.md" '.consecutive_failed_iterations' '0'

# ── Test 11: ready — frontier + phase range + cross-phase blocker ────────────
# Two phases (F30, F31) with a CROSS-PHASE blocker: F31.1 blocks on F30.1.
# Exercises the keep-acquiring frontier, --count's open-regardless-of-blocker
# semantics, range parsing, single-phase aliasing, and the next == ready[0] tie.
echo
echo "--- Test 11: ready (frontier, range, cross-phase blocker) ---"
make_task "$TASKS" F30.1 F30 open "Range root (no blockers)"
make_task "$TASKS" F30.2 F30 open "Depends on F30.1" null "F30.1"
make_task "$TASKS" F31.1 F31 open "Cross-phase depends on F30.1" null "F30.1"
make_task "$TASKS" F31.2 F31 done "Already done in range"
make_task "$TASKS" F32.1 F32 open "Out-of-range open task"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add ready fixtures" || true

# 11a: --count = open tasks in range regardless of blocker state.
#   F30.1, F30.2, F31.1 are open (F30.2/F31.1 blocked-by-incomplete still count);
#   F31.2 is done (excluded); F32.1 is out of range.
got=$("$CLI" ready --phases F30..F31 --count)
[[ "$got" == "3" ]] && pass "ready --count = 3 (open in range, blocker state ignored)" \
  || fail "ready --count expected 3 got '$got'"

# 11b: frontier (eligible) before F30.1 done = just F30.1.
got=$("$CLI" ready --phases F30..F31 --json | jq -r '[.[].id] | join(",")')
[[ "$got" == "F30.1" ]] && pass "ready --json frontier = F30.1 (blocked tasks excluded)" \
  || fail "ready --json frontier expected 'F30.1' got '$got'"

# 11c: complete F30.1 → both dependents become eligible, in phase order.
echo "done" | "$CLI" complete F30.1 >/dev/null
got=$("$CLI" ready --phases F30..F31 --json | jq -r '[.[].id] | join(",")')
[[ "$got" == "F30.2,F31.1" ]] && pass "ready frontier grows after blocker clears (F30.2,F31.1 in phase order)" \
  || fail "ready frontier after F30.1 done expected 'F30.2,F31.1' got '$got'"

# 11c2: --count now 2 (F30.1 done; F30.2,F31.1 still open).
got=$("$CLI" ready --phases F30..F31 --count)
[[ "$got" == "2" ]] && pass "ready --count drops to 2 after F30.1 done" \
  || fail "ready --count after F30.1 done expected 2 got '$got'"

# 11d: single --phase F30 behaves like a one-phase range.
got=$("$CLI" ready --phase F30 --json | jq -r '[.[].id] | join(",")')
[[ "$got" == "F30.2" ]] && pass "ready --phase F30 scopes to one phase (F30.2)" \
  || fail "ready --phase F30 expected 'F30.2' got '$got'"

# 11e: next --phase returns ready --phase's first element.
"$CLI" next --branch feat/mine --phase F30 >/dev/null
nxt=$(jq -r '.id' < "$ARACHNE_TASK_OUT")
rdy0=$("$CLI" ready --phase F30 --json | jq -r '.[0].id')
[[ "$nxt" == "$rdy0" ]] && pass "next --phase F30 == ready --phase F30 first element ($nxt)" \
  || fail "next ($nxt) != ready[0] ($rdy0)"

# 11f: claimed-by-other is excluded from the frontier (like next).
"$CLI" claim F30.2 --branch feat/other --turns 5 >/dev/null
got=$("$CLI" ready --phases F30..F31 --json | jq -r '[.[].id] | join(",")')
[[ "$got" == "F31.1" ]] && pass "ready frontier excludes task claimed by other branch" \
  || fail "ready frontier after F30.2 claimed-by-other expected 'F31.1' got '$got'"

# ── Test 12: ready --count-eligible + the stall fixture (open>0, eligible==0) ──
# The gap Test 11 never covered: a range where open work EXISTS but NOTHING is
# eligible to launch (the C-2 stall signature). Exercises --count-eligible's
# frontier semantics, its --branch sensitivity, the drain-vs-frontier divergence,
# and --count's precedence when both flags are passed.
echo
echo "--- Test 12: ready --count-eligible + stall visibility ---"

# 12a (AC7 mirror): one root + two dependents (one cross-phase). Only the root is
# eligible until it completes, then the whole frontier lifts.
make_task "$TASKS" F33.1 F33 open "Frontier root (no blockers)"
make_task "$TASKS" F33.2 F33 open "Depends on F33.1" null "F33.1"
make_task "$TASKS" F34.1 F34 open "Cross-phase depends on F33.1" null "F33.1"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add count-eligible fixtures" || true

got=$("$CLI" ready --phases F33..F34 --count-eligible)
[[ "$got" == "1" ]] && pass "ready --count-eligible = 1 (only the unblocked root)" \
  || fail "ready --count-eligible expected 1 got '$got'"
got=$("$CLI" ready --phases F33..F34 --count)
[[ "$got" == "3" ]] && pass "ready --count = 3 (all open; blockers ignored)" \
  || fail "ready --count expected 3 got '$got'"

echo "done" | "$CLI" complete F33.1 >/dev/null
got=$("$CLI" ready --phases F33..F34 --count-eligible)
[[ "$got" == "2" ]] && pass "ready --count-eligible = 2 after root completes (frontier lifts)" \
  || fail "ready --count-eligible after F33.1 done expected 2 got '$got'"
got=$("$CLI" ready --phases F33..F34 --count)
[[ "$got" == "2" ]] && pass "ready --count = 2 after root completes (F33.1 now done)" \
  || fail "ready --count after F33.1 done expected 2 got '$got'"

# 12b (THE STALL): all open tasks in range are blocked by an out-of-range,
# not-yet-done task → open-in-range > 0 but eligible-frontier == 0. This is the
# exact divergence (cross-phase blocker unsatisfied) that masked the live stall.
make_task "$TASKS" F36.1 F36 open "Out-of-range root blocker"
make_task "$TASKS" F35.1 F35 open "Stalled by out-of-range F36.1" null "F36.1"
make_task "$TASKS" F35.2 F35 open "Also stalled by out-of-range F36.1" null "F36.1"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add stall fixtures" || true

got=$("$CLI" ready --phases F35 --count)
[[ "$got" == "2" ]] && pass "stall: ready --count = 2 (open work exists in range)" \
  || fail "stall: ready --count expected 2 got '$got'"
got=$("$CLI" ready --phases F35 --count-eligible)
[[ "$got" == "0" ]] && pass "stall: ready --count-eligible = 0 (nothing launchable — open>0, eligible==0)" \
  || fail "stall: ready --count-eligible expected 0 got '$got'"

# Clearing the cross-phase blocker lifts the stalled frontier.
echo "done" | "$CLI" complete F36.1 >/dev/null
got=$("$CLI" ready --phases F35 --count-eligible)
[[ "$got" == "2" ]] && pass "stall clears: ready --count-eligible = 2 once out-of-range blocker done" \
  || fail "stall clears: ready --count-eligible expected 2 got '$got'"

# 12c: --count-eligible respects --branch (claimed-by-other is excluded), while
# --count ignores claim state entirely. An open task claimed by another branch is
# the orphaned-claim flavour of a stall.
make_task "$TASKS" F37.1 F37 open "Open but claimed by another branch" "feat/other"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add branch-sensitivity fixture" || true

got=$("$CLI" ready --phases F37 --count-eligible --branch feat/mine)
[[ "$got" == "0" ]] && pass "ready --count-eligible excludes task claimed by another branch" \
  || fail "ready --count-eligible --branch feat/mine expected 0 got '$got'"
got=$("$CLI" ready --phases F37 --count-eligible --branch feat/other)
[[ "$got" == "1" ]] && pass "ready --count-eligible includes task claimed by the asking branch" \
  || fail "ready --count-eligible --branch feat/other expected 1 got '$got'"
got=$("$CLI" ready --phases F37 --count)
[[ "$got" == "1" ]] && pass "ready --count ignores claim state (counts the open task)" \
  || fail "ready --count --phases F37 expected 1 got '$got'"

# 12d: --count wins when both --count and --count-eligible are passed (drain test
# takes precedence, regardless of flag order).
got=$("$CLI" ready --phases F35 --count --count-eligible)
[[ "$got" == "2" ]] && pass "ready --count --count-eligible returns the --count value (drain wins)" \
  || fail "ready --count --count-eligible expected 2 got '$got'"
got=$("$CLI" ready --phases F35 --count-eligible --count)
[[ "$got" == "2" ]] && pass "ready --count-eligible --count returns the --count value (order-independent)" \
  || fail "ready --count-eligible --count expected 2 got '$got'"

# 12e: --count-eligible without a --phases filter is global and must not error.
got=$("$CLI" ready --count-eligible)
[[ "$got" =~ ^[0-9]+$ ]] && pass "ready --count-eligible (no --phases) returns a global integer ($got)" \
  || fail "ready --count-eligible without --phases expected an integer got '$got'"

# ── Test 13 (A): right-sized --turns 3 budget exhausts after 3 heartbeat cycles ─
# Mirrors the new entrypoint-parallel safety-net claim (--turns 3): three full
# start/end cycles drain the budget to 0, after which scrub reclaims the task.
echo
echo "--- Test 13 (A): right-sized --turns 3 budget → scrub needs-review ---"
make_task "$TASKS" F20.1 F20 open "Budget-3 scrub task"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add F20.1 fixture" || true
"$CLI" claim F20.1 --branch feat/mine --turns 3 >/dev/null
assert_fm "$TASKS/F20.1.md" '.turn_budget_remaining' '3'
"$CLI" heartbeat F20.1 --start >/dev/null; "$CLI" heartbeat F20.1 --end >/dev/null   # 3→2
assert_fm "$TASKS/F20.1.md" '.turn_budget_remaining' '2'
"$CLI" heartbeat F20.1 --start >/dev/null; "$CLI" heartbeat F20.1 --end >/dev/null   # 2→1
"$CLI" heartbeat F20.1 --start >/dev/null; "$CLI" heartbeat F20.1 --end >/dev/null   # 1→0
assert_fm "$TASKS/F20.1.md" '.turn_budget_remaining' '0'
"$CLI" scrub >/dev/null
assert_fm "$TASKS/F20.1.md" '.status' 'needs-review'
assert_fm "$TASKS/F20.1.md" '.claimed_by' 'null'
# budget<=0 is checked before failures>=3, so the reason is the budget one even
# though the three non-productive cycles also drove failures to 3.
assert_fm "$TASKS/F20.1.md" '.scrub_reason' 'turn_budget exhausted'

# ── Test 14 (B): last_heartbeat_ts written by both --start and --end ──────────
echo
echo "--- Test 14 (B): heartbeat writes last_heartbeat_ts ---"
make_task "$TASKS" F20.2 F20 open "Heartbeat-ts task"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add F20.2 fixture" || true
"$CLI" claim F20.2 --branch feat/mine --turns 3 >/dev/null
# Claim does not stamp a heartbeat, so the field is still null/absent.
assert_fm "$TASKS/F20.2.md" '.last_heartbeat_ts' 'null'
"$CLI" heartbeat F20.2 --start >/dev/null
ts_start=$(yq --front-matter=extract '.last_heartbeat_ts' "$TASKS/F20.2.md")
if [[ -n "$ts_start" && "$ts_start" != "null" ]]; then
  pass "heartbeat --start wrote last_heartbeat_ts ($ts_start)"
else
  fail "heartbeat --start did not write last_heartbeat_ts (got '$ts_start')"
fi
"$CLI" heartbeat F20.2 --end >/dev/null
ts_end=$(yq --front-matter=extract '.last_heartbeat_ts' "$TASKS/F20.2.md")
if [[ -n "$ts_end" && "$ts_end" != "null" ]]; then
  pass "heartbeat --end wrote last_heartbeat_ts ($ts_end)"
else
  fail "heartbeat --end did not write last_heartbeat_ts (got '$ts_end')"
fi

# ── Test 15 (C): staleness tripwire fires (STALE_HOURS=0 + ancient claimed_at) ─
# ARACHNE_CLAIM_STALE_HOURS=0 makes any past claim immediately stale, so the
# test needs no sleep. budget/failures are untripped, so the staleness branch
# is the one that fires.
echo
echo "--- Test 15 (C): staleness tripwire fires ---"
make_task "$TASKS" F20.3 F20 open "Staleness-fires task"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add F20.3 fixture" || true
"$CLI" claim F20.3 --branch feat/mine --turns 3 >/dev/null
yq -i --front-matter=process '.claimed_at = "2000-01-01T00:00:00Z"' "$TASKS/F20.3.md"
ARACHNE_CLAIM_STALE_HOURS=0 "$CLI" scrub >/dev/null
assert_fm "$TASKS/F20.3.md" '.status' 'needs-review'
assert_fm "$TASKS/F20.3.md" '.claimed_by' 'null'
assert_fm "$TASKS/F20.3.md" '.scrub_reason' 'heartbeat_staleness'

# ── Test 16 (D): staleness does NOT fire for a fresh claim (STALE_HOURS=24) ───
echo
echo "--- Test 16 (D): fresh claim is not reclaimed by staleness ---"
make_task "$TASKS" F20.4 F20 open "Staleness-fresh task"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add F20.4 fixture" || true
"$CLI" claim F20.4 --branch feat/mine --turns 3 >/dev/null
ARACHNE_CLAIM_STALE_HOURS=24 "$CLI" scrub >/dev/null
assert_fm "$TASKS/F20.4.md" '.status' 'in_progress'
assert_fm "$TASKS/F20.4.md" '.claimed_by' 'feat/mine'

# ── Test 17 (E): staleness uses claimed_at fallback when last_heartbeat_ts null ─
echo
echo "--- Test 17 (E): staleness falls back to claimed_at when ts is null ---"
make_task "$TASKS" F20.5 F20 open "Staleness-fallback task"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add F20.5 fixture" || true
"$CLI" claim F20.5 --branch feat/mine --turns 3 >/dev/null
# Explicit null last_heartbeat_ts forces the claimed_at fallback path.
yq -i --front-matter=process '.claimed_at = "2000-01-01T00:00:00Z" | .last_heartbeat_ts = null' "$TASKS/F20.5.md"
ARACHNE_CLAIM_STALE_HOURS=0 "$CLI" scrub >/dev/null
assert_fm "$TASKS/F20.5.md" '.status' 'needs-review'
assert_fm "$TASKS/F20.5.md" '.scrub_reason' 'heartbeat_staleness'

# ── Test 18: reopen a DONE task (falsely-done) sheds completion markers ───────
echo
echo "--- Test 18: reopen done -> open ---"
make_task "$TASKS" F21.1 F21 done "Falsely-done task"
yq -i --front-matter=process '.completed_at = "2026-01-01T00:00:00Z" | .completed_by_commits = ["abc1234","def5678"] | .wiring_deferred = true | .wiring_deferred_note = "no caller"' "$TASKS/F21.1.md"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add F21.1 fixture" || true
"$CLI" reopen F21.1 --reason "falsely-done: no production caller" >/dev/null
assert_fm "$TASKS/F21.1.md" '.status' 'open'
assert_fm "$TASKS/F21.1.md" '.completed_at' 'null'
assert_fm "$TASKS/F21.1.md" '.completed_by_commits' '[]'
assert_fm "$TASKS/F21.1.md" '.wiring_deferred' 'false'
if grep -q 'prior completion commits: abc1234,def5678' "$TASKS/F21.1.md"; then
  pass "reopen-from-done preserved prior commits in body note"
else
  fail "reopen-from-done did not record prior commits"
fi

# ── Test 19: defer marks wiring_deferred without changing status ──────────────
echo
echo "--- Test 19: defer ---"
make_task "$TASKS" F21.2 F21 done "Foundation-only task"
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add F21.2 fixture" || true
"$CLI" defer F21.2 --reason "offload not wired into state-store" >/dev/null
assert_fm "$TASKS/F21.2.md" '.status' 'done'
assert_fm "$TASKS/F21.2.md" '.wiring_deferred' 'true'
assert_fm "$TASKS/F21.2.md" '.wiring_deferred_note' 'offload not wired into state-store'
if "$CLI" defer F21.2 >/dev/null 2>&1; then fail "defer should require --reason"; else pass "defer requires --reason"; fi

# ── Test 20: complete --defer-wiring marks done + deferred ────────────────────
echo
echo "--- Test 20: complete --defer-wiring ---"
make_task "$TASKS" F21.3 F21 in_progress "Task completed with deferral" feat/mine
git -C "$TASKS_REPO" add -A; git -C "$TASKS_REPO" -c user.name=test -c user.email=t@e commit -q -m "add F21.3 fixture" || true
"$CLI" complete F21.3 --commits aaa1111 --defer-wiring "runtime caller left for follow-up" >/dev/null
assert_fm "$TASKS/F21.3.md" '.status' 'done'
assert_fm "$TASKS/F21.3.md" '.wiring_deferred' 'true'
assert_fm "$TASKS/F21.3.md" '.completed_by_commits[0]' 'aaa1111'

# ── Test 21: deferred lists both, --json is valid ────────────────────────────
echo
echo "--- Test 21: deferred lister ---"
deferred_out=$("$CLI" deferred)
if grep -q 'F21.2' <<<"$deferred_out" && grep -q 'F21.3' <<<"$deferred_out"; then
  pass "deferred lists both deferred tasks"
else
  fail "deferred missing a task: $deferred_out"
fi
if "$CLI" deferred --json | jq -e 'map(.id) | index("F21.2") and index("F21.3")' >/dev/null 2>&1; then
  pass "deferred --json is valid and contains both"
else
  fail "deferred --json invalid or incomplete"
fi

# ── Test 22: undefer clears the flag and drops the task from `deferred` ───────
echo
echo "--- Test 22: undefer ---"
if "$CLI" undefer F21.2 >/dev/null 2>&1; then
  fail "undefer should require --caller"
else
  pass "undefer requires --caller"
fi
"$CLI" undefer F21.2 --caller "state_store.rs:406 — F70.6 wired the persist path" >/dev/null
assert_fm "$TASKS/F21.2.md" '.wiring_deferred' 'false'
assert_fm "$TASKS/F21.2.md" '.status' 'done'
if grep -q 'Wiring landed' "$TASKS/F21.2.md"; then
  pass "undefer appends a 'Wiring landed' note with the caller evidence"
else
  fail "undefer did not append the caller evidence to the body"
fi
if "$CLI" deferred | grep -q 'F21.2'; then
  fail "undefer'd task still listed by deferred"
else
  pass "undefer'd task no longer collected by deferred"
fi
# Undeferring a task that was never deferred is an error, not a silent no-op —
# it would otherwise mask a typo'd id.
if "$CLI" undefer F21.2 --caller "x:1" >/dev/null 2>&1; then
  fail "undefer should reject a task whose wiring_deferred is not set"
else
  pass "undefer rejects a non-deferred task"
fi

# ── Workspace resolution ──────────────────────────────────────────────────────
# Every worktree carries its own copy of the CLI AND its own ops/ checkout.
# Invoking one workspace's copy of the CLI while standing in another must write
# to the workspace the caller is standing in, not the one the script lives in —
# otherwise a claim made from a worktree lands in the primary's ledger and both
# silently drift apart. These cases run the CLI with no ARACHNE_TASKS_DIR set,
# so they exercise the default-resolution path the rest of the suite overrides.
resolution_root_of() {
  # Print the tasks dir the CLI resolves when run from $1. TP_ENV_UNSET clears
  # both spellings of every key, so nothing the suite exported can pre-answer
  # the question; only the ledger probe is then re-pinned to the Arachne shape
  # these fixtures are built in (the examples/arachne.conf value — the shipped
  # default until G1.6 flips it to `tasks`). What these cases exercise is the
  # workspace-vs-script-root MECHANISM, not the probed path's default.
  ( cd "$1" && env "${TP_ENV_UNSET[@]}" \
      TASKPUMP_LEDGER_PROBE=ops/task-loop/tasks \
      ARACHNE_TASK_NOCOMMIT=1 "$2" resolve --tasks-dir 2>/dev/null )
}

WS_A="$TMPDIR_TEST/ws-a"
WS_B="$TMPDIR_TEST/ws-b"
# Each fake workspace is a self-contained TaskPump install, so the CLI's own root
# ($ws/libexec/..) really is $ws — the condition these cases are written against.
# Copies, not symlinks: the root comes from `readlink -f`, which would follow a
# symlink back to the real installation and defeat the whole fixture.
for ws in "$WS_A" "$WS_B"; do
  mkdir -p "$ws/libexec" "$ws/lib" "$ws/ops/task-loop/tasks"
  git -C "$ws" init -q
  cp "$CLI" "$ws/libexec/tp-task"
  # The whole lib, not a hand-picked file: "self-contained install" above is the
  # claim these fixtures make, and a workspace that carries the CLI but only
  # some of what it sources is not one. (Cherry-picking config.sh worked until
  # the CLI also needed pump-lib.sh for the branch-naming rule.)
  cp -R "$TP_ROOT/lib/." "$ws/lib/"
  chmod +x "$ws/libexec/tp-task"
  git -C "$ws" -c user.name=test -c user.email=t@e add -A
  git -C "$ws" -c user.name=test -c user.email=t@e commit -q -m "init $ws"
done

# Standing in workspace B but invoking workspace A's copy of the CLI: the
# ledger written must be B's. This is the regression — it used to resolve to A.
got=$(resolution_root_of "$WS_B" "$WS_A/libexec/tp-task")
if [[ "$got" == "$WS_B/ops/task-loop/tasks" ]]; then
  pass "cross-workspace invocation resolves to the caller's workspace"
else
  fail "cross-workspace invocation resolved to '$got', expected '$WS_B/ops/task-loop/tasks'"
fi

# Standing in its own workspace still resolves to itself.
got=$(resolution_root_of "$WS_A" "$WS_A/libexec/tp-task")
if [[ "$got" == "$WS_A/ops/task-loop/tasks" ]]; then
  pass "same-workspace invocation resolves to that workspace"
else
  fail "same-workspace invocation resolved to '$got', expected '$WS_A/ops/task-loop/tasks'"
fi

# Outside any git repo — and inside a git repo with no ops/ checkout — there is
# no caller workspace to prefer, so it must fall back to the script's own root
# rather than resolving to nothing.
NO_OPS="$TMPDIR_TEST/no-ops"
mkdir -p "$NO_OPS"
git -C "$NO_OPS" init -q
got=$(resolution_root_of "$NO_OPS" "$WS_A/libexec/tp-task")
if [[ "$got" == "$WS_A/ops/task-loop/tasks" ]]; then
  pass "git repo without an ops/ checkout falls back to the script's workspace"
else
  fail "no-ops fallback resolved to '$got', expected '$WS_A/ops/task-loop/tasks'"
fi

got=$(resolution_root_of "$TMPDIR_TEST" "$WS_A/libexec/tp-task")
if [[ "$got" == "$WS_A/ops/task-loop/tasks" ]]; then
  pass "outside any git repo falls back to the script's workspace"
else
  fail "non-repo fallback resolved to '$got', expected '$WS_A/ops/task-loop/tasks'"
fi

# ── The install-root fallback must not be a silent WRITE target ───────────────
# The fallback above is correct for the vendored layout and a silent wrong answer
# everywhere else, and it has produced one incident: `tp task create` in a fresh
# repository with no ledger wrote the task into TaskPump's OWN ledger, with a
# commit, and was caught only because that ledger happened to be under watch
# (2026-08-12). Both sides look fine afterwards — the operator's repository never
# learns it was ignored, and the installation's ledger silently grows a task from
# a project it has never heard of.
#
# So resolution keeps falling back (the cases above still pass, and `resolve`
# still answers), but a MUTATING command refuses when the fallback lands outside
# the caller's repository.
mutate_from() {  # mutate_from <cwd> <cli> <verb...> — a mutation with nothing pre-answered
  local dir=$1 cli=$2; shift 2
  ( cd "$dir" && env "${TP_ENV_UNSET[@]}" \
      TASKPUMP_LEDGER_PROBE=ops/task-loop/tasks \
      ARACHNE_TASK_NOCOMMIT=1 "$cli" "$@" 2>&1 )
}

# The incident shape exactly: a fresh git repo with no ledger, TaskPump installed
# somewhere else entirely.
INCIDENT="$TMPDIR_TEST/incident"
mkdir -p "$INCIDENT"
git -C "$INCIDENT" init -q
before=$(ls "$WS_A/ops/task-loop/tasks" | wc -l)
rc=0; out=$(mutate_from "$INCIDENT" "$WS_A/libexec/tp-task" create T99 --title "must not land") || rc=$?
[[ $rc -ne 0 ]] && pass "create in a ledger-less repo is refused" \
  || fail "create wrote somewhere on the incident shape (rc=$rc):\n$out"
[[ "$(ls "$WS_A/ops/task-loop/tasks" | wc -l)" -eq "$before" ]] \
  && pass "nothing was written to the installation's own ledger" \
  || fail "the refusal still wrote into $WS_A's ledger"
[[ ! -e "$INCIDENT/tasks" && ! -e "$INCIDENT/ops" ]] \
  && pass "nothing was written to the caller's repo either" \
  || fail "a ledger was invented in the caller's repo"

# The error has to be actionable, so it names what was probed, where resolution
# landed, and both fixes. An error that says only "no" sends the operator to the
# source.
grep -q "$INCIDENT" <<<"$out" && pass "the error names the repository it probed" \
  || fail "the error does not name the caller's repo:\n$out"
grep -q "$WS_A" <<<"$out" && pass "the error names where resolution landed" \
  || fail "the error does not name the install ledger:\n$out"
grep -q 'mkdir ops/task-loop/tasks' <<<"$out" && pass "the error offers the mkdir fix" \
  || fail "the error does not offer the mkdir fix:\n$out"
grep -q 'TASKPUMP_TASKS_DIR' <<<"$out" && pass "the error offers the explicit-dir fix" \
  || fail "the error does not offer the env fix:\n$out"

# Read-only commands keep working — `resolve` is the diagnostic the error points
# at, and an error that disables the tool you need to diagnose it is worse.
rc=0; got=$(mutate_from "$INCIDENT" "$WS_A/libexec/tp-task" resolve --tasks-dir) || rc=$?
[[ $rc -eq 0 && "$got" == "$WS_A/ops/task-loop/tasks" ]] \
  && pass "resolve still prints where resolution would land" \
  || fail "resolve was blocked too (rc=$rc): '$got'"

# The vendored layout is the reason the fallback exists, and it must stay silent:
# standing in the workspace whose install this is, the install root IS the
# caller's repo.
rc=0; out=$(mutate_from "$WS_A" "$WS_A/libexec/tp-task" create T98 --title "vendored is fine") || rc=$?
[[ $rc -eq 0 ]] && pass "the vendored layout still mutates without complaint" \
  || fail "the guard broke the vendored layout (rc=$rc):\n$out"
[[ -f "$WS_A/ops/task-loop/tasks/T98.md" ]] \
  && pass "the vendored write landed in its own ledger" \
  || fail "the vendored create wrote nowhere"
rm -f "$WS_A/ops/task-loop/tasks/T98.md"

# An explicit tasks dir is an answer, not a fallback: the caller said where the
# ledger is, so there is nothing to guess and nothing to refuse.
mkdir -p "$INCIDENT/elsewhere"
rc=0; out=$( cd "$INCIDENT" && env "${TP_ENV_UNSET[@]}" ARACHNE_TASK_NOCOMMIT=1 \
    TASKPUMP_TASKS_DIR="$INCIDENT/elsewhere" "$WS_A/libexec/tp-task" \
    create T97 --title "explicit is fine" 2>&1 ) || rc=$?
[[ $rc -eq 0 && -f "$INCIDENT/elsewhere/T97.md" ]] \
  && pass "an explicit TASKPUMP_TASKS_DIR is honoured without complaint" \
  || fail "the guard fired on an explicit tasks dir (rc=$rc):\n$out"

# An explicit ARACHNE_TASKS_DIR still wins over both.
got=$( cd "$WS_B" && ARACHNE_TASKS_DIR="$TASKS" ARACHNE_TASK_NOCOMMIT=1 \
        "$WS_A/libexec/tp-task" resolve --tasks-dir )
if [[ "$got" == "$TASKS" ]]; then
  pass "ARACHNE_TASKS_DIR overrides workspace resolution"
else
  fail "env override resolved to '$got', expected '$TASKS'"
fi

# The same rule, driven by a non-default TASKPUMP_LEDGER_PROBE. A workspace that
# keeps its ledger somewhere other than ops/task-loop/tasks must be recognised as
# carrying one — otherwise generalizing the probe would quietly reintroduce the
# wrong-ledger bug for every consumer that is not shaped like Arachne.
WS_C="$TMPDIR_TEST/ws-c"
mkdir -p "$WS_C/tasks"
git -C "$WS_C" init -q
got=$( cd "$WS_C" && env "${TP_ENV_UNSET[@]}" TASKPUMP_LEDGER_PROBE=tasks \
        ARACHNE_TASK_NOCOMMIT=1 "$WS_A/libexec/tp-task" resolve --tasks-dir )
if [[ "$got" == "$WS_C/tasks" ]]; then
  pass "a custom ledger probe resolves to the caller's workspace"
else
  fail "custom-probe resolution got '$got', expected '$WS_C/tasks'"
fi

# A DISCOVERED taskpump.conf marks its own directory as a workspace (G1.6): a
# subdirectory carrying a conf and the probed ledger owns its own ledger even
# when the enclosing worktree also answers the probe — the generic-project
# fixture's situation, sitting inside a repo whose root has a tasks/ of its own.
SUBWS="$WS_C/vendor/subproject"
mkdir -p "$SUBWS/tasks"
printf '# marks this directory as its own TaskPump workspace\n' >| "$SUBWS/taskpump.conf"
got=$( cd "$SUBWS" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 \
        TASKPUMP_LEDGER_PROBE=tasks ARACHNE_TASK_NOCOMMIT=1 \
        "$WS_A/libexec/tp-task" resolve --tasks-dir )
if [[ "$got" == "$SUBWS/tasks" ]]; then
  pass "a discovered conf anchors resolution to its own directory"
else
  fail "conf-anchored resolution got '$got', expected '$SUBWS/tasks'"
fi

# An EXPLICIT TASKPUMP_CONFIG is deliberate configuration, not a workspace
# marker: it may live anywhere (a suite's pins file), so it must never move the
# ledger to wherever the file happens to sit.
got=$( cd "$WS_C" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=1 \
        TASKPUMP_CONFIG="$SUBWS/taskpump.conf" TASKPUMP_LEDGER_PROBE=tasks \
        ARACHNE_TASK_NOCOMMIT=1 "$WS_A/libexec/tp-task" resolve --tasks-dir )
if [[ "$got" == "$WS_C/tasks" ]]; then
  pass "an explicit TASKPUMP_CONFIG does not anchor resolution to the file's directory"
else
  fail "explicit-config resolution got '$got', expected '$WS_C/tasks'"
fi

# And the negative: under the pinned ops/task-loop/tasks probe, that same
# workspace does NOT look like it carries a ledger, so resolution falls back to
# the script's workspace. This is what proves the probe is doing the deciding.
got=$(resolution_root_of "$WS_C" "$WS_A/libexec/tp-task")
if [[ "$got" == "$WS_A/ops/task-loop/tasks" ]]; then
  pass "the pinned probe does not match a differently-shaped workspace"
else
  fail "pinned-probe fallback got '$got', expected '$WS_A/ops/task-loop/tasks'"
fi

# ── title / blockers / create verbs ──────────────────────────────────────────
# These three exist so that retiring, re-pointing, and filing tasks never
# requires hand-editing frontmatter (a documented anti-pattern). Each fixture
# below is isolated in its own tasks dir so it cannot perturb the shared ones.
VERB_TASKS="$TMPDIR_TEST/verbs/task-loop/tasks"
mkdir -p "$VERB_TASKS"
git -C "$TMPDIR_TEST/verbs" init -q
git -C "$TMPDIR_TEST/verbs" -c user.name=test -c user.email=t@e commit --allow-empty -q -m "init verbs"

make_task "$VERB_TASKS" F90.1 F90 done "Done prerequisite"
make_task "$VERB_TASKS" F90.2 F90 open "Original title" null "F90.1"
make_task "$VERB_TASKS" F90.3 F90 open "Another task"

vcli() { ARACHNE_TASKS_DIR="$VERB_TASKS" ARACHNE_TASK_NOCOMMIT=1 "$CLI" "$@"; }

# title — read then set.
got=$(vcli title F90.2)
[[ "$got" == "Original title" ]] && pass "title reads the current title" \
  || fail "title read got '$got'"

vcli title F90.2 --set "Rewritten title" >/dev/null
assert_fm "$VERB_TASKS/F90.2.md" '.title' "Rewritten title"

# A title containing a colon must survive the round trip — bare YAML would break.
vcli title F90.2 --set "fix: colons: everywhere" >/dev/null
assert_fm "$VERB_TASKS/F90.2.md" '.title' "fix: colons: everywhere"

vcli title F90.2 --set "Original title" >/dev/null

if vcli title F90.2 --set "" 2>/dev/null; then
  fail "title --set accepted empty text"
else
  pass "title --set rejects empty text"
fi

# blockers — read, add, remove, set, clear.
got=$(vcli blockers F90.2)
[[ "$got" == "F90.1" ]] && pass "blockers reads the current list" \
  || fail "blockers read got '$got'"

vcli blockers F90.2 --add F90.3 >/dev/null
got=$(vcli blockers F90.2 | tr '\n' ',')
[[ "$got" == "F90.1,F90.3," ]] && pass "blockers --add appends" \
  || fail "blockers --add produced '$got'"

# Adding twice must not duplicate.
vcli blockers F90.2 --add F90.3 >/dev/null
got=$(vcli blockers F90.2 | wc -l | tr -d ' ')
[[ "$got" == "2" ]] && pass "blockers --add is idempotent" \
  || fail "blockers --add duplicated, list length $got"

vcli blockers F90.2 --remove F90.1 >/dev/null
got=$(vcli blockers F90.2 | tr '\n' ',')
[[ "$got" == "F90.3," ]] && pass "blockers --remove drops the id" \
  || fail "blockers --remove produced '$got'"

vcli blockers F90.2 --set "F90.1,F90.3" >/dev/null
got=$(vcli blockers F90.2 | tr '\n' ',')
[[ "$got" == "F90.1,F90.3," ]] && pass "blockers --set replaces the list" \
  || fail "blockers --set produced '$got'"

# Style is load-bearing, not cosmetic: lib/dag-layout.awk (the DAG renderer and
# the monitor's GRAPH tab) parses `blockers:` as a BLOCK sequence and
# special-cases only the empty `[]`. yq's natural output for a list rebuilt
# from JSON is FLOW style, which that parser reads as no blockers at all — so
# the task loses every edge and draws as a detached root with the *eligible*
# glyph while yq-based eligibility correctly holds it shut. Read-back through
# yq (every assertion above) cannot see the difference.
grep -qE '^  - F90\.1$' "$VERB_TASKS/F90.2.md" \
  && pass "blockers --set writes a BLOCK sequence (the only style the DAG renderer parses)" \
  || fail "blockers --set wrote a non-block style:\n$(grep -A3 '^blockers:' "$VERB_TASKS/F90.2.md")"

vcli blockers F90.2 --clear >/dev/null
got=$(vcli blockers F90.2)
[[ -z "$got" ]] && pass "blockers --clear empties the list" \
  || fail "blockers --clear left '$got'"
grep -qE '^blockers: \[\]$' "$VERB_TASKS/F90.2.md" \
  && pass "and --clear writes the empty flow form the renderer special-cases" \
  || fail "blockers --clear wrote an unparseable empty list:\n$(grep -A3 '^blockers:' "$VERB_TASKS/F90.2.md")"

# The whole point of validating: a typo'd blocker silently removes a task from
# the frontier forever, with no diagnostic anywhere.
if vcli blockers F90.2 --add F99.9 2>/dev/null; then
  fail "blockers --add accepted a nonexistent id"
else
  pass "blockers --add rejects a nonexistent id"
fi

if vcli blockers F90.2 --add F90.2 2>/dev/null; then
  fail "blockers --add accepted a self-blocker"
else
  pass "blockers --add rejects self-blocking"
fi

# A rejected mutation must not have partially written.
got=$(vcli blockers F90.2)
[[ -z "$got" ]] && pass "a rejected blockers mutation leaves the list untouched" \
  || fail "rejected mutation wrote '$got'"

# create — happy path, then each guard.
vcli create F90.10 --title "Newly filed task" --goal "Prove create works." \
  --files "crates/a/src/lib.rs,web/src/b.ts" --blockers "F90.1" >/dev/null
NEW="$VERB_TASKS/F90.10.md"
[[ -f "$NEW" ]] && pass "create writes the task file" || fail "create wrote no file"
assert_fm "$NEW" '.id' "F90.10"
assert_fm "$NEW" '.phase' "F90"
assert_fm "$NEW" '.status' "open"
assert_fm "$NEW" '.title' "Newly filed task"
assert_fm "$NEW" '.goal' "Prove create works."
assert_fm "$NEW" '.consecutive_failed_iterations' "0"
assert_fm "$NEW" '.blockers[0]' "F90.1"
assert_fm "$NEW" '.files[0]' "crates/a/src/lib.rs"
assert_fm "$NEW" '.files[1]' "web/src/b.ts"

# A freshly created task must be legible to the rest of the CLI, not just on disk.
got=$(vcli title F90.10)
[[ "$got" == "Newly filed task" ]] && pass "create output round-trips through title" \
  || fail "title on a created task got '$got'"

# F90.1 is done, so F90.10's blocker is satisfied and it should be eligible.
got=$(vcli ready --count-eligible)
[[ "$got" =~ ^[0-9]+$ ]] && pass "created task keeps ready parseable (got $got)" \
  || fail "ready --count-eligible returned '$got' after create"

if vcli create F90.10 --title "Duplicate" 2>/dev/null; then
  fail "create overwrote an existing task"
else
  pass "create refuses to overwrite an existing task"
fi

if vcli create 91.1 --title "Bad id" 2>/dev/null; then
  fail "create accepted a non-phase-anchored id"
else
  pass "create rejects a non-phase-anchored id"
fi

if vcli create F90.11 2>/dev/null; then
  fail "create accepted a missing --title"
else
  pass "create requires --title"
fi

if vcli create F90.12 --title "Bad blocker" --blockers "F99.9" 2>/dev/null; then
  fail "create accepted a nonexistent blocker"
else
  pass "create rejects a nonexistent blocker"
fi
[[ ! -f "$VERB_TASKS/F90.12.md" ]] && pass "create leaves no file behind when it rejects" \
  || fail "create wrote a file despite rejecting"

# ── Regression: YAML-hostile values must never produce an unparseable file ────
# A task file whose frontmatter yq cannot parse is read as empty by fm_get and
# silently vanishes from next/ready. F45.15 sat unreachable for nine weeks that
# way. Every scalar `create` writes must survive a value containing ": ".
echo
echo "--- YAML-hostile create values ---"

vcli create F90.20 --title "fix: colons: everywhere" --goal "goal: with a colon" \
  --milestone "2026-Q3: integration" --files "crates/a:b.rs,c.rs" --blockers "F90.1" >/dev/null
HOSTILE="$VERB_TASKS/F90.20.md"

if yq --front-matter=extract '.id' "$HOSTILE" >/dev/null 2>&1; then
  pass "create with colon-bearing values produces parseable frontmatter"
else
  fail "create with colon-bearing values produced UNPARSEABLE frontmatter"
fi
assert_fm "$HOSTILE" '.title' "fix: colons: everywhere"
assert_fm "$HOSTILE" '.goal' "goal: with a colon"
assert_fm "$HOSTILE" '.milestone' "2026-Q3: integration"
assert_fm "$HOSTILE" '.files[0]' "crates/a:b.rs"
assert_fm "$HOSTILE" '.phase' "F90"

# The created task must be reachable through the CLI, not merely on disk —
# that is the property that actually failed for F45.15.
got=$(vcli title F90.20)
[[ "$got" == "fix: colons: everywhere" ]] && pass "colon-bearing task is readable back through the CLI" \
  || fail "title on a colon-bearing task got '$got'"

# ── Regression: create and blockers must agree on list normalization ──────────
echo
echo "--- create/blockers normalization parity ---"

vcli create F90.21 --title "Dup blockers" --blockers "F90.1,F90.1, F90.3 " >/dev/null
got=$(yq --front-matter=extract '.blockers | length' "$VERB_TASKS/F90.21.md")
[[ "$got" == "2" ]] && pass "create --blockers de-duplicates like blockers --add" \
  || fail "create --blockers kept $got entries, expected 2 after dedup"
assert_fm "$VERB_TASKS/F90.21.md" '.blockers[1]' "F90.3"

if vcli create F90.22 --title "Self block" --blockers "F90.22" 2>/dev/null; then
  fail "create --blockers accepted a self-blocker"
else
  pass "create --blockers rejects self-blocking like blockers --add"
fi

# ── scrub reports unparseable frontmatter ────────────────────────────────────
# The failure this guards against is silence: fm_get swallows yq's error, so an
# unparseable task reads as having no id and no status, matches no filter, and
# never reaches the frontier. F45.15 was authored that way (an unquoted `goal:`
# containing a colon) and was invisible for nine weeks with nothing reporting it.
echo
echo "--- scrub: unparseable frontmatter ---"

SCRUB_TASKS="$TMPDIR_TEST/scrubyaml/task-loop/tasks"
mkdir -p "$SCRUB_TASKS"
git -C "$TMPDIR_TEST/scrubyaml" init -q
git -C "$TMPDIR_TEST/scrubyaml" -c user.name=test -c user.email=t@e commit --allow-empty -q -m init

make_task "$SCRUB_TASKS" F91.1 F91 open "Healthy task"

# Reproduce F45.15's exact shape: an unquoted scalar containing ": ".
cat >| "$SCRUB_TASKS/F91.2.md" <<'BROKEN'
---
id: F91.2
phase: F91
title: Broken task
status: open
goal: Verify the thing: a flow that reaches a block cannot do the other thing.
---

# F91.2 — Broken task
BROKEN

scrubcli() { ARACHNE_TASKS_DIR="$SCRUB_TASKS" ARACHNE_TASK_NOCOMMIT=1 "$CLI" "$@"; }

# Precondition: the broken file really is invisible to the frontier, so this
# test would still be meaningful if the reporting were removed.
got=$(scrubcli ready --count-eligible)
[[ "$got" == "1" ]] && pass "unparseable task is absent from the frontier (1 of 2 eligible)" \
  || fail "expected 1 eligible with one broken file, got '$got'"

out=$(scrubcli scrub 2>/dev/null) && scrub_rc=0 || scrub_rc=$?
if [[ "$out" == *"UNPARSEABLE"*"F91.2.md"* ]]; then
  pass "scrub names the unparseable file"
else
  fail "scrub did not report F91.2; output: '$out'"
fi
# Exit 3 specifically, not just non-zero: the pump keys off it to distinguish a
# corrupt ledger (name the paths) from scrub itself crashing (generic warning).
[[ "$scrub_rc" -eq 3 ]] && pass "scrub exits 3 when a file is unparseable" \
  || fail "expected exit 3 for an unparseable file, got $scrub_rc"

# The path must appear exactly once across stdout+stderr combined — entrypoint.sh
# runs `scrub 2>&1 | tee`, which double-reported every file when the diagnostic
# was written to both streams.
merged=$(scrubcli scrub 2>&1) || true
n=$(grep -c 'F91.2.md' <<<"$merged" || true)
[[ "$n" -eq 1 ]] && pass "unparseable path reported once under 2>&1 (no tee duplication)" \
  || fail "expected F91.2.md once in merged output, got $n: '$merged'"

# A file that parses but has no id is equally unreachable — no verb can name it.
# yq is perfectly happy with it, so the parse check alone would let it through.
rm "$SCRUB_TASKS/F91.2.md"
cat >| "$SCRUB_TASKS/F91.3.md" <<'NOID'
---
phase: F91
title: Task with no id
status: open
---

# F91.3 — no id
NOID
out=$(scrubcli scrub 2>/dev/null) && scrub_rc=0 || scrub_rc=$?
[[ "$out" == *"NO-ID"*"F91.3.md"* ]] && pass "scrub names a parseable file that has no id" \
  || fail "scrub did not report the id-less F91.3; output: '$out'"
[[ "$scrub_rc" -eq 3 ]] && pass "scrub exits 3 for an id-less file" \
  || fail "expected exit 3 for an id-less file, got $scrub_rc"

# A healthy ledger must stay quiet and exit 0, or the pump warns every tick.
rm "$SCRUB_TASKS/F91.3.md"
out=$(scrubcli scrub 2>&1) && scrub_rc=0 || scrub_rc=$?
[[ "$scrub_rc" -eq 0 ]] && pass "scrub exits 0 on a healthy ledger" \
  || fail "scrub exited $scrub_rc on a healthy ledger"
[[ "$out" != *"UNPARSEABLE"* && "$out" != *"NO-ID"* ]] && pass "scrub is quiet on a healthy ledger" \
  || fail "scrub reported an integrity problem on a healthy ledger: '$out'"

# scrub must still do its real job — the integrity guard reads id and status in
# one pass, so a bug there would silently stop all stale-claim relabeling.
cat >| "$SCRUB_TASKS/F91.4.md" <<'EXHAUSTED'
---
id: F91.4
phase: F91
title: Exhausted claim
status: in_progress
claimed_by: agent-x
turn_budget_remaining: 0
consecutive_failed_iterations: 0
---

# F91.4 — exhausted claim
EXHAUSTED
out=$(scrubcli scrub 2>/dev/null) || true
[[ "$out" == *"F91.4"*"needs-review"* ]] && pass "scrub still relabels an exhausted claim" \
  || fail "scrub did not relabel F91.4 after the integrity refactor; output: '$out'"

# ── Test 24: resume-attempt (pump stalled-claim budget) ──────────────────────
# The pump's auto-resume budget lives here rather than in the pump because the
# increment, the progress-reset and the limit test have to be one locked
# read-modify-write, and because no read verb exists for arbitrary frontmatter.
# It deliberately does NOT reuse consecutive_failed_iterations: that is driven by
# `heartbeat --end`, which a dead agent never fires, and `claim` zeroes it on
# every (re)claim — so the pump's own resume cycle would reset the tripwire meant
# to bound it.
echo
echo "--- Test 24: resume-attempt ---"
ra_field() { sed -n "s/^$2: *//p" "$TASKS/$1.md" | head -1; }
make_task "$TASKS" F93.1 F93 in_progress "Stalled claim" "feat/f93"

out=$("$CLI" resume-attempt F93.1 --head aaaaaaa1111 --max 3) && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == "resume 1/3" ]] && pass "first resume: 'resume 1/3', rc 0" \
  || fail "first resume gave rc=$rc out='$out'"
[[ "$(ra_field F93.1 resume_attempts)" == "1" ]] && pass "resume_attempts written as 1" \
  || fail "resume_attempts='$(ra_field F93.1 resume_attempts)'"

out=$("$CLI" resume-attempt F93.1 --head aaaaaaa1111 --max 3) || true
[[ "$out" == "resume 2/3" ]] && pass "same head ⇒ counter increments" || fail "got '$out'"

out=$("$CLI" resume-attempt F93.1 --head bbbbbbb2222 --max 3) || true
[[ "$out" == "resume 1/3" ]] && pass "moved head ⇒ counter resets to 1" || fail "got '$out'"
[[ "$(ra_field F93.1 resume_head_sha)" == "bbbbbbb2222" ]] && pass "new head recorded" \
  || fail "resume_head_sha='$(ra_field F93.1 resume_head_sha)'"

"$CLI" resume-attempt F93.1 --head bbbbbbb2222 --max 3 >/dev/null || true
"$CLI" resume-attempt F93.1 --head bbbbbbb2222 --max 3 >/dev/null || true
out=$("$CLI" resume-attempt F93.1 --head bbbbbbb2222 --max 3) && rc=0 || rc=$?
[[ "$rc" -eq 10 && "$out" == "escalate 3/3" ]] && pass "budget spent ⇒ 'escalate 3/3', rc 10" \
  || fail "escalation gave rc=$rc out='$out'"

# Idempotent once exhausted: the pump ticks every 30s, and a counter that kept
# climbing would write (and commit) a ledger change on every one of them.
before=$(md5sum "$TASKS/F93.1.md" | cut -d' ' -f1)
out=$("$CLI" resume-attempt F93.1 --head bbbbbbb2222 --max 3) || true
after=$(md5sum "$TASKS/F93.1.md" | cut -d' ' -f1)
[[ "$out" == "escalate 3/3" && "$before" == "$after" ]] && pass "repeat escalate is a no-op write" \
  || fail "escalate churned the file (out='$out')"

# A legacy task file (none of the 680 in the ledger carry these fields yet) must
# backfill rather than fail — there is no migration step.
make_task "$TASKS" F93.2 F93 in_progress "Legacy shape" "feat/f93"
out=$("$CLI" resume-attempt F93.2 --head ccccccc3333 --max 3) || true
[[ "$out" == "resume 1/3" && "$(ra_field F93.2 resume_attempts)" == "1" ]] \
  && pass "fields backfill onto a task that lacks them" || fail "backfill failed: '$out'"

"$CLI" resume-attempt F93.2 --head "not-a-sha!!" --max 3 >/dev/null 2>&1 \
  && fail "accepted a non-sha --head" || pass "rejects a --head that is not a git sha"

# ── Test 25: reopen from needs-review / stuck ────────────────────────────────
# Before this, both were dead ends: release requires in_progress, reopen took
# only blocked|done, and claim takes only open or a same-branch in_progress. A
# task scrubbed to needs-review could be revived ONLY by hand-editing
# frontmatter — which the ledger's one-writer rule forbids.
echo
echo "--- Test 25: reopen from needs-review / stuck ---"
make_task "$TASKS" F93.3 F93 in_progress "Parked by scrub" "feat/f93"
"$CLI" needs-review F93.3 --reason "turn budget exhausted" >/dev/null
"$CLI" reopen F93.3 --reason "human looked, it is workable" >/dev/null 2>&1 \
  && pass "reopen accepts needs-review" || fail "reopen rejected a needs-review task"
[[ "$(ra_field F93.3 status)" == "open" ]] && pass "needs-review → open" \
  || fail "status='$(ra_field F93.3 status)'"
[[ -z "$(ra_field F93.3 scrub_reason)" || "$(ra_field F93.3 scrub_reason)" == "null" ]] \
  && pass "scrub_reason cleared on reopen" || fail "scrub_reason survived: '$(ra_field F93.3 scrub_reason)'"

# `stuck` means the failure streak hit 3; reopening without clearing it would
# re-trip on the next unproductive heartbeat.
make_task "$TASKS" F93.4 F93 stuck "Tripped the failure tripwire"
sed -i 's/^consecutive_failed_iterations: 0/consecutive_failed_iterations: 3/' "$TASKS/F93.4.md"
"$CLI" reopen F93.4 --reason "root cause fixed" >/dev/null 2>&1 \
  && pass "reopen accepts stuck" || fail "reopen rejected a stuck task"
[[ "$(ra_field F93.4 consecutive_failed_iterations)" == "0" ]] \
  && pass "failure streak cleared reopening from stuck" \
  || fail "streak survived: '$(ra_field F93.4 consecutive_failed_iterations)'"

# Still refuses the statuses it always refused.
make_task "$TASKS" F93.5 F93 open "Already open"
"$CLI" reopen F93.5 --reason "nope" >/dev/null 2>&1 \
  && fail "reopen accepted an already-open task" || pass "reopen still refuses an open task"

# ── Test 26: dual-invocation equivalence ─────────────────────────────────────
# The same operation, configured three ways — a legacy ARACHNE_* export, the
# canonical TASKPUMP_* export, and a taskpump.conf discovered by walking up from
# $PWD — must leave byte-identical ledger state. Without this, "the legacy
# spellings still work" is an assertion about lib/config.sh's internals rather
# than about what a consumer actually observes, and the two could drift apart
# key by key as tools migrate.
echo
echo "--- Test 26: dual-invocation equivalence ---"

# A deterministic projection of a ledger: every field a mutation is supposed to
# touch, excluding the wall-clock stamps, which differ between two runs a
# millisecond apart and would drown the signal.
ledger_fingerprint() {
  local dir=$1 f
  for f in "$dir"/*.md; do
    [[ -e "$f" ]] || continue
    printf '%s ' "$(basename "$f")"
    yq --front-matter=extract -o=json -I=0 \
      '[.id, .status, .claimed_by, .turn_budget_remaining,
        .consecutive_failed_iterations, .blockers, .completed_by_commits,
        .goal, .title, .phase, .files, .milestone]' "$f"
  done | sort
}

# The operation under test: file two tasks, wire one behind the other, then
# claim and complete the blocker. Touches create/blockers/claim/complete, so a
# spelling that failed to arrive would change the outcome rather than merely the
# path taken to it. These runners deliberately CLEAR both spellings of every
# key, so `create` here validates against the BAKED default grammar — T-shaped
# ids since the G1.6 flip, hence T ids in an otherwise F-shaped suite.
seed_ledger() {
  local runner=$1
  $runner create T80.1 --title "Blocker task" --goal "Unblock T80.2." >/dev/null
  $runner create T80.2 --title "Dependent task" --blockers "T80.1" >/dev/null
  $runner claim T80.1 --branch feat/dual --turns 9 >/dev/null
  $runner complete T80.1 --commits "abc1234,def5678" >/dev/null </dev/null
}

DUAL_LEGACY="$TMPDIR_TEST/dual-legacy/tasks"
DUAL_CANON="$TMPDIR_TEST/dual-canon/tasks"
DUAL_CONF_WS="$TMPDIR_TEST/dual-conf"
DUAL_CONF="$DUAL_CONF_WS/tasks"
mkdir -p "$DUAL_LEGACY" "$DUAL_CANON" "$DUAL_CONF"
git -C "$DUAL_CONF_WS" init -q

# 1. legacy spelling
legacy_cli() { env "${TP_ENV_UNSET[@]}" \
  ARACHNE_TASKS_DIR="$DUAL_LEGACY" ARACHNE_TASK_NOCOMMIT=1 "$CLI" "$@"; }
seed_ledger legacy_cli

# 2. canonical spelling
canon_cli() { env "${TP_ENV_UNSET[@]}" \
  TASKPUMP_TASKS_DIR="$DUAL_CANON" TASKPUMP_TASK_NOCOMMIT=1 "$CLI" "$@"; }
seed_ledger canon_cli

# 3. taskpump.conf, discovered from $PWD. Nothing about the ledger is in the
# environment for this one — the config file is the only thing pointing at it.
# Discovery is exactly what this case tests, so it opts back out of the suite's
# hermeticity switch; the walk still stops at $DUAL_CONF_WS's own git root, so
# no enclosing repo's conf can reach it.
cat >| "$DUAL_CONF_WS/taskpump.conf" <<CONF
TASKPUMP_TASKS_DIR=$DUAL_CONF
TASKPUMP_TASK_NOCOMMIT=1
CONF
conf_cli() { ( cd "$DUAL_CONF_WS" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 "$CLI" "$@" ); }
seed_ledger conf_cli

fp_legacy=$(ledger_fingerprint "$DUAL_LEGACY")
fp_canon=$(ledger_fingerprint "$DUAL_CANON")
fp_conf=$(ledger_fingerprint "$DUAL_CONF")

[[ -n "$fp_legacy" ]] && pass "dual-invocation fixture produced a non-empty ledger" \
  || fail "dual-invocation fixture produced nothing to compare"

if [[ "$fp_legacy" == "$fp_canon" ]]; then
  pass "TASKPUMP_TASKS_DIR produces the same ledger as ARACHNE_TASKS_DIR"
else
  fail "canonical vs legacy diverged:
--- legacy ---
$fp_legacy
--- canonical ---
$fp_canon"
fi

if [[ "$fp_legacy" == "$fp_conf" ]]; then
  pass "taskpump.conf produces the same ledger as an env export"
else
  fail "conf vs legacy diverged:
--- legacy ---
$fp_legacy
--- conf ---
$fp_conf"
fi

# Precedence: both spellings in the environment ⇒ the canonical one wins. Two
# equally-strong sources, and the current name is authoritative. Asserted
# materially (which directory the task lands in), not just via `resolve`, so it
# covers the whole config path and not only the reporting verb.
PREC_LEGACY="$TMPDIR_TEST/prec-legacy/tasks"
PREC_CANON="$TMPDIR_TEST/prec-canon/tasks"
mkdir -p "$PREC_LEGACY" "$PREC_CANON"

got=$(env "${TP_ENV_UNSET[@]}" \
  ARACHNE_TASKS_DIR="$PREC_LEGACY" TASKPUMP_TASKS_DIR="$PREC_CANON" \
  ARACHNE_TASK_NOCOMMIT=1 "$CLI" resolve --tasks-dir)
[[ "$got" == "$PREC_CANON" ]] && pass "TASKPUMP_TASKS_DIR outranks ARACHNE_TASKS_DIR" \
  || fail "precedence resolved to '$got', expected '$PREC_CANON'"

env "${TP_ENV_UNSET[@]}" \
  ARACHNE_TASKS_DIR="$PREC_LEGACY" TASKPUMP_TASKS_DIR="$PREC_CANON" \
  ARACHNE_TASK_NOCOMMIT=1 "$CLI" create T81.1 --title "Precedence" >/dev/null
[[ -f "$PREC_CANON/T81.1.md" && ! -f "$PREC_LEGACY/T81.1.md" ]] \
  && pass "the write lands in the canonical dir, not the legacy one" \
  || fail "precedence write went to the wrong ledger"

# An env export must still outrank a config file, in either spelling — otherwise
# a stale taskpump.conf in a parent directory would silently capture a caller who
# was explicit about where the ledger is.
ENV_OVER_CONF="$TMPDIR_TEST/env-over-conf/tasks"
mkdir -p "$ENV_OVER_CONF"
got=$( cd "$DUAL_CONF_WS" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 \
        ARACHNE_TASKS_DIR="$ENV_OVER_CONF" "$CLI" resolve --tasks-dir )
[[ "$got" == "$ENV_OVER_CONF" ]] && pass "a legacy env export outranks taskpump.conf" \
  || fail "env-over-conf resolved to '$got', expected '$ENV_OVER_CONF'"

got=$( cd "$DUAL_CONF_WS" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 \
        TASKPUMP_TASKS_DIR="$ENV_OVER_CONF" "$CLI" resolve --tasks-dir )
[[ "$got" == "$ENV_OVER_CONF" ]] && pass "a canonical env export outranks taskpump.conf" \
  || fail "env-over-conf resolved to '$got', expected '$ENV_OVER_CONF'"

echo
echo "--- a branch that cannot carry an agent name is refused at the claim ---"
# The agent name is the branch with `/` → `-` (docs/RUNNERS.md §2), and the whole
# stack joins on it. The encoding is frozen — names already exist on operators'
# hosts — so a branch the encoding cannot carry has to be stopped at the door.
# The claim is that door: it is where a branch enters the ledger.
#
# The cost of letting one through is not a bad error message later. `feat/a/b`
# and `feat/a-b` produce the same slug, so liveness cannot map the name back to
# one branch: the agent launches, the pump reads the phase as dead, and it
# launches a second agent on the same branch. That is the one thing the
# supervisor is supposed to never do.
make_task "$TASKS" F90.1 F90 open "Slug round-trip fixture"

# `rc=0; out=$(...) || rc=$?`, not `out=$(...); rc=$?` — this suite runs under
# `set -e`, where a failing command substitution in a bare assignment kills the
# script before the assertion below can read the status it is asserting on.
rc=0; out=$("$CLI" claim F90.1 --branch feat/a/b 2>&1) || rc=$?
[[ $rc -ne 0 ]] && pass "claim --branch feat/a/b is refused" \
  || fail "a two-separator branch was accepted (rc=$rc):\n$out"
grep -q 'feat-a-b' <<<"$out" \
  && pass "the refusal shows the ambiguous name it would have produced" \
  || fail "the message does not name the collision:\n$out"
grep -qi 'at most one' <<<"$out" \
  && pass "the refusal states the constraint" \
  || fail "the message does not state the rule:\n$out"
assert_fm "$TASKS/F90.1.md" '.status' 'open'
assert_fm "$TASKS/F90.1.md" '.claimed_by' 'null'

# The shape the pump actually produces, and the shape a human uses: both fine.
# A fresh fixture per case — reusing one task would test `release` semantics
# here rather than the rule under test.
make_task "$TASKS" F90.2 F90 open "Slug round-trip fixture (accepted)"
"$CLI" claim F90.2 --branch feat/a --turns 5 >/dev/null 2>&1 \
  && pass "claim --branch feat/a is accepted" || fail "a one-separator branch was refused"
assert_fm "$TASKS/F90.2.md" '.claimed_by' 'feat/a'

make_task "$TASKS" F90.3 F90 open "Slug round-trip fixture (no separator)"
"$CLI" claim F90.3 --branch main --turns 5 >/dev/null 2>&1 \
  && pass "a branch with no separator at all is accepted" || fail "'main' was refused"

# The other three shapes the encoding cannot carry. Each produces a name that is
# either illegal (leading `-`) or collides with a different branch.
for bad in "/leading" "trailing/" "has space"; do
  rc=0; out=$("$CLI" claim F90.1 --branch "$bad" 2>&1) || rc=$?
  [[ $rc -ne 0 ]] && pass "claim --branch '$bad' is refused" \
    || fail "'$bad' was accepted (rc=$rc):\n$out"
done
assert_fm "$TASKS/F90.1.md" '.status' 'open'

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
