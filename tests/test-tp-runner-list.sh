#!/usr/bin/env bash
# test-tp-runner-list.sh — the `list` half of RUNNER CONTRACT v2.
#
# docs/RUNNERS.md §1.3 promises liveness is askable: `list` prints the name of
# every live agent this runner knows about, one per line, exit 0. Three
# properties carry the weight, and each of them is a way the verb could look
# right and be useless:
#
#   1. An empty fleet is exit 0 with NO output. A bare `printf '%s\n' "$names"`
#      on an empty string emits a blank line, and a caller counting lines then
#      reads one live agent where there are none — the exact wrong answer for the
#      one decision liveness feeds (launch, or don't).
#   2. Failure to enumerate is NON-zero, never an empty list. "Nothing is
#      running" and "I could not look" demand opposite actions; a runner that
#      conflates them hands the supervisor a confident wrong answer, and the
#      pump's one safety property (never double-launch a live agent) is what
#      pays for it. The runner never guesses the fallback — the caller decides.
#   3. The names are the names `launch` created (`<prefix><slug>`), so the
#      existing name→branch mapping keeps working. This is why the enumeration is
#      shared with lib/pump-lib.sh rather than re-spelled here: two copies of one
#      `docker ps --filter` is precisely how the two answers would drift apart.
#      The last case below asserts the two agree, so a change to either side
#      that splits them fails here.
#
# DOCKER is the runner's own test seam, so no container is ever created.
#
# Run: ./tests/test-tp-runner-list.sh   (offline)
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RUNNER="$TP_ROOT/runners/claude-docker/runner.sh"
PUMP_LIB="$TP_ROOT/lib/pump-lib.sh"

# Hermeticity: the shared prologue ignores any taskpump.conf in the repo this
# suite happens to run from — TaskPump's own dogfood conf pins
# TASKPUMP_AGENT_PREFIX, which is the single input this verb has — and scrubs
# the pump-exported TASKPUMP_*/TP_*/ARACHNE_* environment (issue #18), where
# the same key arrives as an inherited export. run-all.sh sources the same
# prologue; this one covers standalone runs.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

[[ -f "$RUNNER" ]] || { echo "FAIL: runner not found at $RUNNER" >&2; exit 1; }

# A docker stub that answers `ps` from $STUB_NAMES, one name per line. Quoted on
# purpose (the pump's own harness leaves it unquoted and so cannot carry a name
# with a space); everything that is not `ps` is a harmless success.
cat >| "$WORK/docker-ok" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then
  [[ -n "${STUB_NAMES:-}" ]] && printf '%s\n' "$STUB_NAMES"
  exit 0
fi
exit 0
EOF

# A runtime that cannot be reached. Two lines of complaint on purpose: the
# contract allows the runner one line, so the second must be dropped rather than
# forwarded.
cat >| "$WORK/docker-broken" <<'EOF'
#!/usr/bin/env bash
printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock.\n' >&2
printf 'Is the docker daemon running?\n' >&2
exit 1
EOF
chmod +x "$WORK/docker-ok" "$WORK/docker-broken"

# run_list <docker> [var=value]... — list, in an environment carrying only what
# the case sets. stdout is returned; stderr goes to $WORK/err so the two can be
# told apart, which is the whole subject of half these cases.
run_list() {
  local docker="$1"; shift
  (
    unset TP_AGENT_PREFIX TASKPUMP_AGENT_PREFIX ARACHNE_AGENT_PREFIX STUB_NAMES
    unset TP_CONTAINER_NAME ARACHNE_CONTAINER_NAME TP_WORKSPACE TP_IMAGE
    local kv
    for kv in "$@"; do export "$kv"; done
    DOCKER="$docker" bash "$RUNNER" list 2>"$WORK/err"
  )
}

echo "--- a populated fleet: one name per line, exit 0 ---"

# A host runs more than agents. `docker ps --filter name=` matches as a
# SUBSTRING, so the filter alone would hand back `not-tp-agent-x` too; the
# anchoring is what makes the answer trustworthy.
names=$'tp-agent-feat-a\nnot-tp-agent-impostor\nunrelated-container\ntp-agent-feat-b'
out=$(run_list "$WORK/docker-ok" "STUB_NAMES=$names"); rc=$?
[[ $rc -eq 0 && "$out" == $'tp-agent-feat-a\ntp-agent-feat-b' ]] \
  && pass "live agents are printed one per line, in runtime order" \
  || fail "unexpected list (rc=$rc): '$out'"

[[ "$out" != *impostor* ]] \
  && pass "a container that merely contains the prefix is not an agent" \
  || fail "substring match leaked a non-agent container: '$out'"

echo "--- an empty fleet is an answer, not an absence of one ---"

out=$(run_list "$WORK/docker-ok"); rc=$?
[[ $rc -eq 0 ]] \
  && pass "no live agents still exits 0" \
  || fail "empty fleet exited non-zero (rc=$rc)"

# The blank-line trap. Byte count, not string compare: `[[ -z ]]` is true for a
# lone newline read through $(), which strips it — exactly the way this defect
# hides from a naive assertion.
n=$(run_list "$WORK/docker-ok" | wc -c)
[[ "$n" -eq 0 ]] \
  && pass "no live agents prints nothing at all (not a blank line)" \
  || fail "empty fleet printed $n bytes; a line-counting caller would see an agent"

echo "--- an unreachable runtime is not an empty fleet ---"

out=$(run_list "$WORK/docker-broken"); rc=$?
[[ $rc -ne 0 ]] \
  && pass "a runtime that cannot answer exits non-zero" \
  || fail "an unreachable runtime was reported as an empty fleet (rc=$rc)"

[[ -z "$out" ]] \
  && pass "a failed enumeration prints no names on stdout" \
  || fail "a failed enumeration still printed to stdout: '$out'"

n=$(wc -l < "$WORK/err")
[[ "$n" -eq 1 ]] \
  && pass "a failed enumeration says why in exactly one line" \
  || fail "expected one line on stderr, got $n:\n$(cat "$WORK/err")"

grep -q 'Cannot connect to the Docker daemon' "$WORK/err" \
  && pass "the one line carries the runtime's own reason, not a paraphrase" \
  || fail "the reason was lost:\n$(cat "$WORK/err")"

echo "--- the prefix is configuration, and the only input list takes ---"

# Bare default: the shipped spelling (G1.5). A drift here silently empties every
# consumer's liveness answer.
mixed=$'tp-agent-feat-a\narachne-agent-feat-b'
out=$(run_list "$WORK/docker-ok" "STUB_NAMES=$mixed")
[[ "$out" == "tp-agent-feat-a" ]] \
  && pass "the bare default prefix is tp-agent-" \
  || fail "default prefix drifted: '$out'"

out=$(run_list "$WORK/docker-ok" "STUB_NAMES=$mixed" TP_AGENT_PREFIX=arachne-agent-)
[[ "$out" == "arachne-agent-feat-b" ]] \
  && pass "TP_AGENT_PREFIX selects the fleet to enumerate" \
  || fail "TP_AGENT_PREFIX ignored: '$out'"

out=$(run_list "$WORK/docker-ok" "STUB_NAMES=$mixed" TASKPUMP_AGENT_PREFIX=arachne-agent-)
[[ "$out" == "arachne-agent-feat-b" ]] \
  && pass "the shared TASKPUMP_AGENT_PREFIX spelling works too" \
  || fail "TASKPUMP_AGENT_PREFIX ignored: '$out'"

# The pump calls this once per tick with no task in hand, so requiring anything
# launch-shaped would make it uncallable at exactly the moment it is needed.
# run_list already unsets those; this asserts the runner never asks for them.
out=$(run_list "$WORK/docker-ok" "STUB_NAMES=tp-agent-feat-a"); rc=$?
[[ $rc -eq 0 && "$out" == "tp-agent-feat-a" ]] \
  && pass "list needs no container name, workspace or image" \
  || fail "list demanded per-launch input (rc=$rc):\n$(cat "$WORK/err")"

echo "--- list and the pump's own scrape are the same enumeration ---"

# The naming contract (docs/RUNNERS.md §2) only holds if these two agree. They
# share a code path today; this is what fails if someone re-spells either.
fleet=$'tp-agent-feat-a\nnot-tp-agent-impostor\ntp-agent-feat-b'
via_runner=$(run_list "$WORK/docker-ok" "STUB_NAMES=$fleet")
via_lib=$(
  # shellcheck disable=SC1090
  . "$PUMP_LIB"
  STUB_NAMES="$fleet" DOCKER="$WORK/docker-ok" apl_live_agent_names
)
[[ "$via_runner" == "$via_lib" && -n "$via_lib" ]] \
  && pass "runner list agrees with apl_live_agent_names name for name" \
  || fail "the two enumerations have drifted:\n runner: '$via_runner'\n lib:    '$via_lib'"

echo "--- the verb is advertised, and the contract version says so ---"

out=$(bash "$RUNNER" --help 2>&1)
grep -q '^  runner\.sh list' <<<"$out" \
  && pass "list appears in the runner's own usage" \
  || fail "list is undocumented in usage:\n$out"

out=$(bash "$RUNNER" contract 2>&1)
[[ "$out" -ge 2 ]] \
  && pass "the contract version is at least 2 (liveness is askable)" \
  || fail "contract version did not advance past v1: '$out'"

echo
printf 'Tests: %d  Passed: %d  Failed: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
