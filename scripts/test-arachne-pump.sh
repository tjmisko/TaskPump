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

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
