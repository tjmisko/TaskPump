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

# Hermeticity: scrub the pump-exported TASKPUMP_*/TP_*/ARACHNE_* environment
# and ignore any ambient taskpump.conf (issue #18; run-all.sh sources the same
# prologue — this covers standalone runs).
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

# The prologue scrubs by namespace, and this is the one control input the runner
# reads under a bare name: TP_REPO_ROOT's legacy twin decides which fleet `list`
# and `stop` answer for, so an inherited REPO_ROOT — every pump-launched agent
# session exports one — would silently scope the sections below that mean to run
# unscoped.
unset REPO_ROOT

WORK=$(mktemp -d)
cleanup() {
  # Never leave a stub agent behind, whatever the suite did. Both registries:
  # the suite's own, and the host-global default the two-repo section drives
  # through a fixture XDG_STATE_HOME.
  local reg n p
  for reg in "$WORK/registry" "$WORK/xdg/taskpump/local-agents"; do
    [[ -f "$reg" ]] || continue
    while read -r n p _rest; do
      [[ "$p" =~ ^[0-9]+$ ]] && kill -KILL -- "-$p" 2>/dev/null
    done < "$reg"
  done
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

echo "--- one host, two repos: an agent belongs to the workspace it was launched for ---"
# Issue #40, found live in the G4.4 rehearsal. The registry is host-global by
# default and the agent prefix is shared, so the moment two projects agree on a
# branch convention their agent NAMES collide — and the second repo's supervisor
# read the first repo's live agent as its own RUNNING phase. That is the
# false-liveness family: work confidently reported as running that belongs to
# another project entirely. The workspace an agent was launched for is recorded,
# and it is what tells the two fleets apart.

WT_A=$(mkdir -p "$WORK/repo-a" && CDPATH= cd -- "$WORK/repo-a" && pwd -P)
WT_B=$(mkdir -p "$WORK/repo-b" && CDPATH= cd -- "$WORK/repo-b" && pwd -P)

launch_for() {   # launch_for <workspace-root> <name> <agent-cmd>
  TP_REPO_ROOT="$1" TP_WORKSPACE="$1" TP_CONTAINER_NAME="$2" TASKPUMP_LOCAL_AGENT_CMD="$3" \
    bash "$RUNNER" launch
}
list_for() { TP_REPO_ROOT="$1" bash "$RUNNER" list; }
stop_for() { TP_REPO_ROOT="$1" TP_CONTAINER_NAME="$2" bash "$RUNNER" stop; }
# The name alone is ambiguous once two repos use it, which is the whole subject
# of this section — so the fixture reads pgids by (name, workspace).
pgid_for() { awk -v n="$2" -v r="$1" '$1 == n && $3 == r { print $2 }' "$TASKPUMP_LOCAL_REGISTRY" 2>/dev/null; }

SHARED=tp-agent-feat-shared
launch_for "$WT_A" "$SHARED" 'sleep 60' >/dev/null
PG_SHARED_A=$(pgid_for "$WT_A" "$SHARED")
[[ -n "$PG_SHARED_A" ]] \
  && pass "should record the workspace an agent was launched for when it launches one" \
  || fail "no workspace-scoped entry for $SHARED:\n$(cat "$TASKPUMP_LOCAL_REGISTRY")"

out=$(list_for "$WT_B")
[[ "$out" != *"$SHARED"* ]] \
  && pass "should hide another workspace's agent when a second repo lists the shared registry" \
  || fail "repo B adopted repo A's agent: '$out'"

out=$(list_for "$WT_A")
[[ "$out" == *"$SHARED"* ]] \
  && pass "should still report its own agent when the workspace matches" \
  || fail "repo A lost sight of its own agent: '$out'"

# The name is free in repo B, because repo B has no agent by it. Refusing here
# would be the mirror-image wrong answer: a project unable to launch a phase
# because an unrelated project happens to be draining a branch of the same name.
out=$(launch_for "$WT_B" "$SHARED" 'sleep 60' 2>&1); rc=$?
[[ $rc -eq 0 ]] \
  && pass "should allow the launch when the live agent of that name belongs to another workspace" \
  || fail "repo B could not launch its own $SHARED (rc=$rc):\n$out"

PG_SHARED_B=$(pgid_for "$WT_B" "$SHARED")
[[ -n "$PG_SHARED_B" && "$PG_SHARED_B" != "$PG_SHARED_A" ]] \
  && pass "should keep both repos' entries when two workspaces run the same agent name" \
  || fail "repo B's entry is missing or aliased repo A's (a=$PG_SHARED_A b=$PG_SHARED_B):\n$(cat "$TASKPUMP_LOCAL_REGISTRY")"

# stop is the destructive half of the same identity bug: a teardown that matched
# on the name alone would reach into another project and kill a live agent.
out=$(stop_for "$WT_B" "$SHARED" 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "should succeed when a repo stops its own agent of a shared name" \
  || fail "stop failed (rc=$rc):\n$out"
group_alive "$PG_SHARED_A" \
  && pass "should leave the other workspace's agent running when one repo stops that name" \
  || fail "repo B's stop killed repo A's agent (pgid $PG_SHARED_A)"
group_alive "$PG_SHARED_B" \
  && fail "repo B's own agent survived its stop (pgid $PG_SHARED_B)" \
  || pass "should stop its own agent when both repos share the name"

out=$(list_for "$WT_A")
[[ "$out" == *"$SHARED"* ]] \
  && pass "should keep reporting its own agent when the other repo tore its own down" \
  || fail "repo A's agent vanished with repo B's teardown: '$out'"

# A teardown that finds only another workspace's entry must say so. "No agent
# named X is recorded" would be a wrong stated reason — the agent IS recorded,
# just not here — and a wrong reason is the failure this repo exists to refuse.
err=$(TP_REPO_ROOT="$WT_B" TP_CONTAINER_NAME="$SHARED" bash "$RUNNER" stop 2>&1 >/dev/null); rc=$?
[[ $rc -eq 0 ]] && grep -q "$WT_A" <<<"$err" \
  && pass "should name the owning workspace when asked to stop another repo's agent" \
  || fail "the refusal did not say whose agent it is (rc=$rc):\n$err"

# An entry written before the workspace was recorded cannot be proven foreign,
# and the destructive mistake is the other one: hiding an agent that IS ours
# makes the supervisor launch a second one on the same worktree. So an unscoped
# entry stays visible to everybody.
launch_for "$WT_A" tp-agent-feat-legacy 'sleep 60' >/dev/null
PG_LEGACY=$(pgid_for "$WT_A" tp-agent-feat-legacy)
sed -i "s|^tp-agent-feat-legacy $PG_LEGACY .*$|tp-agent-feat-legacy $PG_LEGACY|" "$TASKPUMP_LOCAL_REGISTRY"
out=$(list_for "$WT_B")
[[ "$out" == *tp-agent-feat-legacy* ]] \
  && pass "should still report an entry that records no workspace when it cannot be proven foreign" \
  || fail "an unscoped entry went invisible, which is how a live agent gets launched twice: '$out'"

stop_for "$WT_A" tp-agent-feat-legacy >/dev/null 2>&1
stop_for "$WT_A" "$SHARED" >/dev/null 2>&1

echo "--- a name two workspaces hold is a name no unscoped caller can act on ---"
# The other end of the same identity rule. Once two live agents share a name, an
# invocation that names no workspace cannot say which one it means — and the two
# ways of guessing are both destructive: signalling by file order kills whichever
# project was written first, and dropping the entries by NAME unregisters the
# survivor, which is how a running agent goes invisible and gets launched a
# second time on its own worktree. §1.2 already answers this: an ambiguous name
# is a non-zero exit, not a silent guess.

launch_for "$WT_A" "$SHARED" 'sleep 60' >/dev/null
launch_for "$WT_B" "$SHARED" 'sleep 60' >/dev/null
PG_SHARED_A=$(pgid_for "$WT_A" "$SHARED")
PG_SHARED_B=$(pgid_for "$WT_B" "$SHARED")

err=$(env -u REPO_ROOT TP_CONTAINER_NAME="$SHARED" bash "$RUNNER" stop 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 ]] \
  && pass "should refuse when a stop names an agent two workspaces hold and no workspace of its own" \
  || fail "an unscoped stop picked one of two agents by file order (rc=$rc):\n$err"
grep -q "$WT_A" <<<"$err" && grep -q "$WT_B" <<<"$err" \
  && pass "should name both holders of the name when it refuses an ambiguous stop" \
  || fail "the refusal named neither workspace it could not choose between:\n$err"
group_alive "$PG_SHARED_A" && group_alive "$PG_SHARED_B" \
  && pass "should signal neither agent when it refuses an ambiguous stop" \
  || fail "the refused stop killed something (a=$PG_SHARED_A b=$PG_SHARED_B)"

# The registry is the half that goes wrong quietly: an entry dropped for a live
# agent takes it out of `list`, and the supervisor launches over it.
out=$(list_for "$WT_A"); out2=$(list_for "$WT_B")
[[ "$out" == *"$SHARED"* && "$out2" == *"$SHARED"* ]] \
  && pass "should leave both workspaces' entries recorded when it refuses an ambiguous stop" \
  || fail "an entry was dropped for a live agent (a='$out' b='$out2'):\n$(cat "$TASKPUMP_LOCAL_REGISTRY")"

# The scoped caller is never ambiguous: it can prove which entry is its own.
out=$(stop_for "$WT_B" "$SHARED" 2>&1); rc=$?
[[ $rc -eq 0 ]] \
  && pass "should still stop its own agent when the caller names the workspace that holds it" \
  || fail "a scoped stop was refused as ambiguous (rc=$rc):\n$out"
out=$(list_for "$WT_A")
[[ "$out" == *"$SHARED"* ]] \
  && pass "should keep the other workspace's entry when a scoped stop removes its own" \
  || fail "repo A's live entry went with repo B's teardown: '$out'"

# And with one holder left the name is unambiguous again, so the pre-scope
# invocation — no workspace anywhere — works exactly as it always did.
out=$(env -u REPO_ROOT TP_CONTAINER_NAME="$SHARED" bash "$RUNNER" stop 2>&1); rc=$?
[[ $rc -eq 0 ]] \
  && pass "should stop the only agent of that name when an unscoped caller asks" \
  || fail "an unscoped stop failed on an unambiguous name (rc=$rc):\n$out"
wait_gone "$PG_SHARED_A"
group_alive "$PG_SHARED_A" \
  && fail "the unscoped stop reported success without stopping pgid $PG_SHARED_A" \
  || pass "should have actually torn the agent down when it reports success"

# An entry that records no workspace is visible to everybody (above), but it is
# not evidence about anybody: our own entry outranks it however the file is
# ordered. The state is what a mixed-version fleet leaves behind — an older
# runner still writing two-field lines beside ours — so the fixture builds it the
# way the older runner would, by taking the field back off an entry that already
# exists. Ordered first, which is the order that lets it answer for us.
ORDER=tp-agent-feat-order
launch_for "$WT_A" "$ORDER" 'sleep 60' >/dev/null
launch_for "$WT_B" "$ORDER" 'sleep 60' >/dev/null
PG_ORDER_A=$(pgid_for "$WT_A" "$ORDER")
PG_ORDER_B=$(pgid_for "$WT_B" "$ORDER")
[[ -n "$PG_ORDER_A" && -n "$PG_ORDER_B" ]] \
  || fail "the fixture did not get two entries for $ORDER (a=$PG_ORDER_A b=$PG_ORDER_B):\n$(cat "$TASKPUMP_LOCAL_REGISTRY")"
sed -i "s|^$ORDER $PG_ORDER_A .*$|$ORDER $PG_ORDER_A|" "$TASKPUMP_LOCAL_REGISTRY"

stop_for "$WT_B" "$ORDER" >/dev/null 2>&1
wait_gone "$PG_ORDER_B"
group_alive "$PG_ORDER_B" \
  && fail "repo B's stop signalled the unscoped entry instead of its own (pgid $PG_ORDER_B)" \
  || pass "should stop its own agent when an entry recording no workspace is listed first"
group_alive "$PG_ORDER_A" \
  && pass "should leave the unscoped entry's agent running when a scoped stop passes it over" \
  || fail "repo B's stop killed the agent behind the unscoped entry (pgid $PG_ORDER_A)"

env -u REPO_ROOT TP_CONTAINER_NAME="$ORDER" bash "$RUNNER" stop >/dev/null 2>&1
wait_gone "$PG_ORDER_A"

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
# hooks/ is part of the install, not an optional extra: the pump's default
# pre-tick chain is <install>/hooks/gitignore-repair then <install>/hooks/fs-guard,
# and an entry it cannot run now refuses the run at startup rather than being
# skipped with a warning. A fixture install missing them is not a shape a
# consumer should be able to reach quietly, so the fixture is a complete one.
cp -R "$TP_ROOT"/{lib,libexec,gates,hooks,runners,templates} "$REPO"/ 2>/dev/null
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
# Hermeticity: TASKPUMP_AGENT_HOME points the Claude gates' credentials at the
# fixture (absent — both gates skip, fail-open), and TASKPUMP_USAGE_CACHE keeps
# the usage gate off the host-global /tmp/claude-plan-usage.json — a statusline
# keeps that cache warm with the operator's REAL usage, and a live window at or
# above the ceiling would pause feeding and fail every launch assertion below.
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
    TASKPUMP_USAGE_CACHE="$E2E/usage-cache.json" \
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

echo "--- two repos, one host: the second pump must not adopt the first's agent ---"
# The reproduction from issue #40, end to end and with nothing pinned that a
# consumer would not pin: two projects, the default agent prefix, and the
# runner's DEFAULT registry — the host-global file both of them resolve. Their
# phase F80 slugs to the same branch, so both would name their agent
# tp-agent-feat-f80. The second pump must plan its OWN launch; adopting the
# first repo's agent means reporting a phase RUNNING that no one is draining
# here, and leaving F80 undrained for the rest of the run.

XREPO_XDG="$WORK/xdg"
xrepo_repo() {  # xrepo_repo <dir> — a fixture consumer with a root-level ledger
  local dir="$1"
  mkdir -p "$dir/tasks"
  git -C "$dir" init -q -b main 2>/dev/null || git -C "$dir" init -q
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name Test
  printf 'fixture\n' >| "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -qm "fixture"
  git -C "$dir" branch -M main 2>/dev/null || true
  cp "$E2E_TASKS/F80.0.md" "$dir/tasks/F80.0.md"
}
# No TASKPUMP_LOCAL_REGISTRY and no TASKPUMP_STATE_DIR: the runner resolves
# $XDG_STATE_HOME/taskpump/local-agents, which is the one file both repos share.
xrepo_tick() {  # xrepo_tick <repo> [pump args…]
  local repo="$1"; shift
  ( cd "$repo" || exit 1
    env -u WORKSPACE_PATH -u TP_WORKSPACE -u TP_CONTAINER_NAME -u ARACHNE_CONTAINER_NAME \
        -u TASKPUMP_LOCAL_REGISTRY \
      XDG_STATE_HOME="$XREPO_XDG" \
      TASKPUMP_NO_CONF=1 \
      TASKPUMP_NOTIFY_CMD=true \
      TASKPUMP_TASKS_DIR="$repo/tasks" \
      TASKPUMP_ID_PATTERN='^F[0-9]+(\.[0-9]+)?$' \
      TASKPUMP_PHASE_SIGIL=F \
      TASKPUMP_PUMP_OPS_DIR="$repo/ops" \
      TASKPUMP_PUMP_STATE_FILE="$repo/pump.state" \
      TASKPUMP_POOL_CAP_FILE="$repo/cap" \
      TASKPUMP_PUMP_LOG="$repo/pump.log" \
      TASKPUMP_PHASE_BRIEF_TEMPLATE="$E2E/brief.md" \
      TASKPUMP_PUMP_WORKTREES_DIR="$repo/.worktrees" \
      TASKPUMP_AGENT_HOME="$E2E/home" \
      TASKPUMP_USAGE_CACHE="$E2E/usage-cache.json" \
      TASKPUMP_TASK_NOCOMMIT=1 \
      TASKPUMP_RUNNER="$REPO/runners/local/runner.sh" \
      TASKPUMP_LOCAL_AGENT_CMD='sleep 120' \
      TASKPUMP_DOCKER="$E2E/there-is-no-docker-here" \
      TASKPUMP_IMAGE=unused-by-a-process-runner \
      TASKPUMP_IMAGE_BUILD= \
      "$PUMP" --no-health-gate --no-disk-gate --phases F80 "${@:---once}" 2>&1
  )
}

# Canonical paths: the pump derives its workspace root from git, and the runner
# canonicalises what it records, so the fixture has to compare against the same
# spelling rather than whatever mktemp handed back.
mkdir -p "$E2E/consumer-a" "$E2E/consumer-b"
XREPO_A=$(CDPATH= cd -- "$E2E/consumer-a" && pwd -P)
XREPO_B=$(CDPATH= cd -- "$E2E/consumer-b" && pwd -P)
xrepo_repo "$XREPO_A"; xrepo_repo "$XREPO_B"
XREPO_REG="$XREPO_XDG/taskpump/local-agents"

out=$(xrepo_tick "$XREPO_A"); rc=$?
[[ $rc -eq 0 ]] && pass "the first consumer's tick completes on the default registry" \
  || fail "consumer A's tick failed (rc=$rc):\n$out"
PG_XA=$(awk -v n="$E2E_NAME" -v r="$XREPO_A" '$1 == n && $3 == r { print $2 }' "$XREPO_REG" 2>/dev/null)
[[ -n "$PG_XA" ]] && pass "consumer A's agent is recorded against consumer A's workspace" \
  || fail "no scoped entry for consumer A:\n$(cat "$XREPO_REG" 2>/dev/null)"

plan=$(xrepo_tick "$XREPO_B" --dry-run)
grep -qE 'LAUNCH +F80' <<<"$plan" \
  && pass "should plan its own launch when another repo's live agent carries the same name" \
  || fail "the second pump adopted the first repo's agent:\n$plan"

out=$(xrepo_tick "$XREPO_B"); rc=$?
[[ $rc -eq 0 ]] && pass "the second consumer's tick completes too" \
  || fail "consumer B's tick failed (rc=$rc):\n$out"
PG_XB=$(awk -v n="$E2E_NAME" -v r="$XREPO_B" '$1 == n && $3 == r { print $2 }' "$XREPO_REG" 2>/dev/null)
[[ -n "$PG_XB" && "$PG_XB" != "$PG_XA" ]] \
  && pass "should launch a second agent of its own when the name collides across repos" \
  || fail "consumer B launched nothing of its own (a=$PG_XA b=$PG_XB):\n$(cat "$XREPO_REG" 2>/dev/null)"
group_alive "$PG_XA" \
  && pass "should leave the first consumer's agent untouched when the second one drains" \
  || fail "consumer A's agent died when consumer B ticked (pgid $PG_XA)"

TP_REPO_ROOT="$XREPO_A" TP_CONTAINER_NAME="$E2E_NAME" TASKPUMP_LOCAL_REGISTRY="$XREPO_REG" \
  bash "$RUNNER" stop >/dev/null 2>&1
TP_REPO_ROOT="$XREPO_B" TP_CONTAINER_NAME="$E2E_NAME" TASKPUMP_LOCAL_REGISTRY="$XREPO_REG" \
  bash "$RUNNER" stop >/dev/null 2>&1

echo
printf 'Tests: %d  Passed: %d  Failed: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
