#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Tristan Misko
# test-pump-task-grain.sh — `tp pump --grain task` (issue #11).
#
# Phase grain serializes independent siblings behind one agent: during the
# 2026-08-13 canary G3.4/G3.5/G3.6 sat queued behind the G3 container while it
# worked G3.1, and jobs headroom went unused. Task grain dispatches each eligible
# TASK as its own unit — one worktree, one branch, one agent name.
#
# The finer grain is only worth having if every supervisor mechanism survives it,
# so that is what this suite pins, one mechanism per section:
#
#   1. fan-out         — disjoint siblings launch concurrently; the jobs cap holds
#   2. conflict rule   — overlapping footprints wait, and say what they wait on
#   3. liveness        — a live container is RUNNING, never re-launched
#   4. failure isolate — one sibling failing strands neither the others nor itself
#   5. resume          — a stranded claim resumes at task grain, with its context
#   6. naming          — an unnameable or COLLIDING unit is refused at tick zero
#   7. deadlock        — nothing live/launchable/resumable still exits 3, loudly
#   8. phase grain     — untouched: same range, same plan, phases not tasks
#   9. integration     — a quarantined MERGE never un-completes the WORK
#  10. range coverage  — every phase in the range contributes its tasks
#
# Hermetic throughout: a throwaway ledger, a throwaway git repo, a stub runner
# and a stub container runtime. Nothing here touches a real ledger or a real
# container.
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PUMP="$TP_ROOT/libexec/tp-pump"
REAL_TASK="$TP_ROOT/libexec/tp-task"

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
have() { grep -qE "$2" <<<"$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TASKS="$TMP/tasks";  mkdir -p "$TASKS"
BIN="$TMP/bin";      mkdir -p "$BIN"
OPS="$TMP/noops";    mkdir -p "$OPS"
HOME_STUB="$TMP/claude-home"; mkdir -p "$HOME_STUB"

# ── Stubs ─────────────────────────────────────────────────────────────────────
# docker: answers `docker ps ... --format {{.Names}}` from $STUB_LIVE. Liveness
# is the one thing this suite must never read from the host.
cat >| "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "ps" ]]; then printf '%s\n' ${STUB_LIVE:-}; exit 0; fi
exit 0
EOF
# The agent runner. `launch` records the environment the pump handed it, one
# line per launch, and fails for whichever branch $STUB_RUNNER_FAIL names — that
# is how "one sibling fails" is simulated without a container. Exit 2 for `list`
# keeps it a v1 runner, so liveness stays on the name scrape above.
cat >| "$BIN/runner.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) exit 2 ;;
  launch)
    printf '%s\t%s\t%s\t%s\n' "$TP_BRANCH" "$TP_TASK_ID" "$TP_PHASE" "$TP_MAX_TURNS" \
      >> "${STUB_RUNNER_LOG:-/dev/null}"
    if [[ -n "${STUB_RUNNER_FAIL:-}" && "$TP_BRANCH" == "$STUB_RUNNER_FAIL" ]]; then
      echo "stub runner: refusing $TP_BRANCH" >&2
      exit 1
    fi
    printf 'deadbeefcafe\n'
    ;;
esac
exit 0
EOF
chmod +x "$BIN/docker" "$BIN/runner.sh"

export TASKPUMP_TASKS_DIR="$TASKS"
export TASKPUMP_TASK="$REAL_TASK"
export TASKPUMP_TASK_NOCOMMIT=1
export ARACHNE_TASK_NOCOMMIT=1
export DOCKER="$BIN/docker"
# The fixture ledger's own shape, pinned rather than inherited from a default.
export TASKPUMP_ID_PATTERN='^G[0-9]+(\.[A-Za-z0-9]+)?$'
export TASKPUMP_PHASE_SIGIL=G
export TASKPUMP_AGENT_PREFIX=tp-agent-
# Gates are not this suite's subject: the token and disk gates read the host.
export TASKPUMP_TOKEN_GATE=0
export TASKPUMP_DISK_GATE=0

mk() {  # mk <id> <status> [blockers_csv] [files_csv] [claimed_by]
  local id=$1 status=$2 blockers=${3:-} files=${4:-} claimed=${5:-}
  local by="[]" fl="[]" cb="null" f
  [[ -n "$blockers" ]] && by="[$(printf '%s' "$blockers" | sed 's/,/, /g')]"
  if [[ -n "$files" ]]; then
    fl=""
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      fl+="${fl:+, }\"$f\""
    done < <(printf '%s\n' "${files//,/$'\n'}")
    fl="[$fl]"
  fi
  [[ -n "$claimed" ]] && cb="\"$claimed\""
  cat >| "$TASKS/$id.md" <<EOF
---
id: $id
phase: ${id%%.*}
title: fixture $id
status: $status
claimed_by: $cb
claimed_at: null
turn_budget_remaining: null
consecutive_failed_iterations: 0
blockers: $by
completed_by_commits: []
files: $fl
goal: drain $id
---
# $id
EOF
}

# The independent-siblings fixture the issue is about: G3.0 done, then three
# siblings with pairwise-disjoint footprints and no blockers on each other.
sibling_fixture() {
  rm -f "$TASKS"/*.md
  mk G3.0 done  ""    "docs/design.md"
  mk G3.1 open  ""    "libexec/tp-pump"
  mk G3.2 open  ""    "libexec/tp-task"
  mk G3.3 open  ""    "docs/RUNNERS.md"
}

pump() { "$PUMP" --no-health-gate --no-usage-gate --dry-run --phases "$1" "${@:2}"; }
tpump() { pump "$1" --grain task "${@:2}"; }

# ── 1. Fan-out: independent siblings dispatch concurrently ────────────────────
echo "--- 1. independent siblings fan out, one branch and one agent each ---"
sibling_fixture
out=$(tpump G3)
have "$out" 'grain task' && pass "the plan header names the grain it ran at" || fail "grain not in header:\n$out"
have "$out" 'LAUNCH   G3\.1 +-> feat/g3\.1' && pass "G3.1 launches on its own branch" || fail "G3.1 not LAUNCH:\n$out"
have "$out" 'LAUNCH   G3\.2 +-> feat/g3\.2' && pass "G3.2 launches on its own branch" || fail "G3.2 not LAUNCH:\n$out"
have "$out" 'LAUNCH   G3\.3 +-> feat/g3\.3' && pass "G3.3 launches on its own branch" || fail "G3.3 not LAUNCH:\n$out"
have "$out" 'frontier: 3 launchable' && pass "three siblings are launchable at once (phase grain offers one)" \
  || fail "wrong launchable count:\n$out"
have "$out" 'DONE     G3\.0' && pass "a finished task renders DONE at task grain" || fail "G3.0 not DONE:\n$out"

# The plan is a plan, not a launch: the same fixture at phase grain offers ONE
# unit, which is exactly the serialization this grain exists to undo.
out=$(pump G3)
have "$out" 'LAUNCH   G3 +-> feat/g3' && pass "phase grain still offers the phase as one unit" || fail "phase plan changed:\n$out"
have "$out" 'G3\.1' && fail "phase grain leaked task ids into its plan:\n$out" || pass "phase grain names no task ids"

echo "--- 1b. the jobs cap governs total concurrent TASKS ---"
# A NO_LAUNCH tick reports what it would have started; the cap must bind at the
# finer grain exactly as it binds at phase grain.
# TASKPUMP_STATE_DIR, here and on the stall tick in section 7, because these
# are the two real ticks in this suite that pin no workspace: the pump's cwd
# rung then resolves REPO_ROOT to the TaskPump CHECKOUT the suite runs from, and
# any $STATE_DIR-derived name not individually redirected lands in it (B16). The
# mark file is not one of them — it follows TASKPUMP_HOOK_MARK_FILE from
# tests/suite-prologue.sh, which outranks $STATE_DIR, and that redirect is what
# stopped this suite deleting the operator's live .taskpump-fsguard.notified.
# This pin is the backstop for the rest of the family, kept so a name that stops
# being pinned by hand cannot reach the checkout. The ticks below that set
# TASKPUMP_WORKSPACE_ROOT are already anchored in $TMP.
cap_tick() {  # cap_tick <jobs>
  TASKPUMP_PUMP_NO_LAUNCH=1 \
  TASKPUMP_STATE_DIR="$TMP" \
  TASKPUMP_PUMP_OPS_DIR="$OPS" \
  TASKPUMP_PUMP_STATE_FILE="$TMP/cap.state" \
  TASKPUMP_POOL_CAP_FILE="$TMP/cap.file" \
  TASKPUMP_PUMP_LOG="$TMP/cap.log" \
  "$PUMP" --no-health-gate --no-usage-gate --once --phases G3 --grain task --jobs "$1" 2>&1
}
sibling_fixture
rm -f "$TMP/cap.file"
out=$(cap_tick 2)
n=$(grep -c 'would launch' <<<"$out")
[[ "$n" -eq 2 ]] && pass "--jobs 2 launches exactly two of three eligible tasks" || fail "launched $n tasks under --jobs 2:\n$out"
rm -f "$TMP/cap.file"
out=$(cap_tick 3)
n=$(grep -c 'would launch' <<<"$out")
[[ "$n" -eq 3 ]] && pass "--jobs 3 launches all three" || fail "launched $n tasks under --jobs 3:\n$out"

# ── 2. The conflict rule ──────────────────────────────────────────────────────
echo "--- 2. overlapping footprints wait, and the plan names the overlap ---"
rm -f "$TASKS"/*.md
mk G3.1 open "" "libexec/tp-pump"
mk G3.2 open "" "libexec/tp-pump,docs/RUNNERS.md"
mk G3.3 open "" "docs/GATES.md"
out=$(tpump G3)
have "$out" 'LAUNCH   G3\.1' && pass "the first of an overlapping pair launches" || fail "G3.1 not LAUNCH:\n$out"
have "$out" 'WAITING  G3\.2 +\(files overlap with G3\.1: libexec/tp-pump\)' \
  && pass "the second WAITS, naming the task and the path they collide on" || fail "no named overlap:\n$out"
have "$out" 'LAUNCH   G3\.3' && pass "a disjoint third sibling is unaffected by the pair" || fail "G3.3 not LAUNCH:\n$out"

echo "--- 2b. an empty files: is EXCLUSIVE, in both directions ---"
# An undeclared footprint means "unknown", and scheduling unknown as "touches
# nothing" is the silent wrong answer: two agents on one file, a plan that
# reported it clean.
rm -f "$TASKS"/*.md
mk G3.1 open "" "libexec/tp-pump"
mk G3.2 open "" ""
out=$(tpump G3)
have "$out" 'LAUNCH   G3\.1' && pass "the declared task launches" || fail "G3.1 not LAUNCH:\n$out"
have "$out" 'WAITING  G3\.2 +\(files: empty — exclusive' \
  && pass "an undeclared task waits, and the plan says why in as many words" || fail "empty-files hold not named:\n$out"
rm -f "$TASKS"/*.md
mk G3.1 open "" ""
mk G3.2 open "" "libexec/tp-pump"
out=$(tpump G3)
have "$out" 'LAUNCH   G3\.1' && pass "an undeclared task admitted first still launches" || fail "G3.1 not LAUNCH:\n$out"
have "$out" 'WAITING  G3\.2 +\(G3\.1 declares no files:' \
  && pass "and it holds the whole tree against everything after it" || fail "exclusivity not enforced downward:\n$out"

echo "--- 2c. a blocked sibling waits, naming the blocker it waits on ---"
rm -f "$TASKS"/*.md
mk G3.1 open ""     "libexec/tp-pump"
mk G3.2 open G3.1   "libexec/tp-task"
out=$(tpump G3)
have "$out" 'WAITING  G3\.2 +\(blockers pending: G3\.1\)' && pass "a blocked task names its pending blocker" \
  || fail "blocker reason missing:\n$out"

# ── 3. Liveness at task grain ─────────────────────────────────────────────────
echo "--- 3. a live container is RUNNING, never launched again ---"
sibling_fixture
out=$(STUB_LIVE="tp-agent-feat-g3.1" tpump G3)
have "$out" 'RUNNING  G3\.1 +-> feat/g3\.1 \(live container\)' && pass "the live task is RUNNING" || fail "G3.1 not RUNNING:\n$out"
have "$out" 'LAUNCH   G3\.1' && fail "a live task was also planned for launch:\n$out" || pass "a live task is never double-launched"
have "$out" 'LAUNCH   G3\.2' && pass "its siblings keep launching beside it" || fail "G3.2 not LAUNCH:\n$out"

echo "--- 3b. a RUNNING task holds its footprint against candidates ---"
rm -f "$TASKS"/*.md
mk G3.1 open "" "libexec/tp-pump" feat/g3.1
mk G3.2 open "" "libexec/tp-pump"
out=$(STUB_LIVE="tp-agent-feat-g3.1" tpump G3)
have "$out" 'RUNNING  G3\.1' && pass "the running task is reported running" || fail "G3.1 not RUNNING:\n$out"
have "$out" 'WAITING  G3\.2 +\(files overlap with G3\.1' \
  && pass "a candidate overlapping LIVE work waits, not just one overlapping a planned launch" \
  || fail "live footprint not held:\n$out"

# ── 4. A real tick: per-task worktrees, and one sibling failing ───────────────
echo "--- 4. a real tick cuts one worktree, branch and agent per task ---"
REPO="$TMP/project"
git init -q -b main "$REPO"
git -C "$REPO" config user.name  'taskpump-fixture'
git -C "$REPO" config user.email 'fixture@taskpump.test'
printf 'fixture\n' >| "$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm 'seed'

RUNLOG="$TMP/runner.log"
real_tick() {  # real_tick [extra pump flags...] — one --once tick that launches
  : >| "$RUNLOG"
  TASKPUMP_WORKSPACE_ROOT="$REPO" \
  TASKPUMP_PUMP_WORKTREES_DIR="$REPO/.worktrees" \
  TASKPUMP_PUMP_OPS_DIR="$OPS" \
  TASKPUMP_PUMP_STATE_FILE="$TMP/real.state" \
  TASKPUMP_POOL_CAP_FILE="$TMP/real.cap" \
  TASKPUMP_PUMP_LOG="$TMP/real.log" \
  TASKPUMP_RUNNER="$BIN/runner.sh" \
  TASKPUMP_IMAGE=fixture-image \
  TASKPUMP_IMAGE_BUILD= \
  TASKPUMP_AGENT_HOME="$HOME_STUB" \
  TASKPUMP_PUMP_NO_GH=1 \
  TASKPUMP_STAGGER=0 \
  STUB_RUNNER_LOG="$RUNLOG" \
  "$PUMP" --no-health-gate --no-usage-gate --once --phases G3 --grain task "$@" 2>&1
}
sibling_fixture
rm -f "$TMP/real.cap"
out=$(real_tick)
launched=$(cut -f1 "$RUNLOG" 2>/dev/null | sort)
[[ "$launched" == "$(printf 'feat/g3.1\nfeat/g3.2\nfeat/g3.3')" ]] \
  && pass "three tasks, three distinct branches handed to the runner" || fail "runner saw:\n$launched\n$out"
[[ "$(cut -f2 "$RUNLOG" | sort | tr '\n' ' ')" == "G3.1 G3.2 G3.3 " ]] \
  && pass "each container is pointed at its OWN task id" || fail "task ids: $(cut -f2 "$RUNLOG" | tr '\n' ' ')"
[[ "$(cut -f3 "$RUNLOG" | sort -u)" == "G3" ]] && pass "each still carries its phase for the brief" \
  || fail "phases: $(cut -f3 "$RUNLOG" | sort -u)"
[[ "$(cut -f4 "$RUNLOG" | sort -u)" == "120" ]] \
  && pass "a task session gets the task turn budget, not the phase-drain one" \
  || fail "turn budget: $(cut -f4 "$RUNLOG" | sort -u)"
for b in g3.1 g3.2 g3.3; do
  git -C "$REPO" rev-parse --verify "refs/heads/feat/$b" >/dev/null 2>&1 \
    && pass "branch feat/$b was cut from the base" || fail "no branch feat/$b"
  [[ -d "$REPO/.worktrees/feat/$b" ]] && pass "worktree for feat/$b exists" || fail "no worktree for feat/$b"
done
brief="$REPO/.worktrees/feat/g3.1/.taskpump-phase-brief.md"
[[ -f "$brief" ]] && grep -qF 'task G3.1' "$brief" && pass "the rendered brief names the one task it was launched for" \
  || fail "brief missing or unscoped: $(head -3 "$brief" 2>/dev/null)"
grep -qF 'Do not run' "$brief" 2>/dev/null \
  && pass "the task brief forbids the acquisition loop the pump owns at this grain" \
  || fail "task brief does not forbid next:\n$(head -20 "$brief" 2>/dev/null)"

echo "--- 4b. one sibling's launch failing strands neither its siblings nor itself ---"
# At phase grain a failure inside a phase stops that phase's whole serial drain.
# At task grain the blast radius must be one task: the others launch, and the
# failed one stays eligible for the next tick rather than being consumed.
sibling_fixture
rm -f "$TMP/real.cap"
out=$(STUB_RUNNER_FAIL="feat/g3.2" real_tick)
have "$out" 'runner failed to launch G3\.2' && pass "the failing task is reported by name" || fail "no failure report:\n$out"
have "$out" 'launched G3\.1' && pass "its sibling G3.1 launched anyway" || fail "G3.1 did not launch:\n$out"
have "$out" 'launched G3\.3' && pass "its sibling G3.3 launched anyway" || fail "G3.3 did not launch:\n$out"
out=$(tpump G3)
have "$out" 'LAUNCH   G3\.2' && pass "the failed task is still eligible on the next plan" \
  || fail "a failed launch consumed the task:\n$out"

# ── 4c. What the shipped task brief actually says ─────────────────────────────
echo "--- 4c. the shipped task brief renders correctly for both footprint shapes ---"
rb() { "$PUMP" --no-health-gate --no-usage-gate --grain task --render-brief "$1" 2>&1; }

rm -f "$TASKS"/*.md
mk G3.1 open "" "libexec/tp-pump,docs/RUNNERS.md"
mk G3.2 open "" ""
out=$(rb G3.1)
# TASKPUMP_VERIFY_CMDS is unset here, which is the SHIPPED default — and the
# optional verify step used to be its own numbered item inside the conditional
# section, so the default render counted 1,2,3,4,6,7,8. A brief that cannot
# count is a brief an agent is entitled to distrust.
steps=$(grep -oE '^[0-9]+\.' <<<"$out" | tr -d '.' | tr '\n' ' ')
[[ "$steps" == "1 2 3 4 5 6 7 " ]] \
  && pass "the working-method list numbers 1-7 with no gap when VERIFY_CMDS is unset" \
  || fail "numbered steps render as: $steps"
have "$out" 'sets are disjoint' \
  && pass "a task WITH a declared footprint is told why it may run beside its siblings" \
  || fail "the disjointness sentence is missing for a declared task:\n$out"
have "$out" 'libexec/tp-pump' && pass "and the brief names the paths it declared" \
  || fail "the brief does not name the declared files:\n$out"

out=$(rb G3.2)
have "$out" 'sets are disjoint' \
  && fail "a task with files: [] was told it runs concurrently BECAUSE its set is disjoint:\n$out" \
  || pass "an undeclared task is not told the disjointness story that does not apply to it"
have "$out" 'declares no .files:., so you are running alone' \
  && pass "it is told the true reason it was scheduled: exclusively" \
  || fail "the empty-footprint case is unexplained:\n$out"

# The task brief carried the same dead rung its phase-grain sibling did — a probe
# of ops/task-loop/briefs/_task-template.md ahead of the shipped file (issue
# #37). One consumer's directory layout is not a resolution rung: an unconfigured
# file there must not silently become what the launched agent reads.
DEADRUNG="$TMP/deadrung"; mkdir -p "$DEADRUNG/ops/task-loop/briefs"
printf 'ledger-side task template for {{TASK_ID}}\n' \
  >| "$DEADRUNG/ops/task-loop/briefs/_task-template.md"
out=$(TASKPUMP_PUMP_OPS_DIR="$DEADRUNG/ops" rb G3.1)
have "$out" 'ledger-side task template' \
  && fail "should ignore a ledger-side _task-template.md when no template is configured:\n$out" \
  || pass "should ignore a ledger-side _task-template.md when no template is configured"
# And the not-found message must not send an operator to author it either.
out=$(TASKPUMP_PUMP_OPS_DIR="$DEADRUNG/ops" \
      TASKPUMP_TASK_BRIEF_TEMPLATE="$TMP/no-such-task-template.md" rb G3.1)
have "$out" 'task-loop/briefs' \
  && fail "should not name the deleted ledger rung when the configured task brief is missing:\n$out" \
  || pass "should not name the deleted ledger rung when the configured task brief is missing"
have "$out" 'templates/task-brief\.md' \
  && pass "should name the shipped task brief when the configured one is missing" \
  || fail "the not-found message does not name the shipped task brief:\n$out"

echo "--- 4d. --render-brief refuses a PHASE token at task grain ---"
# A debug path that fabricates a task brief for a phase — "your job is one task:
# G3", pointing at tasks/G3.md, which does not exist — is a plausible-looking
# answer to a question nobody asked.
rc=0; out=$(rb G3) || rc=$?
[[ "$rc" -ne 0 ]] && pass "--render-brief G3 at task grain refuses (rc=$rc)" \
  || fail "a task brief was rendered for a phase token:\n$out"
have "$out" 'not a task in range' && pass "and says what is wrong with the argument" \
  || fail "refusal is vague:\n$out"
have "$out" 'grain task' && pass "and names the way out" || fail "no remedy in the refusal:\n$out"
out=$(pump G3 --render-brief G3 2>&1)
have "$out" 'phase G3' && pass "the same token at phase grain still renders the phase-drain brief" \
  || fail "phase-grain --render-brief regressed:\n$out"

# ── 5. Resume-with-context at task grain ──────────────────────────────────────
echo "--- 5. a stranded claim on a task branch resumes, with its commits ---"
# The F79 shape, one grain finer: an agent claimed G3.2, committed real work, and
# died. `ready` shows only open tasks, so the claim is invisible to the frontier;
# reclaim refuses to reopen it (there are commits); without the resume path the
# task is unreachable and everything behind it starves.
#
# Its own fixture repo: section 4's real tick already cut feat/g3.2 and left
# worktrees under .worktrees, so reusing that tree would land this commit on
# main and the branch would be 0 ahead — the stall would go undetected for a
# reason that has nothing to do with the mechanism under test.
REPO2="$TMP/project-resume"
git init -q -b main "$REPO2"
git -C "$REPO2" config user.name  'taskpump-fixture'
git -C "$REPO2" config user.email 'fixture@taskpump.test'
printf 'fixture\n' >| "$REPO2/README.md"
git -C "$REPO2" add -A
git -C "$REPO2" commit -qm 'seed'
git -C "$REPO2" switch -qc feat/g3.2 main
printf 'partial\n' >| "$REPO2/partial.txt"
git -C "$REPO2" add -A
git -C "$REPO2" commit -qm 'feat(g3.2): partial work from the dead agent'
git -C "$REPO2" switch -q main
# The dead agent's worktree survives it — that is where the resume note reads
# the branch state from, and what a relaunched container is pointed back at.
git -C "$REPO2" worktree add -q "$REPO2/.worktrees/feat/g3.2" feat/g3.2

rm -f "$TASKS"/*.md
mk G3.1 open ""     "libexec/tp-pump"
mk G3.2 in_progress "" "libexec/tp-task" feat/g3.2
mk G3.3 open G3.2   "docs/RUNNERS.md"

rpump() {
  TASKPUMP_WORKSPACE_ROOT="$REPO2" \
  TASKPUMP_PUMP_WORKTREES_DIR="$REPO2/.worktrees" \
  TASKPUMP_PUMP_OPS_DIR="$OPS" \
  TASKPUMP_PUMP_STATE_FILE="$TMP/resume.state" \
  TASKPUMP_POOL_CAP_FILE="$TMP/resume.cap" \
  TASKPUMP_RUNNER="$BIN/runner.sh" \
  TASKPUMP_PUMP_NO_GH=1 \
  "$PUMP" --no-health-gate --no-usage-gate --grain task "$@" 2>&1
}
out=$(STUB_LIVE="" rpump --dry-run --phases G3)
have "$out" 'RESUME   G3\.2 +-> feat/g3\.2 \(stalled on G3\.2, in_progress' \
  && pass "the stranded claim plans as RESUME on its own branch" || fail "G3.2 not RESUME:\n$out"
have "$out" 'DONE     G3\.2' && fail "committed, unfinished work was classified DONE:\n$out" \
  || pass "committed, unfinished work is never DONE"
have "$out" 'WAITING  G3\.3 +\(blockers pending: G3\.2\)' && pass "what waits behind it is still visible" \
  || fail "G3.3 reason wrong:\n$out"

note=$(STUB_LIVE="" rpump --render-resume-note G3.2)
have "$note" 'RESUME CONTEXT' && pass "the resume note renders at task grain" || fail "no resume note:\n$note"
have "$note" 'G3\.2' && pass "it names the stranded task" || fail "note does not name the task:\n$note"
have "$note" 'Do NOT start by running' && pass "it keeps the next-returns-null warning" || fail "warning missing:\n$note"
have "$note" 'partial work from the dead agent' && pass "it lists what the dead session already committed" \
  || fail "note lacks the commit list:\n$note"

echo "--- 5b. a live container on the stalled branch is never resumed over ---"
out=$(STUB_LIVE="tp-agent-feat-g3.2" rpump --dry-run --phases G3)
have "$out" 'RESUME   G3\.2' && fail "resumed a task with a live container:\n$out" || pass "live ⇒ no resume"
have "$out" 'RUNNING  G3\.2' && pass "it is reported RUNNING instead" || fail "G3.2 not RUNNING:\n$out"

echo "--- 5c. a claim on a branch this pump does not own is left alone ---"
mk G3.2 in_progress "" "libexec/tp-task" feat/somebody-else
out=$(STUB_LIVE="" rpump --dry-run --phases G3)
have "$out" 'RESUME   G3\.2' && fail "resumed a foreign-branch claim:\n$out" || pass "a foreign claim is not resumed"
have "$out" 'WAITING  G3\.2 +\(claimed by feat/somebody-else' \
  && pass "and the plan says whose it is" || fail "foreign claim not explained:\n$out"

echo "--- 5d. a RESUMED unit holds its footprint too (the disjoint rule is not bypassable) ---"
# The blocking defect the 2026-08-14 adversarial review found: RESUME was
# classified inline in the admission loop WITHOUT becoming a holder, and do_tick
# dispatches PLAN_RESUME and PLAN_LAUNCH in the SAME tick. A stranded task and an
# eligible task with the IDENTICAL files: planned as RESUME + LAUNCH, reported
# "0 waiting", and a real tick started both containers on one file — the plan
# looking clean while scheduling the collision this whole grain exists to refuse.
rtick() {  # a REAL --once tick against the resume fixture repo
  : >| "$RUNLOG"
  TASKPUMP_WORKSPACE_ROOT="$REPO2" \
  TASKPUMP_PUMP_WORKTREES_DIR="$REPO2/.worktrees" \
  TASKPUMP_PUMP_OPS_DIR="$OPS" \
  TASKPUMP_PUMP_STATE_FILE="$TMP/rd.state" \
  TASKPUMP_POOL_CAP_FILE="$TMP/rd.cap" \
  TASKPUMP_PUMP_LOG="$TMP/rd.log" \
  TASKPUMP_RUNNER="$BIN/runner.sh" \
  TASKPUMP_IMAGE=fixture-image \
  TASKPUMP_IMAGE_BUILD= \
  TASKPUMP_AGENT_HOME="$HOME_STUB" \
  TASKPUMP_PUMP_NO_GH=1 \
  TASKPUMP_STAGGER=0 \
  STUB_RUNNER_LOG="$RUNLOG" \
  STUB_LIVE="" \
  "$PUMP" --no-health-gate --no-usage-gate --once --phases G3 --grain task 2>&1
}

# The resumable sorts AHEAD of the eligible one.
rm -f "$TASKS"/*.md
mk G3.2 in_progress "" "libexec/shared.sh" feat/g3.2
mk G3.5 open        "" "libexec/shared.sh"
out=$(STUB_LIVE="" rpump --dry-run --phases G3)
have "$out" 'RESUME   G3\.2' && pass "the stranded task still resumes" || fail "G3.2 not RESUME:\n$out"
have "$out" 'LAUNCH   G3\.5' && fail "an identical footprint was scheduled beside a RESUME:\n$out" \
  || pass "the eligible task with the identical footprint is not launched beside it"
have "$out" 'WAITING  G3\.5 +\(files overlap with G3\.2: libexec/shared\.sh\)' \
  && pass "it WAITS, naming the resumed task and the path they collide on" \
  || fail "the hold is unnamed or missing:\n$out"
have "$out" 'frontier: 0 launchable, 0 running, 1 resumable, 1 waiting' \
  && pass "and the frontier line counts the hold instead of reporting 0 waiting" \
  || fail "frontier counts wrong:\n$out"

# ...and the case an append-as-you-go holder list could never have caught: the
# resumable sorts AFTER the candidate it has to bind.
rm -f "$TASKS"/*.md
mk G3.0 open        "" "libexec/shared.sh"
mk G3.2 in_progress "" "libexec/shared.sh" feat/g3.2
out=$(STUB_LIVE="" rpump --dry-run --phases G3)
have "$out" 'RESUME   G3\.2' && pass "a resumable that sorts last still resumes" || fail "G3.2 not RESUME:\n$out"
have "$out" 'LAUNCH   G3\.0' && fail "a candidate planned BEFORE the resume was admitted onto its files:\n$out" \
  || pass "a candidate planned before the resume is held by it too"
have "$out" 'WAITING  G3\.0 +\(files overlap with G3\.2' \
  && pass "and says which unit holds the path" || fail "hold reason wrong:\n$out"

# The plan is only half the claim; the tick is the other half.
rm -f "$TASKS"/*.md
mk G3.2 in_progress "" "libexec/shared.sh" feat/g3.2
mk G3.5 open        "" "libexec/shared.sh"
rm -f "$TMP/rd.cap"
out=$(rtick)
n=$(wc -l < "$RUNLOG")
[[ "$n" -eq 1 ]] && pass "a real tick starts exactly ONE container over two identical footprints" \
  || fail "the runner was handed $n launches:\n$(cat "$RUNLOG")\n$out"
[[ "$(cut -f1 "$RUNLOG")" == "feat/g3.2" ]] \
  && pass "and it is the resumed branch, not the eligible sibling" \
  || fail "runner saw branch $(cut -f1 "$RUNLOG")"

echo "--- 5e. a LIVE container holds its footprint against a resume ---"
# The same rule from the other side: a resume is a launch, so it is checked
# against what is already running rather than waved through.
rm -f "$TASKS"/*.md
mk G3.1 in_progress "" "libexec/shared.sh" feat/g3.1
mk G3.2 in_progress "" "libexec/shared.sh" feat/g3.2
out=$(STUB_LIVE="tp-agent-feat-g3.1" rpump --dry-run --phases G3)
have "$out" 'RUNNING  G3\.1' && pass "the live task is RUNNING" || fail "G3.1 not RUNNING:\n$out"
have "$out" 'RESUME   G3\.2' && fail "resumed onto a live container's declared files:\n$out" \
  || pass "the resume is held by the live footprint"
have "$out" 'WAITING  G3\.2 +\(stalled on G3\.2 \(in_progress\) but held: files overlap with G3\.1' \
  && pass "and the plan says both that it is stalled and what holds it" \
  || fail "held-resume reason wrong:\n$out"

# ── 6. Naming: refused at tick zero, never at launch ──────────────────────────
echo "--- 6. two tasks that slug to one agent name are refused up front ---"
# The cardinal failure of this grain: one container name for two units means
# liveness answers "running" for a task that is not, and the pump launches a
# second agent onto the first one's branch.
rm -f "$TASKS"/*.md
mk G3.a open "" "libexec/tp-pump"
mk G3.A open "" "libexec/tp-task"
rc=0
out=$(tpump G3 2>&1) || rc=$?
[[ "$rc" -ne 0 ]] && pass "a slug collision refuses the run (rc=$rc)" || fail "collision accepted:\n$out"
have "$out" 'G3\.a and G3\.A|G3\.A and G3\.a' && pass "the refusal names both colliding tasks" || fail "collision message vague:\n$out"
have "$out" 'tp-agent-feat-g3\.a' && pass "and the agent name they collide on" || fail "no agent name in refusal:\n$out"
have "$out" 'LAUNCH' && fail "a plan was printed despite the collision:\n$out" || pass "nothing is planned before the refusal"

echo "--- 6b. a task whose branch cannot carry an agent name is refused too ---"
# Whitespace is the reachable case (a task FILENAME cannot carry a "/"), and it
# is the one that matters: an agent name with a space cannot survive being
# written to a whitespace-delimited registry or read back out of a ps format —
# so the container exists and liveness cannot see it.
rm -f "$TASKS"/*.md
mk "G3.a b" open "" "libexec/tp-pump"
rc=0
out=$(tpump G3 2>&1) || rc=$?
[[ "$rc" -ne 0 ]] && pass "an unnameable unit branch refuses the run (rc=$rc)" || fail "unnameable branch accepted:\n$out"
have "$out" 'whitespace' && pass "the refusal names what is wrong with the name" \
  || fail "refusal does not explain itself:\n$out"
have "$out" 'G3\.a b' && pass "and names the task that would be dispatched on it" \
  || fail "refusal does not name the task:\n$out"

echo "--- 6c. phase grain is unaffected by an id the task grain would refuse ---"
out=$(pump G3 2>&1)
have "$out" 'LAUNCH   G3 ' && pass "the same ledger still plans fine at phase grain" || fail "phase grain broke:\n$out"

# ── 7. Deadlock is still loud ─────────────────────────────────────────────────
echo "--- 7. nothing live, launchable or resumable still exits 3 ---"
rm -f "$TASKS"/*.md
mk G3.1 open G3.9 "libexec/tp-pump"     # blocked on a task that does not exist
rc=0
out=$(TASKPUMP_PUMP_NO_LAUNCH=1 TASKPUMP_PUMP_OPS_DIR="$OPS" TASKPUMP_STATE_DIR="$TMP" \
      TASKPUMP_PUMP_STATE_FILE="$TMP/stall.state" TASKPUMP_POOL_CAP_FILE="$TMP/stall.cap" \
      TASKPUMP_PUMP_LOG="$TMP/stall.log" STUB_LIVE="" \
      timeout 60 "$PUMP" --no-health-gate --no-usage-gate --phases G3 --grain task \
        --tick 1 2>&1) || rc=$?
[[ "$rc" -eq 3 ]] && pass "a deadlocked task-grain run exits 3, not green" || fail "exit=$rc, want 3:\n$out"
have "$out" 'STALLED after [0-9]+ idle ticks' && pass "and pages with a reason" || fail "no stall page:\n$out"
[[ "$(jq -r '.status' "$TMP/stall.state" 2>/dev/null)" == "stalled" ]] \
  && pass "the state file records the stall for a reader" || fail "state: $(cat "$TMP/stall.state" 2>/dev/null)"
[[ "$(jq -r '.grain' "$TMP/stall.state" 2>/dev/null)" == "task" ]] \
  && pass "the state file records the grain the run used" || fail "grain not in state"

# ── 8. The other grains ───────────────────────────────────────────────────────
echo "--- 8. chain grain stays deferred; an unknown grain is still refused ---"
sibling_fixture
rc=0; out=$(pump G3 --grain chain 2>&1) || rc=$?
[[ "$rc" -ne 0 ]] && have "$out" 'SPEC_GAP' && pass "--grain chain still refuses with its SPEC_GAP" \
  || fail "chain grain: rc=$rc\n$out"
have "$out" 'task' && pass "and the message no longer claims task is unimplemented" || fail "stale chain message:\n$out"
rc=0; out=$(pump G3 --grain herd 2>&1) || rc=$?
[[ "$rc" -ne 0 ]] && have "$out" 'unknown grain' && pass "an unknown grain is refused" || fail "unknown grain: rc=$rc\n$out"

# ── 9. --integration-trunk at task grain ──────────────────────────────────────
echo "--- 9. a conflicting merge quarantines the MERGE, never un-completes the WORK ---"
# The second blocking defect of the 2026-08-14 adversarial review. quarantine_unit
# flags the unit's lead task needs-review — and at task grain unit_lead_task
# returns the unit ITSELF, so a DONE task whose branch conflicts with the trunk
# was flipped to needs-review; detect_stalled_orphans then saw needs-review with
# commits ahead, resume_unit reopened it to `open`, and the pump relaunched an
# agent onto finished work. All inside a single tick, because reconcile_trunk
# runs before compute_plan. The merge is what is broken; the work is not.
REPO3="$TMP/project-trunk"
git init -q -b main "$REPO3"
git -C "$REPO3" config user.name  'taskpump-fixture'
git -C "$REPO3" config user.email 'fixture@taskpump.test'
printf 'base\n' >| "$REPO3/shared.txt"
git -C "$REPO3" add -A
git -C "$REPO3" commit -qm 'seed'
# A trunk and a task branch that rewrote the same line: a real merge conflict,
# not a stub.
git -C "$REPO3" switch -qc auto/trunk main
printf 'trunk\n' >| "$REPO3/shared.txt"
git -C "$REPO3" commit -qam 'trunk edit'
for b in g3.3 g3.4; do
  git -C "$REPO3" switch -qc "feat/$b" main
  printf 'task %s\n' "$b" >| "$REPO3/shared.txt"
  git -C "$REPO3" commit -qam "feat($b): conflicting edit"
done
git -C "$REPO3" switch -q main
git -C "$REPO3" worktree add -q "$REPO3/.worktrees/auto-trunk" auto/trunk

QFILE="$TMP/quarantine"
ttick() {  # a real --once tick with the integration trunk on (no containers)
  TASKPUMP_WORKSPACE_ROOT="$REPO3" \
  TASKPUMP_PUMP_WORKTREES_DIR="$REPO3/.worktrees" \
  TASKPUMP_PUMP_OPS_DIR="$OPS" \
  TASKPUMP_PUMP_STATE_FILE="$TMP/trunk.state" \
  TASKPUMP_POOL_CAP_FILE="$TMP/trunk.cap" \
  TASKPUMP_PUMP_LOG="$TMP/trunk.log" \
  TASKPUMP_PUMP_QUARANTINE_FILE="$QFILE" \
  TASKPUMP_PUMP_BUILD_CMD='true' \
  TASKPUMP_PUMP_NO_LAUNCH=1 \
  TASKPUMP_PUMP_NO_GH=1 \
  STUB_LIVE="" \
  "$PUMP" --no-health-gate --no-usage-gate --once --phases G3 --grain task \
    --integration-trunk 2>&1
}

rm -f "$TASKS"/*.md "$TMP/trunk.cap"
: >| "$QFILE"
mk G3.3 done "" "shared.txt"
out=$(ttick)
have "$out" 'quarantine G3\.3: conflict' && pass "a conflicting task branch is still quarantined" \
  || fail "no quarantine at task grain:\n$out"
grep -qE '^G3\.3 .*conflict$' "$QFILE" && pass "the quarantine marker names the unit and the reason" \
  || fail "no marker:\n$(cat "$QFILE" 2>/dev/null)"
have "$out" 'G3\.3 → needs-review' && fail "a done task was flipped to needs-review by a bad MERGE:\n$out" \
  || pass "a done task is never flipped to needs-review"
grep -q '^status: done$' "$TASKS/G3.3.md" \
  && pass "the ledger still says done — the work was never un-completed" \
  || fail "G3.3 status: $(grep '^status:' "$TASKS/G3.3.md")"
have "$out" 'resuming G3\.3' && fail "finished work was resumed:\n$out" || pass "and nothing resumes it"
have "$out" 'would launch G3\.3' && fail "an agent was dispatched onto finished work:\n$out" \
  || pass "no agent is dispatched onto finished work"
have "$out" 'the merge is broken, not the work' \
  && pass "the log says what is actually broken" || fail "no explanation logged:\n$out"

# The positive control, so this is a narrowing and not a disabling: UNFINISHED
# work whose merge conflicts is still flagged for a human, and still resumable.
rm -f "$TASKS"/*.md "$TMP/trunk.cap"
: >| "$QFILE"
mk G3.4 open "" "shared.txt"
out=$(ttick)
have "$out" 'quarantine G3\.4: conflict' && pass "an open task's conflicting merge is quarantined too" \
  || fail "no quarantine for G3.4:\n$out"
have "$out" 'G3\.4 → needs-review' && pass "and unfinished work IS flagged needs-review" \
  || fail "open task not flagged:\n$out"

# ── 10. Range coverage: every phase in the range contributes its tasks ────────
# Every section above ran a single-phase range, and that is exactly where this
# defect hid. The unit list is built by scanning the ledger once per phase, and
# an id belonging to a DIFFERENT phase is the normal case in that scan — but the
# per-id guard was a trailing AND-list, so under `set -e` + `pipefail` the first
# non-matching id ended the scan, killed the enclosing function, and the process
# substitution the planner reads swallowed the non-zero exit. A multi-phase
# range planned its first phase and silently dropped the rest, while the open
# count printed beside it still counted them all. Found smoke-testing a real
# consumer whose every task is its own phase (2026-08-14).
echo "--- 10. a multi-phase range plans every phase's tasks, not just the first ---"
rm -f "$TASKS"/*.md
mk G1.1 open "" "a.txt"
mk G2.1 open "" "b.txt"
mk G3.1 open "" "c.txt"
out=$(tpump G1..G3)
have "$out" 'LAUNCH   G1\.1' && pass "the first phase's task is planned" || fail "G1.1 missing:\n$out"
have "$out" 'LAUNCH   G2\.1' && pass "the second phase's task is planned too" || fail "G2.1 missing:\n$out"
have "$out" 'LAUNCH   G3\.1' && pass "and so is the last phase's" || fail "G3.1 missing:\n$out"
have "$out" 'frontier: 3 launchable' && pass "all three count as launchable" || fail "wrong count:\n$out"

echo "--- 10b. and every unit in range is classified, launchable or not ---"
# The tally is the operator's only cross-check on the plan: a unit missing from
# it is a unit nobody is told about. Held and blocked units in LATER phases are
# where the drop was invisible, because neither prints a LAUNCH line anyway.
rm -f "$TASKS"/*.md
mk G1.1 open ""     "a.txt"
mk G2.1 open G1.1   "b.txt"
mk G3.1 open ""     ""
out=$(tpump G1..G3)
have "$out" 'WAITING  G2\.1 +\(blockers pending: G1\.1\)' \
  && pass "a blocked task in a later phase still says what it waits on" || fail "G2.1 not WAITING:\n$out"
have "$out" 'WAITING  G3\.1 +\(files: empty — exclusive' \
  && pass "a held task in a later phase still names its holder" || fail "G3.1 not WAITING:\n$out"
have "$out" 'frontier: 1 launchable, 0 running, 0 resumable, 2 waiting \| open tasks in range: 3' \
  && pass "the tally accounts for every open task in the range" || fail "tally does not add up:\n$out"

echo "--- 10c. a finished first phase does not end the range ---"
# The operational shape of the bug: a drain that had finished its first phase
# planned nothing at all, and hit the deadlock detector with open work in range.
rm -f "$TASKS"/*.md
mk G1.1 done "" "a.txt"
mk G2.1 open "" "b.txt"
out=$(tpump G1..G3)
have "$out" 'LAUNCH   G2\.1' && pass "work behind a completed phase is still dispatched" || fail "G2.1 not LAUNCH:\n$out"
have "$out" 'frontier: 1 launchable' && pass "and the range is not mistaken for stalled" || fail "wrong count:\n$out"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ "$FAIL" -eq 0 ]]
