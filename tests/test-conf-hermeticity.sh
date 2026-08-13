#!/usr/bin/env bash
# test-conf-hermeticity.sh — the suites must be hermetic against a consumer conf
# in the repo they run from (G0.3).
#
# Discovered 2026-08-12, the first time the suites ran from a checkout carrying
# a taskpump.conf (TaskPump's own dogfood conf): config discovery walks up from
# $PWD, so every fixture invocation that did not override a key inherited the
# enclosing repo's conf. Two symptoms, in increasing severity:
#
#   * TASKPUMP_PHASE_SIGIL=G failed 37 F-range parses in test-tp-pump;
#   * TASKPUMP_BUILD_GATE='./tests/run-all.sh' reached the pump's integration
#     build gate, whose eval runs the configured command from the CALLER'S cwd —
#     the conf-carrying repo root — so a gate-less integration tick re-entered
#     run-all.sh, which re-entered test-tp-pump, which ticked again: the
#     full-suite baseline hang (an hour-plus of captured, invisible output).
#
# The fix is TASKPUMP_NO_CONF=1, lib/config.sh's explicit discovery off-switch,
# exported by run-all.sh and by every suite for standalone runs. This suite
# pins the seam itself: a poison conf (wrong sigil, wrong tasks dir, marker
# build gate) planted in a fixture's enclosing repo is IGNORED by a suite-style
# invocation with the switch set, and HONORED without it — including the exact
# build-gate path that hung the baseline.
#
# Run: ./tests/test-conf-hermeticity.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PUMP="$TP_ROOT/libexec/tp-pump"
TASK="$TP_ROOT/libexec/tp-task"

# Every invocation below states its own TASKPUMP_NO_CONF explicitly (that IS
# the subject under test); the export covers any incidental tool call.
export TASKPUMP_NO_CONF=1

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
have() { grep -qE "$2" <<<"$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ── The poison: a conf-carrying repo enclosing the invocation's cwd ───────────
# Shaped like the dogfood conf that surfaced the defect: a foreign sigil, a
# tasks dir the fixtures never asked for, and a build-gate command — here a
# marker write instead of './tests/run-all.sh', so executing it proves the hang
# path without hanging.
POISON="$TMP/poison-repo"
MARKER="$TMP/gate-ran.marker"
mkdir -p "$POISON"
git -C "$POISON" init -q
cat >| "$POISON/taskpump.conf" <<CONF
TASKPUMP_PHASE_SIGIL=G
TASKPUMP_TASKS_DIR=poison-tasks
TASKPUMP_BUILD_GATE='pwd >> $MARKER'
CONF

# ── Fixtures: what a hermetic suite sets up for itself ────────────────────────
TASKS="$TMP/tasks"; mkdir -p "$TASKS"
mk() {  # mk <id>
  cat >| "$TASKS/$1.md" <<EOF
---
id: $1
phase: ${1%%.*}
title: fixture $1
status: open
claimed_by: null
claimed_at: null
turn_budget_remaining: null
consecutive_failed_iterations: 0
blockers: []
completed_by_commits: []
files: []
goal: drain $1
---
# $1
EOF
}
mk T55.0
mk G55.0

BIN="$TMP/bin"; mkdir -p "$BIN"
cat >| "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then printf '%s\n' ${STUB_LIVE:-}; exit 0; fi
exit 0
EOF
chmod +x "$BIN/docker"

# A suite-style pump invocation, verbatim from test-tp-pump.sh's Test 13 shape:
# integration dry-run, no launch, no gates, every state file in $TMP — and,
# like Tests 13a/b/c/e, NO build-gate override, which is what let the conf's
# gate command through. $1 is the phase spec; extra env comes from the caller.
itick() {
  ( cd "$POISON" && \
    TASKPUMP_NOTIFY_CMD=true \
    TASKPUMP_STATE_DIR="$TMP" \
    TASKPUMP_PRE_TICK_HOOKS=' ' \
    ARACHNE_TASKS_DIR="$TASKS" \
    ARACHNE_TASK_NOCOMMIT=1 \
    ARACHNE_TASK="$TASK" \
    DOCKER="$BIN/docker" \
    ARACHNE_PUMP_NO_LAUNCH=1 \
    ARACHNE_PUMP_INTEGRATE_DRYRUN=1 \
    ARACHNE_PUMP_QUARANTINE_FILE="$TMP/quarantine" \
    ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
    ARACHNE_PUMP_STATE_FILE="$TMP/ipump.state" \
    ARACHNE_POOL_CAP_FILE="$TMP/cap" \
    ARACHNE_PUMP_LOG="$TMP/pump.log" \
    "$PUMP" --no-health-gate --no-usage-gate --no-disk-gate \
      --integration-trunk --phases "$1" --once )
}

echo "--- the off-switch: a suite-style invocation ignores the poison conf ---"

rm -f "$MARKER"
# Bare-default contrast, deliberately: this suite's subject is discovery, and
# the baked defaults are its observable. G1.6 flipped the default sigil (F → T)
# and the default ledger probe (ops/task-loop/tasks → tasks); these cases pin
# the flipped defaults exactly as they pinned the originals.
out=$(TASKPUMP_NO_CONF=1 itick T55..T55 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "T-range tick exits 0 with the switch set" \
  || fail "T-range tick rc=$rc with the switch set:\n$out"
have "$out" 'would integrate T55' && pass "the default T sigil is in force (T55 integrates)" \
  || fail "no 'would integrate T55' with the switch set:\n$out"
[[ ! -f "$MARKER" ]] && pass "the poison build gate never ran with the switch set" \
  || fail "poison TASKPUMP_BUILD_GATE executed despite TASKPUMP_NO_CONF=1"

got=$( cd "$POISON" && env TASKPUMP_NO_CONF=1 ARACHNE_TASK_NOCOMMIT=1 \
        "$TASK" resolve --tasks-dir )
# The */tasks shape is the baked default probe (G1.6 flipped it from
# */ops/task-loop/tasks).
[[ "$got" != "poison-tasks" && "$got" == */tasks ]] \
  && pass "tasks dir resolves to the baked default, not the poison conf's" \
  || fail "resolve --tasks-dir got '$got' with the switch set"

echo
echo "--- no off-switch: the same invocation honors the poison conf ---"
# This direction is the defect as it first surfaced: the conf's sigil rejecting
# the fixture's own ranges. It must keep working — the switch is an explicit
# opt-out for test runs, never a weakening of discovery for real callers.

out=$( unset TASKPUMP_NO_CONF ARACHNE_NO_CONF; itick F55..F55 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && pass "F-range tick fails without the switch (conf sigil G)" \
  || fail "F-range tick succeeded without the switch:\n$out"
have "$out" "bad phase range 'F55..F55'" && pass "the failure names the conf-rejected range" \
  || fail "no bad-phase-range diagnostic:\n$out"

got=$( cd "$POISON" && env -u TASKPUMP_NO_CONF -u ARACHNE_NO_CONF \
        ARACHNE_TASK_NOCOMMIT=1 "$TASK" resolve --tasks-dir )
[[ "$got" == "poison-tasks" ]] && pass "tasks dir resolves to the poison conf's value" \
  || fail "resolve --tasks-dir got '$got' without the switch"

echo
echo "--- the baseline hang path: the conf's build gate reaches a fixture tick ---"
# Under the conf's own sigil the range parses, the integration tick reaches
# run_build_gate_dry, and the pump evals the CONF'S command — from the caller's
# cwd, the conf-carrying repo root. Substitute './tests/run-all.sh' for the
# marker write and this is the recursion that hung the full-suite baseline.

rm -f "$MARKER"
out=$( unset TASKPUMP_NO_CONF ARACHNE_NO_CONF; itick G55..G55 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && pass "G-range tick exits 0 under the conf sigil" \
  || fail "G-range tick rc=$rc without the switch:\n$out"
have "$out" 'would integrate G55' && pass "the tick reached integration (gate green)" \
  || fail "no 'would integrate G55' without the switch:\n$out"
[[ -f "$MARKER" ]] && pass "the conf's TASKPUMP_BUILD_GATE was executed by the tick" \
  || fail "poison build gate did not run without the switch"
[[ "$(tail -1 "$MARKER" 2>/dev/null)" == "$POISON" ]] \
  && pass "the gate ran from the conf-carrying repo root (the recursion cwd)" \
  || fail "gate cwd was '$(tail -1 "$MARKER" 2>/dev/null)', expected '$POISON'"

echo
echo "--- the opt-back-in seams ---"

got=$( cd "$POISON" && env TASKPUMP_NO_CONF=0 ARACHNE_TASK_NOCOMMIT=1 \
        "$TASK" resolve --tasks-dir )
[[ "$got" == "poison-tasks" ]] && pass "TASKPUMP_NO_CONF=0 re-enables discovery" \
  || fail "NO_CONF=0 resolved to '$got', expected the conf's value"

got=$( cd "$POISON" && env TASKPUMP_NO_CONF=1 TASKPUMP_CONFIG="$POISON/taskpump.conf" \
        ARACHNE_TASK_NOCOMMIT=1 "$TASK" resolve --tasks-dir )
[[ "$got" == "poison-tasks" ]] && pass "an explicit TASKPUMP_CONFIG outranks the switch" \
  || fail "TASKPUMP_CONFIG under NO_CONF=1 resolved to '$got'"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
