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
expected=$'ARACHNE_NOTIFY_CMD\nTASKPUMP_HOOK_MARK_FILE\nTASKPUMP_NOTIFY_CMD\nTASKPUMP_NO_CONF'
[[ "$leftover" == "$expected" ]] \
  && pass "the scrub leaves exactly the hermetic baseline, invented keys included" \
  || fail "post-scrub namespace was '$(tr '\n' ' ' <<<"$leftover")', expected exactly the baseline four"

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

# ── 6. Run state: a fixture must not write the caller's checkout (B16) ───────
echo
echo "--- run state: the pump's hook mark file is redirected out of any repo ---"

# The leak the other four sections do not cover runs the OTHER way. tp-pump
# resolves its dotfiles to $TASKPUMP_STATE_DIR, defaulting to the workspace
# root — and a suite helper that runs a real tick without cding or pinning a
# workspace resolves that, through the cwd rung, to the TaskPump checkout the
# suites are running FROM. run_pre_tick_hooks WRITES the mark file when the
# hooks have something to say and `rm -f`s it when they go quiet, so on
# 2026-08-19 a suite run deleted and rewrote the operator's live
# .taskpump-fsguard.notified. Every one of those files is gitignored, so
# run-all.sh's status probe reported the run green; its state manifest is the
# other half of the fix.
PUMP="$TP_ROOT/libexec/tp-pump"

mark=$(bash -c '. "$1"; printf "%s" "${TASKPUMP_HOOK_MARK_FILE:-<unset>}"' _ "$PROLOGUE")
[[ "$mark" == /* && "$mark" != "$TP_ROOT"/* ]] \
  && pass "the prologue points the hook mark file at an absolute path outside the checkout" \
  || fail "the hook mark file default is '$mark' — unset, relative, or inside $TP_ROOT"

# Behaviourally, against a directory shaped exactly like the checkout that got
# hurt: a git repo with a tasks/ probe dir is all the cwd rung needs to answer
# "this is the workspace". Nothing is pinned here on purpose — the tick
# inherits only what the prologue set, which is the situation a new suite
# helper that forgets to pin anything creates.
WS="$TMP/ws"; mkdir -p "$WS/tasks" "$TMP/noops"
git -C "$WS" init -q
mk "$WS/tasks" T1
cat >| "$TMP/hook-noisy" <<'EOF'
#!/usr/bin/env bash
printf 'a persistent condition worth notifying about once\n'
EOF
chmod +x "$TMP/hook-noisy"
( cd "$WS" && TASKPUMP_PRE_TICK_HOOKS="$TMP/hook-noisy" \
    TASKPUMP_PUMP_NO_LAUNCH=1 TASKPUMP_PUMP_OPS_DIR="$TMP/noops" \
    "$PUMP" --no-health-gate --no-usage-gate --no-disk-gate --once --phases T1 \
  ) >/dev/null 2>&1
# The tick has to have really happened, or the two assertions below are vacuous
# — and its OTHER dotfiles must still land in the workspace, because relocating
# the mark file is a test-harness redirect, not a change to where a pump keeps
# its state.
[[ -f "$WS/.taskpump-pump.state" ]] \
  && pass "the tick ran a real tick against the workspace the cwd rung resolved" \
  || fail "no state file in $WS — the tick never got far enough to prove anything"
[[ ! -e "$WS/.taskpump-fsguard.notified" ]] \
  && pass "and left no mark file there, though its hooks had plenty to say" \
  || fail "the tick wrote $WS/.taskpump-fsguard.notified — the default reached a repo again"
[[ -n "${TASKPUMP_HOOK_MARK_FILE:-}" && -f "${TASKPUMP_HOOK_MARK_FILE:-}" ]] \
  && pass "the fingerprint went to the redirect instead, so the dedup still works" \
  || fail "no mark file at the redirect '${TASKPUMP_HOOK_MARK_FILE:-<unset>}' — did the tick reach the hooks?"
rm -f "${TASKPUMP_HOOK_MARK_FILE:-}"

# ── 7. And the gate that would have caught it ────────────────────────────────
echo
echo "--- run-all's state manifest sees what the status probe cannot ---"

# run-all.sh resolves the repo it guards from its own location, so a copy of it
# in a throwaway repo guards THAT repo — which is how this can be driven for
# real without dirtying anything. The canary suite stands in for a helper that
# runs an unpinned tick: it drops one run-state file into the repo it is
# running from, and .gitignore hides that file from `git status` exactly as
# TaskPump's own .gitignore hides it in the real checkout.
GATE="$TMP/gate"; mkdir -p "$GATE/tests"
git -C "$GATE" init -q
printf '.taskpump-*\n' >| "$GATE/.gitignore"
cp "$SCRIPT_DIR/run-all.sh" "$SCRIPT_DIR/suite-prologue.sh" "$GATE/tests/"
cat >| "$GATE/tests/test-canary.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"
printf 'litter\n' >| "$SCRIPT_DIR/../.taskpump-pump.state"
echo "Tests: 1  Passed: 1  Failed: 0"
EOF
chmod +x "$GATE/tests/test-canary.sh"

gate_out=$(bash "$GATE/tests/run-all.sh" canary 2>&1); gate_rc=$?
[[ $gate_rc -ne 0 ]] \
  && pass "a suite that drops a gitignored run-state file fails the run" \
  || fail "run-all exited 0 with a state file planted; tail: $(tail -4 <<<"$gate_out" | tr '\n' ' ')"
grep -qF 'created: .taskpump-pump.state' <<<"$gate_out" \
  && pass "and the failure names the file rather than printing a diff" \
  || fail "the gate did not name .taskpump-pump.state: $(tr '\n' ' ' <<<"$gate_out")"
grep -qF "changed this repo's git status" <<<"$gate_out" \
  && fail "the status probe saw the canary — the fixture is not actually gitignored" \
  || pass "the status probe stayed blind to it, which is why the manifest exists"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
