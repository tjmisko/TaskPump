#!/usr/bin/env bash
# test-tp-task-generic.sh — tp-task against a project that is nothing like Arachne.
#
# test-tp-task.sh proves the tool still behaves exactly as it always did for an
# Arachne-shaped repo. This suite proves the other half: that the behaviour is
# genuinely parameterized rather than merely renamed. Everything here is chosen
# to differ from the baked defaults —
#
#   * a `T` id grammar instead of `F`, with its own TASKPUMP_ID_PATTERN;
#   * the ledger INSIDE the code repo (tasks/), no submodule, so the ledger repo
#     and the code repo are the same git repo — the configuration the two-repo
#     defaults were written against but which most consumers will not have;
#   * no push remote anywhere;
#   * non-default tripwire constants, so a hardcoded value would show up as a
#     wrong answer rather than a coincidentally-correct one.
#
# Run: ./tests/test-tp-task-generic.sh
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CLI="$TP_ROOT/libexec/tp-task"

# Hermeticity: ignore any taskpump.conf in the repo this suite happens to run
# from — the tools discover config by walking up from $PWD, and a leaked conf
# reconfigures every fixture invocation below. run-all.sh exports the same
# switch; this one covers standalone runs.
export TASKPUMP_NO_CONF=1

PASS=0
FAIL=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }

# Clear both spellings of every config key, so an operator's exported TaskPump
# settings cannot leak in and pre-satisfy (or break) a case here. See the same
# block in test-tp-task.sh for why both spellings must go.
for _suffix in TASKS_DIR TASK_OUT CODE_REPO TASK_PUSH PUSH TASK_NOCOMMIT \
               TASK_DEBUG LEDGER_PROBE COMMITTER_NAME COMMITTER_EMAIL \
               ID_PATTERN PHASE_SIGIL TURN_BUDGET_DEFAULT FAILURE_LIMIT \
               CLAIM_STALE_HOURS LOCK_WAIT LOCK_NAME PUSH_RETRIES PROG_NAME \
               CONFIG; do
  unset "ARACHNE_$_suffix" "TASKPUMP_$_suffix" 2>/dev/null || true
done
unset _suffix

# ── Fixture: one repo, ledger in-tree, no remote ─────────────────────────────
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT="$TMPDIR_TEST/widget"
LEDGER="$PROJECT/tasks"
mkdir -p "$LEDGER" "$PROJECT/src"
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.name=test -c user.email=t@e commit --allow-empty -q -m "init widget"

# The whole configuration, in one place — this is also the worked example a
# consumer would copy into their taskpump.conf.
export TASKPUMP_LEDGER_PROBE=tasks
export TASKPUMP_ID_PATTERN='^T[0-9]+(\.[0-9]+)?$'
export TASKPUMP_PHASE_SIGIL=T
export TASKPUMP_TURN_BUDGET_DEFAULT=7
export TASKPUMP_FAILURE_LIMIT=2
export TASKPUMP_COMMITTER_NAME=widget-tasks
export TASKPUMP_COMMITTER_EMAIL=tasks@widget.invalid
export TASKPUMP_TASKS_DIR="$LEDGER"
export TASKPUMP_CODE_REPO="$PROJECT"
export TASKPUMP_TASK_PUSH=0

fm() { yq --front-matter=extract "$2" "$LEDGER/$1.md" 2>/dev/null; }

assert_fm() {
  local id=$1 expr=$2 expected=$3 actual
  actual=$(fm "$id" "$expr")
  [[ "$actual" == "$expected" ]] && pass "$id: $expr == $expected" \
    || fail "$id: $expr expected '$expected' got '$actual'"
}

# A code commit that is not a ledger commit. Both live in the same repo here, so
# heartbeat's productivity check has to discriminate by path, not by repo.
code_commit() {
  printf '%s\n' "$1" >> "$PROJECT/src/main.rs"
  git -C "$PROJECT" add src/main.rs
  git -C "$PROJECT" -c user.name=dev -c user.email=d@e commit -q -m "$1"
}

# ── create: the configured grammar is the one enforced ───────────────────────
echo "--- create under a T grammar ---"

"$CLI" create T1.1 --title "Parse the widget manifest" \
  --goal "Widget manifests load without a schema error." >/dev/null
[[ -f "$LEDGER/T1.1.md" ]] && pass "create writes a T-grammar task" || fail "create wrote no file"
assert_fm T1.1 '.id' T1.1
assert_fm T1.1 '.phase' T1
assert_fm T1.1 '.status' open

"$CLI" create T1.2 --title "Render the manifest" --blockers "T1.1" \
  --files "src/main.rs" >/dev/null
assert_fm T1.2 '.blockers[0]' T1.1
"$CLI" create T2.1 --title "Ship it" >/dev/null

# The Arachne grammar must now be the one that is rejected — otherwise the
# pattern is being ignored rather than applied.
"$CLI" create F1.1 --title "Wrong grammar" >/dev/null 2>&1 \
  && fail "create accepted an F id under a T pattern" \
  || pass "create rejects the default grammar when a T pattern is configured"
[[ ! -f "$LEDGER/F1.1.md" ]] && pass "rejected create left no file" || fail "rejected create wrote a file"

# ── ready / next: phase grouping and range expansion follow the sigil ─────────
echo
echo "--- ready and next under a T sigil ---"

got=$("$CLI" ready --phases T1..T2 --count)
[[ "$got" == "3" ]] && pass "ready --count spans a T range (3 open)" \
  || fail "ready --count over T1..T2 got '$got', expected 3"

# T1.2 is blocked by the still-open T1.1, so the eligible frontier is 2 of 3.
got=$("$CLI" ready --phases T1..T2 --count-eligible)
[[ "$got" == "2" ]] && pass "blockers gate the frontier (2 of 3 eligible)" \
  || fail "ready --count-eligible got '$got', expected 2"

# Lowercase and comma forms of the same range must expand identically — that is
# the sigil-stripping path, which used to be a hardcoded [Ff].
got=$("$CLI" ready --phases t1..t2 --count-eligible)
[[ "$got" == "2" ]] && pass "a lowercase sigil expands the same range" \
  || fail "lowercase range got '$got', expected 2"
got=$("$CLI" ready --phases "T1,T2" --count-eligible)
[[ "$got" == "2" ]] && pass "a comma list expands the same range" \
  || fail "comma list got '$got', expected 2"

got=$("$CLI" ready --phases T2 --json | jq -r 'map(.id) | join(",")')
[[ "$got" == "T2.1" ]] && pass "ready --phases scopes to one T phase" \
  || fail "ready --phases T2 got '$got'"

got=$("$CLI" next --branch feat/t1 | jq -r .id)
[[ "$got" == "T1.1" ]] && pass "next picks the lowest eligible T task" \
  || fail "next got '$got', expected T1.1"

got=$("$CLI" next --branch feat/t1 --phase T2 | jq -r .id)
[[ "$got" == "T2.1" ]] && pass "next --phase scopes to a T phase" \
  || fail "next --phase T2 got '$got'"

# ── claim: the configured turn budget, not the baked 50 ──────────────────────
echo
echo "--- claim, heartbeat, complete ---"

"$CLI" claim T1.1 --branch feat/t1 >/dev/null
assert_fm T1.1 '.status' in_progress
assert_fm T1.1 '.claimed_by' feat/t1
assert_fm T1.1 '.turn_budget_remaining' 7

# Ledger commits really are landing, under the configured identity.
got=$(git -C "$PROJECT" log -1 --format='%an <%ae>')
[[ "$got" == "widget-tasks <tasks@widget.invalid>" ]] \
  && pass "ledger commits carry the configured committer identity" \
  || fail "committer was '$got'"

# ── heartbeat: productive when the code repo moved on the task's own files ───
"$CLI" heartbeat T1.1 --start >/dev/null
code_commit "widget: parse the manifest"
"$CLI" heartbeat T1.1 --end >/dev/null
assert_fm T1.1 '.turn_budget_remaining' 6
assert_fm T1.1 '.consecutive_failed_iterations' 0

"$CLI" complete T1.1 --commits "1111111,2222222" </dev/null >/dev/null
assert_fm T1.1 '.status' done
assert_fm T1.1 '.completed_by_commits[1]' 2222222

# Completing the blocker is what releases T1.2 — the DAG edge, end to end.
got=$("$CLI" ready --phases T1..T2 --count-eligible)
[[ "$got" == "2" ]] && pass "completing a blocker admits its dependent to the frontier" \
  || fail "post-complete frontier got '$got', expected 2"
got=$("$CLI" next --branch feat/t1 | jq -r .id)
[[ "$got" == "T1.2" ]] && pass "the unblocked task is now next" || fail "next got '$got'"

# ── reopen ───────────────────────────────────────────────────────────────────
echo
echo "--- reopen ---"
"$CLI" reopen T1.1 --reason "the parser regressed" >/dev/null
assert_fm T1.1 '.status' open
assert_fm T1.1 '.completed_by_commits | length' 0
grep -q 'prior completion commits: 1111111,2222222' "$LEDGER/T1.1.md" \
  && pass "reopen records the shed completion commits" \
  || fail "reopen did not record the prior commits"
# T1.2 is gated again, since its blocker is no longer done.
got=$("$CLI" ready --phases T1 --count-eligible)
[[ "$got" == "1" ]] && pass "reopening a blocker re-gates its dependent" \
  || fail "post-reopen frontier got '$got', expected 1"

# ── scrub: the configured failure limit, not the baked 3 ─────────────────────
echo
echo "--- scrub under TASKPUMP_FAILURE_LIMIT=2 ---"

"$CLI" claim T1.2 --branch feat/t2 >/dev/null
# Two unproductive iterations: the ledger commits move HEAD, but T1.2 declares
# files: [src/main.rs] and nothing touches it, so neither counts as progress.
for _ in 1 2; do
  "$CLI" heartbeat T1.2 --start >/dev/null
  "$CLI" heartbeat T1.2 --end >/dev/null
done
assert_fm T1.2 '.consecutive_failed_iterations' 2

out=$("$CLI" scrub 2>/dev/null) || true
[[ "$out" == *"T1.2"*"stuck"* ]] && pass "scrub marks a task stuck at the configured limit" \
  || fail "scrub output was '$out'"
assert_fm T1.2 '.status' stuck

# The same streak under the default limit of 3 must NOT be stuck — this is what
# distinguishes a configured limit from a coincidence.
"$CLI" reopen T1.2 --reason "retry with the default limit" >/dev/null
"$CLI" claim T1.2 --branch feat/t2 >/dev/null
for _ in 1 2; do
  "$CLI" heartbeat T1.2 --start >/dev/null
  "$CLI" heartbeat T1.2 --end >/dev/null
done
TASKPUMP_FAILURE_LIMIT=3 "$CLI" scrub >/dev/null 2>&1 || true
assert_fm T1.2 '.status' in_progress

# scrub's other job: report a file the frontier cannot see, and exit 3.
cat >| "$LEDGER/T9.9.md" <<'NOID'
---
phase: T9
title: No id anywhere
status: open
---

# T9.9
NOID
out=$("$CLI" scrub 2>/dev/null) && rc=0 || rc=$?
[[ "$out" == *"NO-ID"*"T9.9.md"* ]] && pass "scrub names an id-less file in a generic ledger" \
  || fail "scrub did not report T9.9; output: '$out'"
[[ "$rc" -eq 3 ]] && pass "scrub still exits 3 for an invisible file" || fail "scrub exited $rc"
rm "$LEDGER/T9.9.md"

# ── blockers verb against the T grammar ──────────────────────────────────────
echo
echo "--- blockers verb ---"
"$CLI" blockers T2.1 --add T1.1 >/dev/null
assert_fm T2.1 '.blockers[0]' T1.1
"$CLI" blockers T2.1 --add T9.9 >/dev/null 2>&1 \
  && fail "blockers --add accepted an id with no task file" \
  || pass "blockers --add still rejects an unresolvable id"
"$CLI" blockers T2.1 --clear >/dev/null
got=$("$CLI" blockers T2.1)
[[ -z "$got" ]] && pass "blockers --clear empties the list" || fail "blockers left '$got'"

# ── push with no remote: commit lands, warn once, exit 0 ─────────────────────
# The graceful path. Six jittered retries followed by a die would fail the verb
# after its commit had already landed, which is how a supervisor concludes a
# ledger write was lost.
echo
echo "--- push against a ledger with no remote ---"

[[ -z "$(git -C "$PROJECT" remote)" ]] && pass "fixture really has no remote" \
  || fail "fixture unexpectedly has a remote"

before=$(git -C "$PROJECT" rev-list --count HEAD)
set +e
err=$(TASKPUMP_TASK_PUSH=1 "$CLI" title T2.1 --set "Ship the widget" 2>&1 >/dev/null)
rc=$?
set -e
after=$(git -C "$PROJECT" rev-list --count HEAD)

[[ $rc -eq 0 ]] && pass "a mutation succeeds when there is no push remote" \
  || fail "mutation exited $rc with no remote"
[[ "$after" -eq $((before + 1)) ]] && pass "the ledger commit still landed" \
  || fail "commit count went $before → $after"
[[ "$err" == *"no push remote"* ]] && pass "it says why it did not push" \
  || fail "no warning about the missing remote; stderr was '$err'"
n=$(grep -c 'no push remote' <<<"$err" || true)
[[ "$n" -eq 1 ]] && pass "the warning is emitted once, not per operation" \
  || fail "warning appeared $n times"
assert_fm T2.1 '.title' "Ship the widget"

# With push off, the same mutation must be silent — the warning belongs to the
# push path, not to every commit.
err=$("$CLI" title T2.1 --set "Ship the widget twice" 2>&1 >/dev/null)
[[ "$err" != *"no push remote"* ]] && pass "no warning when pushing is not requested" \
  || fail "warned about the remote with TASKPUMP_TASK_PUSH=0: '$err'"

# ── diagnostics carry the configured program name ────────────────────────────
echo
echo "--- program name in diagnostics ---"
# Conf-pinned: the reference consumer names the historical prefix explicitly in
# examples/arachne.conf (TASKPUMP_PROG_NAME=arachne-task), so this assertion
# survives every default flip. TASKPUMP_CONFIG outranks the suite's
# TASKPUMP_NO_CONF hermeticity switch, and this suite's exported TASKPUMP_*
# fixture env still outranks the conf — so only keys the suite leaves unset
# (PROG_NAME among them) arrive from the pins.
err=$(TASKPUMP_CONFIG="$TP_ROOT/examples/arachne.conf" "$CLI" block T2.1 2>&1 >/dev/null || true)
[[ "$err" == "arachne-task: "* ]] && pass "the arachne.conf pin keeps the historical prefix" \
  || fail "conf-pinned diagnostic prefix was '$err'"
# Bare default: the shipped default identifies as TaskPump (flipped in G1.4);
# only the arachne.conf pin above keeps the historical `arachne-task: ` prefix.
err=$("$CLI" block T2.1 2>&1 >/dev/null || true)
[[ "$err" == "tp-task: "* ]] && pass "bare default prefix is the TaskPump spelling" \
  || fail "default diagnostic prefix was '$err'"
err=$(TASKPUMP_PROG_NAME=widget-tasks "$CLI" block T2.1 2>&1 >/dev/null || true)
[[ "$err" == "widget-tasks: "* ]] && pass "TASKPUMP_PROG_NAME rebrands diagnostics" \
  || fail "rebranded diagnostic was '$err'"

# ── resolve reports the generic layout ───────────────────────────────────────
echo
echo "--- resolve ---"
got=$( cd "$PROJECT" && env -u TASKPUMP_TASKS_DIR -u ARACHNE_TASKS_DIR \
        -u TASKPUMP_CODE_REPO -u ARACHNE_CODE_REPO "$CLI" resolve --tasks-dir )
[[ "$got" == "$LEDGER" ]] && pass "the probe alone resolves an in-tree ledger" \
  || fail "resolve --tasks-dir got '$got', expected '$LEDGER'"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
