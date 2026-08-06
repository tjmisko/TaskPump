#!/usr/bin/env bash
# test-golden-plan.sh — the prime-directive test.
#
# TaskPump is being generalized out of Arachne, and the one promise that
# generalization must keep is: with NO taskpump.conf present, an Arachne-shaped
# project gets byte-identical behavior. Every knob, template, gate and hook this
# repo grows has to default back to exactly what the pump did before it existed.
#
# So this suite freezes the pump's three rendered surfaces — the tick plan, the
# kickoff brief, and the stalled-claim resume note — against golden files
# captured before any generalization commit. A refactor that changes one byte of
# what an operator or an agent actually reads fails here.
#
# The fixture is a throwaway git repo shaped like Arachne: an `ops/` ledger at
# ops/task-loop/tasks, an ops-side brief template at
# ops/task-loop/briefs/_phase-drain-template.md (a verbatim copy of Arachne's,
# checked in beside this script), phase branches named `feat/fNN`, and worktrees
# under .worktrees/. The TaskPump tools are COPIED into it rather than symlinked,
# because both TP_ROOT and the pump's REPO_ROOT are derived through
# `readlink -f` — a symlink would resolve straight back out of the fixture.
#
# Everything that legitimately varies between runs is normalized before the
# comparison: the fixture's temp path, and git object ids.
#
# Re-record after an INTENTIONAL change (and read the diff before committing):
#   UPDATE_GOLDEN=1 ./tests/test-golden-plan.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
GOLDEN="$SCRIPT_DIR/golden"
UPDATE="${UPDATE_GOLDEN:-0}"

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/project"
BIN="$TMP/bin"; mkdir -p "$BIN"

# ── Stubs ─────────────────────────────────────────────────────────────────────
# Nothing here may touch the host: no real docker, no real usage meter, no real
# free-space probe. Each answers from an environment variable so a single test
# can drive it.
cat >| "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "ps" ]]; then printf '%s\n' ${STUB_LIVE:-}; exit 0; fi
exit 0
EOF
cat >| "$BIN/claude-usage" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--gate" ]]; then
  [[ "${STUB_GATE_RC:-0}" -eq 10 ]] && { echo "claude-usage: 97% of the 5-hour window used (ceiling 95%)" >&2; exit 10; }
  exit 0
fi
exit 0
EOF
cat >| "$BIN/disk-watchdog" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--gate" ]]; then
  [[ "${STUB_DISK_RC:-0}" -eq 10 ]] && { echo "/ free=3GB < 10GiB (disk gate)" >&2; exit 10; }
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/docker" "$BIN/claude-usage" "$BIN/disk-watchdog"

# ── Fixture ledger ────────────────────────────────────────────────────────────
TASKS="$REPO/ops/task-loop/tasks"
BRIEFS="$REPO/ops/task-loop/briefs"
mkdir -p "$TASKS" "$BRIEFS"
cp "$GOLDEN/consumer-brief-template.md" "$BRIEFS/_phase-drain-template.md"

mk() {  # mk <id> <status> [blockers_csv] [claimed_by]
  local id=$1 status=$2 blockers=${3:-} claimed=${4:-null}
  local by="[]"; [[ -n "$blockers" ]] && by="[$(printf '%s' "$blockers" | sed 's/,/, /g')]"
  [[ "$claimed" != "null" ]] && claimed="\"$claimed\""
  cat >| "$TASKS/$id.md" <<EOF
---
id: $id
phase: ${id%%.*}
title: fixture $id
status: $status
claimed_by: $claimed
claimed_at: null
turn_budget_remaining: null
consecutive_failed_iterations: 0
blockers: $by
completed_by_commits: []
files: []
goal: drain $id
---
# $id
EOF
}

# A contiguous range with one cross-phase edge (F57 waits on F55.1), plus a
# separate phase carrying a stalled orphan claim.
mk F55.0 open
mk F55.1 open F55.0
mk F56.0 open
mk F57.0 open F55.1
mk F79.4 in_progress "" feat/f79
mk F79.5 open F79.4

# ── Fixture git repo ──────────────────────────────────────────────────────────
git init -q -b main "$REPO"
git -C "$REPO" config user.name  'taskpump-fixture'
git -C "$REPO" config user.email 'fixture@taskpump.test'
printf 'fixture\n' >| "$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm 'seed'
git -C "$REPO" switch -qc feat/f79
printf 'one\n' >| "$REPO/a.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm 'feat(f79): the ratchet baseline'
printf 'two\n' >| "$REPO/b.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm 'feat(f79): sweep the mechanical lints'
git -C "$REPO" switch -q main
git -C "$REPO" worktree add -q "$REPO/.worktrees/feat/f79" feat/f79
printf 'wip\n' >| "$REPO/.worktrees/feat/f79/c.txt"

# The install, copied in so REPO_ROOT lands inside the fixture.
for d in lib libexec gates templates hooks runners; do
  [[ -d "$TP_ROOT/$d" ]] && cp -r "$TP_ROOT/$d" "$REPO/$d"
done
PUMP="$REPO/libexec/tp-pump"

# ── Invocation ────────────────────────────────────────────────────────────────
# No taskpump.conf anywhere: the whole point is what the tools do on their own.
# Everything set here is a test seam that already existed — a fixture ledger, a
# fixture worktrees base, and the three stubs.
pump() {
  ( cd "$REPO" && \
    ARACHNE_PUMP_OPS_DIR="$REPO/ops" \
    ARACHNE_PUMP_TASKS_DIR="$TASKS" \
    ARACHNE_TASKS_DIR="$TASKS" \
    ARACHNE_TASK_NOCOMMIT=1 \
    ARACHNE_USAGE="$BIN/claude-usage" \
    ARACHNE_DISK_WATCHDOG="$BIN/disk-watchdog" \
    ARACHNE_PUMP_WORKTREES_DIR="$REPO/.worktrees" \
    ARACHNE_TOKEN_GATE=0 \
    ARACHNE_PUMP_NO_GH=1 \
    DOCKER="$BIN/docker" \
    "$PUMP" --no-health-gate "$@" 2>&1 )
}

# normalize — strip the two things that legitimately differ per run.
normalize() {
  sed -e "s#$TMP#<TMP>#g" -e 's/\b[0-9a-f]\{7,40\}\b/<sha>/g'
}

check() {  # check <golden-name> <label> — stdin is the captured output
  local name="$1" label="$2"
  local file="$GOLDEN/$name"
  local got; got="$(normalize)"
  if [[ "$UPDATE" == "1" ]]; then
    printf '%s\n' "$got" >| "$file"
    printf 'RECORDED: %s\n' "$name"
    return 0
  fi
  if [[ ! -f "$file" ]]; then
    fail "$label: no golden file at $file (run UPDATE_GOLDEN=1 $0)"
    return 1
  fi
  if [[ "$got" == "$(cat "$file")" ]]; then
    pass "$label"
  else
    fail "$label — output drifted from $name:"
    diff -u "$file" <(printf '%s\n' "$got") >&2 || true
  fi
}

# capture_check <golden-name> <label> <pump args...> — run the pump, then compare
# in THIS shell. A pipeline would put check() in a subshell and lose the tally.
capture_check() {
  local name="$1" label="$2"; shift 2
  local out; out="$(pump "$@")"
  check "$name" "$label" <<<"$out"
}

echo "--- Plan: the eligible frontier, with a cross-phase gate ---"
capture_check plan-frontier.txt "plan: F55..F57 frontier" --dry-run --phases F55..F57

echo "--- Plan: a live container is RUNNING, never re-launched ---"
STUB_LIVE="arachne-agent-feat-f55" \
  capture_check plan-running.txt "plan: live container joins as RUNNING" --dry-run --phases F55..F57

echo "--- Plan: the usage gate's pause reason reaches the plan header ---"
STUB_GATE_RC=10 \
  capture_check plan-paused.txt "plan: usage gate pauses feeding" --dry-run --phases F55..F57

echo "--- Plan: a stalled orphan claim surfaces as RESUME ---"
capture_check plan-resume.txt "plan: stalled claim is resumable" --dry-run --phases F79

echo "--- Brief: rendered from the consumer's ops-side template ---"
capture_check brief-f55.txt "brief: F55 (no cross-phase dependencies)" --render-brief F55
capture_check brief-f57.txt "brief: F57 (cross-phase dependency block)" --render-brief F57

echo "--- Resume note: the preamble a stalled phase is relaunched with ---"
capture_check resume-note-f79.txt "resume note: F79" --render-resume-note F79

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ "$FAIL" -eq 0 ]]
