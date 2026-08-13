#!/usr/bin/env bash
# test-claude-token-fresh.sh — the token gate's absent-input behaviour.
#
# This gate ships in the DEFAULT gate chain, which means it runs on hosts that
# are driving some other agent entirely, against a credentials file that will
# never exist. Two rules pull in opposite directions there, and both matter:
#
#   Fail open. A meter that cannot be read must never wedge the pump
#   (GATES.md §1.1). Exit 0, never 10.
#
#   Fail open OUT LOUD. A silent feed is indistinguishable from a gate that
#   looked and approved — and those are opposite facts about how protected the
#   run is. One line, on stderr, saying which absent input it hit.
#
# stderr, specifically: stdout is where this gate says why it PAUSED, and a skip
# is not a pause. A skip reason on stdout would be read as one by anything
# capturing the gate's output.
#
# The live-credential path is untouched by all of this and is asserted here too,
# because a gate that has learned to skip and forgotten to gate is worse than
# one that never skipped.
#
# Run: ./tests/test-claude-token-fresh.sh   (offline)
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
GATE="$TP_ROOT/gates/claude-token-fresh"

export TASKPUMP_NO_CONF=1

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

[[ -x "$GATE" ]] || { echo "FAIL: gate not executable at $GATE" >&2; exit 1; }

TMP=$(mktemp -d); trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
NOW=1750000000

# gate <cred-path> — run the gate; stdout in $OUT, stderr in $ERR, status returned.
OUT=""; ERR=""
gate() {
  local rc=0
  OUT="$(TASKPUMP_CREDENTIALS="$1" TASKPUMP_NOW_S="$NOW" "$GATE" 2>"$TMP/err")" || rc=$?
  ERR="$(cat "$TMP/err")"
  return "$rc"
}
mk_cred() { printf '{"claudeAiOauth":{"expiresAt":%s}}' "$1" >| "$2"; }

echo "--- absent input: skip, with a reason, on stderr ---"

rc=0; gate "$TMP/does-not-exist.json" || rc=$?
[[ $rc -eq 0 ]] && pass "a missing credentials file feeds (exit 0, never 10)" \
  || fail "missing credentials paused the pump (rc=$rc): $ERR"
[[ "$(wc -l <<<"$ERR")" -eq 1 ]] && pass "the skip is exactly one line" \
  || fail "expected one line on stderr, got $(wc -l <<<"$ERR"):\n$ERR"
# Prefixed with the tool name like every other diagnostic in this stack; the
# pump's strip_gate_prefix takes it off again when it quotes the line.
grep -q "^claude-token-fresh: skipped: no claude credentials at $TMP/does-not-exist.json\$" <<<"$ERR" \
  && pass "the line names the file it looked for" \
  || fail "unexpected skip line: '$ERR'"
[[ -z "$OUT" ]] && pass "nothing on stdout (stdout means 'here is why I paused')" \
  || fail "the skip reason leaked to stdout: '$OUT'"

MALFORMED="$TMP/malformed.json"; printf 'not json\n' >| "$MALFORMED"
rc=0; gate "$MALFORMED" || rc=$?
[[ $rc -eq 0 ]] && grep -q 'not valid JSON' <<<"$ERR" \
  && pass "malformed credentials skip with a reason" \
  || fail "malformed credentials (rc=$rc): '$ERR'"

# Valid JSON, but nothing to measure — the shape a different agent's config file
# would have. Absent input, not a stale token.
NOEXP="$TMP/no-expiry.json"; printf '{"someOtherAgent":{"token":"x"}}' >| "$NOEXP"
rc=0; gate "$NOEXP" || rc=$?
[[ $rc -eq 0 ]] && grep -q 'no OAuth expiry' <<<"$ERR" \
  && pass "credentials with no OAuth expiry skip with a reason" \
  || fail "no-expiry credentials (rc=$rc): '$ERR'"

if [[ "$(id -u)" -ne 0 ]]; then
  UNREADABLE="$TMP/unreadable.json"; mk_cred $(( (NOW + 99999) * 1000 )) "$UNREADABLE"
  chmod 000 "$UNREADABLE"
  rc=0; gate "$UNREADABLE" || rc=$?
  [[ $rc -eq 0 ]] && grep -q 'not readable' <<<"$ERR" \
    && pass "an unreadable credentials file skips with a reason" \
    || fail "unreadable credentials (rc=$rc): '$ERR'"
  chmod 644 "$UNREADABLE"
else
  pass "SKIP unreadable-credentials case (running as root: no file is unreadable)"
fi

echo "--- the gate still gates ---"
# The whole risk of adding a skip path is a gate that now never fires. These are
# the two live-credential outcomes, unchanged.

EXPIRED="$TMP/expired.json"; mk_cred $(( (NOW - 300) * 1000 )) "$EXPIRED"
rc=0; gate "$EXPIRED" || rc=$?
[[ $rc -eq 10 ]] && pass "an expired token still pauses (exit 10)" \
  || fail "expired token expected 10, got $rc: '$ERR'"
grep -q 'expired' <<<"$OUT" \
  && pass "the pause reason goes to stdout, per the gate contract" \
  || fail "pause reason missing from stdout: '$OUT'"

NEAR="$TMP/near.json"; mk_cred $(( (NOW + 300) * 1000 )) "$NEAR"
rc=0; gate "$NEAR" || rc=$?
[[ $rc -eq 10 ]] && pass "a token inside the margin still pauses (exit 10)" \
  || fail "near-expiry token expected 10, got $rc"

FRESH="$TMP/fresh.json"; mk_cred $(( (NOW + 99999) * 1000 )) "$FRESH"
rc=0; gate "$FRESH" || rc=$?
[[ $rc -eq 0 ]] && pass "a fresh token feeds (exit 0)" || fail "fresh token expected 0, got $rc"
[[ -z "$ERR" ]] && pass "a fresh token says nothing at all — there is nothing to explain" \
  || fail "the gate chattered on the happy path: '$ERR'"

# The off switch predates all of this and stays silent: an operator who turned
# the gate off does not need a line about it every tick.
rc=0
OUT="$(TASKPUMP_TOKEN_GATE=0 TASKPUMP_CREDENTIALS="$EXPIRED" TASKPUMP_NOW_S="$NOW" "$GATE" 2>"$TMP/err")" || rc=$?
ERR="$(cat "$TMP/err")"
[[ $rc -eq 0 && -z "$ERR" && -z "$OUT" ]] \
  && pass "TASKPUMP_TOKEN_GATE=0 feeds silently, even with an expired token" \
  || fail "disabled gate (rc=$rc) out='$OUT' err='$ERR'"

echo
printf 'Tests: %d  Passed: %d  Failed: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
