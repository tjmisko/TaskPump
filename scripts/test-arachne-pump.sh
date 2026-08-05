#!/usr/bin/env bash
# test-arachne-pump.sh — dry-run fixture harness for scripts/arachne-pump.
#
# Per the F64.3 test plan: exercise the planning logic over a synthetic tasks dir
# with a cross-phase blocker — initial frontier, a cross-phase gate releasing, the
# docker-ps liveness join (stub `docker ps`), and the usage gate (stub
# arachne-usage). No real launch / build / ops mutation (that is F64.6's job).
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PUMP="$SCRIPT_DIR/arachne-pump"
REAL_TASK="$SCRIPT_DIR/arachne-task"
PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
have() { grep -qE "$2" <<<"$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TASKS="$TMP/tasks"; mkdir -p "$TASKS"
BIN="$TMP/bin"; mkdir -p "$BIN"

# ── Stubs ──────────────────────────────────────────────────────────────────────
# docker: answer `docker ps … --format {{.Names}}` from $STUB_LIVE (newline list);
# everything else is a harmless success.
cat >| "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then printf '%s\n' ${STUB_LIVE:-}; exit 0; fi
exit 0
EOF
# arachne-usage: only --gate matters here; exit $STUB_GATE_RC (0 feed / 10 pause).
cat >| "$BIN/arachne-usage" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--gate" ]]; then
  [[ "${STUB_GATE_RC:-0}" -eq 10 ]] && { echo "pause: stub ceiling tripped" >&2; exit 10; }
  exit 0
fi
exit 0
EOF
# arachne-disk-watchdog: only --gate matters here; exit $STUB_DISK_GATE_RC
# (0 feed / 10 pause). Defaults feed-ok so Tests 1-8 are unaffected by host disk.
cat >| "$BIN/arachne-disk-watchdog" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--gate" ]]; then
  [[ "${STUB_DISK_GATE_RC:-0}" -eq 10 ]] && { echo "/ free=3GB < 10GiB (disk gate)" >&2; exit 10; }
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/docker" "$BIN/arachne-usage" "$BIN/arachne-disk-watchdog"

export ARACHNE_TASKS_DIR="$TASKS"
export ARACHNE_TASK_NOCOMMIT=1
export ARACHNE_TASK="$REAL_TASK"
export ARACHNE_USAGE="$BIN/arachne-usage"
export ARACHNE_DISK_WATCHDOG="$BIN/arachne-disk-watchdog"
export DOCKER="$BIN/docker"

mk() {  # mk <id> <status> [blockers_csv]
  local id=$1 status=$2 blockers=${3:-}
  local by="[]"; [[ -n "$blockers" ]] && by="[$(printf '%s' "$blockers" | sed 's/,/, /g')]"
  cat >| "$TASKS/$id.md" <<EOF
---
id: $id
phase: ${id%%.*}
title: fixture $id
status: $status
claimed_by: null
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

pump() { "$PUMP" --no-health-gate --dry-run --phases "$1" "${@:2}"; }

# Contiguous range F55..F57 (no phase gaps), with a cross-phase blocker:
#   F55.0 root → F55.1 (in-phase dep) ; F56.0 root ; F57.0 waits on F55.1 (cross-phase)
mk F55.0 open
mk F55.1 open F55.0
mk F56.0 open
mk F57.0 open F55.1

echo "--- Test 1: initial frontier (.0 roots launch; cross-phase-gated phase waits) ---"
out=$(pump F55..F57)
have "$out" 'LAUNCH +F55' && pass "F55 launches (F55.0 eligible)" || fail "F55 not LAUNCH:\n$out"
have "$out" 'LAUNCH +F56' && pass "F56 launches (F56.0 eligible)" || fail "F56 not LAUNCH:\n$out"
have "$out" 'WAITING +F57' && pass "F57 waits (F57.0 blocked on cross-phase F55.1)" || fail "F57 not WAITING:\n$out"
have "$out" 'open tasks in range: 4' && pass "open count = 4" || fail "open count wrong:\n$out"

echo "--- Test 2: cross-phase blocker releases → F57 enters the frontier ---"
mk F55.0 done
mk F55.1 done
out=$(pump F55..F57)
have "$out" 'LAUNCH +F57' && pass "F57 launches once F55.1 is done" || fail "F57 not LAUNCH after release:\n$out"
have "$out" 'DONE +F55' && pass "F55 shown DONE (no open tasks)" || fail "F55 not DONE:\n$out"
have "$out" 'open tasks in range: 2' && pass "open count drops to 2" || fail "open count after release:\n$out"

echo "--- Test 3: docker-ps liveness join (a live container ⇒ RUNNING, not LAUNCH) ---"
# Reset fixtures; mark F55's worktree branch container live.
mk F55.0 open; mk F55.1 open F55.0; mk F56.0 open; mk F57.0 open F55.1
out=$(STUB_LIVE="arachne-agent-feat-f55" pump F55..F57)
have "$out" 'RUNNING +F55' && pass "F55 RUNNING (live container, not double-launched)" || fail "F55 not RUNNING:\n$out"
have "$out" 'LAUNCH +F56' && pass "F56 still LAUNCH (no live container)" || fail "F56 not LAUNCH:\n$out"

echo "--- Test 4: usage gate pause is surfaced ---"
out=$(STUB_GATE_RC=10 pump F55..F57)
have "$out" 'GATE: PAUSED' && pass "GATE: PAUSED shown when arachne-usage --gate returns 10" || fail "gate pause not shown:\n$out"
out=$(STUB_GATE_RC=0 pump F55..F57)
have "$out" 'GATE: feed-ok' && pass "GATE: feed-ok shown when gate returns 0" || fail "gate feed-ok not shown:\n$out"

echo "--- Test 5: single --phase behaves like a one-phase range ---"
out=$(pump F56)
have "$out" 'LAUNCH +F56' && pass "single --phase F56 plans F56" || fail "single phase plan:\n$out"

echo "--- Test 6: fully-drained range reports 0 open ---"
mk F55.0 done; mk F55.1 done; mk F56.0 done; mk F57.0 done
out=$(pump F55..F57)
have "$out" 'open tasks in range: 0' && pass "drained range reports 0 open" || fail "drained count:\n$out"
have "$out" 'DONE +F57' && pass "F57 DONE when all tasks done" || fail "F57 not DONE:\n$out"

echo "--- Test 7: phase-drain brief renders {{PHASE}} (F64.4) ---"
TPL="$TMP/_phase-drain-template.md"
cat >| "$TPL" <<'EOF'
# Kickoff brief — drain phase {{PHASE}}
Loop: scripts/arachne-task next --branch "$(git branch --show-current)" --phase {{PHASE}}
Only phase {{PHASE}}. NEVER merge, and NEVER commit or push to `main`.
Open/refresh a DRAFT PR against `main`. If genuinely blocked,
`scripts/arachne-task block {{PHASE}}.N --reason "..."` and continue.
EOF
r55=$(ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" "$PUMP" --render-brief F55)
grep -qF '{{PHASE}}' <<<"$r55" && fail "stray {{PHASE}} after render" || pass "no stray {{PHASE}}"
grep -qF -- '--phase F55' <<<"$r55" && pass "next --phase F55 scope rendered" || fail "no --phase F55:\n$r55"
grep -qiF 'never commit or push to' <<<"$r55" && pass "never-touch-main clause present" || fail "no never-main clause"
grep -qiF 'DRAFT PR' <<<"$r55" && pass "draft-PR clause present" || fail "no draft-PR clause"
grep -qF 'block F55.N' <<<"$r55" && pass "block-and-continue clause rendered" || fail "no block clause"
r60=$(ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" "$PUMP" --render-brief F60)
grep -qF 'F55' <<<"$r60" && fail "F55 leaked into F60 render" || pass "F60 render has no F55"

echo "--- Test 8: restart-safe state + drain notify (F64.5, no-launch hook) ---"
STATE="$TMP/pump.state"
NOTIFY="$TMP/notify.txt"; : >| "$NOTIFY"
# Hermetic tick: no worktrees/containers (NO_LAUNCH), ops/git ops point at a
# non-repo (fail-open), state/cap/log/template/usage all redirected.
pump_tick() {  # $1=phases ; extra env via caller
  # Suppress real desktop notifications by default (the fs-guard now runs in
  # do_tick and would notify-send against this dirty worktree); a caller can
  # still override ARACHNE_NOTIFY_CMD to capture, as the drain test does.
  ARACHNE_NOTIFY_CMD="${ARACHNE_NOTIFY_CMD:-true}" \
  ARACHNE_PUMP_NO_LAUNCH=1 \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  ARACHNE_PUMP_STATE_FILE="$STATE" \
  ARACHNE_POOL_CAP_FILE="$TMP/cap" \
  ARACHNE_PUMP_LOG="$TMP/pump.log" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate "${@:2}" --phases "$1"
}

# 8a: a feeding tick writes status=running for the range.
mk F55.0 open; mk F55.1 open F55.0; mk F56.0 open; mk F57.0 open F55.1
STUB_GATE_RC=0 pump_tick F55..F57 --once >/dev/null 2>&1
[[ "$(jq -r '.phases' "$STATE" 2>/dev/null)" == "F55..F57" ]] && pass "state.phases = F55..F57" || fail "state.phases: $(cat "$STATE" 2>/dev/null)"
[[ "$(jq -r '.status' "$STATE" 2>/dev/null)" == "running" ]] && pass "state.status = running on a feeding tick" || fail "state.status not running: $(cat "$STATE" 2>/dev/null)"

# 8b: a gated tick writes status=paused with a reason.
STUB_GATE_RC=10 pump_tick F55..F57 --once >/dev/null 2>&1
[[ "$(jq -r '.status' "$STATE" 2>/dev/null)" == "paused" ]] && pass "state.status = paused when gate trips" || fail "state.status not paused: $(cat "$STATE" 2>/dev/null)"
[[ -n "$(jq -r '.paused_reason // empty' "$STATE" 2>/dev/null)" ]] && pass "state.paused_reason recorded" || fail "no paused_reason"

# 8c: a fully-drained range exits → status=drained + one notification.
mk F55.0 done; mk F55.1 done; mk F56.0 done; mk F57.0 done
STUB_GATE_RC=0 ARACHNE_NOTIFY_CMD="tee -a $NOTIFY" pump_tick F55..F57 >/dev/null 2>&1
[[ "$(jq -r '.status' "$STATE" 2>/dev/null)" == "drained" ]] && pass "state.status = drained when range empties" || fail "state.status not drained: $(cat "$STATE" 2>/dev/null)"
grep -qi 'drained' "$NOTIFY" && pass "drain notification fired via ARACHNE_NOTIFY_CMD" || fail "no drain notification: $(cat "$NOTIFY" 2>/dev/null)"

# 8d: restart detection logs a resume for the same range.
out=$(STUB_GATE_RC=0 pump_tick F55..F57 --once 2>&1 >/dev/null; STUB_GATE_RC=0 pump_tick F55..F57 --once 2>&1)
grep -qi "resuming pump for F55..F57" <<<"$out" && pass "restart detection logs resume for same range" || fail "no resume log:\n$out"

echo "--- Test 9: disk feed-gate pauses launching (A4 / F65.3) ---"
# Reset fixtures to a live frontier (the gate line prints regardless of fixtures).
mk F55.0 open; mk F55.1 open F55.0; mk F56.0 open; mk F57.0 open F55.1
# 9a: disk gate trips (watchdog --gate exits 10) → GATE: PAUSED in the plan.
out=$(STUB_DISK_GATE_RC=10 pump F55..F57)
have "$out" 'GATE: PAUSED' && pass "disk gate pause surfaced when watchdog --gate returns 10" || fail "disk pause not shown:\n$out"
have "$out" 'disk gate' && pass "pause reason names the disk gate" || fail "disk-gate reason missing:\n$out"
# 9b: disk gate clears → feed-ok.
out=$(STUB_DISK_GATE_RC=0 pump F55..F57)
have "$out" 'GATE: feed-ok' && pass "disk gate feed-ok when watchdog --gate returns 0" || fail "disk feed-ok not shown:\n$out"
# 9c: --no-disk-gate bypasses the disk check even when it would trip.
out=$(STUB_DISK_GATE_RC=10 "$PUMP" --no-health-gate --no-disk-gate --dry-run --phases F55..F57)
have "$out" 'GATE: feed-ok' && pass "--no-disk-gate bypasses the disk gate" || fail "disk gate not bypassed:\n$out"

# 9d: a disk-gated --once tick writes status=paused with the disk reason.
mk F55.0 open; mk F55.1 open F55.0; mk F56.0 open; mk F57.0 open F55.1
STUB_GATE_RC=0 STUB_DISK_GATE_RC=10 pump_tick F55..F57 --once >/dev/null 2>&1
[[ "$(jq -r '.status' "$STATE" 2>/dev/null)" == "paused" ]] && pass "disk gate trip writes status=paused" || fail "status not paused on disk gate: $(cat "$STATE" 2>/dev/null)"
have "$(jq -r '.paused_reason // empty' "$STATE" 2>/dev/null)" 'disk gate' && pass "paused_reason names the disk gate" || fail "paused_reason missing disk gate: $(jq -r '.paused_reason' "$STATE" 2>/dev/null)"

echo "--- Test 10: reclaim sweep cleans completed-phase target/ dirs (A4 / F65.3) ---"
WT="$TMP/wt"; STATE10="$TMP/pump10.state"
# Stub cargo so `clean --manifest-path X` removes $(dirname X)/target with no real
# build (honours the no-real-cargo test seam). Shadowed onto PATH for the tick.
cat >| "$BIN/cargo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "clean" ]]; then
  shift; mp=""
  while (($#)); do
    case "$1" in
      --manifest-path) mp="$2"; shift 2;;
      --manifest-path=*) mp="${1#--manifest-path=}"; shift;;
      *) shift;;
    esac
  done
  [[ -n "$mp" ]] && rm -rf "$(dirname "$mp")/target"
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/cargo"

plant_target() {  # fake done-phase worktree with a target/ dir + sentinel
  rm -rf "$WT"; mkdir -p "$WT/feat/f56/target"
  : >| "$WT/feat/f56/Cargo.toml"
  echo sentinel >| "$WT/feat/f56/target/sentinel"
}
reclaim_tick() {  # one real tick with the reclaim sweep active, fixture-wired
  PATH="$BIN:$PATH" \
  ARACHNE_NOTIFY_CMD="${ARACHNE_NOTIFY_CMD:-true}" \
  ARACHNE_PUMP_WORKTREES_DIR="$WT" \
  ARACHNE_PUMP_NO_LAUNCH=1 \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  ARACHNE_PUMP_STATE_FILE="$STATE10" \
  ARACHNE_POOL_CAP_FILE="$TMP/cap" \
  ARACHNE_PUMP_LOG="$TMP/pump.log" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate "$@"
}

# 10a: a PLAN_DONE phase (all tasks done) with no live container → target reclaimed.
mk F56.0 done; plant_target
out=$(STUB_GATE_RC=0 ARACHNE_DISK_RECLAIM=1 reclaim_tick --phases F56 --once 2>&1)
[[ ! -d "$WT/feat/f56/target" ]] && pass "reclaim removed F56 target/ on a DONE tick" || fail "F56 target/ survived reclaim:\n$out"
have "$out" 'reclaimed F56' && pass "reclaim logged 'reclaimed F56'" || fail "no reclaim log line:\n$out"

# 10b: ARACHNE_DISK_RECLAIM=0 → reclaim disabled, target survives.
plant_target
STUB_GATE_RC=0 ARACHNE_DISK_RECLAIM=0 reclaim_tick --phases F56 --once >/dev/null 2>&1
[[ -d "$WT/feat/f56/target" ]] && pass "ARACHNE_DISK_RECLAIM=0 leaves target/ intact" || fail "target removed despite RECLAIM=0"

# 10c: a live container for F56 → target survives even though open_count=0.
plant_target
STUB_GATE_RC=0 ARACHNE_DISK_RECLAIM=1 STUB_LIVE="arachne-agent-feat-f56" reclaim_tick --phases F56 --once >/dev/null 2>&1
[[ -d "$WT/feat/f56/target" ]] && pass "live-phase target/ never reclaimed (phase_live guard)" || fail "live phase target/ was reclaimed"

echo "--- Test 11: A8 read-only-primary mount set in both launchers (F65.5) ---"
# Static guard against a future blanket-RW $REPO_ROOT regression (RC-4). Each
# launcher must carry the :ro parent plus the three RW overlays, and must NOT
# carry an un-suffixed `-v "$REPO_ROOT":"$REPO_ROOT"` (blanket read-write).
assert_mounts() {  # <launcher-path> <label>
  local f="$1" label="$2"
  grep -qF -- '-v "$REPO_ROOT":"$REPO_ROOT":ro' "$f" \
    && pass "$label: :ro primary mount present" || fail "$label: missing :ro primary mount"
  grep -qF -- '-v "$REPO_ROOT/.git":"$REPO_ROOT/.git"' "$f" \
    && pass "$label: .git RW overlay present" || fail "$label: missing .git RW overlay"
  grep -qF -- '-v "$wt":"$wt"' "$f" \
    && pass "$label: worktree RW overlay present" || fail "$label: missing worktree RW overlay"
  grep -qF -- '-v "$REPO_ROOT/ops":"$REPO_ROOT/ops"' "$f" \
    && pass "$label: ops RW overlay present" || fail "$label: missing ops RW overlay"
  # Regression: a blanket `-v "$REPO_ROOT":"$REPO_ROOT"` not followed by `:` (so
  # not the `:ro` line, and distinct from the /.git and /ops overlays).
  if grep -Eq -- '-v "\$REPO_ROOT":"\$REPO_ROOT"[^:]' "$f"; then
    fail "$label: blanket RW \$REPO_ROOT mount re-introduced (A8 regression)"
  else
    pass "$label: no blanket RW \$REPO_ROOT mount"
  fi
}
assert_mounts "$PUMP" "arachne-pump"
assert_mounts "$SCRIPT_DIR/run-parallel.sh" "run-parallel.sh"

echo "--- Test 12: apl_fs_guard flags primary-source dirt, ignores allowlist (F65.5) ---"
# shellcheck source=scripts/arachne-pump-lib.sh
source "$SCRIPT_DIR/arachne-pump-lib.sh"
GR="$TMP/guardrepo"; mkdir -p "$GR"
git -C "$GR" init -q
git -C "$GR" config user.email t@t.t
git -C "$GR" config user.name t
# `ops` modelled as a tracked path (the submodule-pointer line is ` M ops`); a
# tracked source file models the RC-4 incident (an uncommitted edit to plan.rs).
echo v1 >| "$GR/ops"; echo seed >| "$GR/seed.txt"
mkdir -p "$GR/crates/arachne-core/src"; echo fn_main >| "$GR/crates/arachne-core/src/plan.rs"
git -C "$GR" add -A >/dev/null 2>&1
git -C "$GR" commit -qm seed
# 12a: an edit to a tracked primary-source file (outside the allowlist) is flagged
# with its full path (` M crates/...` — the literal F56.2 footgun).
echo edited >> "$GR/crates/arachne-core/src/plan.rs"
g="$(apl_fs_guard "$GR")"
have "$g" 'FS-GUARD' && pass "primary-source dirt is flagged" || fail "primary-source dirt not flagged:\n$g"
have "$g" 'crates/arachne-core/src/plan.rs' && pass "flagged path named" || fail "flagged path not named:\n$g"
git -C "$GR" checkout -- crates/arachne-core/src/plan.rs
# 12b: only .worktrees/ scratch + the ops pointer dirty → silent (allowlisted).
mkdir -p "$GR/.worktrees/feat/x"; echo scratch >| "$GR/.worktrees/feat/x/scratch"
echo v2 >| "$GR/ops"   # ` M ops` — the submodule-pointer line, allowlisted
g="$(apl_fs_guard "$GR")"
[[ -z "$g" ]] && pass "allowlisted dirt (.worktrees/ + ops) is silent" || fail "allowlist not respected:\n$g"

echo "--- Test 13: integration trunk — selection, build-gate, conflict (A3 v0) ---"
# Drive reconcile_trunk through the ARACHNE_PUMP_INTEGRATE_DRYRUN seam (no real
# git/cargo/gh): STUB_INTEGRATE_{NOBRANCH,ANCESTOR,CONFLICT} + BUILD_GATE_CMD
# drive branch-exists / already-integrated / conflict / build-red.
QFILE="$TMP/quarantine"; ISTATE="$TMP/ipump.state"
itick() {  # integration dry-run --once tick: $1=phases ; extra env via caller
  ARACHNE_NOTIFY_CMD="${ARACHNE_NOTIFY_CMD:-true}" \
  ARACHNE_PUMP_NO_LAUNCH=1 \
  ARACHNE_PUMP_INTEGRATE_DRYRUN=1 \
  ARACHNE_PUMP_QUARANTINE_FILE="$QFILE" \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  ARACHNE_PUMP_STATE_FILE="$ISTATE" \
  ARACHNE_POOL_CAP_FILE="$TMP/cap" \
  ARACHNE_PUMP_LOG="$TMP/pump.log" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate --integration-trunk "${@:2}" --phases "$1" --once
}

# 13a: two quiescent phases with (assumed-present) branches → both "would integrate".
mk F55.0 open; mk F56.0 open
out=$(STUB_GATE_RC=0 itick F55..F56 2>&1)
have "$out" 'would integrate F55' && pass "quiescent F55 → would integrate" || fail "F55 not integrated:\n$out"
have "$out" 'would integrate F56' && pass "quiescent F56 → would integrate" || fail "F56 not integrated:\n$out"

# 13b: a phase already an ancestor of the trunk → no integrate line.
out=$(STUB_GATE_RC=0 STUB_INTEGRATE_ANCESTOR="F55" itick F55..F56 2>&1)
have "$out" 'would integrate F55' && fail "already-integrated F55 re-integrated:\n$out" || pass "already-ancestor F55 skipped"
have "$out" 'would integrate F56' && pass "F56 still integrates" || fail "F56 not integrated:\n$out"

# 13c: a live container ⇒ phase not quiescent ⇒ skipped (mirrors the liveness join).
out=$(STUB_GATE_RC=0 STUB_LIVE="arachne-agent-feat-f55" itick F55..F56 2>&1)
have "$out" 'would integrate F55' && fail "live F55 integrated (not quiescent):\n$out" || pass "live F55 skipped (not quiescent)"
have "$out" 'would integrate F56' && pass "quiescent F56 still integrates" || fail "F56 not integrated:\n$out"

# 13d: build-gate red ⇒ quarantine; trunk not advanced; needs-review recorded; marker written.
: >| "$QFILE"
out=$(STUB_GATE_RC=0 ARACHNE_PUMP_BUILD_CMD='false' itick F55 2>&1)
have "$out" 'would quarantine F55: build red' && pass "build-red → would quarantine" || fail "no build-red quarantine:\n$out"
have "$out" 'needs-review' && pass "needs-review recorded as the quarantine action" || fail "no needs-review action:\n$out"
have "$out" 'would integrate F55' && fail "trunk advanced despite build red:\n$out" || pass "trunk not advanced on build red"
grep -qE '^F55 .*build red$' "$QFILE" && pass "quarantine marker written for build red" || fail "no build-red marker:\n$(cat "$QFILE")"

# 13e: merge conflict ⇒ quarantine; trunk not advanced; marker written.
: >| "$QFILE"
out=$(STUB_GATE_RC=0 STUB_INTEGRATE_CONFLICT="F55" itick F55 2>&1)
have "$out" 'would quarantine F55: conflict' && pass "conflict → would quarantine" || fail "no conflict quarantine:\n$out"
have "$out" 'would integrate F55' && fail "trunk advanced despite conflict:\n$out" || pass "trunk not advanced on conflict"
grep -qE '^F55 .*conflict$' "$QFILE" && pass "quarantine marker written for conflict" || fail "no conflict marker:\n$(cat "$QFILE")"

# 13f: --integration-trunk OFF ⇒ no integration whatsoever (opt-out regression).
: >| "$QFILE"
out=$(STUB_GATE_RC=0 ARACHNE_PUMP_BUILD_CMD='false' \
  ARACHNE_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 ARACHNE_PUMP_INTEGRATE_DRYRUN=1 \
  ARACHNE_PUMP_QUARANTINE_FILE="$QFILE" ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  ARACHNE_PUMP_STATE_FILE="$ISTATE" ARACHNE_POOL_CAP_FILE="$TMP/cap" \
  ARACHNE_PUMP_LOG="$TMP/pump.log" ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate --phases F55 --once 2>&1)
have "$out" 'would integrate' && fail "integration ran with flag off:\n$out" || pass "flag-off ⇒ no integration (opt-out)"
have "$out" 'would quarantine' && fail "quarantine ran with flag off:\n$out" || pass "flag-off ⇒ no quarantine (opt-out)"

echo "--- Test 14: arachne-task needs-review subcommand (A3 v0) ---"
mk F58.0 open
"$REAL_TASK" claim F58.0 --branch feat/f58 --turns 5 >/dev/null 2>&1
"$REAL_TASK" needs-review F58.0 --reason "auto/trunk conflict for F58" >/dev/null 2>&1
grep -q 'status: needs-review' "$TASKS/F58.0.md" && pass "needs-review sets status: needs-review" || fail "status not needs-review:\n$(cat "$TASKS/F58.0.md")"
grep -q 'claimed_by: null' "$TASKS/F58.0.md" && pass "needs-review clears the claim" || fail "claim not cleared:\n$(cat "$TASKS/F58.0.md")"
grep -qi 'Needs review' "$TASKS/F58.0.md" && pass "needs-review appends a body note" || fail "no body note:\n$(cat "$TASKS/F58.0.md")"
grep -qF 'auto/trunk conflict for F58' "$TASKS/F58.0.md" && pass "needs-review note carries the reason" || fail "reason not in note"
"$REAL_TASK" needs-review F58.0 >/dev/null 2>&1 && fail "needs-review without --reason should error" || pass "needs-review requires --reason"

echo "--- Test 15: dependency-aware briefs expand {{DEPENDS_ON}} (A3 v1) ---"
# A template carrying the new {{DEPENDS_ON}} placeholder; rendered via the pump's
# TASKS_DIR override against the fixtures, gh disabled (ARACHNE_PUMP_NO_GH=1) so
# the render is hermetic. F60.0 depends cross-phase on F55.7; F56.0 has none.
TPL2="$TMP/_phase-drain-template-v1.md"
cat >| "$TPL2" <<'EOF'
# Kickoff brief — drain phase {{PHASE}}
You are based on `auto/trunk` (an integration branch off `main`).

## Depends on / builds upon
{{DEPENDS_ON}}

## Working method
scripts/arachne-task next --phase {{PHASE}}
EOF
mk F60.0 open F55.7        # cross-phase blocker on F55
rbrief() {  # $1=phase
  ARACHNE_PUMP_NO_GH=1 ARACHNE_PUMP_TASKS_DIR="$TASKS" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL2" "$PUMP" --render-brief "$1"
}
r60=$(rbrief F60)
grep -qF '{{DEPENDS_ON}}' <<<"$r60" && fail "stray {{DEPENDS_ON}} after render:\n$r60" || pass "no stray {{DEPENDS_ON}}"
grep -qF '{{PHASE}}' <<<"$r60" && fail "stray {{PHASE}} after render (v1):\n$r60" || pass "no stray {{PHASE}} (v1)"
grep -qF 'Depends on / builds upon' <<<"$r60" && pass "deps section header present" || fail "no deps header:\n$r60"
grep -qF 'feat/f55' <<<"$r60" && pass "cross-phase blocker names feat/f55" || fail "feat/f55 not named:\n$r60"
r56=$(rbrief F56)
grep -qF 'No cross-phase dependencies' <<<"$r56" && pass "empty-deps line for F56 (no cross-phase blockers)" || fail "no empty-deps line:\n$r56"
grep -qF 'feat/f55' <<<"$r56" && fail "F55 leaked into F56 deps:\n$r56" || pass "F56 deps block clean"

echo "--- Test 16: integration-aware launch gate — done≠integrated (A3 v2) ---"
# F57.0 depends cross-phase on F55.1; F55.1 is done (ledger-ready) but its CODE
# may not yet be on auto/trunk. STUB_INTEGRATED drives the ancestor check; the
# pump reads the fixtures via ARACHNE_PUMP_TASKS_DIR so phase_deps_integrated
# sees F57's cross-phase blocker.
ipump() { ARACHNE_PUMP_TASKS_DIR="$TASKS" "$PUMP" --no-health-gate --dry-run --phases "$1" "${@:2}"; }
mk F55.0 done; mk F55.1 done; mk F56.0 done; mk F57.0 open F55.1
# 16a: --integration-trunk on, dep NOT integrated → F57 WAITS, does not LAUNCH.
out=$(STUB_INTEGRATED="" ipump F55..F57 --integration-trunk)
have "$out" 'WAITING +F57' && pass "F57 WAITING: dep done but not integrated" || fail "F57 not WAITING:\n$out"
have "$out" 'LAUNCH +F57' && fail "F57 launched before dep integrated:\n$out" || pass "F57 not LAUNCH before integration"
have "$out" 'not yet integrated' && pass "WAITING reason names the integration gap" || fail "no integration reason:\n$out"
# 16b: flip the dep to integrated → F57 LAUNCHES.
out=$(STUB_INTEGRATED="F55" ipump F55..F57 --integration-trunk)
have "$out" 'LAUNCH +F57' && pass "F57 LAUNCH once F55 integrated" || fail "F57 not LAUNCH after integration:\n$out"
# 16c: integration OFF → ledger-ready F57 LAUNCHES regardless (opt-out: no gate).
out=$(STUB_INTEGRATED="" ipump F55..F57)
have "$out" 'LAUNCH +F57' && pass "flag-off ⇒ F57 LAUNCH on done (no integration gate)" || fail "F57 not LAUNCH with flag off:\n$out"

echo "--- Test 17: liveness-based reclaim of orphaned claims (A1, D3 eligibility path) ---"
# An in_progress task whose claiming container is DEAD starves the frontier
# (`ready` excludes claimed tasks). reclaim_orphaned_claims (run in do_tick after
# scrub) releases clean orphans (0 commits) and parks ones with committed work. A
# PATH-injected git stub makes the commits-ahead check hermetic; F95 has no real
# branch so nothing here touches the working repo. Staleness reclaim is disabled
# (ARACHNE_CLAIM_STALE_HOURS huge) so this isolates reclaim_orphaned_claims.
cat >| "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *rev-list*--count*) echo "${STUB_AHEAD:-0}";;
  *) : ;;
esac
exit 0
EOF
chmod +x "$BIN/git"
mkdir -p "$TMP/noops"
STATE17="$TMP/pump17.state"
mkclaim() {  # mkclaim <id> <claimed_by_branch> — an in_progress, claimed fixture
  cat >| "$TASKS/$1.md" <<EOF
---
id: $1
phase: ${1%%.*}
title: fixture $1
status: in_progress
claimed_by: $2
claimed_at: "2026-06-23T00:00:00Z"
turn_budget_remaining: 9999
consecutive_failed_iterations: 0
blockers: []
completed_by_commits: []
files: []
goal: drain $1
---
# $1
EOF
}
status_of() { sed -n 's/^status: *//p' "$TASKS/$1.md" | head -1; }
claim_tick() {  # $1 = phases ; STUB_LIVE/STUB_AHEAD supplied by caller
  PATH="$BIN:$PATH" ARACHNE_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 \
  ARACHNE_CLAIM_STALE_HOURS=99999 ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  ARACHNE_PUMP_STATE_FILE="$STATE17" ARACHNE_POOL_CAP_FILE="$TMP/cap" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate --once --phases "$1"
}

# 17a: dead container + 0 commits → released to open (the core stall fix).
rm -f "$TASKS"/*.md; mk F95.0 done; mkclaim F95.1 feat/f95
out=$(STUB_LIVE="" STUB_AHEAD=0 claim_tick F95 2>/dev/null)
[[ "$(status_of F95.1)" == "open" ]] && pass "orphaned claim (dead container, 0 commits) released to open" || fail "F95.1 not reopened: status=$(status_of F95.1)"
have "$out" 'reclaimed orphaned claim F95.1' && pass "reclaim logged for F95.1" || fail "no reclaim log:\n$out"

# 17b: LIVE container → claim is legitimate, left untouched.
mkclaim F95.1 feat/f95
STUB_LIVE="arachne-agent-feat-f95" STUB_AHEAD=0 claim_tick F95 >/dev/null 2>&1
[[ "$(status_of F95.1)" == "in_progress" ]] && pass "live container ⇒ claim left in_progress" || fail "F95.1 wrongly reclaimed while live: $(status_of F95.1)"

# 17c: claim on a branch this pump does NOT own → untouched.
mkclaim F95.1 feat/somebody-else
STUB_LIVE="" STUB_AHEAD=0 claim_tick F95 >/dev/null 2>&1
[[ "$(status_of F95.1)" == "in_progress" ]] && pass "foreign-branch claim left untouched" || fail "F95.1 wrongly reclaimed (foreign branch): $(status_of F95.1)"

# 17d: dead container but commits present → parked for review, NOT auto-reopened.
mkclaim F95.1 feat/f95
err=$(STUB_LIVE="" STUB_AHEAD=3 claim_tick F95 2>&1 >/dev/null)
[[ "$(status_of F95.1)" == "in_progress" ]] && pass "orphan with commits left parked (not reopened)" || fail "F95.1 wrongly reopened despite commits: $(status_of F95.1)"
have "$err" 'committed work' && pass "parked-with-commits surfaced via warn" || fail "no committed-work warning:\n$err"

echo "--- Test 18: scrub integrity findings reach the pump log with their paths ---"
# do_tick used to run `scrub >/dev/null 2>&1 || warn "scrub failed (continuing)"`,
# which threw away the only actionable detail — which file is invisible — and
# could not tell a corrupt ledger from scrub itself crashing.
STATE18="$TMP/pump18.state"
tick18() {
  ARACHNE_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" ARACHNE_PUMP_STATE_FILE="$STATE18" \
  ARACHNE_POOL_CAP_FILE="$TMP/cap" ARACHNE_PUMP_LOG="$TMP/pump18.log" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate --once --phases F96
}

# 18a: an unparseable file is named in the warning, not swallowed.
rm -f "$TASKS"/*.md; mk F96.0 open
cat >| "$TASKS/F96.9.md" <<'BROKEN18'
---
id: F96.9
status: open
goal: Verify the thing: a colon that breaks yq.
---
# F96.9
BROKEN18
err=$(STUB_LIVE="" STUB_GATE_RC=0 tick18 2>&1 >/dev/null)
have "$err" 'ledger integrity' && pass "pump warns about ledger integrity (not a generic failure)" || fail "no integrity warning:\n$err"
have "$err" 'F96\.9\.md' && pass "pump names the offending file path" || fail "path not surfaced in pump warning:\n$err"
have "$err" 'scrub failed \(continuing\)' && fail "integrity finding mislabelled as a scrub crash:\n$err" || pass "integrity finding not conflated with a scrub crash"

# 18b: a healthy ledger stays silent — this runs every tick for days.
rm -f "$TASKS/F96.9.md"
err=$(STUB_LIVE="" STUB_GATE_RC=0 tick18 2>&1 >/dev/null)
have "$err" 'ledger integrity' && fail "pump warned about integrity on a healthy ledger:\n$err" || pass "pump silent on a healthy ledger"

# 18c: scrub genuinely failing still reports as a failure, not an integrity finding.
STUB_TASK="$BIN/arachne-task-broken"
printf '#!/usr/bin/env bash\nexit 1\n' >| "$STUB_TASK"; chmod +x "$STUB_TASK"
err=$(STUB_LIVE="" STUB_GATE_RC=0 ARACHNE_TASK="$STUB_TASK" tick18 2>&1 >/dev/null)
have "$err" 'scrub failed \(continuing\)' && pass "a crashing scrub still warns 'scrub failed'" || fail "scrub crash not reported:\n$err"

echo "--- Test 19: auto-resume of a stalled orphaned claim (2026-08-05 F79 stall) ---"
# reclaim_orphaned_claims PARKS an orphan that has committed work rather than
# reopening it (Test 17d) — the right call, but it left no exit. `ready` only
# surfaces status:open, so the claim is invisible to the frontier, everything
# blocked behind it is ineligible, compute_plan files the phase under WAITING,
# and is_drained never fires because open_count > 0. The live F79 pump idled
# 563 ticks over 7h with 5 open tasks and launched nothing.
#
# The fix resumes rather than reopens: keep the claim, relaunch the phase, and
# hand the agent a note naming the task (a plain relaunch would call
# `next --phase FN`, get null, and re-conclude "frontier drained").
#
# The git stub answers rev-parse (branch head, for progress detection),
# rev-parse --verify (branch exists), rev-list --count (commits ahead) and
# log --oneline (the resume note's commit list). Order matters: --verify must
# be matched before the bare rev-parse arm.
cat >| "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *rev-parse*--verify*) exit 0 ;;
  *rev-parse*)          echo "${STUB_HEAD:-aaaaaaa1111}" ;;
  *rev-list*--count*)   echo "${STUB_AHEAD:-0}" ;;
  *log*--oneline*)      echo "cafe123 feat: partial work from the dead agent" ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$BIN/git"
STATE19="$TMP/pump19.state"
rtick() {  # one --once tick over F97; extra flags forwarded
  PATH="$BIN:$PATH" ARACHNE_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 \
  ARACHNE_CLAIM_STALE_HOURS=99999 ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  ARACHNE_PUMP_STATE_FILE="$STATE19" ARACHNE_POOL_CAP_FILE="$TMP/cap" \
  ARACHNE_PUMP_LOG="$TMP/pump19.log" ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate --once --phases F97 "$@"
}
attempts_of() { sed -n 's/^resume_attempts: *//p' "$TASKS/$1.md" | head -1; }
# The F79 shape: a done .0, the stalled claim .1, and a .2 blocked behind it.
stall_fixture() { rm -f "$TASKS"/*.md; mk F97.0 done; mkclaim F97.1 feat/f97; mk F97.2 open F97.1; }

# 19a: dead container + committed work + empty frontier ⇒ resumed, not parked.
stall_fixture
out=$(STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=aaaa111 rtick 2>&1)
have "$out" 'resuming F97 task F97\.1' && pass "stalled phase resumed" || fail "no resume:\n$out"
have "$out" 'NO_LAUNCH, resume F97\.1' && pass "container would launch with the orphan as its task id" || fail "resume task id not passed to launch:\n$out"
[[ "$(attempts_of F97.1)" == "1" ]] && pass "first resume records attempt 1" || fail "attempts=$(attempts_of F97.1), want 1"
[[ "$(status_of F97.1)" == "in_progress" ]] && pass "resume keeps the claim (does not reopen)" || fail "F97.1 status=$(status_of F97.1), want in_progress"

# 19b: a LIVE container on the phase ⇒ never resumed (no double-launch).
stall_fixture
out=$(STUB_LIVE="arachne-agent-feat-f97" STUB_AHEAD=3 STUB_HEAD=aaaa111 rtick 2>&1)
have "$out" 'resuming F97' && fail "resumed a phase with a live container:\n$out" || pass "live container ⇒ no resume"

# 19c: no new commits between ticks ⇒ the counter climbs.
stall_fixture
for _ in 1 2 3; do STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=bbbb222 rtick >/dev/null 2>&1; done
[[ "$(attempts_of F97.1)" == "3" ]] && pass "three no-progress resumes ⇒ attempts=3" || fail "attempts=$(attempts_of F97.1), want 3"

# 19d: the branch moved ⇒ real progress ⇒ counter resets. A task that needs four
# sessions but commits each time must never be escalated.
STUB_LIVE="" STUB_AHEAD=4 STUB_HEAD=cccc333 rtick >/dev/null 2>&1
[[ "$(attempts_of F97.1)" == "1" ]] && pass "new commits reset the attempt counter" || fail "attempts=$(attempts_of F97.1) after progress, want 1"

# 19e: budget spent ⇒ escalate to needs-review + notify, and do NOT relaunch.
stall_fixture
for _ in 1 2 3; do STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=dddd444 rtick >/dev/null 2>&1; done
out=$(STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=dddd444 rtick 2>&1)
[[ "$(status_of F97.1)" == "needs-review" ]] && pass "exhausted budget ⇒ needs-review" || fail "F97.1 status=$(status_of F97.1), want needs-review"
have "$out" 'STALLED on F97\.1' && pass "escalation notifies" || fail "no escalation notice:\n$out"
have "$out" 'NO_LAUNCH, resume' && fail "relaunched after escalating:\n$out" || pass "no relaunch once escalated"

# 19f: --resume-max is honoured (2 ⇒ escalate on the third).
stall_fixture
for _ in 1 2; do STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=eeee555 rtick --resume-max 2 >/dev/null 2>&1; done
STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=eeee555 rtick --resume-max 2 >/dev/null 2>&1
[[ "$(status_of F97.1)" == "needs-review" ]] && pass "--resume-max 2 escalates one attempt earlier" || fail "F97.1 status=$(status_of F97.1), want needs-review"

# 19g: a claim on a branch this pump does not own is never resumed.
rm -f "$TASKS"/*.md; mk F97.0 done; mkclaim F97.1 feat/somebody-else
out=$(STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=aaaa111 rtick 2>&1)
have "$out" 'resuming F97' && fail "resumed a foreign-branch claim:\n$out" || pass "foreign-branch claim not resumed"

# 19h: the orphan is the phase's ONLY remaining work (open_count == 0). Before
# the RESUME arm was tested ahead of `oc`, this phase was classified DONE and
# is_drained declared the range finished over committed, unfinished work.
rm -f "$TASKS"/*.md; mk F97.0 done; mkclaim F97.1 feat/f97
out=$(PATH="$BIN:$PATH" ARACHNE_NOTIFY_CMD=true ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
      ARACHNE_PUMP_STATE_FILE="$STATE19" ARACHNE_POOL_CAP_FILE="$TMP/cap" \
      ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=aaaa111 \
      "$PUMP" --no-health-gate --dry-run --phases F97 2>&1)
have "$out" 'RESUME +F97' && pass "orphan-only phase plans as RESUME" || fail "not RESUME:\n$out"
have "$out" 'DONE +F97' && fail "orphan-only phase wrongly classified DONE:\n$out" || pass "orphan-only phase not classified DONE"

# 19i: a shut feed gate must not resume — and must not burn an attempt on a
# resume it never performed.
stall_fixture
out=$(STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=ffff666 STUB_GATE_RC=10 rtick 2>&1)
have "$out" 'resuming F97' && fail "resumed while the feed gate was shut:\n$out" || pass "gate paused ⇒ no resume"
[[ -z "$(attempts_of F97.1)" || "$(attempts_of F97.1)" == "0" ]] && pass "gate-paused tick burns no attempt" || fail "attempt burned while gated: $(attempts_of F97.1)"

# 19j: --no-resume-stalled restores the old park-and-warn behaviour verbatim.
stall_fixture
out=$(STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=aaaa111 rtick --no-resume-stalled 2>&1)
have "$out" 'resuming F97' && fail "resumed despite --no-resume-stalled:\n$out" || pass "--no-resume-stalled disables resume"
have "$out" 'parked for review' && pass "parked-for-review warning still surfaces" || fail "no park warning:\n$out"
[[ "$(status_of F97.1)" == "in_progress" ]] && pass "claim untouched with resume disabled" || fail "F97.1 status=$(status_of F97.1)"

# 19k: the resume note tells the agent NOT to trust `next` — the single most
# load-bearing sentence in it. A relaunched agent that calls `next --phase F97`
# gets null (the task is claimed, so it is not `open`) and exits "drained",
# which is the stall reproducing itself.
stall_fixture
note=$(PATH="$BIN:$PATH" ARACHNE_PUMP_OPS_DIR="$TMP/noops" ARACHNE_POOL_CAP_FILE="$TMP/cap" \
       ARACHNE_PUMP_STATE_FILE="$STATE19" ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
       STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=aaaa111 \
       "$PUMP" --no-health-gate --render-resume-note F97 2>/dev/null)
have "$note" 'RESUME CONTEXT' && pass "resume note renders" || fail "no resume note:\n$note"
have "$note" 'Do NOT start by running' && pass "note warns against the next-returns-null trap" || fail "note lacks the next warning:\n$note"
have "$note" 'F97\.1' && pass "note names the stalled task" || fail "note does not name the task:\n$note"
have "$note" 'partial work from the dead agent' && pass "note lists the already-committed work" || fail "note lacks the commit log:\n$note"
have "$note" 'Split it' && pass "note authorises split-and-unblock" || fail "note lacks the split escape hatch:\n$note"

# 19l: fully deadlocked (nothing live, launchable, or resumable) ⇒ the pump
# exits 3 and pages, instead of idling green forever. Escalate first so the
# phase leaves PLAN_RESUME, then let the run loop tick.
stall_fixture
for _ in 1 2 3; do STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=9999aaa rtick >/dev/null 2>&1; done
rc=0
out=$(PATH="$BIN:$PATH" ARACHNE_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 \
      ARACHNE_CLAIM_STALE_HOURS=99999 ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
      ARACHNE_PUMP_STATE_FILE="$STATE19" ARACHNE_POOL_CAP_FILE="$TMP/cap" \
      ARACHNE_PUMP_LOG="$TMP/pump19.log" ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
      STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=9999aaa \
      timeout 60 "$PUMP" --no-health-gate --phases F97 --tick 1 --resume-max 1 2>&1) || rc=$?
[[ "$rc" -eq 3 ]] && pass "deadlocked pump exits 3 (systemd sees failed, not green)" || fail "exit=$rc, want 3:\n$out"
have "$out" 'STALLED after [0-9]+ idle ticks' && pass "stall exit pages with a reason" || fail "no stall page:\n$out"
have "$out" 'none can launch' && pass "stall page explains why nothing ran" || fail "stall page lacks the cause:\n$out"

# ── Test 20: --detach hands the terminal to the monitor ───────────────────────
# The detach itself is stubbed: systemd-run records its argv to a marker instead
# of creating a unit, so no supervisor is ever launched. The marker is asserted
# FIRST — if the stub were bypassed this test would start a real pump.
echo "--- Test 20: monitor handoff after --detach ---"
MARK="$TMP/systemd-run.argv"
cat >| "$BIN/systemd-run" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$MARK"
exit 0
EOF
cat >| "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
MONMARK="$TMP/monitor.ran"
cat >| "$BIN/fake-monitor" <<EOF
#!/usr/bin/env bash
printf 'monitor-started %s\n' "\$*" >> "$MONMARK"
exit 0
EOF
chmod +x "$BIN/systemd-run" "$BIN/systemctl" "$BIN/fake-monitor"

detach_run() {  # $@ = extra pump flags
    PATH="$BIN:$PATH" ARACHNE_MONITOR_BIN="$BIN/fake-monitor" \
    ARACHNE_PUMP_STATE_FILE="$TMP/detach.state" ARACHNE_PUMP_LOG="$TMP/detach.log" \
    ARACHNE_TASKS_DIR="$TASKS" \
    timeout 60 "$PUMP" --phases F98 --detach "$@" 2>&1
}

: >| "$MARK"
out=$(detach_run) || true
[[ -s "$MARK" ]] && pass "detach went through the systemd-run stub (no real unit)" \
                 || fail "systemd-run stub was NOT used — aborting:\n$out"
have "$out" 'detached as systemd --user unit' && pass "detach reports the unit" || fail "no detach line:\n$out"
# This harness is not a tty, so the handoff must decline rather than block.
have "$out" 'not a tty' && pass "non-tty declines the monitor instead of blocking" || fail "no tty guard:\n$out"
[[ -s "$MONMARK" ]] && fail "monitor was started from a non-tty" || pass "monitor not started from a non-tty"

: >| "$MARK"
out=$(detach_run --no-monitor) || true
[[ -s "$MARK" ]] && pass "--no-monitor still detaches" || fail "--no-monitor broke detach:\n$out"
have "$out" 'not a tty' && fail "--no-monitor still probed for a tty:\n$out" \
                        || pass "--no-monitor skips the handoff entirely"

out=$(PATH="$BIN:$PATH" ARACHNE_PUMP_MONITOR=0 ARACHNE_MONITOR_BIN="$BIN/fake-monitor" \
      ARACHNE_PUMP_STATE_FILE="$TMP/detach.state" ARACHNE_PUMP_LOG="$TMP/detach2.log" \
      ARACHNE_TASKS_DIR="$TASKS" timeout 60 "$PUMP" --phases F98 --detach 2>&1) || true
have "$out" 'not a tty' && fail "ARACHNE_PUMP_MONITOR=0 ignored:\n$out" \
                        || pass "ARACHNE_PUMP_MONITOR=0 opts out"
have "$(sed -n '2,60p' "$PUMP")" 'no-monitor' && pass "--no-monitor is documented in --help" \
                                              || fail "--no-monitor missing from the help block"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
