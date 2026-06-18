#!/usr/bin/env bash
# test-arachne-task.sh — fixture-based tests for scripts/arachne-task.
#
# Creates a temp directory with fixture task files, runs CLI subcommands
# against it, asserts expected state transitions.
#
# Run: ./scripts/test-arachne-task.sh
# Exit non-zero on any failure; prints a PASS/FAIL line per test.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CLI="$SCRIPT_DIR/arachne-task"

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

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
