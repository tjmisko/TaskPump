#!/usr/bin/env bash
# test-tp-runner-stop.sh — the `stop` half of RUNNER CONTRACT v1.
#
# docs/RUNNERS.md §1.2 promises stop is idempotent: "stopping an agent that is
# already gone is success, not an error". A supervisor tearing down should not
# have to race `docker ps` to find out whether it still has something to stop.
#
# "Already gone" is two distinct conditions, and the container runtime words them
# differently: the container does not exist at all ("No such container"), or it
# exists but has already exited ("is not running"). do_stop tolerates both, and
# only one of them was covered — a change that dropped the second pattern from
# the match would have kept a green suite while turning every teardown of an
# exited container into a hard failure. The second condition is the one that
# actually happens in a drain: a container that finished on its own between the
# supervisor deciding to stop it and the call landing.
#
# The other half of the contract matters just as much: tolerating those two is
# not the same as ignoring errors. A genuine failure — the daemon is down, the
# name is ambiguous — must still exit non-zero, or a teardown that silently did
# nothing looks like a teardown that worked.
#
# DOCKER is the runner's own test seam, so no container is ever created.
#
# Run: ./tests/test-tp-runner-stop.sh   (offline)
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RUNNER="$TP_ROOT/runners/claude-docker/runner.sh"

# Hermeticity: the shared prologue ignores any taskpump.conf in the repo this
# suite happens to run from (a leaked conf reconfigures every fixture
# invocation below) and scrubs the pump-exported TASKPUMP_*/TP_*/ARACHNE_*
# environment (issue #18). run-all.sh sources the same prologue; this one
# covers standalone runs.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

[[ -f "$RUNNER" ]] || { echo "FAIL: runner not found at $RUNNER" >&2; exit 1; }

# A docker stub that fails with a given message on stderr and a given code.
# Every stop path the runner can meet is one of these.
make_docker() {
  local path="$WORK/$1" code="$2" msg="$3"
  cat >| "$path" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/calls.log"
printf '%s\n' "$msg" >&2
exit $code
EOF
  chmod +x "$path"
  printf '%s' "$path"
}

# run_stop <docker> [var=value]... — stop, in an environment carrying only what
# the case sets, so the harness's own variables cannot decide the outcome.
run_stop() {
  local docker="$1"; shift
  (
    unset TP_CONTAINER_NAME ARACHNE_CONTAINER_NAME
    local kv
    for kv in "$@"; do export "$kv"; done
    DOCKER="$docker" bash "$RUNNER" stop 2>&1
  )
}

echo "--- stop is idempotent across both 'already gone' conditions ---"

# The condition a real drain produces: the agent finished on its own before the
# supervisor got to it.
D=$(make_docker docker-exited 1 "Error response from daemon: Container abc is not running")
out=$(run_stop "$D" TP_CONTAINER_NAME=tp-agent-feat-t4); rc=$?
[[ $rc -eq 0 ]] \
  && pass "stopping a container that has already exited succeeds" \
  || fail "stop rejected an already-exited container (rc=$rc):\n$out"

# The condition a repeated teardown produces: it is gone entirely.
D=$(make_docker docker-absent 1 "Error response from daemon: No such container: ghost")
out=$(run_stop "$D" TP_CONTAINER_NAME=ghost); rc=$?
[[ $rc -eq 0 ]] \
  && pass "stopping a container that does not exist succeeds" \
  || fail "stop rejected an absent container (rc=$rc):\n$out"

# Idempotent means callable twice, which is the property the contract is for.
: >| "$WORK/calls.log"
run_stop "$D" TP_CONTAINER_NAME=ghost >/dev/null; rc1=$?
run_stop "$D" TP_CONTAINER_NAME=ghost >/dev/null; rc2=$?
[[ $rc1 -eq 0 && $rc2 -eq 0 && $(grep -c . "$WORK/calls.log") -eq 2 ]] \
  && pass "two stops in a row both succeed, and both reach the runtime" \
  || fail "repeated stop was not idempotent (rc1=$rc1 rc2=$rc2)"

echo "--- tolerance is not blanket error-swallowing ---"

# A daemon that is down is not "already gone", and reporting success would turn
# a failed teardown into a silent one.
D=$(make_docker docker-broken 1 "Cannot connect to the Docker daemon at unix:///var/run/docker.sock")
out=$(run_stop "$D" TP_CONTAINER_NAME=tp-agent-feat-t4); rc=$?
[[ $rc -ne 0 ]] && grep -q 'docker stop failed' <<<"$out" \
  && pass "an unrelated runtime failure still exits non-zero with a reason" \
  || fail "a broken daemon was reported as a successful stop (rc=$rc):\n$out"

# The name is the whole input; without it there is nothing to be idempotent
# about, and guessing would be worse than failing.
D=$(make_docker docker-unused 0 "")
out=$(run_stop "$D"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'TP_CONTAINER_NAME' <<<"$out" \
  && pass "a missing container name fails loudly rather than stopping nothing" \
  || fail "stop accepted an empty container name (rc=$rc):\n$out"

echo
printf 'Tests: %d  Passed: %d  Failed: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
