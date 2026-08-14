#!/usr/bin/env bash
# test-pump-workspace-root.sh — the pump's context must be the CALLER's, not
# its own (issues #32, #31). Shared root cause: an anchor derived from the
# pump's own location — the install dir for REPO_ROOT, the resolved $0 plus a
# fresh $HOME for the systemd re-exec — silently substituting for the context
# of the invocation. Right-looking behavior against the wrong root.
#
#   #32  REPO_ROOT was $SCRIPT_DIR/.., so for a consumer that vendors TaskPump
#        (submodule / subtree / nested copy) every workspace surface — the
#        default image build, worktrees, branches, state files, every
#        `git -C` — targeted the vendored taskpump/ instead of the workspace;
#   #31  tp pump --detach's systemd-run path re-execed forwarding only
#        GITHUB_TOKEN: it dropped TASKPUMP_CONFIG, the working directory, and
#        every TASKPUMP_* / MAX_TURNS / AGENT_MODEL override, so the detached
#        run quietly diverged from the invocation just watched dry-running.
#
# Run: ./tests/test-pump-workspace-root.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PUMP="$TP_ROOT/libexec/tp-pump"

# Hermeticity: no ambient conf from the repo this suite runs in. Cases that
# need a conf name one explicitly or opt back in per-invocation.
export TASKPUMP_NO_CONF=1
export TASKPUMP_NOTIFY_CMD=true

# Both spellings of every key that could pre-answer a resolution question are
# cleared, and TP_ENV_UNSET re-establishes the clean slate per subshell.
TP_CONFIG_SUFFIXES=(
  TASKS_DIR TASK_OUT CODE_REPO LEDGER_PROBE LEDGER_REPO TASKS_SUBDIR
  PUMP_TASKS_DIR PUMP_OPS_DIR SUBMODULE_PROBE ID_PATTERN PHASE_SIGIL
  BRIEF_TEMPLATE PHASE_BRIEF_TEMPLATE RESUME_TEMPLATE TASK_NOCOMMIT CONFIG
  WORKSPACE_ROOT WORKTREES_DIR PUMP_WORKTREES_DIR STATE_DIR IMAGE IMAGE_BUILD
  RUNNER TASK JOBS MAX_TURNS AGENT_MODEL AGENT_PREFIX AGENT_HOME GATES
  PRE_TICK_HOOKS PUMP_PROG_NAME
)
TP_ENV_UNSET=(-u MAX_TURNS -u AGENT_MODEL -u JOBS -u GITHUB_TOKEN -u DOCKER)
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

# ══ #32 — a vendored-install pump drives the CONSUMER's workspace ═════════════
echo "--- #32: a real --once from a vendored install targets the consumer, not itself ---"

# The F90.5 canary shape: a consumer repository that vendors a full TaskPump
# checkout in a subdirectory, and runs the VENDORED copy of the tools. The
# vendored copy is its own committed git repository so that "never writes a
# byte under the vendored copy" is a git-status assertion, exactly as the
# issue's acceptance phrases it.
CONS="$TMP/consumer"
mkdir -p "$CONS/tasks"
git -C "$TMP" init -qb main consumer
mk "$CONS/tasks" T1
( cd "$CONS" \
  && git -c user.name=t -c user.email=t@e add -A >/dev/null \
  && git -c user.name=t -c user.email=t@e commit -qm seed )

VEND="$CONS/taskpump"
mkdir -p "$VEND"
cp -R "$TP_ROOT/lib" "$TP_ROOT/libexec" "$TP_ROOT/gates" "$TP_ROOT/runners" \
      "$TP_ROOT/templates" "$TP_ROOT/hooks" "$VEND/"
git -C "$VEND" init -qb main
( cd "$VEND" \
  && git -c user.name=t -c user.email=t@e add -A >/dev/null \
  && git -c user.name=t -c user.email=t@e commit -qm vendored )
VHEAD_BEFORE="$(git -C "$VEND" rev-parse HEAD)"
VPUMP="$VEND/libexec/tp-pump"

# Stubs, modeled on test-config-resolution.sh's probe_tick: a recording docker
# (the default image build is `docker build -t <img> "$REPO_ROOT"` — the
# literal command that died on the canary), a recording runner with no `list`
# verb (exit 2, the documented v1 answer), a recording pre-tick hook (hooks
# receive the workspace root as $1), and a feed-ok gate so no host state leaks.
BIN="$TMP/bin"; mkdir -p "$BIN"
DOCKERLOG="$TMP/docker.log"; RUNLOG="$TMP/runner.log"; HOOKLOG="$TMP/hook.log"
cat >| "$BIN/docker" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$PWD" "\$*" >> "$DOCKERLOG"
exit 0
EOF
cat >| "$BIN/runner" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  list) exit 2 ;;
  launch)
    printf 'TP_REPO_ROOT=%s\n'  "\${TP_REPO_ROOT:-}"  >> "$RUNLOG"
    printf 'TP_WORKSPACE=%s\n'  "\${TP_WORKSPACE:-}"  >> "$RUNLOG"
    printf 'TP_TASKS_DIR=%s\n'  "\${TP_TASKS_DIR:-}"  >> "$RUNLOG"
    echo stub-container-id
    exit 0 ;;
esac
exit 0
EOF
cat >| "$BIN/hook-rec" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${1:-}" >> "$HOOKLOG"
exit 0
EOF
cat >| "$BIN/gate-ok" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/docker" "$BIN/runner" "$BIN/hook-rec" "$BIN/gate-ok"

AGENT_HOME="$TMP/agent-home"; mkdir -p "$AGENT_HOME"
# An empty HOME so the claude gates of the dry-run invocations below skip
# identically on any host (the test-config-resolution.sh pattern).
NOHOME="$TMP/nohome"; mkdir -p "$NOHOME"
# The knobs every dry-run below shares: stubbed container runtime and runner
# (no host docker daemon in a hermetic suite), no host-state gates.
DRY_STUBS=(DOCKER="$BIN/docker" TASKPUMP_RUNNER="$BIN/runner" HOME="$NOHOME")
DRY_FLAGS=(--no-health-gate --no-usage-gate --no-disk-gate)

# A REAL --once tick (not --dry-run: a dry-run touches none of the REPO_ROOT
# surfaces, which is exactly how 16 green suites missed this). Zero conf: the
# workspace anchor is the caller's worktree root.
out=$( cd "$CONS" && env "${TP_ENV_UNSET[@]}" \
        TASKPUMP_TASK_NOCOMMIT=1 \
        TASKPUMP_AGENT_HOME="$AGENT_HOME" \
        TASKPUMP_IMAGE=probe-img \
        TASKPUMP_RUNNER="$BIN/runner" \
        TASKPUMP_GATES="$BIN/gate-ok" \
        TASKPUMP_PRE_TICK_HOOKS="$BIN/hook-rec" \
        TASKPUMP_PUMP_OPS_DIR="$TMP/noops" \
        TASKPUMP_STAGGER=0 \
        DOCKER="$BIN/docker" \
        GITHUB_TOKEN=stub-token \
        "$VPUMP" --phases T1 --once 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && pass "vendored-install pump --once exits 0" \
  || fail "vendored-install pump --once rc=$rc:\n$out"

# The default image build ran against the CONSUMER root — the canary's failure
# was `docker build ... <vendored taskpump/>` finding no Dockerfile.
if grep -qF "$CONS|build -t probe-img $CONS" "$DOCKERLOG" 2>/dev/null; then
  pass "the default image build targets the consumer workspace root"
else
  fail "image build did not target the consumer root: $(cat "$DOCKERLOG" 2>/dev/null)"
fi
grep -qF "$VEND" "$DOCKERLOG" 2>/dev/null \
  && fail "the image build touched the vendored copy: $(cat "$DOCKERLOG")" \
  || pass "the image build never targets the vendored copy"

# The agent worktree and its branch live in the consumer's repository.
[[ -d "$CONS/.worktrees/feat/t1" ]] \
  && pass "the agent worktree is under the consumer root" \
  || fail "no worktree at $CONS/.worktrees/feat/t1:\n$out"
git -C "$CONS" rev-parse --verify refs/heads/feat/t1 >/dev/null 2>&1 \
  && pass "the phase branch was cut in the consumer's object store" \
  || fail "no feat/t1 branch in the consumer repo"

# The runner hand-off names the consumer's roots.
grep -qxF "TP_REPO_ROOT=$CONS" "$RUNLOG" 2>/dev/null \
  && pass "the runner receives the consumer root as TP_REPO_ROOT" \
  || fail "runner env wrong: $(cat "$RUNLOG" 2>/dev/null)"
grep -qxF "TP_WORKSPACE=$CONS/.worktrees/feat/t1" "$RUNLOG" 2>/dev/null \
  && pass "the runner receives a consumer-rooted worktree" \
  || fail "runner workspace wrong: $(cat "$RUNLOG" 2>/dev/null)"
grep -qxF "TP_TASKS_DIR=$CONS/tasks" "$RUNLOG" 2>/dev/null \
  && pass "the runner receives the consumer's tasks dir" \
  || fail "runner tasks dir wrong: $(cat "$RUNLOG" 2>/dev/null)"

# Pre-tick hooks operate on the workspace, not the install.
grep -qxF "$CONS" "$HOOKLOG" 2>/dev/null \
  && pass "pre-tick hooks receive the consumer root" \
  || fail "hook arg wrong: $(cat "$HOOKLOG" 2>/dev/null)"

# Run state landed at the consumer root (the STATE_DIR default).
[[ -f "$CONS/.taskpump-pump.state" ]] \
  && pass "pump state lands at the consumer root" \
  || fail "no state file at the consumer root"

# The issue's acceptance line: the vendored copy stays byte-clean — no state
# files, no worktrees, no branches, no commits, nothing untracked.
vstatus="$(git -C "$VEND" status --porcelain 2>&1)"
[[ -z "$vstatus" ]] \
  && pass "the vendored copy is byte-clean after the tick (git status empty)" \
  || fail "the run wrote into the vendored copy:\n$vstatus"
[[ "$(git -C "$VEND" rev-parse HEAD)" == "$VHEAD_BEFORE" ]] \
  && pass "the vendored HEAD is unchanged" \
  || fail "the vendored HEAD moved"
vbranches="$(git -C "$VEND" branch --list 'feat/*' 2>/dev/null)"
[[ -z "$vbranches" ]] \
  && pass "no phase branch was cut in the vendored object store" \
  || fail "phase branches in the vendored repo:\n$vbranches"
[[ ! -e "$VEND/.worktrees" ]] \
  && pass "no worktrees dir appeared under the vendored copy" \
  || fail ".worktrees appeared under the vendored copy"

# ══ #32 — the TASKPUMP_WORKSPACE_ROOT pin ═════════════════════════════════════
echo "--- #32: TASKPUMP_WORKSPACE_ROOT pins the workspace explicitly ---"

# Without a pin, from inside the vendored copy (no conf, no tasks/ there) the
# fallback is the install root — whose missing ledger must refuse LOUDLY, never
# plan against something plausible.
out=$( cd "$VEND" && env "${TP_ENV_UNSET[@]}" "${DRY_STUBS[@]}" \
        TASKPUMP_TASK_NOCOMMIT=1 \
        "$VPUMP" "${DRY_FLAGS[@]}" --phases T1 --dry-run 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && have "$out" 'tasks directory does not exist' \
  && pass "unpinned from inside the vendored copy: a loud refusal, not a wrong plan" \
  || fail "expected the missing-ledger refusal (rc=$rc):\n$out"

# Pinned, the same invocation drives the consumer — from inside the vendored
# copy, or from a directory with no relationship to the workspace at all.
out=$( cd "$VEND" && env "${TP_ENV_UNSET[@]}" "${DRY_STUBS[@]}" \
        TASKPUMP_TASK_NOCOMMIT=1 TASKPUMP_WORKSPACE_ROOT="$CONS" \
        "$VPUMP" "${DRY_FLAGS[@]}" --phases T1 --dry-run 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && have "$out" 'open tasks in range: 1' \
  && pass "the pin from inside the vendored copy plans against the consumer" \
  || fail "pinned dry-run from the vendored copy failed (rc=$rc):\n$out"

ELSEWHERE="$TMP/elsewhere"
mkdir -p "$ELSEWHERE"
git -C "$TMP" init -qb main elsewhere
out=$( cd "$ELSEWHERE" && env "${TP_ENV_UNSET[@]}" "${DRY_STUBS[@]}" \
        TASKPUMP_TASK_NOCOMMIT=1 TASKPUMP_WORKSPACE_ROOT="$CONS" \
        "$VPUMP" "${DRY_FLAGS[@]}" --phases T1 --dry-run 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && have "$out" 'open tasks in range: 1' \
  && pass "the pin wins over an unrelated \$PWD worktree (ledger CLI included)" \
  || fail "pinned dry-run from an unrelated repo failed (rc=$rc):\n$out"

# A pin naming a missing directory is a loud error naming the key (the same
# rule TASKPUMP_CONFIG follows) — never a silent fallback.
out=$( cd "$CONS" && env "${TP_ENV_UNSET[@]}" "${DRY_STUBS[@]}" \
        TASKPUMP_TASK_NOCOMMIT=1 TASKPUMP_WORKSPACE_ROOT="$TMP/does-not-exist" \
        "$VPUMP" "${DRY_FLAGS[@]}" --phases T1 --dry-run 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && have "$out" 'TASKPUMP_WORKSPACE_ROOT' \
  && pass "a pin naming a missing directory refuses loudly, naming the key" \
  || fail "missing-dir pin was not refused (rc=$rc):\n$out"

# A conf-relative pin anchors to the conf's workspace (the issue-#1 rule).
PINCONF="$TMP/pin-consumer"
mkdir -p "$PINCONF/tasks" "$PINCONF/sub"
git -C "$TMP" init -qb main pin-consumer
printf 'TASKPUMP_WORKSPACE_ROOT=.\n' >| "$PINCONF/taskpump.conf"
mk "$PINCONF/tasks" T3
out=$( cd "$PINCONF/sub" && env "${TP_ENV_UNSET[@]}" "${DRY_STUBS[@]}" \
        TASKPUMP_NO_CONF=0 TASKPUMP_TASK_NOCOMMIT=1 \
        "$PUMP" "${DRY_FLAGS[@]}" --phases T3 --dry-run 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && have "$out" 'open tasks in range: 1' \
  && pass "a conf-relative pin anchors to the conf's own workspace" \
  || fail "conf-relative pin failed from a subdir (rc=$rc):\n$out"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
