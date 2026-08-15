#!/usr/bin/env bash
# test-tp-task-fsck.sh — the whole-ledger conformance check and the import path.
#
# fsck is what a repository with a PRE-EXISTING markdown task DAG runs before
# pointing any TaskPump tool at it, so these fixtures are deliberately not
# authored through the CLI: each one is a hand-written file carrying exactly one
# violation class from docs/LEDGER-CONTRACT.md, plus the whole-graph shapes
# (dangling blocker, self-block, a 3-cycle) that no single-file tool can see.
# The --fix cases prove the stamping repairs only what has a documented default,
# never touches a body, never rewrites a present-but-wrong value, and lands as
# one auditable ledger commit.
#
# Run: ./tests/test-tp-task-fsck.sh
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
CLI="$TP_ROOT/libexec/tp-task"

# Hermeticity: ignore any taskpump.conf in the repo this suite happens to run
# from, and scrub inherited pump env (issue #18). run-all.sh sources the same
# prologue; this covers standalone runs.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

PASS=0
FAIL=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Skip ledger commits (and the state lock) for the pure-report fixtures; the
# --fix audit-commit case re-enables committing against its own git repo.
export TASKPUMP_TASK_NOCOMMIT=1

# A fully-populated, contract-clean task file — the shape `create` emits.
# Usage: full_task <path> <id> [status] [blockers-flow-seq]
full_task() {
  local path=$1 id=$2 status=${3:-open} blockers=${4:-[]}
  cat >| "$path" <<EOF
---
id: $id
phase: ${id%%.*}
title: Task $id
status: $status
claimed_by: null
claimed_at: null
turn_budget_remaining: null
consecutive_failed_iterations: 0
blockers: $blockers
completed_by_commits: []
milestone: null
files: []
last_heartbeat_head_sha: null
completed_at: null
goal: null
last_heartbeat_ts: null
blocked_at: null
blocked_reason: null
resume_attempts: 0
resume_head_sha: null
---

# $id — Task $id
EOF
}

# ── The violations ledger: one file per violation class ──────────────────────
echo "--- report mode: one line per violation class, exit 3 ---"

BAD="$TMPDIR_TEST/bad/tasks"
mkdir -p "$BAD"

full_task "$BAD/T1.md" T1                              # control: clean
printf -- '---\nid: T2\n  bad: [unclosed\n---\n\n# T2\n' >| "$BAD/T2.md"   # invalid YAML
printf '# just a readme, no frontmatter\n' >| "$BAD/T3.md"                 # no --- at all
printf -- '---\nid: T16\nstatus: open\n\n# body\n' >| "$BAD/T16.md"        # no closing ---
full_task "$BAD/T4.md" T44                             # id != filename stem
full_task "$BAD/X6.md" X6                              # id fails TASKPUMP_ID_PATTERN
full_task "$BAD/T7.md" T7 doing                        # status outside the vocabulary
full_task "$BAD/T8.md" T8 open '"T1"'                  # blockers: wrong type (string)
full_task "$BAD/T9.md" T9 open '[T77]'                 # dangling blocker
full_task "$BAD/T10.md" T10 open '[T10]'               # self-block
full_task "$BAD/T11.md" T11 open '[T12]'               # ┐
full_task "$BAD/T12.md" T12 open '[T13]'               # ├ 3-cycle
full_task "$BAD/T13.md" T13 open '[T11]'               # ┘
printf -- '---\nid: T15\ntitle: Bare import\n---\n\n# T15\n' >| "$BAD/T15.md"  # missing machine keys
# T14: wrong-typed present values — a timestamp that is not one, a counter that
# is not an integer.
full_task "$BAD/T14.md" T14
sed -i 's/^claimed_at: null$/claimed_at: yesterday/' "$BAD/T14.md"
sed -i 's/^resume_attempts: 0$/resume_attempts: three/' "$BAD/T14.md"
# T17: clean, plus a namespaced extension key — §3 says unknown keys pass.
full_task "$BAD/T17.md" T17
sed -i 's/^resume_head_sha: null$/resume_head_sha: null\nx_myteam_note: extension keys are legal/' "$BAD/T17.md"
# The review surface (§3 "Review", all verb-added). T18: a role outside the
# vocabulary. T19: review_of dangling — the verdict verb could never find its
# implementation, and no per-file read would ever say so. T20: a counter that
# is not an integer. T22: a chain reviewing itself. T21 is the clean control:
# a well-formed reviewer task must produce no line at all.
full_task "$BAD/T18.md" T18
sed -i 's/^resume_head_sha: null$/resume_head_sha: null\nreview_of: T1\nreview_role: judge/' "$BAD/T18.md"
full_task "$BAD/T19.md" T19
sed -i 's/^resume_head_sha: null$/resume_head_sha: null\nreview_of: T77\nreview_role: reviewer/' "$BAD/T19.md"
full_task "$BAD/T20.md" T20
sed -i 's/^resume_head_sha: null$/resume_head_sha: null\nreview_of: T1\nreview_role: reviewer\nreview_round: three/' "$BAD/T20.md"
full_task "$BAD/T21.md" T21 open '[T1]'
sed -i 's/^resume_head_sha: null$/resume_head_sha: null\nreview_of: T1\nreview_role: reviewer\nreview_prompt: null/' "$BAD/T21.md"
full_task "$BAD/T22.md" T22
sed -i 's/^resume_head_sha: null$/resume_head_sha: null\nreview_of: T22\nreview_role: adjudicator/' "$BAD/T22.md"
# T23: review_role with review_of absent. `review_role` is what makes a task a
# review task — the frontier hides it (§6) and every verb that acts on one
# resolves its subject through review_of, so this is open work nothing can
# dispatch and `verdict` dies on. fsck accepted it until the shapes below were
# added, which is the same silent class as a dangling review_of.
full_task "$BAD/T23.md" T23
sed -i 's/^resume_head_sha: null$/resume_head_sha: null\nreview_role: reviewer/' "$BAD/T23.md"
# T24 + T24.1 + T25: the review that fails OPEN. T24 is an implementation under
# a live one-reviewer chain (T24.1 is the gate); T25 blocks on the
# implementation but not on the gate, so it goes eligible the moment T24
# completes with the verdict unrendered. `review` wires this correctly and the
# authoring verbs carry the gate along, but an imported ledger, a hand edit, or
# a `blockers --remove` of the gate produces it — and every other reader is
# silent about it.
full_task "$BAD/T24.md" T24 "done"
sed -i 's/^resume_head_sha: null$/resume_head_sha: null\nreview_round: 1\nreview_max_rounds: 3/' "$BAD/T24.md"
full_task "$BAD/T24.1.md" T24.1 open '[T24]'
sed -i 's/^resume_head_sha: null$/resume_head_sha: null\nreview_of: T24\nreview_role: reviewer/' "$BAD/T24.1.md"
full_task "$BAD/T25.md" T25 open '[T24]'

set +e
out=$(TASKPUMP_TASKS_DIR="$BAD" "$CLI" fsck 2>/dev/null)
rc=$?
set -e

[[ $rc -eq 3 ]] && pass "violations exit 3" || fail "fsck exited $rc, expected 3"

expect_line() { # <needle> <label>
  if grep -qF "$1" <<<"$out"; then pass "$2"; else fail "$2 — no line matching '$1'"; fi
}

expect_line "T2.md: frontmatter is not valid YAML" "invalid YAML is named"
expect_line "T3.md: no YAML frontmatter" "a file with no frontmatter is named"
expect_line "T16.md: frontmatter has no closing \"---\"" "an unclosed frontmatter block is named"
expect_line "T4.md: id 'T44' does not match the filename stem 'T4'" "id/filename mismatch is named"
expect_line "X6.md: id 'X6' does not match TASKPUMP_ID_PATTERN" "an id outside the pattern is named"
expect_line "T7.md: status 'doing' is not in the status vocabulary" "an unknown status is named"
expect_line "T8.md: blockers: expected a list of task-id strings" "a wrong-typed blockers key is named"
expect_line "T9.md: blocker 'T77' names no task" "a dangling blocker is named"
expect_line "T10.md: task blocks itself" "a self-block is named"
expect_line "T14.md: claimed_at: expected an ISO-8601 UTC timestamp" "a malformed timestamp is named"
expect_line "T14.md: resume_attempts: expected an integer" "a non-integer counter is named"
expect_line "T15.md: missing machine key 'status'" "a missing machine key is named"
expect_line "T18.md: review_role 'judge' is not in the role vocabulary" "a role outside reviewer|adjudicator is named"
expect_line "T19.md: review_of 'T77' names no task" "a dangling review_of is named"
expect_line "T20.md: review_round: expected an integer or null" "a non-integer review round is named"
expect_line "T22.md: review_of names the task itself" "a self-review is named"
expect_line "T23.md: review_role 'reviewer' with no review_of" "a review task with no subject is named"
expect_line "T25.md: blocks on 'T24', which is under live review, but not on that chain's gate 'T24.1'" \
  "a task that bypasses a live review gate is named (the review would fail open)"
grep -q 'T24\.1\.md: blocks' <<<"$out" \
  && fail "the chain's own reviewer was reported as bypassing its gate" \
  || pass "a chain member blocking on its own subject is not a bypass"

# The cycle: one line, all three members, anchored deterministically.
cycle_lines=$(grep -c 'blocker cycle' <<<"$out" || true)
[[ "$cycle_lines" -eq 1 ]] && pass "a 3-cycle reports as exactly one violation line" \
  || fail "expected 1 cycle line, got $cycle_lines"
expect_line "T11.md: blocker cycle T11 -> T12 -> T13 -> T11" "the cycle line names every member"

# Clean files stay silent; format is one violation per line, <file>: <what>.
grep -q 'T1\.md' <<<"$out" && fail "the clean control file was reported" \
  || pass "a clean file produces no line"
grep -q 'T17\.md' <<<"$out" && fail "a namespaced extension key was reported" \
  || pass "unknown extension keys pass (§3 Extension)"
grep -q 'T21\.md' <<<"$out" && fail "a well-formed reviewer task was reported" \
  || pass "a well-formed reviewer task passes (§3 Review, verb-added)"
bad_format=$(grep -cEv '^[^:]+\.md: ' <<<"$out" || true)
[[ "$bad_format" -eq 0 ]] && pass "every line is <file>: <what>" \
  || fail "$bad_format line(s) broke the <file>: <what> format"

# ── clean ledger: exit 0, no output at all ───────────────────────────────────
echo
echo "--- clean ledger ---"

CLEAN="$TMPDIR_TEST/clean/tasks"
mkdir -p "$CLEAN"
full_task "$CLEAN/T1.md" T1 "done"
# A full review chain in flight: the round counters on the implementation and
# a reviewer gating a downstream task are contract-clean, not violations. The
# downstream task blocks on BOTH the implementation and the gate — that is the
# shape `review` writes, and blocking on the implementation alone is itself a
# violation now (the review would fail open; see the bad ledger above).
full_task "$CLEAN/T2.1.md" T2.1 open '[T1, T1.1]'
sed -i 's/^resume_head_sha: null$/resume_head_sha: null\nreview_round: 1\nreview_max_rounds: 3/' "$CLEAN/T1.md"
full_task "$CLEAN/T1.1.md" T1.1 open '[T1]'
sed -i 's|^resume_head_sha: null$|resume_head_sha: null\nreview_of: T1\nreview_role: reviewer\nreview_prompt: prompts/security.md|' "$CLEAN/T1.1.md"

set +e
out=$(TASKPUMP_TASKS_DIR="$CLEAN" "$CLI" fsck 2>&1)
rc=$?
set -e
[[ $rc -eq 0 ]] && pass "clean ledger exits 0" || fail "clean ledger exited $rc: '$out'"
[[ -z "$out" ]] && pass "clean ledger prints nothing" || fail "clean ledger printed: '$out'"

# ── a missing tasks dir is an error, not a clean ledger ──────────────────────
set +e
out=$(TASKPUMP_TASKS_DIR="$TMPDIR_TEST/nope" "$CLI" fsck 2>&1)
rc=$?
set -e
[[ $rc -eq 1 ]] && pass "a missing tasks dir exits 1, not 0 or 3" \
  || fail "missing tasks dir exited $rc"
[[ "$out" == *"no tasks directory"* ]] && pass "and says what is missing" \
  || fail "missing-dir diagnostic was '$out'"

# ── the import round-trip: bare markdown → --fix → clean → in the frontier ───
echo
echo "--- --fix: the bare-markdown import path ---"

IMP="$TMPDIR_TEST/import"
mkdir -p "$IMP/tasks"
git -C "$IMP" init -q
printf -- '---\nid: T1\ntitle: First imported task\n---\n\n# T1 — body  with   odd spacing\n\n- a list\n' >| "$IMP/tasks/T1.md"
printf -- '---\nid: T2\ntitle: Second imported task\n---\n\n# T2\n' >| "$IMP/tasks/T2.md"
git -C "$IMP" add -A
git -C "$IMP" -c user.name=test -c user.email=t@e commit -q -m "import the bare DAG"
body_before=$(awk 'body { print; next } NR > 1 && $0 == "---" { body = 1 }' "$IMP/tasks/T1.md")

# Report mode first: the bare files are violations, not silently tolerated.
set +e
out=$(TASKPUMP_TASKS_DIR="$IMP/tasks" "$CLI" fsck 2>/dev/null)
rc=$?
set -e
[[ $rc -eq 3 ]] && pass "a bare ledger reports before it is stamped" \
  || fail "bare ledger exited $rc, expected 3"
grep -qF "T1.md: missing machine key 'status'" <<<"$out" \
  && pass "the missing status is named" || fail "missing status not named: '$out'"

# Stamp it — with committing ON, so the repair is one auditable ledger commit.
commits_before=$(git -C "$IMP" rev-list --count HEAD)
set +e
out=$(TASKPUMP_TASK_NOCOMMIT=0 TASKPUMP_TASKS_DIR="$IMP/tasks" "$CLI" fsck --fix 2>/dev/null)
rc=$?
set -e
[[ $rc -eq 0 ]] && pass "--fix on an all-stampable ledger exits 0" \
  || fail "--fix exited $rc: '$out'"
grep -qF "T1.md: stamped missing machine key(s):" <<<"$out" \
  && pass "--fix says what it stamped" || fail "--fix reported nothing for T1: '$out'"

commits_after=$(git -C "$IMP" rev-list --count HEAD)
[[ "$commits_after" -eq $((commits_before + 1)) ]] \
  && pass "the whole repair is exactly one ledger commit" \
  || fail "commit count went $commits_before -> $commits_after"
got=$(git -C "$IMP" log -1 --format='%an')
[[ "$got" == "tp-task" ]] && pass "the repair commit carries the ledger committer identity" \
  || fail "repair committer was '$got'"
got=$(git -C "$IMP" log -1 --format='%s')
[[ "$got" == *"fsck --fix"* ]] && pass "the commit message names the verb" \
  || fail "repair commit message was '$got'"

# The review keys are verb-added: legal to omit, so --fix must not stamp them
# — a plain task that never met the review verb stays a plain task.
grep -qE '^review_' "$IMP/tasks/T1.md" \
  && fail "--fix stamped review keys onto a plain task" \
  || pass "--fix leaves the verb-added review keys unstamped"

# Round-trip, leg two: the stamped ledger is clean.
set +e
out=$(TASKPUMP_TASKS_DIR="$IMP/tasks" "$CLI" fsck 2>&1)
rc=$?
set -e
[[ $rc -eq 0 && -z "$out" ]] && pass "fsck is clean after --fix" \
  || fail "post-fix fsck rc=$rc output='$out'"

# Leg three: the imported tasks are real ones — the frontier sees them.
got=$(TASKPUMP_TASKS_DIR="$IMP/tasks" "$CLI" ready --count)
[[ "$got" == "2" ]] && pass "tp task ready counts the imported tasks" \
  || fail "ready --count got '$got', expected 2"
got=$(TASKPUMP_TASKS_DIR="$IMP/tasks" TASKPUMP_TASK_OUT="$IMP/.next-task" "$CLI" next --branch feat/import | jq -r .id)
[[ "$got" == "T1" ]] && pass "tp task next surfaces an imported task" \
  || fail "next got '$got', expected T1"

# The body is human-owned: stamping must not have altered a byte of it.
body_after=$(awk 'body { print; next } NR > 1 && $0 == "---" { body = 1 }' "$IMP/tasks/T1.md")
[[ "$body_after" == "$body_before" ]] && pass "--fix left the body byte-identical" \
  || fail "--fix changed the body"

# ── --fix never rewrites a present-but-wrong value ───────────────────────────
echo
echo "--- --fix: present-but-wrong values are reported, not repaired ---"

WRT="$TMPDIR_TEST/wrongtype/tasks"
mkdir -p "$WRT"
full_task "$WRT/T1.md" T1 open '"oops-a-string"'   # blockers present, wrong type
cp "$WRT/T1.md" "$TMPDIR_TEST/T1.before"
# A broken-identity file with missing keys: --fix must not touch it either —
# writing to a file whose id is in question launders it into a half-plausible one.
printf -- '---\nid: T99\ntitle: Wrong stem\n---\n\n# stem says T5\n' >| "$WRT/T5.md"
cp "$WRT/T5.md" "$TMPDIR_TEST/T5.before"

set +e
out=$(TASKPUMP_TASKS_DIR="$WRT" "$CLI" fsck --fix 2>/dev/null)
rc=$?
set -e
[[ $rc -eq 3 ]] && pass "--fix still exits 3 when unfixable violations remain" \
  || fail "--fix exited $rc, expected 3"
cmp -s "$WRT/T1.md" "$TMPDIR_TEST/T1.before" \
  && pass "a wrong-typed present value is left byte-identical" \
  || fail "--fix rewrote the wrong-typed file"
grep -qF "T1.md: blockers: expected a list of task-id strings" <<<"$out" \
  && pass "and is still reported" || fail "wrong-typed value not reported: '$out'"
cmp -s "$WRT/T5.md" "$TMPDIR_TEST/T5.before" \
  && pass "a broken-identity file is left byte-identical" \
  || fail "--fix wrote into a file whose id does not match its name"
grep -qF "T5.md: id 'T99' does not match the filename stem 'T5'" <<<"$out" \
  && pass "and its identity violation is still reported" \
  || fail "identity violation not reported: '$out'"

# ── the grammar is the configured one, not a baked T ─────────────────────────
echo
echo "--- fsck under a consumer's own id pattern ---"

GEN="$TMPDIR_TEST/generic/tasks"
mkdir -p "$GEN"
full_task "$GEN/J1.md" J1
set +e
out=$(TASKPUMP_TASKS_DIR="$GEN" TASKPUMP_ID_PATTERN='^J[0-9]+(\.[0-9]+)?$' \
      TASKPUMP_PHASE_SIGIL=J "$CLI" fsck 2>&1)
rc=$?
set -e
[[ $rc -eq 0 && -z "$out" ]] && pass "a J-grammar ledger is clean under a J pattern" \
  || fail "J-grammar fsck rc=$rc output='$out'"
set +e
out=$(TASKPUMP_TASKS_DIR="$GEN" "$CLI" fsck 2>/dev/null)
rc=$?
set -e
[[ $rc -eq 3 ]] && pass "the same ledger violates the default T pattern" \
  || fail "default-pattern fsck exited $rc, expected 3"
grep -qF "J1.md: id 'J1' does not match TASKPUMP_ID_PATTERN" <<<"$out" \
  && pass "and the pattern line names the id" || fail "pattern violation not named: '$out'"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
