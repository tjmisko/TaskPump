#!/usr/bin/env bash
# test-env-hermeticity.sh — the suites must be hermetic against pump-exported
# ledger environment (issue #18, G4.5).
#
# The pump/entrypoint export TASKPUMP_TASKS_DIR / TP_TASKS_DIR — pointing at
# the REAL ledger — into every agent session. Necessarily: that is how an
# agent's tp finds its ledger, so the exports themselves are correct. But
# lib/config.sh gives a canonical spelling the win over its legacy twin, so a
# fixture that configures itself as ARACHNE_TASKS_DIR=<tmpdir> is silently
# outranked by the inherited TASKPUMP_TASKS_DIR: the test reads the real
# ledger while believing it reads its fixture. The 2026-08-13 G3 drain agent
# saw 64 spurious failures across three suites this way, and burned session
# time proving they were not its own — the false-red mirror of the false-green
# problem TASKPUMP_NO_CONF already solved for leaked conf files.
#
# tests/suite-prologue.sh is the guard: run-all.sh and every suite source it
# before any fixture is built, and it unsets the entire inherited
# TASKPUMP_*/TP_*/ARACHNE_* namespace by enumeration. This suite pins that
# seam:
#
#   * the CONTROL — without the prologue, an inherited canonical spelling
#     really does outrank a fixture's legacy spelling (the bug's mechanism,
#     which is also the tools' correct precedence, pinned here as such);
#   * the GUARD — after sourcing the prologue the poison is gone, including
#     names invented for this test (so a hand-kept list can never quietly
#     replace the enumeration), and the fixture's own values are authoritative
#     again;
#   * the COVERAGE — every tests/test-*.sh and run-all.sh source the shared
#     prologue, so a future suite that forgets it fails here, loudly;
#   * the CENTRAL guard, end to end — run-all.sh launches a real
#     legacy-spelled suite green under the poisoned environment.
#
# Two ledgers that answer `ready --count` differently are the tracer:
# whichever ledger answered is unambiguous from the number alone.
#
# Run: ./tests/test-env-hermeticity.sh   (offline)
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CLI="$TP_ROOT/libexec/tp-task"
PROLOGUE="$SCRIPT_DIR/suite-prologue.sh"

# Sourced by its literal path, not through $PROLOGUE: the coverage check below
# looks for a source line naming the file, and this suite must satisfy its own
# rule the same way every other suite does. $PROLOGUE stays for the control
# case, which re-sources it deliberately.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ── Fixtures ──────────────────────────────────────────────────────────────────
# The "real" ledger a pump would export (two open tasks) and the ledger a
# hermetic suite builds for itself (one open task). Plain directories, default
# T grammar, read-only verbs only.
mk() {  # mk <dir> <id>
  cat >| "$1/$2.md" <<EOF
---
id: $2
phase: ${2%%.*}
title: $2
status: open
claimed_by: null
blockers: []
completed_by_commits: []
---

# $2
EOF
}
PUMP_TASKS="$TMP/pump-ledger/tasks"; mkdir -p "$PUMP_TASKS"
mk "$PUMP_TASKS" T1
mk "$PUMP_TASKS" T2
FIXTURE_TASKS="$TMP/fixture/tasks"; mkdir -p "$FIXTURE_TASKS"
mk "$FIXTURE_TASKS" T1

# ── 1. The control: the mechanism, unguarded ─────────────────────────────────
echo "--- control: inherited canonical env vs a fixture's legacy spelling ---"

got=$(env ARACHNE_TASKS_DIR="$FIXTURE_TASKS" "$CLI" ready --count)
[[ "$got" == "1" ]] && pass "fixture ledger alone answers 1 (legacy spelling reaches the tool)" \
  || fail "fixture-only read got '$got', expected 1"

# Both spellings in the environment: the canonical one wins. That is the
# documented precedence (CONFIG.md §2) — correct for the tools, and exactly
# what made unguarded suites read the pump's ledger instead of their own.
got=$(env TASKPUMP_TASKS_DIR="$PUMP_TASKS" TP_TASKS_DIR="$PUMP_TASKS" \
        ARACHNE_TASKS_DIR="$FIXTURE_TASKS" "$CLI" ready --count)
[[ "$got" == "2" ]] && pass "control: inherited TASKPUMP_TASKS_DIR outranks the fixture's ARACHNE_TASKS_DIR (issue #18's mechanism)" \
  || fail "control read got '$got', expected 2 (the pump ledger)"

# ── 2. The guard: the prologue restores the fixture's authority ──────────────
echo
echo "--- guard: sourcing the prologue under a poisoned environment ---"

# A child shell gets the pump-poisoned environment, sources the prologue, and
# only THEN configures its fixture — the exact order every suite now follows.
# The legacy spelling must be authoritative again.
got=$(env TASKPUMP_TASKS_DIR="$PUMP_TASKS" TP_TASKS_DIR="$PUMP_TASKS" \
        TASKPUMP_ID_PATTERN='^ZZZNOPE$' TASKPUMP_PHASE_SIGIL=Z \
        bash -c '. "$1" && export ARACHNE_TASKS_DIR="$2" && exec "$3" ready --count' \
        _ "$PROLOGUE" "$FIXTURE_TASKS" "$CLI")
[[ "$got" == "1" ]] && pass "after the prologue, the fixture's legacy spelling is authoritative again" \
  || fail "guarded legacy-spelling read got '$got', expected 1"

# A suite that needs one of the scrubbed names sets it explicitly after the
# scrub — the contract's other half.
got=$(env TASKPUMP_TASKS_DIR="$PUMP_TASKS" TP_TASKS_DIR="$PUMP_TASKS" \
        bash -c '. "$1" && export TASKPUMP_TASKS_DIR="$2" && exec "$3" ready --count' \
        _ "$PROLOGUE" "$FIXTURE_TASKS" "$CLI")
[[ "$got" == "1" ]] && pass "a value set explicitly after the scrub survives it" \
  || fail "explicit post-scrub value read got '$got', expected 1"

# ── 3. The scrub is an enumeration, not a name list ──────────────────────────
echo
echo "--- scrub: enumeration over the three namespaces ---"

# Keys invented for this test stand in for every key added after the scrub was
# written; a hand-kept list would miss them. TASKPUMP_CONFIG rides along
# because an inherited explicit-config path is an instant loud error in every
# fixture invocation. The bystander proves the prefix match is anchored:
# TASKPUMPX_* is not TASKPUMP_*.
leftover=$(env TASKPUMP_TASKS_DIR="$PUMP_TASKS" TP_TASKS_DIR="$PUMP_TASKS" \
             ARACHNE_TASKS_DIR="$PUMP_TASKS" TASKPUMP_CONFIG="$TMP/no-such.conf" \
             TASKPUMP_ZZ_FUTURE_KEY=poison TP_ZZ_FUTURE_KEY=poison \
             ARACHNE_ZZ_FUTURE_KEY=poison TASKPUMPX_BYSTANDER=keep \
             bash -c '. "$1"; compgen -e TASKPUMP_; compgen -e TP_; compgen -e ARACHNE_; true' \
             _ "$PROLOGUE" | LC_ALL=C sort)
expected=$'ARACHNE_NOTIFY_CMD\nTASKPUMP_NOTIFY_CMD\nTASKPUMP_NO_CONF'
[[ "$leftover" == "$expected" ]] \
  && pass "the scrub leaves exactly the hermetic baseline, invented keys included" \
  || fail "post-scrub namespace was '$(tr '\n' ' ' <<<"$leftover")', expected exactly the baseline three"

got=$(env TASKPUMPX_BYSTANDER=keep \
        bash -c '. "$1"; printf "%s" "${TASKPUMPX_BYSTANDER:-gone}"' _ "$PROLOGUE")
[[ "$got" == "keep" ]] && pass "a non-namespace bystander variable survives the scrub" \
  || fail "bystander was scrubbed (got '$got')"

got=$(env TASKPUMP_NO_CONF=0 TASKPUMP_NOTIFY_CMD=notify-send ARACHNE_NOTIFY_CMD=notify-send \
        bash -c '. "$1"; printf "%s/%s/%s" "$TASKPUMP_NO_CONF" "$TASKPUMP_NOTIFY_CMD" "$ARACHNE_NOTIFY_CMD"' \
        _ "$PROLOGUE")
[[ "$got" == "1/true/true" ]] \
  && pass "the baseline is re-established after the scrub: NO_CONF=1, notify stubbed in both spellings" \
  || fail "baseline was '$got', expected '1/true/true'"

# ── 4. Coverage: every suite carries the double-guard ────────────────────────
echo
echo "--- coverage: every suite and run-all source the shared prologue ---"

missing=""
while IFS= read -r suite; do
  # A SOURCE line, not a mention: a suite that only names the prologue in a
  # comment would satisfy a bare substring match while inheriting pump env.
  grep -qE '^[[:space:]]*(\.|source)[[:space:]].*suite-prologue\.sh' "$suite" \
    || missing+=" $(basename "$suite")"
done < <(find "$SCRIPT_DIR" -maxdepth 1 -name 'test-*.sh' | LC_ALL=C sort)
[[ -z "$missing" ]] && pass "every tests/test-*.sh sources the shared prologue" \
  || fail "suites missing the shared prologue (standalone runs inherit pump env):$missing"

grep -qE '^[[:space:]]*(\.|source)[[:space:]].*suite-prologue\.sh' "$SCRIPT_DIR/run-all.sh" \
  && pass "run-all.sh sources the shared prologue (the central guard)" \
  || fail "run-all.sh does not source the shared prologue"

# ── 5. The central guard, end to end ─────────────────────────────────────────
echo
echo "--- end to end: run-all launches a legacy-spelled suite clean under poison ---"

# test-claude-usage configures itself entirely in ARACHNE_* spellings, so it is
# exactly the suite the incident environment breaks: every canonical twin below
# points somewhere that does not exist. Green through run-all.sh proves the
# central scrub reaches a real suite. (The filter cannot match this suite, so
# there is no recursion; the poison credentials paths do not exist, so nothing
# can attempt a network call even if the guard regresses.)
out=$(env TASKPUMP_TASKS_DIR="$PUMP_TASKS" TP_TASKS_DIR="$PUMP_TASKS" \
        TASKPUMP_USAGE_CACHE="$TMP/no-such-cache.json" \
        TASKPUMP_USAGE_RESET_FILE="$TMP/no-such-reset" \
        TASKPUMP_CREDENTIALS="$TMP/no-such-credentials.json" \
        TASKPUMP_ID_PATTERN='^ZZZNOPE$' TASKPUMP_PHASE_SIGIL=Z \
        bash "$SCRIPT_DIR/run-all.sh" claude-usage 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "run-all under pump-poisoned env exits 0 for a legacy-spelled suite" \
  || fail "run-all under poison exited $rc; tail: $(tail -5 <<<"$out" | tr '\n' ' ')"
grep -q 'All 1 suite(s) passed' <<<"$out" \
  && pass "the nested run reports the suite green" \
  || fail "nested run-all summary did not report 1 passing suite"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
