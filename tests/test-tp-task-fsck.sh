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
# T26: CRLF line endings — the shape an externally-authored DAG arrives in, and
# fsck's core audience. yq's front-matter mode parses it, so the frontier reads
# it fine; the delimiters are `---`, just CR-terminated. fsck called it "no YAML
# frontmatter", which sent an importer hunting for a delimiter that is right
# there.
full_task "$BAD/T26.md" T26
sed -i 's/$/\r/' "$BAD/T26.md"
# T27: the same machine key twice — the classic merge-conflict artifact. yq's
# tree keeps both entries and every reader takes the LAST, so a human reading
# the file top-down and every tool reading it disagree about what it says.
full_task "$BAD/T27.md" T27
sed -i 's/^status: open$/status: open\nstatus: done/' "$BAD/T27.md"
sed -i 's/^files: \[\]$/files: []\nfiles: [src\/a.txt]/' "$BAD/T27.md"
# T28: an empty blocker entry. The dangling check skips it and so does the
# eligibility predicate (§6), so the edge is inert in every reader — but it
# reads as a dependency in the file, and nothing said otherwise.
full_task "$BAD/T28.md" T28 open '[""]'
# T29/T30: CRLF files yq CANNOT read. Both CRLF diagnostics assert that yq
# reads the block and list/next/ready/scrub see the task, so they must lose to
# the parse and mapping checks — these are the invisible-to-the-frontier class
# scrub calls UNPARSEABLE and NO-ID, and answering one of them with a
# readability claim is fsck contradicting scrub about the same file. T29 is the
# unquoted-colon import (the F45.15 shape) in its Windows spelling; T30 is the
# README-in-the-tasks-dir case, CR-terminated.
printf -- '---\r\nid: T29\r\ntitle: Imported\r\ngoal: ship it: fast\r\n---\r\n\r\n# T29\r\n' >| "$BAD/T29.md"
printf -- '---\r\njust a note, not a mapping\r\n---\r\n\r\n# T30\r\n' >| "$BAD/T30.md"
# T31: an LF opening delimiter over CRLF frontmatter — the file the CR-tolerant
# delimiter comparison newly admits. Reading the CR off line 1 alone classified
# it as nothing at all, so --fix stamped it and converted endings nobody asked
# it to touch. The hazard is a property of the whole block fm_set rewrites.
full_task "$BAD/T31.md" T31
sed -i '1!s/$/\r/' "$BAD/T31.md"
# T32: the CR sits on the closing delimiter and nowhere else — the least of the
# half-Windows shapes, and still a block fm_set would rewrite as all-LF.
full_task "$BAD/T32.md" T32
awk '!closed && NR > 1 && $0 == "---" { printf "%s\r\n", $0; closed = 1; next } { print }' \
  "$BAD/T32.md" >| "$TMPDIR_TEST/T32.tmp"
mv "$TMPDIR_TEST/T32.tmp" "$BAD/T32.md"
# T33: the converse, and the boundary of the check — an all-LF frontmatter over
# a CRLF body. --fix rewrites the block only, and yq leaves the body's bytes
# alone, so nothing gets mixed and there is nothing to report. Silence here is
# what keeps the code-5 message ("--fix would convert the rest of the block")
# a true statement rather than a blanket complaint about carriage returns.
full_task "$BAD/T33.md" T33
awk 'body { printf "%s\r\n", $0; next } { print } NR > 1 && $0 == "---" { body = 1 }' \
  "$BAD/T33.md" >| "$TMPDIR_TEST/T33.tmp"
mv "$TMPDIR_TEST/T33.tmp" "$BAD/T33.md"
# T34: the CR on the keys and NOT on either delimiter. Every other CRLF shape
# here hides the block from lib/dag-layout.awk, which matches its delimiters as
# /^---[ \t]*$/; this one it finds, and then carries the CR into every value it
# reads. Same repair, different damage, so the two are separate lines — the
# whole point of the check is telling this file's owner what is true of it.
full_task "$BAD/T34.md" T34
awk '$0 == "---" { print; next } { printf "%s\r\n", $0 }' \
  "$BAD/T34.md" >| "$TMPDIR_TEST/T34.tmp"
mv "$TMPDIR_TEST/T34.tmp" "$BAD/T34.md"

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
expect_line "T26.md: CRLF line endings in the frontmatter, delimiters included" \
  "should name CRLF line endings when a task file is CR-terminated"
grep -q 'T26\.md: no YAML frontmatter' <<<"$out" \
  && fail "a CRLF file was still reported as having no frontmatter" \
  || pass "should not claim the frontmatter is missing when it is there behind a CR"
expect_line "T27.md: duplicate key 'status'" \
  "should name a duplicated machine key when a file carries one twice"
expect_line "T27.md: duplicate key 'files'" \
  "should name every duplicated key when a file carries more than one"
expect_line "T28.md: blockers contains an empty entry" \
  "should name an empty blocker entry when blockers carries one"
expect_line "T29.md: frontmatter is not valid YAML" \
  "should name the YAML error when a CRLF file's frontmatter does not parse"
grep -q 'T29\.md: CRLF line endings' <<<"$out" \
  && fail "an unparseable CRLF file was told the frontier reads it" \
  || pass "should not claim the frontier reads it when yq cannot parse the CRLF file"
expect_line "T30.md: frontmatter is not a YAML mapping" \
  "should name the missing mapping when a CRLF file's frontmatter is a scalar"
grep -q 'T30\.md: CRLF line endings' <<<"$out" \
  && fail "a scalar-frontmatter CRLF file was told the frontier reads it" \
  || pass "should not claim the frontier reads it when the CRLF frontmatter is no mapping"
expect_line "T31.md: CRLF line endings in the frontmatter, delimiters included" \
  "should name CRLF line endings when only the frontmatter after line 1 is CR-terminated"
expect_line "T32.md: CRLF line endings in the frontmatter, delimiters included" \
  "should name CRLF line endings when only the closing delimiter is CR-terminated"
grep -q 'T33\.md' <<<"$out" \
  && fail "an all-LF frontmatter over a CRLF body was reported" \
  || pass "should report nothing when the CRLF is in the body and not the frontmatter"
expect_line "T34.md: CRLF line endings on the frontmatter keys" \
  "should name the keys when they carry the CR and both --- delimiters are bare"
grep -q 'T34\.md: CRLF line endings in the frontmatter, delimiters included' <<<"$out" \
  && fail "a bare-delimiter file was told its delimiters are CR-terminated" \
  || pass "should not blame the delimiters when the delimiters are bare"

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

# ── CRLF: named, never rewritten, and repairable in two passes ───────────────
echo
echo "--- --fix: a CRLF file is named, not silently converted ---"

CR="$TMPDIR_TEST/crlf/tasks"
mkdir -p "$CR"
printf -- '---\r\nid: T1\r\ntitle: Imported from a Windows checkout\r\n---\r\n\r\n# T1\r\n' >| "$CR/T1.md"
cp "$CR/T1.md" "$TMPDIR_TEST/crlf-T1.before"

set +e
out=$(TASKPUMP_TASKS_DIR="$CR" "$CLI" fsck --fix 2>/dev/null)
rc=$?
set -e
[[ $rc -eq 3 ]] && pass "should still exit 3 when a CRLF file is all that remains" \
  || fail "--fix on a CRLF ledger exited $rc, expected 3"
cmp -s "$CR/T1.md" "$TMPDIR_TEST/crlf-T1.before" \
  && pass "should leave a CRLF file byte-identical when --fix runs" \
  || fail "--fix rewrote a CRLF file (fm_set writes LF frontmatter into a CRLF body)"

# The diagnostic tells the importer to convert and re-run; that has to be a
# workflow that actually terminates, not advice with no second leg.
sed -i 's/\r$//' "$CR/T1.md"
set +e
out=$(TASKPUMP_TASKS_DIR="$CR" "$CLI" fsck --fix 2>/dev/null)
rc=$?
set -e
[[ $rc -eq 0 ]] && pass "should stamp and go clean when the CRLF file is converted to LF" \
  || fail "post-conversion --fix exited $rc: '$out'"

# The half-Windows file: LF opening delimiter, CRLF from there on. Reading the
# CR off line 1 alone left this one classified as nothing, so --fix stamped it,
# rewrote its frontmatter to LF and then certified the ledger clean — a silent
# conversion of the operator's bytes followed by a false all-clear.
MIX="$TMPDIR_TEST/mixed/tasks"
mkdir -p "$MIX"
printf -- '---\nid: T1\r\ntitle: Half a Windows checkout\r\nstatus: open\r\n---\r\n\r\n# T1\r\n' >| "$MIX/T1.md"
cp "$MIX/T1.md" "$TMPDIR_TEST/mixed-T1.before"
set +e
out=$(TASKPUMP_TASKS_DIR="$MIX" "$CLI" fsck --fix 2>/dev/null)
rc=$?
set -e
[[ $rc -eq 3 ]] && pass "should exit 3 when only the frontmatter after line 1 is CR-terminated" \
  || fail "--fix on a half-CRLF ledger exited $rc, expected 3"
cmp -s "$MIX/T1.md" "$TMPDIR_TEST/mixed-T1.before" \
  && pass "should leave a half-CRLF file byte-identical when --fix runs" \
  || fail "--fix converted the line endings of a file it was never asked to touch"

# The other side of the boundary: an all-LF frontmatter over a CRLF body is
# stampable, because fm_set rewrites the block and yq leaves the body's bytes
# where they are. Refusing this one would be the same overreach in the other
# direction — a violation nobody can act on, about endings --fix never touches.
BODY="$TMPDIR_TEST/crlfbody/tasks"
mkdir -p "$BODY"
printf -- '---\nid: T1\ntitle: LF frontmatter\n---\n\r\n# T1 body\r\n' >| "$BODY/T1.md"
body_cr_before=$(tr -cd '\r' < "$BODY/T1.md" | wc -c)
set +e
out=$(TASKPUMP_TASKS_DIR="$BODY" "$CLI" fsck --fix 2>/dev/null)
rc=$?
set -e
[[ $rc -eq 0 ]] && pass "should stamp and go clean when only the body is CR-terminated" \
  || fail "--fix on a CRLF-body ledger exited $rc: '$out'"
body_cr_after=$(tr -cd '\r' < "$BODY/T1.md" | wc -c)
[[ "$body_cr_after" -eq "$body_cr_before" ]] \
  && pass "should leave the body's carriage returns alone when --fix stamps the frontmatter" \
  || fail "--fix changed the body CR count $body_cr_before -> $body_cr_after"

# ── a CRLF file is audited in full, and the second pass holds no surprises ───
echo
echo "--- CRLF: every other check still runs, and the re-run is a strict subset ---"

# The first cut of this returned as soon as it had classified the endings, so a
# CRLF file got the CRLF line and NO other check. An operator who did exactly
# what the line said and converted the endings then met a second, DIFFERENT
# report — the id mismatch and the dangling blocker had been in the file all
# along and were suppressed. Advice whose result is a fresh diagnosis is worse
# than no advice, so both runs are pinned: run one names everything, run two
# names run one minus the line-endings line and nothing else.
AUD="$TMPDIR_TEST/audit/tasks"
mkdir -p "$AUD"
full_task "$AUD/T40.md" T41 open '[T99]'      # CRLF + wrong id + dangling blocker
sed -i 's/$/\r/' "$AUD/T40.md"

set +e
first=$(TASKPUMP_TASKS_DIR="$AUD" "$CLI" fsck 2>/dev/null)
rc=$?
set -e
[[ $rc -eq 3 ]] && pass "should exit 3 for a CRLF file that carries other violations" \
  || fail "CRLF-plus-violations fsck exited $rc, expected 3"
if grep -qF "T40.md: CRLF line endings" <<<"$first" \
   && grep -qF "T40.md: id 'T41' does not match the filename stem 'T40'" <<<"$first" \
   && grep -qF "T40.md: blocker 'T99' names no task" <<<"$first"; then
  pass "should report every other violation alongside the CRLF one when a CRLF file also has a wrong id and a dangling blocker"
else
  fail "the CRLF file's other violations were suppressed: '$first'"
fi

sed -i 's/\r$//' "$AUD/T40.md"
set +e
second=$(TASKPUMP_TASKS_DIR="$AUD" "$CLI" fsck 2>/dev/null)
rc=$?
set -e
[[ $rc -eq 3 ]] && pass "should still exit 3 once the endings are converted and the rest remains" \
  || fail "post-conversion fsck exited $rc, expected 3"
[[ "$second" == "$(grep -v 'CRLF line endings' <<<"$first")" ]] \
  && pass "should report the same violation set minus the CRLF line when the operator converts the endings and re-runs" \
  || fail "the re-run was not the first run minus its CRLF line — first: '$first' second: '$second'"

# The two checks that read the file a second time rather than $fm_json — the
# duplicate-key walk goes back to yq, and the empty-blocker count to jq — are
# pinned separately: both sit below the endings verdict, and both are exactly
# what an imported Windows ledger arrives carrying.
AUD2="$TMPDIR_TEST/audit2/tasks"
mkdir -p "$AUD2"
full_task "$AUD2/T45.md" T45 open '[""]'
sed -i 's/^status: open$/status: open\nstatus: done/' "$AUD2/T45.md"
sed -i 's/$/\r/' "$AUD2/T45.md"
set +e
out=$(TASKPUMP_TASKS_DIR="$AUD2" "$CLI" fsck 2>/dev/null)
set -e
grep -qF "T45.md: duplicate key 'status'" <<<"$out" \
  && grep -qF "T45.md: blockers contains an empty entry" <<<"$out" \
  && pass "should still name a duplicate key and an empty blocker when the file is CRLF" \
  || fail "a CRLF file's duplicate key or empty blocker went unreported: '$out'"

# ── the CRLF lines, asserted against what the tools measurably do ────────────
echo
echo "--- CRLF: the diagnostic is pinned to measured behaviour, not to phrasing ---"

# Both CRLF lines make claims about OTHER tools, and the claim that got the
# first cut rejected ("every verb reads it") had never been measured against
# one. So each clause is driven here: the yq-backed verbs the lines say see the
# task, and lib/dag-layout.awk — the renderer's parser, and the monitor's GRAPH
# tab through it — which the lines say loses it.
MEAS="$TMPDIR_TEST/measured/tasks"
mkdir -p "$MEAS"
full_task "$MEAS/T50.md" T50                    # CR everywhere, delimiters included
sed -i 's/$/\r/' "$MEAS/T50.md"
full_task "$MEAS/T51.md" T51                    # CR on the keys, delimiters bare
awk '$0 == "---" { print; next } { printf "%s\r\n", $0 }' \
  "$MEAS/T51.md" >| "$TMPDIR_TEST/T51.tmp"
mv "$TMPDIR_TEST/T51.tmp" "$MEAS/T51.md"
# The downstream task carries its blockers in BLOCK style on purpose: the awk
# parser reads `blockers:` plus `  - id` lines and a flow list parses as no
# blockers at all (see write_blockers), so a flow-style fixture would prove
# nothing about which edges survive.
full_task "$MEAS/T52.md" T52
sed -i 's|^blockers: \[\]$|blockers:\n  - T50\n  - T51|' "$MEAS/T52.md"

got=$(TASKPUMP_TASKS_DIR="$MEAS" "$CLI" list --json | jq -r '[.[].id] | sort | join(",")')
[[ "$got" == "T50,T51,T52" ]] \
  && pass "should have list --json return both CRLF tasks, as the diagnostic says" \
  || fail "list --json returned '$got'"
got=$(TASKPUMP_TASKS_DIR="$MEAS" "$CLI" ready --count-eligible)
[[ "$got" == "2" ]] \
  && pass "should have the ready frontier hold both CRLF tasks, as the diagnostic says" \
  || fail "ready --count-eligible got '$got', expected 2"
got=$(TASKPUMP_TASKS_DIR="$MEAS" TASKPUMP_TASK_OUT="$TMPDIR_TEST/.next-crlf" \
      "$CLI" next --branch feat/crlf 2>/dev/null | jq -r .id)
[[ "$got" == "T50" ]] && pass "should have next dispatch a CRLF task, as the diagnostic says" \
  || fail "next got '$got', expected T50"
set +e
scrub_out=$(TASKPUMP_TASKS_DIR="$MEAS" "$CLI" scrub 2>&1)
rc=$?
set -e
[[ $rc -eq 0 ]] && ! grep -qE 'UNPARSEABLE|NO-ID' <<<"$scrub_out" \
  && pass "should have scrub call neither CRLF task invisible, as the diagnostic says" \
  || fail "scrub exited $rc saying: '$scrub_out'"

IDX="$TMPDIR_TEST/dag-index.tsv"
TASKPUMP_TASKS_DIR="$MEAS" TASKPUMP_PUMP_STATE_FILE="$TMPDIR_TEST/no-such.state" \
  "$TP_ROOT/libexec/tp-dag-render" --phases T50..T59 --no-color \
  --index-file "$IDX" >/dev/null 2>&1
dag_ids=$(cut -f1 "$IDX")
grep -qxF 'T50' <<<"$dag_ids" \
  && fail "the DAG drew a task whose --- delimiters are CR-terminated" \
  || pass "should be absent from the DAG when the CR is on the delimiters, as the diagnostic says"
grep -qF $'T51\r' <<<"$dag_ids" \
  && pass "should be drawn under a CR-bearing id when the CR is on the keys, as the diagnostic says" \
  || fail "the keys-CRLF task's DAG id was not CR-bearing: '$dag_ids'"
# Field 10 of the node table is the blocker column, `<id>:<status>` with "?" for
# an id the layout never saw — the edge the graph could not draw.
edges=$(awk -F'\t' '$1 == "T52" { print $10 }' "$IDX")
[[ "$edges" == "T50:?|T51:?" ]] \
  && pass "should drop every edge into a CRLF task, as the diagnostic says" \
  || fail "T52's DAG blocker column was '$edges', expected both edges unresolved"

# ── fsck and scrub answer for the same file the same way ─────────────────────
echo
echo "--- a file scrub calls invisible is never called readable by fsck ---"

# Every file here is invisible to the frontier: CRLF, and frontmatter yq cannot
# turn into a mapping. scrub has always said so. Both CRLF diagnostics assert
# the opposite in so many words ("list/next/ready/scrub see this task"), so if
# either can reach these files the two verbs of one CLI give contradictory
# verdicts — and the one that hides the tool's most important failure class is
# the wrong one.
CONTRA="$TMPDIR_TEST/contra/tasks"
mkdir -p "$CONTRA"
printf -- '---\r\nid: T1\r\ntitle: Imported\r\ngoal: ship it: fast\r\n---\r\n\r\n# T1\r\n' >| "$CONTRA/T1.md"
printf -- '---\r\njust a note, not a mapping\r\n---\r\n\r\n# T2\r\n' >| "$CONTRA/T2.md"

set +e
scrub_out=$(TASKPUMP_TASKS_DIR="$CONTRA" "$CLI" scrub 2>&1)
out=$(TASKPUMP_TASKS_DIR="$CONTRA" "$CLI" fsck 2>/dev/null)
set -e
visible=$(TASKPUMP_TASKS_DIR="$CONTRA" "$CLI" list --json | jq -r 'length')
[[ "$visible" -eq 0 ]] && pass "should keep both files off the frontier when yq cannot read them" \
  || fail "$visible of 2 unreadable files reached list --json"
# Anchored: scrub's trailing summary line names UNPARSEABLE/NO-ID too, and
# counting it would let a one-file report pass for a two-file one.
[[ "$(grep -cE '^scrub: (UNPARSEABLE|NO-ID) ' <<<"$scrub_out")" -eq 2 ]] \
  && pass "should have scrub name both files invisible when yq cannot read them" \
  || fail "scrub did not name both files: '$scrub_out'"
grep -q 'see this task' <<<"$out" \
  && fail "fsck called a file readable that scrub calls invisible" \
  || pass "should not call a file readable when scrub calls it invisible"

# ── a duplicate key is named, never resolved ─────────────────────────────────
# The fixture is missing a machine key on purpose, so --fix genuinely writes
# this file. A duplicate in a file --fix skips for some unrelated reason proves
# nothing about whether --fix would resolve one.
DUP="$TMPDIR_TEST/dup/tasks"
mkdir -p "$DUP"
full_task "$DUP/T1.md" T1
sed -i 's/^status: open$/status: open\nstatus: done/' "$DUP/T1.md"
sed -i '/^milestone: null$/d' "$DUP/T1.md"
set +e
out=$(TASKPUMP_TASKS_DIR="$DUP" "$CLI" fsck --fix 2>/dev/null)
rc=$?
set -e
[[ $rc -eq 3 ]] && pass "should exit 3 when a duplicate key survives --fix" \
  || fail "--fix on a duplicate-key ledger exited $rc, expected 3"
grep -qF "T1.md: stamped missing machine key(s): milestone" <<<"$out" \
  && pass "should still stamp the missing keys of a file that carries a duplicate" \
  || fail "--fix skipped the duplicate-key file entirely: '$out'"
[[ "$(grep -c '^status:' "$DUP/T1.md")" -eq 2 ]] \
  && pass "should leave both values of a duplicated key in place when --fix writes the file" \
  || fail "--fix picked one of two values for a duplicated key"
grep -qF "T1.md: duplicate key 'status'" <<<"$out" \
  && pass "should still name the duplicate after --fix has written the file" \
  || fail "the duplicate went unreported once --fix had written the file: '$out'"

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
