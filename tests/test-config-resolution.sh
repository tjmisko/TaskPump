#!/usr/bin/env bash
# test-config-resolution.sh — the silent config-resolution class (issues #1,
# #2, #3, #6). Shared root cause: a resolution answer derived from the wrong
# anchor, silently — rc=0 with a wrong or empty result.
#
#   #1  a relative path in taskpump.conf resolved against $PWD, so a ledger
#       command run from a SUBDIRECTORY saw an empty frontier with rc=0;
#   #2  tp-pump's tasks-dir default was hardcoded to Arachne's
#       ops/task-loop/tasks instead of deriving from TASKPUMP_LEDGER_PROBE
#       like tp-task and tp-monitor;
#   #3  TASKPUMP_SUBMODULE_PROBE defaulted to Arachne's ops/planning/STATUS.md,
#       which can exist for the wrong reason and silently SKIP the submodule
#       init some other submodule still needs;
#   #6  a vendored TaskPump checkout's own tracked taskpump.conf hijacked the
#       enclosing consumer's ledger resolution.
#
# Run: ./tests/test-config-resolution.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TASK="$TP_ROOT/libexec/tp-task"
PUMP="$TP_ROOT/libexec/tp-pump"

# Hermeticity: no ambient conf from the repo this suite runs in, and no
# inherited pump env (issue #18). Cases that test discovery itself opt back in
# per-invocation (TASKPUMP_NO_CONF=0 or an explicit TASKPUMP_CONFIG).
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

# Both spellings of every key that could pre-answer a resolution question are
# cleared, and TP_ENV_UNSET re-establishes the clean slate per subshell.
TP_CONFIG_SUFFIXES=(
  TASKS_DIR TASK_OUT CODE_REPO LEDGER_PROBE LEDGER_REPO TASKS_SUBDIR
  PUMP_TASKS_DIR PUMP_OPS_DIR SUBMODULE_PROBE ID_PATTERN PHASE_SIGIL
  BRIEF_TEMPLATE PHASE_BRIEF_TEMPLATE TASK_BRIEF_TEMPLATE RESUME_TEMPLATE
  TASK_NOCOMMIT CONFIG WORKSPACE_ROOT
)
TP_ENV_UNSET=()
for _suffix in "${TP_CONFIG_SUFFIXES[@]}"; do
  TP_ENV_UNSET+=(-u "ARACHNE_$_suffix" -u "TASKPUMP_$_suffix")
  unset "ARACHNE_$_suffix" "TASKPUMP_$_suffix" 2>/dev/null || true
done
unset _suffix

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
have() { grep -qE "$2" <<<"$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

mk() {  # mk <dir> <id> [status]
  local dir=$1 id=$2 status=${3:-open}
  cat >| "$dir/$id.md" <<EOF
---
id: $id
phase: ${id%%.*}
title: fixture $id
status: $status
claimed_by: null
claimed_at: null
turn_budget_remaining: null
consecutive_failed_iterations: 0
blockers: []
completed_by_commits: []
files: []
goal: drain $id
---
# $id
EOF
}

# ══ Issue #1 — conf-relative paths anchor to the workspace, never $PWD ════════
echo "--- #1: a conf-relative tasks dir works from a subdirectory ---"

# A consumer whose checked-in conf carries a relative tasks dir — the only kind
# a committed conf CAN carry, since every worktree is a different absolute path.
C1="$TMP/consumer1"
mkdir -p "$C1/planning/tasks" "$C1/crates/deep"
git -C "$C1" init -q
cat >| "$C1/taskpump.conf" <<'CONF'
TASKPUMP_TASKS_DIR=planning/tasks
CONF
mk "$C1/planning/tasks" T1
mk "$C1/planning/tasks" T2

# The literal issue-#1 reproduction: an explicit TASKPUMP_CONFIG, invoked from
# a subdirectory of the workspace. This used to print the header row only —
# an empty frontier over open tasks, rc=0.
out=$( cd "$C1/crates" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        TASKPUMP_CONFIG="$C1/taskpump.conf" "$TASK" ready 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && have "$out" '^T1 ' && have "$out" '^T2 ' \
  && pass "explicit conf from a subdir: the frontier lists the open tasks" \
  || fail "explicit conf from a subdir lost the frontier (rc=$rc):\n$out"

got=$( cd "$C1/crates" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        TASKPUMP_CONFIG="$C1/taskpump.conf" "$TASK" ready --count 2>/dev/null )
[[ "$got" == "2" ]] && pass "ready --count sees both open tasks from the subdir" \
  || fail "ready --count got '$got', expected 2"

# The discovered-conf flavor of the same defect, from a deeper subdirectory.
out=$( cd "$C1/crates/deep" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 \
        TASKPUMP_TASK_NOCOMMIT=1 "$TASK" ready 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && have "$out" '^T1 ' \
  && pass "discovered conf from a subdir: the frontier lists the open tasks" \
  || fail "discovered conf from a subdir lost the frontier (rc=$rc):\n$out"

# The pump flavor of the same defect — the shape G5.2 escalated: a pump
# launched from a subdirectory used to read an empty ledger and false-drain
# the range at rc=0. The plan must see both open tasks from anywhere in the
# workspace. HOME is pointed at an empty dir so the claude gates skip
# identically on any host.
CFGHOME="$TMP/cfg-home"; mkdir -p "$CFGHOME"
out=$( cd "$C1/crates" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 \
        TASKPUMP_TASK_NOCOMMIT=1 HOME="$CFGHOME" TASKPUMP_TASK="$TASK" \
        "$PUMP" --no-health-gate --no-usage-gate --no-disk-gate \
        --phases T1..T2 --dry-run 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && pass "pump --dry-run from a subdir exits 0" \
  || fail "pump --dry-run from a subdir rc=$rc:\n$out"
have "$out" 'open tasks in range: 2' \
  && pass "the subdir plan sees both open tasks — no false drain" \
  || fail "the subdir plan lost the ledger (the G5.2 false-drain shape):\n$out"
have "$out" 'LAUNCH' && pass "the subdir plan can launch the frontier" \
  || fail "no LAUNCH in the subdir plan:\n$out"

# resolve reports what will actually be used: an absolute path, the same
# answer from every directory of the workspace.
got=$( cd "$C1/crates" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 \
        TASKPUMP_TASK_NOCOMMIT=1 "$TASK" resolve --tasks-dir )
[[ "$got" == "$C1/planning/tasks" ]] \
  && pass "resolve prints the absolute anchored tasks dir" \
  || fail "resolve got '$got', expected '$C1/planning/tasks'"

# The via line names the rung that actually decided — a conf-supplied or
# env-supplied tasks dir must not be attributed to the workspace walk.
got=$( cd "$C1/crates" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 \
        TASKPUMP_TASK_NOCOMMIT=1 "$TASK" resolve --all | awk '/^via/{print $2}' )
[[ "$got" == "conf-value" ]] \
  && pass "resolve --all attributes a conf-supplied tasks dir to conf-value" \
  || fail "via for a conf-supplied tasks dir reads '$got', expected conf-value"
got=$( cd "$C1" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        TASKPUMP_TASKS_DIR="$C1/planning/tasks" "$TASK" resolve --all \
        | awk '/^via/{print $2}' )
[[ "$got" == "env" ]] \
  && pass "resolve --all attributes an env-supplied tasks dir to env" \
  || fail "via for an env-supplied tasks dir reads '$got', expected env"

# An ENVIRONMENT value keeps the shell's own convention: the caller typed it
# where they stood, so it stays $PWD-relative and is not rewritten.
got=$( cd "$C1" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        TASKPUMP_TASKS_DIR=planning/tasks "$TASK" resolve --tasks-dir )
[[ "$got" == "planning/tasks" ]] \
  && pass "an environment-supplied relative path is left alone" \
  || fail "env-supplied path was rewritten to '$got'"

echo "--- #1: the residual cases are loud, not empty ---"

# A tasks dir that does not exist is an error naming the diagnostic — never an
# empty frontier with rc=0 (the pump would report the range drained).
out=$( cd "$C1" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        TASKPUMP_TASKS_DIR="$TMP/no-such-ledger" "$TASK" ready 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && pass "a nonexistent tasks dir fails ready (rc=$rc), not an empty frontier" \
  || fail "ready over a nonexistent tasks dir exited 0:\n$out"
have "$out" "$TMP/no-such-ledger" && pass "the refusal names the missing directory" \
  || fail "the refusal does not name the directory:\n$out"
have "$out" 'resolve' && pass "the refusal points at the resolve diagnostic" \
  || fail "the refusal does not point at resolve:\n$out"

# The pump flavor of the same refusal: open_count/frontier_phases mask
# tp-task's error into "0 open tasks" with their 2>/dev/null fallbacks, so
# without a startup check a missing ledger renders every phase DONE at rc=0.
out=$( cd "$C1" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        HOME="$CFGHOME" TASKPUMP_TASKS_DIR="$TMP/no-such-ledger" \
        TASKPUMP_TASK="$TASK" "$PUMP" --no-health-gate --no-usage-gate \
        --no-disk-gate --phases T1..T2 --dry-run 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && pass "pump --dry-run refuses a nonexistent tasks dir (rc=$rc)" \
  || fail "pump --dry-run over a missing ledger exited 0:\n$out"
have "$out" "$TMP/no-such-ledger" && pass "the pump refusal names the missing directory" \
  || fail "the pump refusal does not name the directory:\n$out"
have "$out" 'DONE' \
  && fail "the plan still renders DONE over a missing ledger:\n$out" \
  || pass "no phase renders DONE over a missing ledger"

# `resolve` itself keeps working — it is the diagnostic the error points at.
rc=0
got=$( cd "$C1" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        TASKPUMP_TASKS_DIR="$TMP/no-such-ledger" "$TASK" resolve --tasks-dir ) || rc=$?
[[ $rc -eq 0 && "$got" == "$TMP/no-such-ledger" ]] \
  && pass "resolve still answers over the missing directory" \
  || fail "resolve was blocked too (rc=$rc): '$got'"

# Unanchorable: an explicit conf with a relative path, run from OUTSIDE any
# git worktree. Resolving against $PWD would silently pick a different ledger
# per directory, so it is an error naming the key and the fixes.
NOREPO="$TMP/norepo"; mkdir -p "$NOREPO"
out=$( cd "$NOREPO" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        TASKPUMP_CONFIG="$C1/taskpump.conf" "$TASK" ready 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && pass "an unanchorable conf-relative path is refused (rc=$rc)" \
  || fail "unanchorable conf path was accepted:\n$out"
have "$out" 'TASKPUMP_TASKS_DIR' && pass "the refusal names the key" \
  || fail "the refusal does not name the key:\n$out"

echo "--- #1: EVERY documented anchored key anchors, from a subdirectory ---"

# The keys CONFIG.md promises to anchor are a list, and a list is exactly the
# kind of thing that goes one entry short: TASKPUMP_TASK_BRIEF_TEMPLATE was
# documented as anchored and was missing from TP_ANCHORED_PATH_KEYS, so a
# conf-relative task brief resolved from the workspace root and died "task brief
# template not found" from a subdirectory — while its phase-grain sibling on the
# same conf resolved fine. Both grains, both directories, one conf.
CT="$TMP/consumer-templates"
mkdir -p "$CT/planning/tasks" "$CT/briefs" "$CT/crates"
git -C "$CT" init -q
cat >| "$CT/taskpump.conf" <<'CONF'
TASKPUMP_TASKS_DIR=planning/tasks
TASKPUMP_PHASE_BRIEF_TEMPLATE=briefs/phase.md
TASKPUMP_TASK_BRIEF_TEMPLATE=briefs/task.md
CONF
printf 'ANCHORED phase brief for {{PHASE}}\n' >| "$CT/briefs/phase.md"
printf 'ANCHORED task brief for {{TASK_ID}}\n' >| "$CT/briefs/task.md"
mk "$CT/planning/tasks" T1.1

render_at() {  # render_at <dir> [pump flags...] — --render-brief from <dir>
  ( cd "$1" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 \
      TASKPUMP_TASK_NOCOMMIT=1 TASKPUMP_TASK="$TASK" "$PUMP" "${@:2}" 2>&1 )
}

for where in "$CT" "$CT/crates"; do
  label="the workspace root"; [[ "$where" == */crates ]] && label="a subdirectory"
  out=$(render_at "$where" --render-brief T1); rc=$?
  [[ $rc -eq 0 ]] && have "$out" 'ANCHORED phase brief for T1' \
    && pass "a conf-relative phase brief resolves from $label" \
    || fail "phase brief from $label (rc=$rc):\n$out"
  out=$(render_at "$where" --grain task --render-brief T1.1); rc=$?
  [[ $rc -eq 0 ]] && have "$out" 'ANCHORED task brief for T1\.1' \
    && pass "a conf-relative task brief resolves from $label" \
    || fail "task brief from $label (rc=$rc):\n$out"
done
unset where label

# ══ Issue #2 — tp-pump derives its tasks dir from the probe, like tp-task ═════
echo "--- #2: a zero-conf consumer's pump brief points at ITS ledger ---"

# The README's zero-conf shape: git init, a tasks/ directory, nothing else.
ZC="$TMP/zeroconf"
mkdir -p "$ZC/tasks"
git -C "$ZC" init -q
mk "$ZC/tasks" T1

# The brief the pump would hand an agent must name this repository's tasks
# dir. It used to say ops/task-loop/tasks — a directory that does not exist in
# a repo set up exactly as documented — because tp-pump never consulted
# TASKPUMP_LEDGER_PROBE. Named as the AGENT reaches it from its worktree:
# workspace-relative (`tasks/…`), since the ledger lives inside the workspace.
# (Before issue #32 this rendered as the primary checkout's ABSOLUTE path —
# an artifact of REPO_ROOT being the install root, so the workspace prefix
# never stripped.)
out=$( cd "$ZC" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        TASKPUMP_TASK="$TASK" "$PUMP" --render-brief T1 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && pass "zero-conf --render-brief renders (rc=0)" \
  || fail "zero-conf --render-brief rc=$rc:\n$out"
have "$out" '`tasks/T1\.N\.md`' \
  && pass "the brief names the consumer's own tasks dir, worktree-relative" \
  || fail "the brief does not name tasks/T1.N.md:\n$out"
have "$out" 'ops/task-loop/tasks' \
  && fail "the Arachne-shaped tasks dir is still in the brief:\n$out" \
  || pass "the Arachne ops/task-loop/tasks fallback is gone from the brief"

# The probe spelling still reaches the pump: a consumer whose ledger lives
# elsewhere names it once, and the pump's derivation follows.
mkdir -p "$ZC/work/items"
mk "$ZC/work/items" T9
out=$( cd "$ZC" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        TASKPUMP_LEDGER_PROBE=work/items TASKPUMP_TASK="$TASK" \
        "$PUMP" --render-brief T9 2>&1 )
have "$out" '`work/items/T9\.N\.md`' \
  && pass "TASKPUMP_LEDGER_PROBE drives the pump's tasks dir" \
  || fail "the probe did not reach the pump's derivation:\n$out"

# ══ Issue #3 — no Arachne-shaped submodule probe default ══════════════════════
echo "--- #3: an unset submodule probe always inits; a configured one can skip ---"

# A real --once tick with a recording git stub: the worktree pre-exists and
# carries Arachne's old probe file ops/planning/STATUS.md. Under the OLD
# default the pump would read that as "submodules are populated" and skip the
# init — for any consumer with a second submodule, a silent skip. With no
# default, the (idempotent) init must run anyway.
BIN="$TMP/bin"; mkdir -p "$BIN"
SUBLOG="$TMP/submodule-calls.log"
GITCOMMON="$TMP/gitcommon"; mkdir -p "$GITCOMMON/info"
cat >| "$BIN/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *submodule*)          printf '%s\n' "\$*" >> "$SUBLOG" ;;
  *--git-common-dir*)   echo "$GITCOMMON" ;;
  *rev-parse*--verify*) exit 0 ;;
  *rev-parse*)          echo "aaaaaaa1111" ;;
  *rev-list*--count*)   echo "0" ;;
  *) : ;;
esac
exit 0
EOF
cat >| "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "ps" ]]; then exit 0; fi
exit 0
EOF
cat >| "$BIN/runner" <<'EOF'
#!/usr/bin/env bash
echo "stub-container-id"
exit 0
EOF
chmod +x "$BIN/git" "$BIN/docker" "$BIN/runner"

mkdir -p "$TMP/nohome"
PTASKS="$TMP/pump-tasks"; mkdir -p "$PTASKS"
mk "$PTASKS" T5
WTS="$TMP/wts"
mkdir -p "$WTS/feat/t5/ops/planning"
printf 'status\n' >| "$WTS/feat/t5/ops/planning/STATUS.md"

# TASKPUMP_STATE_DIR pins the whole state-dir family into $TMP (B16). It is
# worth having here because this tick cds to $TMP but also names
# TASKPUMP_TASKS_DIR — which exempts it from the pump's install-root refusal —
# so REPO_ROOT resolves to the TaskPump INSTALL root, i.e. the checkout the
# suite runs from, and any $STATE_DIR-derived name not pinned individually below
# would land there. It is a backstop, not the fix: measured, removing it today
# leaves nothing at the checkout root, because the names that matter here are
# already pinned by hand.
#
# It does NOT cover the file this suite actually damaged. With
# TASKPUMP_PRE_TICK_HOOKS=' ' the hooks produce no output and
# run_pre_tick_hooks' quiet branch `rm -f`s the mark file — that is how this
# suite deleted the operator's live .taskpump-fsguard.notified. The mark file
# follows TASKPUMP_HOOK_MARK_FILE, which tests/suite-prologue.sh sets and which
# outranks $STATE_DIR; that redirect, not this pin, is what stopped it.
probe_tick() {  # extra env assignments come first, as "K=V" words
  ( cd "$TMP" && env "${TP_ENV_UNSET[@]}" "$@" \
      PATH="$BIN:$PATH" \
      TASKPUMP_STATE_DIR="$TMP" \
      TASKPUMP_TASK_NOCOMMIT=1 \
      TASKPUMP_TASKS_DIR="$PTASKS" \
      TASKPUMP_TASK="$TASK" \
      TASKPUMP_PUMP_WORKTREES_DIR="$WTS" \
      TASKPUMP_PUMP_OPS_DIR="$TMP/noops" \
      TASKPUMP_PUMP_STATE_FILE="$TMP/probe.state" \
      TASKPUMP_POOL_CAP_FILE="$TMP/cap" \
      TASKPUMP_PUMP_LOG="$TMP/probe-pump.log" \
      TASKPUMP_PRE_TICK_HOOKS=' ' \
      TASKPUMP_AGENT_HOME="$TMP/nohome" \
      TASKPUMP_IMAGE=probe-img TASKPUMP_IMAGE_BUILD='' \
      TASKPUMP_RUNNER="$BIN/runner" \
      DOCKER="$BIN/docker" \
      "$PUMP" --no-health-gate --no-usage-gate --no-disk-gate \
        --phases T5 --once 2>&1 )
}

: >| "$SUBLOG"
out=$(probe_tick)
grep -q 'submodule update --init --recursive' "$SUBLOG" \
  && pass "no probe configured: the submodule init runs despite ops/planning/STATUS.md existing" \
  || fail "no probe configured: the init was skipped — the Arachne default is back:\n$out\n$(cat "$SUBLOG" 2>/dev/null)"

: >| "$SUBLOG"
out=$(probe_tick TASKPUMP_SUBMODULE_PROBE=ops/planning/STATUS.md)
grep -q 'submodule update' "$SUBLOG" \
  && fail "a configured probe that answers still ran the init:\n$(cat "$SUBLOG")" \
  || pass "a configured probe that answers skips the init (the opt-in optimization)"

: >| "$SUBLOG"
out=$(probe_tick TASKPUMP_SUBMODULE_PROBE=does/not/exist)
grep -q 'submodule update' "$SUBLOG" \
  && pass "a configured probe that does not answer runs the init" \
  || fail "a configured, unanswered probe skipped the init:\n$out"

# ══ Issue #6 — a vendored TaskPump's conf never captures the consumer ═════════
echo "--- #6: a vendored (subtree/copy) TaskPump conf is skipped by discovery ---"

# A consumer that vendors a TaskPump checkout as tracked files (subtree or
# plain copy): the vendored tree carries lib/, libexec/, its own dogfood conf,
# and its own G-shaped ledger.
C2="$TMP/consumer2"
VEND="$C2/vendor/taskpump"
mkdir -p "$C2/tasks" "$VEND/tasks" "$VEND/deeper"
git -C "$C2" init -q
printf 'TASKPUMP_TASKS_DIR=tasks\n' >| "$C2/taskpump.conf"
cat >| "$VEND/taskpump.conf" <<'CONF'
TASKPUMP_TASKS_DIR=tasks
TASKPUMP_ID_PATTERN='^G[0-9]+(\.[0-9]+)?$'
TASKPUMP_PHASE_SIGIL=G
CONF
cp -R "$TP_ROOT/lib" "$VEND/lib"
mkdir -p "$VEND/libexec"
cp "$TASK" "$VEND/libexec/tp-task"
chmod +x "$VEND/libexec/tp-task"
mk "$C2/tasks" T1
mk "$VEND/tasks" G1

# Standing INSIDE the vendored checkout, discovery must pass over the vendored
# conf and land on the consumer's — for an outside install of the tools...
got=$( cd "$VEND/deeper" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 \
        TASKPUMP_TASK_NOCOMMIT=1 "$TASK" resolve --tasks-dir )
[[ "$got" == "$C2/tasks" ]] \
  && pass "outside-install invocation from inside the vendored tree resolves to the consumer's ledger" \
  || fail "resolution got '$got', expected '$C2/tasks'"

# ...and equally for the vendored copy of the tools themselves.
got=$( cd "$VEND/deeper" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 \
        TASKPUMP_TASK_NOCOMMIT=1 "$VEND/libexec/tp-task" resolve --tasks-dir )
[[ "$got" == "$C2/tasks" ]] \
  && pass "the vendored CLI itself resolves to the consumer's ledger" \
  || fail "vendored-CLI resolution got '$got', expected '$C2/tasks'"

# The consumer's frontier — not the vendored G ledger — is what `ready` shows
# from inside the vendored tree.
out=$( cd "$VEND" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 \
        TASKPUMP_TASK_NOCOMMIT=1 "$TASK" ready 2>&1 )
have "$out" '^T1 ' && pass "ready inside the vendored tree lists the consumer's tasks" \
  || fail "ready inside the vendored tree lost the consumer's frontier:\n$out"
have "$out" '^G1 ' && fail "ready surfaced the vendored G ledger:\n$out" \
  || pass "the vendored G ledger stays out of the consumer's frontier"

echo "--- #6: a standalone TaskPump checkout (dogfood) keeps its own conf ---"

# The dogfood shape: a TaskPump install that is its own repository and nobody's
# vendored copy. Its conf must keep anchoring — this is TaskPump driving its
# own G ledger.
DOG="$TMP/dogfood"
mkdir -p "$DOG/tasks" "$DOG/sub"
git -C "$DOG" init -q
printf 'TASKPUMP_TASKS_DIR=tasks\n' >| "$DOG/taskpump.conf"
cp -R "$TP_ROOT/lib" "$DOG/lib"
mkdir -p "$DOG/libexec"
cp "$TASK" "$DOG/libexec/tp-task"
chmod +x "$DOG/libexec/tp-task"
mk "$DOG/tasks" T3

got=$( cd "$DOG/sub" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 \
        TASKPUMP_TASK_NOCOMMIT=1 "$DOG/libexec/tp-task" resolve --tasks-dir )
[[ "$got" == "$DOG/tasks" ]] \
  && pass "a standalone install's own conf still anchors (dogfood unchanged)" \
  || fail "dogfood resolution got '$got', expected '$DOG/tasks'"

echo "--- #6: the submodule flavor resolves to the superproject ---"

# The F90.4 shape: TaskPump vendored as a git SUBMODULE. From inside it, the
# submodule root is $PWD's worktree root — so both the discovery walk and the
# cwd anchor must look through to the superproject.
TPSRC="$TMP/tp-src"
mkdir -p "$TPSRC/tasks"
git -C "$TPSRC" init -q
printf 'TASKPUMP_TASKS_DIR=tasks\nTASKPUMP_PHASE_SIGIL=G\n' >| "$TPSRC/taskpump.conf"
cp -R "$TP_ROOT/lib" "$TPSRC/lib"
mkdir -p "$TPSRC/libexec"
cp "$TASK" "$TPSRC/libexec/tp-task"
mk "$TPSRC/tasks" G1
git -C "$TPSRC" -c user.name=t -c user.email=t@e add -A
git -C "$TPSRC" -c user.name=t -c user.email=t@e commit -qm seed

C3="$TMP/consumer3"
mkdir -p "$C3/tasks"
git -C "$C3" init -q
printf 'TASKPUMP_TASKS_DIR=tasks\n' >| "$C3/taskpump.conf"
mk "$C3/tasks" T1
git -C "$C3" -c user.name=t -c user.email=t@e add -A
git -C "$C3" -c user.name=t -c user.email=t@e commit -qm seed
if git -C "$C3" -c protocol.file.allow=always submodule add -q "$TPSRC" taskpump 2>/dev/null; then
  got=$( cd "$C3/taskpump" && env "${TP_ENV_UNSET[@]}" TASKPUMP_NO_CONF=0 \
          TASKPUMP_TASK_NOCOMMIT=1 "$TASK" resolve --tasks-dir )
  [[ "$got" == "$C3/tasks" ]] \
    && pass "inside the submodule, resolution reaches the superproject's ledger" \
    || fail "submodule resolution got '$got', expected '$C3/tasks'"
else
  printf 'SKIP: git refuses file-protocol submodules here; submodule flavor not exercised\n'
fi

# ══ Issue #45 — one pin, one workspace, both tools ═══════════════════════════
echo "--- #45: TASKPUMP_WORKSPACE_ROOT pins the CLI's ledger, not just the pump's ---"

# The G4.4 walkthrough shape (PR #39): the workspace is pinned by env because
# $PWD proves nothing — a container, a CI step, an operator standing in ~.
# `tp pump --dry-run` planned the pinned consumer's frontier; `tp task ready
# --count` in the SAME shell answered 0, `via install-root` — the install's own
# ledger. Nothing was corrupted, but 0 is the answer a human reads as "drained".
PIN="$TMP/pinned-consumer"
mkdir -p "$PIN/tasks"
git -C "$PIN" init -q
mk "$PIN/tasks" T1
mk "$PIN/tasks" T2
OUTSIDE="$TMP/elsewhere"; mkdir -p "$OUTSIDE"

pinned() {  # pinned <args...> — tp-task from OUTSIDE the pin, pin the only clue
  ( cd "$OUTSIDE" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
      TASKPUMP_WORKSPACE_ROOT="$PIN" "$TASK" "$@" 2>&1 )
}

got=$(pinned resolve --tasks-dir)
[[ "$got" == "$PIN/tasks" ]] \
  && pass "should resolve the ledger inside the pinned workspace when the pin is set and \$PWD is outside every repo" \
  || fail "pinned resolve --tasks-dir got '$got', expected '$PIN/tasks'"

got=$(pinned resolve --code-repo)
[[ "$got" == "$PIN" ]] \
  && pass "should point code_repo at the pinned workspace when the pin decides the workspace" \
  || fail "pinned resolve --code-repo got '$got', expected '$PIN'"

got=$(pinned resolve --all | awk '/^via/{print $2}')
[[ "$got" == "workspace-pin" ]] \
  && pass "should name the pin as the rung that decided when resolve --all prints via" \
  || fail "via under the pin reads '$got', expected workspace-pin"

got=$(pinned ready --count)
[[ "$got" == "2" ]] \
  && pass "should count the pinned workspace's open tasks when ready --count runs from outside it" \
  || fail "ready --count under the pin got '$got', expected 2"

# The asymmetry itself: two tools, one shell, one pin — one answer. Compared
# against the CLI's own count rather than a literal, so the assertion is the
# two-tool comparison its name promises: a literal passes on an unfixed CLI.
cli_count=$(pinned ready --count)
out=$( cd "$OUTSIDE" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        HOME="$CFGHOME" TASKPUMP_TASK="$TASK" TASKPUMP_WORKSPACE_ROOT="$PIN" \
        "$PUMP" --no-health-gate --no-usage-gate --no-disk-gate \
        --phases T1..T2 --dry-run 2>&1 )
[[ "$cli_count" == "2" ]] && have "$out" "open tasks in range: $cli_count" \
  && pass "should agree with the pump's plan when both tools read the same pin in one shell" \
  || fail "the pump's plan and the CLI disagree under one pin (CLI said '$cli_count'):\n$out"

# The cross-agent state lock is created in the git root of the RESOLVED ledger,
# so two agents on one ledger must resolve one tasks dir or they derive two
# lockfiles and stop excluding each other. The tasks dir is the input the lock
# path is computed from; asserting it is stronger than asserting the path.
inside=$( cd "$PIN" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
            "$TASK" resolve --tasks-dir )
[[ "$inside" == "$(pinned resolve --tasks-dir)" ]] \
  && pass "should resolve one ledger path when one agent pins the workspace and another stands in it" \
  || fail "pinned resolution and cwd resolution disagree ('$(pinned resolve --tasks-dir)' vs '$inside') — two agents on one ledger would take different locks"

# The mutating-verb guard refuses the install-root FALLBACK, not a pin: naming
# the workspace is the caller saying where the work lives, the same exemption
# an explicit tasks dir already gets.
out=$(pinned claim T1 --branch feat/t1); rc=$?
[[ $rc -eq 0 ]] \
  && pass "should let a claim through when the pin names the workspace it lands in" \
  || fail "claim under the pin was refused (rc=$rc):\n$out"
grep -q 'status: in_progress' "$PIN/tasks/T1.md" \
  && pass "should write the claim into the pinned ledger when the workspace is pinned" \
  || fail "the claim never reached $PIN/tasks/T1.md"

# The pin says which WORKSPACE, not which ledger: an explicitly named tasks dir
# is more specific and still wins, and via still names the rung that decided.
got=$( cd "$OUTSIDE" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        TASKPUMP_WORKSPACE_ROOT="$PIN" TASKPUMP_TASKS_DIR="$C1/planning/tasks" \
        "$TASK" resolve --tasks-dir )
[[ "$got" == "$C1/planning/tasks" ]] \
  && pass "should keep an explicit tasks dir winning when a workspace pin is set alongside it" \
  || fail "an explicit tasks dir lost to the pin: got '$got'"
got=$( cd "$OUTSIDE" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        TASKPUMP_WORKSPACE_ROOT="$PIN" TASKPUMP_TASKS_DIR="$C1/planning/tasks" \
        "$TASK" resolve --all | awk '/^via/{print $2}' )
[[ "$got" == "env" ]] \
  && pass "should attribute the ledger to env when an explicit tasks dir outranks the pin" \
  || fail "via with both a pin and an explicit tasks dir reads '$got', expected env"

# A pin naming nothing must be loud. Falling back to the install root there is
# the silent wrong ledger the pin was set to prevent.
out=$( cd "$OUTSIDE" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
        TASKPUMP_WORKSPACE_ROOT="$TMP/no-such-workspace" "$TASK" ready 2>&1 ); rc=$?
[[ $rc -ne 0 ]] \
  && pass "should refuse instead of falling back when the pin names a missing directory" \
  || fail "a pin naming a missing directory was ignored (rc=$rc):\n$out"
have "$out" 'TASKPUMP_WORKSPACE_ROOT' \
  && pass "should name the pin in the refusal when the pinned directory is missing" \
  || fail "the refusal does not name TASKPUMP_WORKSPACE_ROOT:\n$out"

echo "--- #45: the pin outranks a \$PWD that carries its own ledger ---"

# The precedence this change actually creates, and the riskiest shape in it:
# the pin names one workspace while $PWD stands in a WORKTREE of another that
# carries a ledger of its own. Before the fix the cwd probe answered and a
# claim landed in the worktree's ledger; now the pin answers and it lands in
# the pinned one. That is the intended direction — the caller naming the
# workspace outranks a directory answering for itself — but it is a live
# behaviour change in a repo whose agents each run in their own worktree, so
# it is asserted here rather than left to be discovered.
PINP="$TMP/pin-primary"
mkdir -p "$PINP/tasks"
git -C "$PINP" init -q
mk "$PINP/tasks" T1
git -C "$PINP" -c user.name=t -c user.email=t@e add -A
git -C "$PINP" -c user.name=t -c user.email=t@e commit -qm seed
PINW="$TMP/pin-worktree"
git -C "$PINP" -c user.name=t -c user.email=t@e worktree add -q -b feat/pin "$PINW"
# The worktree's own ledger, deliberately divergent: one extra open task, so a
# count alone tells which of the two answered.
mk "$PINW/tasks" T2

in_wt() {  # in_wt <args...> — pinned at PINP while standing in PINP's worktree
  ( cd "$PINW" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
      TASKPUMP_WORKSPACE_ROOT="$PINP" "$TASK" "$@" 2>&1 )
}

got=$(in_wt resolve --tasks-dir)
[[ "$got" == "$PINP/tasks" ]] \
  && pass "should resolve the pinned workspace's ledger when the pin names one workspace and \$PWD stands in another that carries its own ledger" \
  || fail "pin vs cwd resolved '$got', expected '$PINP/tasks'"

got=$(in_wt resolve --all | awk '/^via/{print $2}')
[[ "$got" == "workspace-pin" ]] \
  && pass "should name workspace-pin as the deciding rung when the pin outranks a cwd worktree carrying its own ledger" \
  || fail "via with a pin and a ledger-carrying cwd reads '$got', expected workspace-pin"

got=$(in_wt ready --count)
[[ "$got" == "1" ]] \
  && pass "should count the pinned workspace's frontier when \$PWD's own ledger holds a different one" \
  || fail "ready --count with a pin and a ledger-carrying cwd got '$got', expected 1 (the worktree's own ledger holds 2)"

out=$(in_wt claim T1 --branch feat/pin); rc=$?
[[ $rc -eq 0 ]] && grep -q 'status: in_progress' "$PINP/tasks/T1.md" \
  && pass "should land a claim in the pinned workspace's ledger when the caller stands in a worktree with its own" \
  || fail "the claim did not reach $PINP/tasks/T1.md (rc=$rc):\n$out"

# `--help` is where an operator decides whether keeping the pin exported is
# safe, so the sentence promising the worktree guarantee must carry the one
# condition that revokes it. Stated unqualified, it is a confident wrong reason
# printed three lines under the rung that breaks it. Matched by sentence rather
# than by wording: the guarantee may be phrased any way, it may not be phrased
# without the pin.
help_sentence=$( env "${TP_ENV_UNSET[@]}" "$TASK" --help 2>&1 | tr '\n' ' ' \
                 | sed 's/\. /.\n/g' | grep -F "out of the primary checkout's ledger" | head -1 )
[[ -n "$help_sentence" ]] && have "$help_sentence" 'pin' \
  && pass "should qualify the worktree-safety guarantee with the pin that revokes it when --help states it" \
  || fail "--help promises the worktree guarantee without naming the pin that overrides it: '$help_sentence'"

echo "--- #45: an explicit tasks dir strands the pin, code_repo included ---"

# The pin moves the workspace only when it is the rung that DECIDES it. The
# workspace root feeds TASKPUMP_CODE_REPO as well as the tasks dir, so a pin
# that moved it under an explicit tasks dir would redirect the heartbeat's
# productivity meter while `via` still read `env` — the losing rung acting
# anyway, invisibly. This is the pump-launched agent's exact environment:
# tp-pump exports the pinned TASKPUMP_TASKS_DIR, the local runner cds into the
# agent's worktree carrying the operator's pin whole, and neither sets
# TASKPUMP_CODE_REPO.
HBP="$TMP/hb-primary"
mkdir -p "$HBP/tasks"
git -C "$HBP" init -q
mk "$HBP/tasks" T1
: >| "$HBP/seed"
git -C "$HBP" -c user.name=t -c user.email=t@e add -A
git -C "$HBP" -c user.name=t -c user.email=t@e commit -qm seed
HBW="$TMP/hb-worktree"
git -C "$HBP" -c user.name=t -c user.email=t@e worktree add -q -b feat/hb "$HBW"

agent() {  # agent <args...> — what a pump-launched local-runner agent sees
  ( cd "$HBW" && env "${TP_ENV_UNSET[@]}" TASKPUMP_TASK_NOCOMMIT=1 \
      TASKPUMP_WORKSPACE_ROOT="$HBP" TASKPUMP_TASKS_DIR="$HBP/tasks" \
      "$TASK" "$@" 2>&1 )
}

got=$(agent resolve --code-repo)
[[ "$got" == "$HBW" ]] \
  && pass "should leave code_repo on the caller's own worktree when an explicit tasks dir outranks the pin" \
  || fail "code_repo under a stranded pin got '$got', expected '$HBW' — the pin moved a derivation on a rung it lost"

# The consequence, end to end, because "code_repo moved" reads as cosmetic
# until you watch it verdict a working agent. Three of these in a row and
# scrub writes status: stuck on a task whose agent is committing normally.
agent claim T1 --branch feat/hb >/dev/null
agent heartbeat T1 --start >/dev/null
: >| "$HBW/agent-work.txt"
git -C "$HBW" -c user.name=a -c user.email=a@e add -A
git -C "$HBW" -c user.name=a -c user.email=a@e commit -qm "agent work"
out=$(agent heartbeat T1 --end)
have "$out" 'productive=1' && have "$out" 'failures=0' \
  && pass "should credit an agent's own worktree commits when a pinned pump launched it with an explicit tasks dir" \
  || fail "heartbeat scored a committing agent unproductive under a stranded pin:\n$out"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
