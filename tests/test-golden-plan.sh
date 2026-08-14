#!/usr/bin/env bash
# test-golden-plan.sh — the prime-directive test.
#
# TaskPump is being generalized out of Arachne, and the one promise that
# generalization must keep is: with the REFERENCE CONF (examples/arachne.conf)
# loaded, an Arachne-shaped project gets byte-identical behavior. That promise
# used to read "with NO taskpump.conf present" — every knob defaulted back to
# what the pump did before extraction — but the v0.1.0 default flips retire the
# Arachne-shaped defaults deliberately, so the equivalence claim is re-anchored
# (G1.2) to the explicit pins the reference consumer actually carries. Flipping
# a shipped default must never be able to silently break this suite; only
# editing the pins can.
#
# So this suite freezes the pump's three rendered surfaces — the tick plan, the
# kickoff brief, and the stalled-claim resume note — against golden files
# captured before any generalization commit. A refactor that changes one byte of
# what an operator or an agent actually reads fails here.
#
# The fixture is a throwaway git repo shaped like Arachne: an `ops/` ledger at
# ops/task-loop/tasks, an ops-side brief template at
# ops/task-loop/briefs/ holding both consumer-side templates (checked in beside
# this script), phase branches named `feat/fNN`, and worktrees
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

# Hermeticity: an AMBIENT conf discovered from whatever repo this suite happens
# to run from must never leak in — the only configuration allowed here is the
# reference pins file the fixture loads deliberately, via TASKPUMP_CONFIG, which
# outranks this switch. run-all.sh exports the same switch; this one covers
# standalone runs.
export TASKPUMP_NO_CONF=1

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
  # The real meter prefixes its own name; the pump strips that prefix before
  # showing the reason, so the stub has to speak the same way for the golden to
  # pin the stripping.
  [[ "${STUB_GATE_RC:-0}" -eq 10 ]] && { echo "arachne-usage: 97% of the 5-hour window used (ceiling 95%)" >&2; exit 10; }
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

# Fixture host credentials, for the claude-token-fresh gate. Without this pin
# the gate reads the HOST's ~/.claude/.credentials.json: on a dev machine it
# passes silently, on a credential-less host (CI) it prints its G3.5 skip line
# into the captured plan — the same golden green here and red in CI. The
# fixture token expires far beyond the pinned clock, so the gate passes
# silently EVERYWHERE, which is what the goldens were captured recording.
# expiresAt is milliseconds; TASKPUMP_NOW_S pins the clock the margin check
# subtracts from, so no wall clock can age this fixture into a pause.
CRED_FIXTURE="$TMP/credentials.json"
printf '{"claudeAiOauth":{"expiresAt":2000000000000}}\n' >| "$CRED_FIXTURE"

# ── Reference pins ────────────────────────────────────────────────────────────
# The flip census: every shipped default the v0.1.0 flips (G1.3–G1.7) change,
# by config-key suffix. examples/arachne.conf pins each one to its historical
# value; that file is the reference pin set (G1.1's audit), extended by G1.3
# with the ledger-lock name (LOCK_NAME, a key the flip introduced).
FLIP_CENSUS=(
  # G1.3 — state, log, and note filenames, plus the ledger-lock name
  PUMP_STATE_NAME PUMP_LOG POOL_CAP_FILE USAGE_RESET_FILE DISK_WATCHDOG_LOG
  HOOK_MARK_FILE AGENT_LOG_NAME BRIEF_OUT_NAME RESUME_NOTE_NAME GOAL_NOTE_NAME
  RO_PROBE_FILE MONITOR_NOTES_DIRNAME MONITOR_CACHE_BASE LOCK_NAME
  # G1.4 — identity strings
  COMMITTER_NAME COMMITTER_EMAIL PROG_NAME PUMP_PROG_NAME MONITOR_TASK_CLASS
  # G1.5 — runner defaults. ENTRYPOINT left the census with issue #5: the
  # historical /entrypoint-parallel.sh pin predated the pre-flight hook and
  # silently disabled it, so the reference consumer now runs the shipped
  # /entrypoint.sh default (its image bakes it per RUNNERS.md §4.0) and the
  # conf deliberately carries no pin.
  AGENT_PREFIX IMAGE
  # G1.6 — ledger shape
  LEDGER_PROBE ID_PATTERN PHASE_SIGIL TASK_CLI WORKSPACE_TASK_CLI
  # G1.7 — Rust and host-hardware defaults
  VERIFY_CMDS RECLAIM_CMD HEALTH_GATE
)
ARACHNE_CONF="$TP_ROOT/examples/arachne.conf"

# The pins file the fixture loads: the reference conf laid over a sentinel
# prelude. Every flip-census key is first set to an UNPINNED-* sentinel, then
# the conf's own assignment overwrites it — so the shipped default never
# participates. Delete a pin from arachne.conf and the sentinel shows through:
# the goldens diff where the pump reads the key, and the census check below
# goes red regardless.
PINS_CONF="$TMP/pins.conf"
{
  printf '# generated by %s — sentinel prelude, then the reference conf\n' "$(basename "$0")"
  for _key in "${FLIP_CENSUS[@]}"; do
    printf "TASKPUMP_%s=UNPINNED-%s\n" "$_key" "$_key"
  done
  cat "$ARACHNE_CONF"
} >| "$PINS_CONF"
unset _key

# ── Fixture ledger ────────────────────────────────────────────────────────────
TASKS="$REPO/ops/task-loop/tasks"
BRIEFS="$REPO/ops/task-loop/briefs"
mkdir -p "$TASKS" "$BRIEFS"
cp "$GOLDEN/consumer-brief-template.md" "$BRIEFS/_phase-drain-template.md"
# The resume note the same way. Both templates resolve consumer-side-first, so
# what this pins is the CONSUMER's wording, not whichever generic default
# TaskPump happens to ship — which is the point: the byte-identity promise is
# Arachne's to keep, in its own ledger, and the shipped default stays something
# a second consumer can actually use. These two files are also the migration:
# they are what Arachne drops into ops/task-loop/briefs/ to keep its prose.
cp "$GOLDEN/consumer-resume-template.md" "$BRIEFS/_resume-note-template.md"

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
# Every arachne-flavored value arrives through TASKPUMP_CONFIG — the pins file
# built above — never through a shipped default. The environment seams are the
# ones that already existed (a fixture ledger, a fixture worktrees base, the
# three stubs) and they outrank the conf, exactly as lib/config.sh documents:
# environment > taskpump.conf > baked defaults. TASKPUMP_JOBS is a seam too:
# since issue #8 arachne.conf keeps the shipped default of 4 (the historical
# drains widened per invocation with --jobs 6, never ambiently), which is also
# the pre-extraction cap the goldens were captured at; the env pin stays so
# this suite cannot drift if that decision is ever revisited.
# TASKPUMP_HEALTH_PROBE_CMD is a hermeticity seam, not a pin: the arachne.conf
# pin TASKPUMP_HEALTH_GATE=1 keeps net-health at the head of the pinned chain
# (G1.7 ships it off bare), and the inert probe keeps this host's real kernel
# journal out of the fixture — the gate consults `true` and always feeds.
pump() {
  ( cd "$REPO" && \
    TASKPUMP_CONFIG="$PINS_CONF" \
    TASKPUMP_JOBS=4 \
    ARACHNE_PUMP_OPS_DIR="$REPO/ops" \
    ARACHNE_PUMP_TASKS_DIR="$TASKS" \
    ARACHNE_TASKS_DIR="$TASKS" \
    ARACHNE_TASK_NOCOMMIT=1 \
    ARACHNE_USAGE="$BIN/claude-usage" \
    ARACHNE_DISK_WATCHDOG="$BIN/disk-watchdog" \
    ARACHNE_PUMP_WORKTREES_DIR="$REPO/.worktrees" \
    ARACHNE_TOKEN_GATE=0 \
    ARACHNE_PUMP_NO_GH=1 \
    TASKPUMP_HEALTH_PROBE_CMD=true \
    TASKPUMP_CREDENTIALS="$CRED_FIXTURE" \
    TASKPUMP_NOW_S=1755000000 \
    DOCKER="$BIN/docker" \
    "$PUMP" "$@" 2>&1 )
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

echo "--- Pins: examples/arachne.conf pins every flip-census default ---"
# The other half of the sentinel mechanism: not every census key reaches the
# three rendered surfaces (a monitor window class cannot diff a pump plan), so
# presence is asserted directly. Deleting ANY census pin from the reference
# conf fails here even when no golden byte moves.
for key in "${FLIP_CENSUS[@]}"; do
  if grep -qE "^TASKPUMP_$key=" "$ARACHNE_CONF"; then
    pass "arachne.conf pins TASKPUMP_$key"
  else
    fail "arachne.conf no longer pins TASKPUMP_$key — a default flip can now reach the reference consumer"
  fi
done

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
