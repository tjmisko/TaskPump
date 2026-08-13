#!/usr/bin/env bash
# test-tp-runner-local.sh — runners/local/runner.sh against RUNNER CONTRACT v2.
#
# The local runner is the one with no runtime underneath it: no daemon keeps the
# name→process mapping, so the runner keeps it itself, in a registry file. That
# file is the whole design, and it is where every interesting failure lives.
#
# The properties that carry weight:
#
#   1. A finished agent is DEAD, even while its process-table entry survives.
#      `kill -0` succeeds on a zombie, and a reaped-by-nobody agent (any
#      container whose PID 1 is not an init — which is where unattended drains
#      run) stays a zombie indefinitely. The obvious implementation reports a
#      long-dead agent as live forever: stop never finishes, list never prunes,
#      and the phase is never relaunched. The zombie case below is deliberately
#      constructed, not incidental.
#   2. The registry never accumulates. An agent that exits on its own leaves an
#      entry nobody else will clean up, so list prunes what it walks.
#   3. Both "already gone" shapes are success (docs/RUNNERS.md §1.2): never
#      recorded, and recorded but exited. Only the second is what a real drain
#      produces.
#   4. A signal reaches the whole process GROUP. An agent spawns children; a
#      stop that kills only the leader leaves them holding the workspace.
#
# The stub agent is `sleep`. Nothing here needs docker, a network, or an agent.
#
# Run: ./tests/test-tp-runner-local.sh   (offline)
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RUNNER="$TP_ROOT/runners/local/runner.sh"

export TASKPUMP_NO_CONF=1

WORK=$(mktemp -d)
cleanup() {
  # Never leave a stub agent behind, whatever the suite did.
  local n p
  [[ -f "$WORK/registry" ]] && while read -r n p _rest; do
    [[ "$p" =~ ^[0-9]+$ ]] && kill -KILL -- "-$p" 2>/dev/null
  done < "$WORK/registry"
  rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

[[ -f "$RUNNER" ]] || { echo "FAIL: runner not found at $RUNNER" >&2; exit 1; }

WT="$WORK/wt"; mkdir -p "$WT"
export TASKPUMP_LOCAL_REGISTRY="$WORK/registry"

run() { bash "$RUNNER" "$@"; }
launch() {  # launch <name> <agent-cmd>
  TP_WORKSPACE="$WT" TP_CONTAINER_NAME="$1" TASKPUMP_LOCAL_AGENT_CMD="$2" \
    bash "$RUNNER" launch
}
pgid_of() { awk -v n="$1" '$1 == n { print $2 }' "$TASKPUMP_LOCAL_REGISTRY" 2>/dev/null; }
group_alive() {   # any non-zombie process in the group?
  ps -eo pgid=,stat= 2>/dev/null | awk -v g="$1" '$1 == g && $2 !~ /^Z/ { f = 1 } END { exit f ? 0 : 1 }'
}
wait_gone() {     # bounded wait, so a slow host does not fail a correct runner
  local pgid="$1" i=0
  while group_alive "$pgid" && (( i < 50 )); do sleep 0.1; i=$((i + 1)); done
}

echo "--- launch: detached, logged, recorded, named ---"

out=$(launch tp-agent-feat-a 'echo agent-started; sleep 60'); rc=$?
[[ $rc -eq 0 && "$out" == "tp-agent-feat-a" ]] \
  && pass "launch prints the agent name as its handle" \
  || fail "launch handle wrong (rc=$rc): '$out'"

PG_A=$(pgid_of tp-agent-feat-a)
[[ -n "$PG_A" ]] && pass "the agent is recorded in the registry" \
  || fail "no registry entry after launch:\n$(cat "$TASKPUMP_LOCAL_REGISTRY" 2>/dev/null)"

group_alive "$PG_A" && pass "the agent is actually running" || fail "no live process for pgid $PG_A"

# The registry records a process GROUP, and that is load-bearing: the agent's
# children must die with it. `sleep` under `bash -c` is already a child, so this
# check is not hypothetical.
[[ "$(ps -eo pgid= | grep -c "^ *$PG_A\$")" -ge 1 ]] \
  && pass "the agent runs in its own process group" \
  || fail "the agent is not in group $PG_A"

for i in 1 2 3 4 5 6 7 8 9 10; do
  [[ -s "$WT/.taskpump-agent.log" ]] && break
  sleep 0.1
done
grep -q 'agent-started' "$WT/.taskpump-agent.log" 2>/dev/null \
  && pass "the agent's output lands in the workspace log" \
  || fail "no agent log at $WT/.taskpump-agent.log"

echo "--- list reflects reality ---"

out=$(run list)
[[ "$out" == "tp-agent-feat-a" ]] && pass "list reports the live agent" || fail "list wrong: '$out'"

launch tp-agent-feat-b 'sleep 60' >/dev/null
PG_B=$(pgid_of tp-agent-feat-b)
out=$(run list | sort | tr '\n' ' ')
[[ "$out" == "tp-agent-feat-a tp-agent-feat-b " ]] \
  && pass "list reports every live agent, one per line" \
  || fail "list with two agents: '$out'"

# The contract's empty case, checked by byte count: `$()` strips a lone newline,
# so a string compare cannot see the blank-line defect that makes a
# line-counting caller read one live agent where there are none.
echo "--- an agent that dies on its own ---"

kill -KILL -- "-$PG_B" 2>/dev/null
wait_gone "$PG_B"

out=$(run list)
[[ "$out" == "tp-agent-feat-a" ]] \
  && pass "an agent killed behind the runner's back drops out of list" \
  || fail "list still reports a dead agent: '$out'"

# This is the zombie case. The killed agent is very likely still a process-table
# entry right now (its parent is gone, so whether it is reaped depends on the
# host's PID 1) — and `kill -0` would still succeed on it. list must not.
grep -q '^tp-agent-feat-b ' "$TASKPUMP_LOCAL_REGISTRY" \
  && fail "list left the dead agent in the registry:\n$(cat "$TASKPUMP_LOCAL_REGISTRY")" \
  || pass "list prunes the dead agent's registry entry"

[[ "$(wc -l < "$TASKPUMP_LOCAL_REGISTRY")" -eq 1 ]] \
  && pass "the registry holds exactly the live agents (it does not accumulate)" \
  || fail "registry has $(wc -l < "$TASKPUMP_LOCAL_REGISTRY") lines, expected 1"

echo "--- stop is idempotent across both 'already gone' shapes ---"

# The shape a real drain produces: recorded, but it finished on its own between
# the supervisor deciding to stop it and the call landing.
launch tp-agent-feat-c 'sleep 60' >/dev/null
PG_C=$(pgid_of tp-agent-feat-c)
kill -KILL -- "-$PG_C" 2>/dev/null
wait_gone "$PG_C"
out=$(TP_CONTAINER_NAME=tp-agent-feat-c bash "$RUNNER" stop 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "stopping an agent that already exited succeeds" \
  || fail "stop rejected an exited agent (rc=$rc):\n$out"
grep -q '^tp-agent-feat-c ' "$TASKPUMP_LOCAL_REGISTRY" \
  && fail "stop left a tombstone entry behind" \
  || pass "stop removes the entry of an agent that had already exited"

# The shape a repeated teardown produces: never recorded at all.
out=$(TP_CONTAINER_NAME=never-existed bash "$RUNNER" stop 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "stopping an agent that was never recorded succeeds" \
  || fail "stop rejected an unknown agent (rc=$rc):\n$out"

# Idempotent means callable twice.
out=$(TP_CONTAINER_NAME=tp-agent-feat-c bash "$RUNNER" stop 2>&1); rc2=$?
[[ $rc2 -eq 0 ]] && pass "a second stop of the same agent also succeeds" \
  || fail "repeated stop failed (rc=$rc2):\n$out"

echo "--- stop actually stops, and takes the children with it ---"

# The agent spawns a child that ignores nothing but is not the leader. Killing
# the leader alone would leave it running and holding the workspace.
launch tp-agent-feat-d 'sleep 120 & sleep 120' >/dev/null
PG_D=$(pgid_of tp-agent-feat-d)
sleep 0.3
members_before=$(ps -eo pgid=,stat= | awk -v g="$PG_D" '$1 == g && $2 !~ /^Z/ { n++ } END { print n + 0 }')
[[ "$members_before" -ge 2 ]] \
  && pass "the agent and its child share one process group ($members_before members)" \
  || fail "expected at least 2 processes in group $PG_D, saw $members_before"

out=$(TP_CONTAINER_NAME=tp-agent-feat-d bash "$RUNNER" stop 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "stop of a live agent succeeds" || fail "stop failed (rc=$rc):\n$out"
group_alive "$PG_D" \
  && fail "the agent's process group survived stop" \
  || pass "stop signals the whole group, children included"
[[ -z "$(pgid_of tp-agent-feat-d)" ]] \
  && pass "stop removes the stopped agent from the registry" \
  || fail "stop left the entry behind"

echo "--- list's empty and unreadable cases ---"

TP_CONTAINER_NAME=tp-agent-feat-a bash "$RUNNER" stop >/dev/null 2>&1
n=$(run list | wc -c)
[[ "$n" -eq 0 ]] \
  && pass "an empty fleet prints nothing at all (not a blank line)" \
  || fail "empty list printed $n bytes"
rc=0; run list >/dev/null 2>&1 || rc=$?
[[ $rc -eq 0 ]] && pass "an empty fleet still exits 0" || fail "empty list exited $rc"

# No registry at all — a host that has never launched anything.
saved="$TASKPUMP_LOCAL_REGISTRY"
TASKPUMP_LOCAL_REGISTRY="$WORK/nothing-here" out=$(run list); rc=$?
[[ $rc -eq 0 && -z "$out" ]] \
  && pass "no registry yet is an empty fleet, not an error" \
  || fail "missing registry (rc=$rc): '$out'"

# A registry that exists and cannot be read is a failure to ENUMERATE, which is
# the one case the contract says must not look like an empty fleet.
if [[ "$(id -u)" -eq 0 ]]; then
  pass "SKIP unreadable-registry case (running as root: no file is unreadable)"
  pass "SKIP unreadable-registry stderr case (running as root)"
else
  : >| "$WORK/locked"; chmod 000 "$WORK/locked"
  err=$(TASKPUMP_LOCAL_REGISTRY="$WORK/locked" bash "$RUNNER" list 2>&1 >/dev/null); rc=$?
  [[ $rc -ne 0 ]] \
    && pass "an unreadable registry exits non-zero rather than reporting nothing live" \
    || fail "an unreadable registry looked like an empty fleet (rc=$rc)"
  [[ "$(wc -l <<<"$err")" -eq 1 ]] \
    && pass "the failure says why in one line" \
    || fail "expected one line on stderr:\n$err"
  chmod 644 "$WORK/locked"
fi
TASKPUMP_LOCAL_REGISTRY="$saved"

echo "--- inputs the runner refuses to guess ---"

# Every input has a legacy twin the runner also reads, and this harness runs
# inside an agent workspace where several of them are already exported. A "no
# input" case has to unset BOTH spellings or it silently tests the ambient
# environment instead — which is how the WORKSPACE_PATH case first passed for
# the wrong reason.
bare() {
  env -u TP_WORKSPACE -u WORKSPACE_PATH \
      -u TP_CONTAINER_NAME -u ARACHNE_CONTAINER_NAME \
      -u TASKPUMP_LOCAL_AGENT_CMD -u TP_LOCAL_AGENT_CMD \
      TASKPUMP_LOCAL_REGISTRY="$TASKPUMP_LOCAL_REGISTRY" \
      "$@"
}

out=$(bare TP_WORKSPACE="$WT" TP_CONTAINER_NAME=tp-agent-x bash "$RUNNER" launch 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'TASKPUMP_LOCAL_AGENT_CMD' <<<"$out" \
  && pass "launch with no agent command fails loudly (there is no sane default)" \
  || fail "launch invented an agent (rc=$rc):\n$out"

out=$(bare TP_CONTAINER_NAME=tp-agent-x TASKPUMP_LOCAL_AGENT_CMD='sleep 1' bash "$RUNNER" launch 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'TP_WORKSPACE' <<<"$out" \
  && pass "launch with no workspace fails loudly" \
  || fail "launch accepted a missing workspace (rc=$rc):\n$out"

out=$(bare bash "$RUNNER" stop 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'TP_CONTAINER_NAME' <<<"$out" \
  && pass "stop with no name fails rather than stopping something arbitrary" \
  || fail "stop accepted an empty name (rc=$rc):\n$out"

# Two agents of one name is the one thing a container runtime prevents for free
# (`docker run --name`), and the pump's never-double-launch property leans on it.
launch tp-agent-feat-e 'sleep 60' >/dev/null
out=$(launch tp-agent-feat-e 'sleep 60' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'already running' <<<"$out" \
  && pass "launching over a live agent of the same name is refused" \
  || fail "a duplicate launch was allowed (rc=$rc):\n$out"
TP_CONTAINER_NAME=tp-agent-feat-e bash "$RUNNER" stop >/dev/null 2>&1

echo "--- the contract this runner claims ---"

out=$(run contract 2>&1)
[[ "$out" -ge 2 ]] && pass "it declares contract v2 (it implements list)" \
  || fail "contract version wrong: '$out'"
out=$(run --help 2>&1)
grep -q '^  runner\.sh list' <<<"$out" && pass "list appears in usage" || fail "list undocumented:\n$out"
grep -qi 'does NOT sandbox' <<<"$out" \
  && pass "the help says out loud that it does not sandbox" \
  || fail "the non-sandboxing warning is missing from --help:\n$out"

echo "--- end to end: a real pump tick, with no container runtime anywhere ---"
# The claim this runner exists to make good on: a consumer with no Docker can
# run a drain. So this section runs the actual supervisor, once, against a real
# git fixture — and points TASKPUMP_DOCKER at a path that does not exist, so any
# code path that still reaches for a container runtime fails loudly instead of
# quietly returning "nothing is live".
#
# Liveness is the part worth proving. The first tick launches; the second must
# see that agent still running, and the ONLY way it can know is by asking the
# runner (G3.2). A pump that scraped container names would report the phase dead
# and launch it a second time.

E2E="$WORK/e2e"; mkdir -p "$E2E"/{repo,ops,home}
REPO="$E2E/repo"

# The tools are COPIED into the fixture repo rather than invoked from the
# checkout. tp-pump derives the repository it drives from its own resolved
# location (readlink -f, so a symlink resolves straight back), which means
# running the installed pump here would create `feat/f80` and a worktree in
# TaskPump's own repo — a suite that mutates the checkout it is testing. The copy
# costs a second and makes this hermetic.
cp -R "$TP_ROOT"/{lib,libexec,gates,runners,templates} "$REPO"/ 2>/dev/null
PUMP="$REPO/libexec/tp-pump"

git -C "$REPO" init -q -b main 2>/dev/null || git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name Test
printf 'fixture\n' >| "$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture"
git -C "$REPO" branch -M main 2>/dev/null || true

E2E_TASKS="$E2E/tasks"; mkdir -p "$E2E_TASKS"
cat >| "$E2E_TASKS/F80.0.md" <<'EOF'
---
id: F80.0
phase: F80
title: fixture F80.0
status: open
claimed_by: null
claimed_at: null
turn_budget_remaining: null
consecutive_failed_iterations: 0
blockers: []
completed_by_commits: []
files: []
goal: drain F80.0
---
# F80.0
EOF
printf 'Phase {{PHASE}}. Goal: {{GOAL}}\n' >| "$E2E/brief.md"

E2E_REG="$E2E/registry"
e2e_tick() {
  env -u WORKSPACE_PATH -u TP_WORKSPACE -u TP_CONTAINER_NAME -u ARACHNE_CONTAINER_NAME \
    TASKPUMP_NO_CONF=1 \
    TASKPUMP_NOTIFY_CMD=true \
    TASKPUMP_TASKS_DIR="$E2E_TASKS" \
    TASKPUMP_ID_PATTERN='^F[0-9]+(\.[0-9]+)?$' \
    TASKPUMP_PHASE_SIGIL=F \
    TASKPUMP_PUMP_OPS_DIR="$E2E/ops" \
    TASKPUMP_PUMP_STATE_FILE="$E2E/pump.state" \
    TASKPUMP_POOL_CAP_FILE="$E2E/cap" \
    TASKPUMP_PUMP_LOG="$E2E/pump.log" \
    TASKPUMP_PHASE_BRIEF_TEMPLATE="$E2E/brief.md" \
    TASKPUMP_PUMP_WORKTREES_DIR="$E2E/worktrees" \
    TASKPUMP_AGENT_HOME="$E2E/home" \
    TASKPUMP_TASK_NOCOMMIT=1 \
    TASKPUMP_RUNNER="$REPO/runners/local/runner.sh" \
    TASKPUMP_LOCAL_REGISTRY="$E2E_REG" \
    TASKPUMP_LOCAL_AGENT_CMD='sleep 120' \
    TASKPUMP_DOCKER="$E2E/there-is-no-docker-here" \
    TASKPUMP_IMAGE=unused-by-a-process-runner \
    TASKPUMP_IMAGE_BUILD= \
    "$PUMP" --no-health-gate --no-disk-gate --phases F80 "${@:---once}" 2>&1
}

# The pump runs from the repo it drives.
out=$(cd "$REPO" && e2e_tick); rc=$?
[[ $rc -eq 0 ]] && pass "a real --once tick completes with no container runtime" \
  || fail "the tick failed (rc=$rc):\n$out"
grep -q 'liveness: asking the runner' <<<"$out" \
  && pass "the pump probed the runner and chose it as the liveness source" \
  || fail "the pump did not delegate liveness:\n$out"

E2E_NAME="tp-agent-feat-f80"
E2E_PG=$(awk -v n="$E2E_NAME" '$1 == n { print $2 }' "$E2E_REG" 2>/dev/null)
[[ -n "$E2E_PG" ]] && pass "the tick launched a real agent process ($E2E_NAME)" \
  || fail "no agent was launched:\n$out\nregistry: $(cat "$E2E_REG" 2>/dev/null)"
group_alive "$E2E_PG" && pass "the launched agent is alive" || fail "the agent died immediately"

# The second tick is the liveness proof. A pump that scraped container names
# would see nothing (there is no container runtime here at all), call the phase
# dead, and launch it again — so "did not relaunch" is the assertion, and the
# plan view of the same state is the readable version of it.
out2=$(cd "$REPO" && e2e_tick); rc=$?
[[ $rc -eq 0 ]] && pass "a second tick completes too" || fail "second tick failed (rc=$rc):\n$out2"
[[ "$(grep -c "^$E2E_NAME " "$E2E_REG")" -eq 1 ]] \
  && pass "the live agent was not launched a second time" \
  || fail "duplicate launch:\n$(cat "$E2E_REG")"

plan=$(cd "$REPO" && e2e_tick --dry-run 2>&1)
grep -qE 'RUNNING +F80' <<<"$plan" \
  && pass "the pump reports F80 RUNNING (liveness via the runner, not docker)" \
  || fail "the pump lost sight of a live agent:\n$plan"

TP_CONTAINER_NAME="$E2E_NAME" TASKPUMP_LOCAL_REGISTRY="$E2E_REG" bash "$RUNNER" stop >/dev/null 2>&1

echo
printf 'Tests: %d  Passed: %d  Failed: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
