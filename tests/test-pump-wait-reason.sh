#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Tristan Misko
# test-pump-wait-reason.sh — the WAITING line has to be right about WHY.
#
# The plan used to assert one reason for every ineligible phase: "cross-phase
# blockers pending". It was loud and correct that nothing could launch, and then
# it named a dependency that in several real ledgers did not exist — a phase
# gated on its own review task (issue #12) being the case that surfaced it
# (issue #46). An operator acts on the words, so a wrong stated reason costs
# them the afternoon they spend looking for an upstream phase.
#
# This suite pins the derivation: every ineligibility the ledger's own
# eligibility predicate can produce gets named, with the ids the operator has to
# act on, and nothing else gets called a cross-phase blocker.
#
# It also pins the one fact `ready` cannot produce at all — an in-flight claim,
# which is `in_progress` and therefore not `open`. That clause is named here at
# both open counts because the plan has two arms for it, and a phase described
# one way with other work beside it and another way alone is the same defect as
# describing it wrongly (issues #46/#48).
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PUMP="$TP_ROOT/libexec/tp-pump"
REAL_TASK="$TP_ROOT/libexec/tp-task"
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
have() { grep -qE "$2" <<<"$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TASKS="$TMP/tasks"
BIN="$TMP/bin"; mkdir -p "$BIN"

# ── Stubs ─────────────────────────────────────────────────────────────────────
# docker: nothing is ever live here — every scenario is about a phase that
# CANNOT launch, and a live container would classify it RUNNING before any
# reason was derived.
cat >| "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then printf '%s\n' ${STUB_LIVE:-}; exit 0; fi
exit 0
EOF
# One always-feeding gate replaces the whole default chain: the shipped gates
# read this host's credentials, usage meter and free disk, and none of that has
# an opinion about a WAITING reason.
cat >| "$BIN/feed-ok-gate" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/docker" "$BIN/feed-ok-gate"

export TASKPUMP_TASKS_DIR="$TASKS"
export TASKPUMP_TASK_NOCOMMIT=1
export TASKPUMP_TASK="$REAL_TASK"
export TASKPUMP_GATES="$BIN/feed-ok-gate"
export DOCKER="$BIN/docker"
# Arachne-shaped fixtures (F ids), as in tests/test-tp-pump.sh: the spellings
# that used to be baked defaults are pinned here explicitly.
export TASKPUMP_ID_PATTERN='^F[0-9]+(\.[0-9]+)?$'
export TASKPUMP_PHASE_SIGIL=F

fresh_tasks() {  # each scenario gets its own ledger; a review chain adds files
  rm -rf "$TASKS"
  mkdir -p "$TASKS"
}

mk() {  # mk <id> <status> [blockers_csv] [claimed_by]
  local id=$1 status=$2 blockers=${3:-} claimed=${4:-null}
  local by="[]"; [[ -n "$blockers" ]] && by="[$(printf '%s' "$blockers" | sed 's/,/, /g')]"
  [[ "$claimed" != "null" ]] && claimed="\"$claimed\""
  cat >| "$TASKS/$id.md" <<EOF
---
id: $id
phase: ${id%%.*}
title: fixture $id
status: $status
claimed_by: $claimed
claimed_at: null
turn_budget_remaining: null
consecutive_failed_iterations: 0
blockers: $by
completed_by_commits: []
files: []
goal: drain $id
---
# $id
EOF
}

task() { "$REAL_TASK" "$@"; }
pump() { "$PUMP" --no-health-gate --dry-run --phases "$1" "${@:2}"; }

echo "--- a phase gated only on its own review task ---"
# The reproduction from the issue: F55.0 is done, its review is open (and hidden
# from the frontier, because nothing dispatches a review), and F55.1 carries the
# gate. Two open tasks, nothing eligible, and not one cross-phase edge in the
# ledger. Authored through the CLI on purpose — a chain the CLI cannot build is
# not a chain this suite should accept.
fresh_tasks
mk F55.0 done
mk F55.1 open F55.0
mk F56.0 open
task review F55.0 --panel 1 >/dev/null 2>&1
out=$(pump F55..F56)
have "$out" 'WAITING +F55 +\(2 open, none eligible' \
  && pass "should still report the phase WAITING when only its review is open" \
  || fail "F55 not WAITING with 2 open:\n$out"
have "$out" 'awaiting review: F55\.2' \
  && pass "should name the review task holding the phase when a review is the only gate" \
  || fail "reason does not name the review task F55.2:\n$out"
have "$out" 'cross-phase blockers pending' \
  && fail "reason still asserts a cross-phase blocker that does not exist:\n$out" \
  || pass "should not claim a cross-phase blocker when the ledger has no cross-phase edge"
have "$out" 'LAUNCH +F56' \
  && pass "should leave an unrelated phase launchable when another phase is explained" \
  || fail "F56 no longer launches:\n$out"

echo "--- a phase gated on another phase's task ---"
fresh_tasks
mk F55.0 open
mk F55.1 open F55.0
mk F57.0 open F55.1
out=$(pump F55..F57)
have "$out" 'WAITING +F57 +\(1 open, none eligible — cross-phase blockers pending: F55\.1 \(open\)\)' \
  && pass "should name the upstream task and its status when the gate is cross-phase" \
  || fail "F57's reason does not name F55.1:\n$out"

echo "--- a satisfied blocker outside the range ---"
# The reason is derived from the WHOLE ledger, not from the range: F55.1 is done
# and out of range, and reading its absence from a range-scoped snapshot as
# "unfinished" would report a blocker the operator finished weeks ago.
fresh_tasks
mk F55.1 done
mk F56.0 open
mk F57.0 open F55.1,F56.0
out=$(pump F57)
have "$out" 'WAITING +F57 +\(1 open, none eligible — cross-phase blockers pending: F56\.0 \(open\)\)' \
  && pass "should name only the unfinished blocker when a done blocker lies outside the range" \
  || fail "F57's reason misreports an out-of-range done blocker:\n$out"

echo "--- a phase gated on an in-phase sibling no agent can take ---"
# F55.0 is blocked (a human owes it something), so F55.1 can never become
# eligible — and there is nothing cross-phase to go looking for.
fresh_tasks
mk F55.0 blocked
mk F55.1 open F55.0
out=$(pump F55)
have "$out" 'WAITING +F55 +\(1 open, none eligible — in-phase blockers pending: F55\.0 \(blocked\)\)' \
  && pass "should name the in-phase sibling and its status when the blocker is not done" \
  || fail "F55's reason does not name the blocked sibling:\n$out"

echo "--- a phase whose only open task is claimed ---"
# `ready` skips a claimed task before it ever looks at blockers, so the claim is
# the reason — and the operator needs the branch name to chase it.
fresh_tasks
mk F55.0 open "" feat/f55
out=$(pump F55)
have "$out" 'WAITING +F55 +\(1 open, none eligible — claimed: F55\.0 by feat/f55\)' \
  && pass "should name the claimant when an open task is held by a branch with no live container" \
  || fail "F55's reason does not name the claimant:\n$out"

echo "--- an open task and a stranded claim in the same phase ---"
# The #48/#46 interaction. A claim is `in_progress`, not `open`, so the walk
# below used to skip it and no clause named it; compute_plan named it in the one
# arm where the claim is the phase's LAST work. Put any other open task in the
# phase and the claim appeared nowhere in the phase-grain plan — while --grain
# task named it every tick off the same ledger. The operator's answer to "who is
# holding this phase" must not depend on a grain switch.
fresh_tasks
mk F55.0 open F56.0
mk F55.1 in_progress "" feat/foreign
mk F56.0 open
out=$(pump F55)
have "$out" 'WAITING +F55 +\(1 open, none eligible — cross-phase blockers pending: F56\.0 \(open\); in flight: F55\.1 \(claimed by feat/foreign\)\)' \
  && pass "should name the in-flight claim and its branch when open work sits beside it" \
  || fail "F55's reason drops the stranded claim:\n$out"
tout=$(pump F55 --grain task)
have "$tout" 'WAITING +F55\.1 +\(claimed by feat/foreign, no live container\)' \
  && pass "should give the same claim and branch at task grain when the grain switches" \
  || fail "the task-grain plan and the phase-grain plan disagree about F55.1:\n$tout"

echo "--- the claim is the phase's last remaining work ---"
# The other arm of the same question. compute_plan used to spell this sentence
# itself, so one claim had two descriptions depending on what else was open
# beside it; both arms now read the clause off this derivation.
fresh_tasks
mk F55.0 done
mk F55.1 in_progress "" feat/foreign
out=$(pump F55)
have "$out" 'WAITING +F55 +\(no open tasks — in flight: F55\.1 \(claimed by feat/foreign\)\)' \
  && pass "should describe the claim the same way when it is the phase's only remaining work" \
  || fail "the no-open-tasks arm describes the claim differently:\n$out"

echo "--- a claim the ledger never finished writing ---"
# status in_progress with no claimed_by. The old rendering printed the table's
# own `-` placeholder, which reads as a branch NAMED nothing rather than as a
# field the ledger is missing.
fresh_tasks
mk F55.0 open F56.0
mk F55.1 in_progress
mk F56.0 open
out=$(pump F55)
have "$out" 'in flight: F55\.1 \(claimed, no branch recorded\)' \
  && pass "should say which field is missing when an in-flight claim records no branch" \
  || fail "F55's reason does not name the unrecorded claimant:\n$out"
have "$out" 'claimed by -' \
  && fail "an unrecorded claimant still renders as a branch named nothing:\n$out" \
  || pass "should not render an unrecorded claimant as a branch called '-'"

echo "--- a blocker with no task file ---"
fresh_tasks
mk F55.0 open F99.9
out=$(pump F55)
have "$out" 'WAITING +F55 +\(1 open, none eligible — blockers with no task file: F99\.9\)' \
  && pass "should say the blocker has no task file when the id resolves to nothing" \
  || fail "F55's reason does not name the dangling blocker:\n$out"

echo "--- more than one reason at once ---"
# A phase can be held by two independent things, and dropping either sends the
# operator back for a second look. Both clauses, one line.
fresh_tasks
mk F55.0 done
mk F55.1 open F55.0
mk F56.0 open
# The chain is cut before F55.3 exists, so the review allocates F55.2 and F55.3
# keeps the single cross-phase edge it was authored with.
task review F55.0 --panel 1 >/dev/null 2>&1
mk F55.3 open F56.0
out=$(pump F55)
have "$out" 'WAITING +F55 +\(3 open, none eligible — awaiting review: F55\.2.*; cross-phase blockers pending: F56\.0 \(open\)\)' \
  && pass "should report every distinct reason when a phase is held by more than one" \
  || fail "F55's reason does not carry both clauses:\n$out"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ "$FAIL" -eq 0 ]]
