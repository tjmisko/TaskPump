#!/usr/bin/env bash
# test-arachne-pump.sh — dry-run fixture harness for scripts/arachne-pump.
#
# Per the F64.3 test plan: exercise the planning logic over a synthetic tasks dir
# with a cross-phase blocker — initial frontier, a cross-phase gate releasing, the
# docker-ps liveness join (stub `docker ps`), and the usage gate (stub
# arachne-usage). No real launch / build / ops mutation (that is F64.6's job).
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PUMP="$TP_ROOT/libexec/tp-pump"
REAL_TASK="$TP_ROOT/libexec/tp-task"

# Hermeticity: the shared prologue ignores any taskpump.conf in the repo this
# suite happens to run from — a leaked conf reconfigures every fixture
# invocation below. From TaskPump's own dogfood conf that leak once failed 37
# range parses (TASKPUMP_PHASE_SIGIL=G vs the F fixtures) and hung Test 13,
# whose gate-less integration ticks eval'd the conf's
# TASKPUMP_BUILD_GATE='./tests/run-all.sh' — re-entering the whole suite
# unboundedly. The prologue also scrubs the pump-exported
# TASKPUMP_*/TP_*/ARACHNE_* environment (issue #18: an inherited canonical
# TASKPUMP_TASKS_DIR silently outranks the legacy ARACHNE_TASKS_DIR this suite
# sets — most of that incident's spurious failures were in this suite).
# run-all.sh sources the same prologue; this covers standalone runs.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

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

# Reference pins (G1.2): the fixtures below are Arachne-shaped — F-grammar ids
# and arachne-agent-* container names in the docker stubs. Those spellings used
# to arrive through the tools' baked defaults; the v0.1.0 flips (G1.5 agent
# prefix, G1.6 id grammar) retire them, so they are pinned here with the
# examples/arachne.conf values. Tests that drive OTHER spellings (Test 20's
# tp-agent- prefix, Test 29's G sigil) override these per invocation, which is
# exactly how a differently-shaped consumer would.
export TASKPUMP_ID_PATTERN='^F[0-9]+(\.[0-9]+)?$'
export TASKPUMP_PHASE_SIGIL=F
export TASKPUMP_AGENT_PREFIX=arachne-agent-

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
# The default pre-tick chain, read out of the pump rather than re-listed here.
default_hooks_of_pump() { sed -n '/^default_pre_tick_hooks()/,/^}/p' "$PUMP"; }

# Contiguous range F55..F57 (no phase gaps), with a cross-phase blocker:
#   F55.0 root → F55.1 (in-phase dep) ; F56.0 root ; F57.0 waits on F55.1 (cross-phase)
mk F55.0 open
mk F55.1 open F55.0
mk F56.0 open
mk F57.0 open F55.1

echo "--- Test 1: initial frontier (.0 roots launch; cross-phase-gated phase waits) ---"
out=$(pump F55..F57)
# Bare default: the plan header identifies as tp-pump (G1.4). The reference
# consumer keeps `arachne-pump plan` via the TASKPUMP_PUMP_PROG_NAME pin in
# examples/arachne.conf, which test-golden-plan.sh holds byte-identical.
have "$out" '^tp-pump plan — phases F55\.\.F57' && pass "bare-default plan header identifies as tp-pump" \
  || fail "plan header not tp-pump:\n$out"
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
  # still override TASKPUMP_NOTIFY_CMD to capture, as the drain test does.
  TASKPUMP_NOTIFY_CMD="${TASKPUMP_NOTIFY_CMD:-true}" \
  ARACHNE_PUMP_NO_LAUNCH=1 \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  ARACHNE_PUMP_STATE_FILE="$STATE" \
  ARACHNE_POOL_CAP_FILE="$TMP/cap" \
  ARACHNE_PUMP_LOG="$TMP/pump.log" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate "${@:2}" --phases "$1"
}

# 8a: a --once tick records the range and — issue #22 — exits with a TERMINAL
# status. do_tick's last write is `running`, and leaving that behind after the
# process dies is exactly the G3 incident, so the tail stamps `stopped`.
mk F55.0 open; mk F55.1 open F55.0; mk F56.0 open; mk F57.0 open F55.1
STUB_GATE_RC=0 pump_tick F55..F57 --once >/dev/null 2>&1
[[ "$(jq -r '.phases' "$STATE" 2>/dev/null)" == "F55..F57" ]] && pass "state.phases = F55..F57" || fail "state.phases: $(cat "$STATE" 2>/dev/null)"
[[ "$(jq -r '.status' "$STATE" 2>/dev/null)" == "stopped" ]] && pass "state.status = stopped after a feeding --once tick (never running, #22)" || fail "state.status not stopped: $(cat "$STATE" 2>/dev/null)"
have "$(jq -r '.paused_reason // empty' "$STATE" 2>/dev/null)" 'single tick' && pass "stop reason names the --once exit" || fail "stop reason missing: $(cat "$STATE" 2>/dev/null)"
[[ "$(jq -r '.pid // empty' "$STATE" 2>/dev/null)" =~ ^[0-9]+$ ]] && pass "state carries the pump's pid (#22 liveness anchor)" || fail "no pid in state: $(cat "$STATE" 2>/dev/null)"

# 8b: a gated --once tick also exits terminal, but the gate's pause reason is
# carried into the stop reason so the tick stays diagnosable from the file.
STUB_GATE_RC=10 pump_tick F55..F57 --once >/dev/null 2>&1
[[ "$(jq -r '.status' "$STATE" 2>/dev/null)" == "stopped" ]] && pass "gated --once still exits terminal (stopped, not paused)" || fail "state.status not stopped: $(cat "$STATE" 2>/dev/null)"
have "$(jq -r '.paused_reason // empty' "$STATE" 2>/dev/null)" 'paused' && pass "stop reason preserves the gate pause" || fail "gate pause lost from stop reason: $(jq -r '.paused_reason' "$STATE" 2>/dev/null)"

# 8c: a fully-drained range exits → status=drained + one notification.
mk F55.0 done; mk F55.1 done; mk F56.0 done; mk F57.0 done
STUB_GATE_RC=0 TASKPUMP_NOTIFY_CMD="tee -a $NOTIFY" pump_tick F55..F57 >/dev/null 2>&1
[[ "$(jq -r '.status' "$STATE" 2>/dev/null)" == "drained" ]] && pass "state.status = drained when range empties" || fail "state.status not drained: $(cat "$STATE" 2>/dev/null)"
grep -qi 'drained' "$NOTIFY" && pass "drain notification fired via TASKPUMP_NOTIFY_CMD" || fail "no drain notification: $(cat "$NOTIFY" 2>/dev/null)"

# 8d: restart detection logs a resume for the same range.
out=$(STUB_GATE_RC=0 pump_tick F55..F57 --once 2>&1 >/dev/null; STUB_GATE_RC=0 pump_tick F55..F57 --once 2>&1)
grep -qi "resuming pump for F55..F57" <<<"$out" && pass "restart detection logs resume for same range" || fail "no resume log:\n$out"

# 8e: a configured notify command that FAILS is reported, never swallowed
# (issue #35). The two delivery channels take the message differently on
# purpose — a configured command reads it on stdin, the notify-send fallback
# gets it as argv — which is how a plausible pin (`notify-send -u low`, which
# wants a summary argument and never reads stdin) errors on every notice. With
# the status discarded, the pump looked like it had notified for a whole drain.
#
# The pre-tick chain is pinned to stubs throughout 8e. Left at the default it
# is the fs-guard, whose output depends on how dirty the checkout running this
# suite happens to be, and whose change-fingerprint dedup carries state from
# test 8a — so the count assertion below would answer for the host's tree
# rather than for the drain.
cat >| "$BIN/hook-quiet" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# A pre-tick hook with a lot to say — a dirty tree with thousands of paths in
# it — so that its notification is larger than the 64KiB pipe buffer.
cat >| "$BIN/hook-flood" <<'EOF'
#!/usr/bin/env bash
printf 'fs-guard: untracked path %s\n' $(seq 1 8000)
EOF
chmod +x "$BIN/hook-quiet" "$BIN/hook-flood"

mk F55.0 done; mk F55.1 done; mk F56.0 done; mk F57.0 done
# The value is a command line, and a webhook notifier keeps its token in the
# arguments (`curl -sS -f -d @- https://hooks…/SECRET`); the stand-in below is
# shaped like one so the warning has something to leak.
err=$(STUB_GATE_RC=0 TASKPUMP_PRE_TICK_HOOKS="$BIN/hook-quiet" \
      TASKPUMP_HOOK_MARK_FILE="$TMP/8e.mark" \
      TASKPUMP_NOTIFY_CMD="false https://hooks.example/T0/B0/s3cret-t0ken" \
      pump_tick F55..F57 2>&1 >/dev/null)
have "$err" 'notify command failed' \
  && pass "should report the drop when the configured notify command fails" \
  || fail "a failing TASKPUMP_NOTIFY_CMD was swallowed:\n$err"
have "$err" 'notify command failed \(exit 1\): false' \
  && pass "should name the program and its exit status when reporting the drop" \
  || fail "the warning does not name the failing command and status:\n$err"
# Under --detach the pump's stderr is persisted for the life of the run (the
# unit's journal, or $PUMP_LOG), so the warning names the program and stops
# there rather than copying a secret out of the command line.
have "$err" 's3cret-t0ken' \
  && fail "the warning echoed the notify command's arguments into the log:\n$err" \
  || pass "should keep the notify command's arguments out of the log when reporting the drop"
[[ "$(grep -c 'notify command failed' <<<"$err")" -eq 1 ]] \
  && pass "should warn once per dropped notification when a drain fires one" \
  || fail "expected one warning per dropped notification:\n$err"
# The delivered case must stay silent: a warning on every successful notify
# would train an operator to ignore the line that matters.
err=$(STUB_GATE_RC=0 TASKPUMP_PRE_TICK_HOOKS="$BIN/hook-quiet" \
      TASKPUMP_HOOK_MARK_FILE="$TMP/8e.mark" TASKPUMP_NOTIFY_CMD="tee -a $NOTIFY" \
      pump_tick F55..F57 2>&1 >/dev/null)
have "$err" 'notify command failed' \
  && fail "a delivered notification still warned:\n$err" \
  || pass "should stay silent when the notify command delivers"
# …and so must the command that exits 0 without ever reading the message:
# `true`, which docs/CONFIG.md names as the way to silence notifications, and
# every argv-style notifier (`notify-send TaskPump`, terminal-notifier) that
# really does deliver. Carried on a pipeline the writer takes a SIGPIPE from
# the notifier's early exit, pipefail hands that 141 to the caller, and the
# pump names a drop that did not happen. The flood hook is what makes that
# deterministic instead of a 1-in-100 flake: a notification bigger than the
# pipe buffer blocks the writer until the non-reading notifier is gone.
err=$(STUB_GATE_RC=0 TASKPUMP_NOTIFY_CMD=true \
      TASKPUMP_PRE_TICK_HOOKS="$BIN/hook-flood" TASKPUMP_HOOK_MARK_FILE="$TMP/8e-flood.mark" \
      pump_tick F55..F57 2>&1 >/dev/null)
have "$err" 'notify command failed' \
  && fail "a notifier that exited 0 without reading the message was called a drop:\n$(grep 'notify command failed' <<<"$err")" \
  || pass "should stay silent when the notify command exits 0 without reading the message"

# 8f: the value the tree hands an operator to COPY has to survive the same
# contract. `notify-send -u low` was the shipped syntax example in
# docs/CONFIG.md and taskpump.conf.example — argv-style, so once 8e stopped
# swallowing the status it warned on every notice and delivered nothing, which
# is the shape examples/arachne.conf already records having lived through. The
# examples are re-read out of those files rather than restated here, so a
# rewrite that reintroduces an argv-style value fails on the value's own
# behaviour instead of on a grep for one spelling.
#
# Every program a documented value names is stubbed, and every stub appends what
# it was handed to one record, so the question this asks is the one the harness
# can answer: did the message the pump wrote to stdin reach the notifier's own
# hands. Whether the notifier's own back end is reachable — a session bus for
# notify-send, a syslog socket for logger — is a property of the host, not of
# the value, and is docs/CONFIG.md §3.2's to state rather than this suite's to
# assert.
NBIN="$TMP/notify-bin"; mkdir -p "$NBIN"
NREC="$TMP/notify.record"
# Faithful where it matters: the real notify-send takes its summary from argv,
# never reads stdin, and exits 1 with exactly this line when argv carries none.
# The short options that consume an argument are spelled out because a stub that
# swallowed a summary as an option's value would fail a value libnotify accepts.
cat >| "$NBIN/notify-send" <<EOF
#!/usr/bin/env bash
REC="$NREC"
EOF
cat >> "$NBIN/notify-send" <<'EOF'
pos=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|-t|-a|-i|-n|-c|-h|-r|-A) shift 2 ;;
    -*) shift ;;
    *) pos+=("$1"); shift ;;
  esac
done
[[ ${#pos[@]} -ge 1 ]] || { echo "No summary specified." >&2; exit 1; }
printf '%s\n' "${pos[*]}" >> "$REC"
exit 0
EOF
chmod +x "$NBIN/notify-send"

# logger(1) is the other half of the same contract and the headless value the
# docs now lead with, so it is stubbed on the same terms: util-linux's logger
# takes the message from argv when argv carries one and reads stdin only when it
# does not, which is the distinction this whole test exists to police. Stubbed
# rather than real because the real one needs a syslog socket, and a suite that
# passed or failed on whether the host runs a journal would be measuring the
# host.
cat >| "$NBIN/logger" <<EOF
#!/usr/bin/env bash
REC="$NREC"
EOF
cat >> "$NBIN/logger" <<'EOF'
pos=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|-p|-n|-u|-f|-P|--tag|--priority) shift 2 ;;
    --) shift; pos+=("$@"); break ;;
    -*) shift ;;
    *) pos+=("$1"); shift ;;
  esac
done
if [[ ${#pos[@]} -gt 0 ]]; then printf '%s\n' "${pos[*]}" >> "$REC"; else cat >> "$REC"; fi
exit 0
EOF
chmod +x "$NBIN/logger"

notify_examples() {  # notify_examples <file> → each documented value, once, one per line
  local match value
  # sort -u because a file documents one value in more than one place — the
  # syntax example and the key's own entry — and that is one value to check.
  while IFS= read -r match; do
    value="${match#TASKPUMP_NOTIFY_CMD=}"
    value="${value#\'}"; value="${value%\'}"
    printf '%s\n' "$value"
  done < <(grep -oE "TASKPUMP_NOTIFY_CMD='[^']+'|TASKPUMP_NOTIFY_CMD=[^ '\"#]+" "$1") | sort -u
}

# One drained tick per documented value; the record is what the stub was
# actually handed, so "delivered" is answered by the notifier, not by the pump.
notify_tick() {  # notify_tick <value> → the pump's stderr; delivery lands in $NREC
  local value="$1"
  : >| "$NREC"
  PATH="$NBIN:$PATH" STUB_GATE_RC=0 \
    TASKPUMP_PRE_TICK_HOOKS="$BIN/hook-quiet" TASKPUMP_HOOK_MARK_FILE="$TMP/8f.mark" \
    TASKPUMP_NOTIFY_CMD="$value" \
    pump_tick F55..F57 2>&1 >/dev/null
}

mk F55.0 done; mk F55.1 done; mk F56.0 done; mk F57.0 done
# A guard that has never been shown to go red is not a guard: the pre-fix
# example goes through the same harness first.
err=$(notify_tick 'notify-send -u low')
if have "$err" 'notify command failed' && ! grep -q 'drained' "$NREC"; then
  pass "control: the pre-fix example ('notify-send -u low') still loses the drain notice and says so"
else
  fail "control: the stubbed notify-send swallowed an argv-style value with no summary — the harness cannot go red"
fi

for conf_doc in "$TP_ROOT/docs/CONFIG.md" "$TP_ROOT/taskpump.conf.example"; do
  rel="${conf_doc#"$TP_ROOT"/}"
  n=0
  while IFS= read -r example; do
    n=$((n + 1))
    err=$(notify_tick "$example")
    if have "$err" 'notify command failed'; then
      fail "$rel documents TASKPUMP_NOTIFY_CMD='$example', which the pump reports as a dropped notification:\n$(grep 'notify command failed' <<<"$err")"
    elif [[ "$example" == true ]]; then
      # `true` is the documented silencer, not a delivery command: what it owes
      # is silence, and 8e above owns the reason that silence must not be a warning.
      pass "should stay silent when TASKPUMP_NOTIFY_CMD is the silencer $rel documents (true)"
    elif grep -q 'drained' "$NREC"; then
      pass "should hand the drain notice to its notifier when TASKPUMP_NOTIFY_CMD is the value $rel documents ($example)"
    else
      # Only the notifiers the docs name are stubbed, so this arm cannot tell a
      # value that drops the message from one that delivers it through some
      # other program; it says so rather than naming a cause it did not
      # establish.
      fail "$rel documents TASKPUMP_NOTIFY_CMD='$example', which exits 0 but never handed the message to a notifier this harness stubs (notify-send, logger) — either the value drops what the pump feeds it on stdin, or it delivers through a program this harness does not stub yet"
    fi
  done < <(notify_examples "$conf_doc")
  [[ "$n" -ge 1 ]] && pass "$rel still carries a TASKPUMP_NOTIFY_CMD example to check ($n)" \
    || fail "$rel documents no TASKPUMP_NOTIFY_CMD value any more — this guard now verifies nothing"
done

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

# 9d: a disk-gated --once tick exits terminal (#22) with the disk reason
# carried into the stop reason — the pause must survive the terminal stamp.
mk F55.0 open; mk F55.1 open F55.0; mk F56.0 open; mk F57.0 open F55.1
STUB_GATE_RC=0 STUB_DISK_GATE_RC=10 pump_tick F55..F57 --once >/dev/null 2>&1
[[ "$(jq -r '.status' "$STATE" 2>/dev/null)" == "stopped" ]] && pass "disk-gated --once exits terminal (stopped)" || fail "status not stopped on disk gate: $(cat "$STATE" 2>/dev/null)"
have "$(jq -r '.paused_reason // empty' "$STATE" 2>/dev/null)" 'disk gate' && pass "stop reason names the disk gate" || fail "stop reason missing disk gate: $(jq -r '.paused_reason' "$STATE" 2>/dev/null)"

echo "--- Test 10: reclaim sweep cleans completed-phase target/ dirs (A4 / F65.3) ---"
WT="$TMP/wt"; STATE10="$TMP/pump10.state"
plant_target() {  # fake done-phase worktree with a target/ dir + sentinel
  rm -rf "$WT"; mkdir -p "$WT/feat/f56/target"
  echo sentinel >| "$WT/feat/f56/target/sentinel"
}
reclaim_tick() {  # one real tick with the reclaim sweep active, fixture-wired
  PATH="$BIN:$PATH" \
  TASKPUMP_NOTIFY_CMD="${TASKPUMP_NOTIFY_CMD:-true}" \
  ARACHNE_PUMP_WORKTREES_DIR="$WT" \
  ARACHNE_PUMP_NO_LAUNCH=1 \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  ARACHNE_PUMP_STATE_FILE="$STATE10" \
  ARACHNE_POOL_CAP_FILE="$TMP/cap" \
  ARACHNE_PUMP_LOG="$TMP/pump.log" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate "$@"
}

# 10a: a PLAN_DONE phase (all tasks done) with no live container → target
# reclaimed via the CONFIGURED command. There is no built-in fallback: the key
# names the consumer's own reclaim (G1.7 retired the cargo one).
mk F56.0 done; plant_target
out=$(STUB_GATE_RC=0 ARACHNE_DISK_RECLAIM=1 TASKPUMP_RECLAIM_CMD='rm -rf target' \
  reclaim_tick --phases F56 --once 2>&1)
[[ ! -d "$WT/feat/f56/target" ]] && pass "reclaim removed F56 target/ on a DONE tick" || fail "F56 target/ survived reclaim:\n$out"
have "$out" 'reclaimed F56' && pass "reclaim logged 'reclaimed F56'" || fail "no reclaim log line:\n$out"

# 10a': no TASKPUMP_RECLAIM_CMD → the pass is a no-op that says so (G1.7).
plant_target
out=$(STUB_GATE_RC=0 ARACHNE_DISK_RECLAIM=1 reclaim_tick --phases F56 --once 2>&1)
[[ -d "$WT/feat/f56/target" ]] && pass "unconfigured reclaim pass touches nothing" \
  || fail "target/ removed with no reclaim command configured:\n$out"
have "$out" 'TASKPUMP_RECLAIM_CMD unconfigured' && pass "unconfigured reclaim pass logs the no-op line" \
  || fail "no unconfigured log line:\n$out"

# 10b: ARACHNE_DISK_RECLAIM=0 → reclaim disabled, target survives.
plant_target
STUB_GATE_RC=0 ARACHNE_DISK_RECLAIM=0 TASKPUMP_RECLAIM_CMD='rm -rf target' reclaim_tick --phases F56 --once >/dev/null 2>&1
[[ -d "$WT/feat/f56/target" ]] && pass "ARACHNE_DISK_RECLAIM=0 leaves target/ intact" || fail "target removed despite RECLAIM=0"

# 10c: a live container for F56 → target survives even though open_count=0.
plant_target
STUB_GATE_RC=0 ARACHNE_DISK_RECLAIM=1 TASKPUMP_RECLAIM_CMD='rm -rf target' STUB_LIVE="arachne-agent-feat-f56" reclaim_tick --phases F56 --once >/dev/null 2>&1
[[ -d "$WT/feat/f56/target" ]] && pass "live-phase target/ never reclaimed (phase_live guard)" || fail "live phase target/ was reclaimed"

echo "--- Test 11: the read-only-primary mount, now the runner's to keep ---"
# Static guard against a blanket-RW $REPO_ROOT regression: a container that can
# write the primary checkout is how a past run silently corrupted the shared
# tree. The mounts moved out of the pump and into the runner when launching
# became a seam, so the guard follows them there.
# Overridable so this guard can be validated against the runner while it still
# lives on another branch (git show gen/runner:runners/... > /tmp/runner.sh).
RUNNER_SH="${TEST_RUNNER_SH:-$TP_ROOT/runners/claude-docker/runner.sh}"
# The runner holds the repo root in a LOWER-CASE local: `local REPO_ROOT` would
# blank the inherited value before the legacy fallback could read it. So each
# pattern accepts either spelling rather than pinning one.
assert_mounts() {  # <launcher-path> <label>
  local f="$1" label="$2"
  local root='\$(TP_REPO_ROOT|REPO_ROOT|repo_root)'
  local work='\$(TP_WORKSPACE|WORKSPACE_PATH|workspace|wt)'
  local ledger='\$(TP_LEDGER_REPO|ledger_repo|(TP_REPO_ROOT|REPO_ROOT|repo_root)/ops)'
  grep -qE -- "-v +\"?$root\"?:\"?$root\"?:ro" "$f" \
    && pass "$label: :ro primary mount present" || fail "$label: missing :ro primary mount"
  grep -qE -- "-v +\"?$root/\\.git\"?:" "$f" \
    && pass "$label: .git RW overlay present" || fail "$label: missing .git RW overlay"
  grep -qE -- "-v +\"?$work\"?:" "$f" \
    && pass "$label: worktree RW overlay present" || fail "$label: missing worktree RW overlay"
  grep -qE -- "-v +\"?$ledger\"?:" "$f" \
    && pass "$label: ledger RW overlay present" || fail "$label: missing ledger RW overlay"
  # The terminator must be whitespace, a line continuation, or end of line.
  # A bare [^:] backtracks: it lets the optional closing quote match empty and
  # then matches the quote itself, so the legitimate `:"$root":ro` line reads as
  # a blanket mount. Verified in both directions against the real runner.
  if grep -qE -- "-v +\"?$root\"?:\"?$root\"?([[:space:]\\\\]|\$)" "$f"; then
    fail "$label: blanket RW primary mount re-introduced"
  else
    pass "$label: no blanket RW primary mount"
  fi
  # G4.3: the TaskPump installation rides into the container read-only at
  # /opt/taskpump so tp is on the agent's PATH. Read-only is load-bearing —
  # an agent that can write /opt/taskpump edits the supervisor supervising it.
  grep -qE -- '-v +"?\$tp_install_root"?:/opt/taskpump:ro' "$f" \
    && pass "$label: TaskPump installation mounted :ro at /opt/taskpump (G4.3)" \
    || fail "$label: missing the :ro /opt/taskpump installation mount"
  if grep -vE '^[[:space:]]*#' "$f" | grep -qE -- ':/opt/taskpump([[:space:]]|$)'; then
    fail "$label: /opt/taskpump mounted read-write (must be :ro)"
  else
    pass "$label: no RW /opt/taskpump mount"
  fi
}
if [[ -f "$RUNNER_SH" ]]; then
  assert_mounts "$RUNNER_SH" "claude-docker runner"
else
  # The runner is built alongside this change on its own branch; until the two
  # are integrated there is nothing here to read.
  printf 'SKIP: mount guard — no runner at %s yet (lands on integration)\n' "$RUNNER_SH"
fi
# The pump must no longer carry mounts of its own: launching is the runner's.
grep -qE -- '-v +"' "$PUMP" && fail "the pump still mounts things itself" \
  || pass "the pump carries no container mounts"

echo "--- Test 12b: the runner contract the pump exports ---"
# The runner is a separate process, so every one of these has to be in the
# environment. A name dropped here is a silent, launch-time-only failure.
for v in TP_WORKSPACE TP_BRANCH TP_CONTAINER_NAME TP_IMAGE TP_ENTRYPOINT TP_TASK_ID \
         TP_PHASE TP_MODEL TP_MAX_TURNS TP_REPO_ROOT TP_BRIEF TP_RESUME_NOTE \
         TP_LEDGER_REPO TP_CLAUDE_DIR TP_CLAUDE_JSON TP_MEMORY_MAX TP_MEMORY_SWAP \
         TP_DOCKER TP_AGENT_LOG_NAME TP_GOAL_NOTE_NAME TP_TASKS_DIR; do
  grep -qF "$v=" "$PUMP" && pass "runner contract exports $v" || fail "runner contract missing $v"
done
# The legacy twins the in-container entrypoint still reads.
for v in WORKSPACE_PATH REPO_ROOT ARACHNE_BRIEF ARACHNE_RESUME_NOTE ARACHNE_TASK_ID \
         ARACHNE_PHASE MAX_TURNS AGENT_MODEL AGENT_MEMORY_MAX AGENT_MEMORY_SWAP \
         CLAUDE_DIR CLAUDE_JSON GITHUB_TOKEN; do
  grep -qF "$v=" "$PUMP" && pass "runner contract keeps the legacy $v" || fail "legacy twin missing: $v"
done

echo "--- Test 12: apl_fs_guard flags primary-source dirt, ignores allowlist (F65.5) ---"
# shellcheck source=../lib/pump-lib.sh
source "$TP_ROOT/lib/pump-lib.sh"
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
  TASKPUMP_NOTIFY_CMD="${TASKPUMP_NOTIFY_CMD:-true}" \
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

# 13g: a DONE lead is never un-completed by a bad merge. The quarantine flag
# says "reconcile feat/fN by hand", and a phase whose last task already
# completed has no eligible lead — phase_lead_task returns nothing and the
# fallback names <phase>.0, which by then is done. Flipping it to needs-review
# tells the ledger that finished work is unfinished, and (with the resume path
# armed) hands a fresh agent a task that has nothing left to do. The broken
# thing is the merge.
# Its own phase, so the drained state is the fixture's and not a leftover.
: >| "$QFILE"
mk F59.0 done
out=$(STUB_GATE_RC=0 STUB_INTEGRATE_CONFLICT="F59" itick F59 2>&1)
have "$out" 'would quarantine F59: conflict' && pass "a drained phase's conflict still quarantines" \
  || fail "no quarantine for a drained phase:\n$out"
have "$out" 'would needs-review F59\.0' && fail "a done lead was flipped to needs-review:\n$out" \
  || pass "a done lead is never flipped to needs-review"
have "$out" 'would leave F59\.0 done' && pass "and the log says the merge is what is broken" \
  || fail "no explanation:\n$out"
grep -qE '^F59 .*conflict$' "$QFILE" && pass "the marker is still written for the human" \
  || fail "no marker:\n$(cat "$QFILE")"
rm -f "$TASKS/F59.0.md"

# 13f: --integration-trunk OFF ⇒ no integration whatsoever (opt-out regression).
: >| "$QFILE"
out=$(STUB_GATE_RC=0 ARACHNE_PUMP_BUILD_CMD='false' \
  TASKPUMP_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 ARACHNE_PUMP_INTEGRATE_DRYRUN=1 \
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
#
# Every stub that a tick can reach MUST answer --git-common-dir with a real
# directory inside the fixture, matched before any catch-all: the worktree
# visibility guard resolves the answer and heals that git dir's info/exclude,
# so a fallthrough answer (a HEAD sha, or nothing) once made it manufacture
# <answer>/info/exclude trees in the REAL repo the suite ran from (issue #20).
STUB_GIT_COMMON="$TMP/stub-git-common"; mkdir -p "$STUB_GIT_COMMON"
export STUB_GIT_COMMON
cat >| "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--git-common-dir*) echo "${STUB_GIT_COMMON:?}";;
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
  PATH="$BIN:$PATH" TASKPUMP_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 \
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

# 17e: liveness went dark → reclaim does NOTHING. The absence-driven passes read
# "no live agents" from a source that has failed exactly as they read it from a
# fleet that has died, and a runner-backed pump answering for a non-container
# runner gets an EMPTY fallback scrape — so one bad tick would release every
# claim in the range and put every phase on the resume path. Skipping costs a
# tick of latency on a genuinely dead agent; acting costs the fleet.
cat >| "$BIN/runner-v2-broken" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) echo "runner.sh: cannot list agents (rc=1): daemon unreachable" >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
# The control: same shape, but it answers. An empty answer from a runner that
# ANSWERED is authoritative, and reclaim must still run — a guard that cannot
# tell these apart would strand orphaned claims forever.
cat >| "$BIN/runner-v2-empty" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/runner-v2-broken" "$BIN/runner-v2-empty"

mkclaim F95.1 feat/f95
err=$(TASKPUMP_RUNNER="$BIN/runner-v2-broken" STUB_LIVE="" STUB_AHEAD=0 claim_tick F95 2>&1 >/dev/null)
[[ "$(status_of F95.1)" == "in_progress" ]] \
  && pass "degraded liveness reclaims nothing (no mass release on a blind tick)" \
  || fail "F95.1 was reclaimed on a blind liveness tick: $(status_of F95.1)"
have "$err" 'runner liveness unavailable' \
  && pass "the blind tick says so, once" \
  || fail "no degraded-liveness warning:\n$err"

# 17f: the same runner, answering an empty fleet → reclaim runs as before.
mkclaim F95.1 feat/f95
out=$(TASKPUMP_RUNNER="$BIN/runner-v2-empty" STUB_LIVE="" STUB_AHEAD=0 claim_tick F95 2>/dev/null)
[[ "$(status_of F95.1)" == "open" ]] \
  && pass "an authoritative empty fleet still reclaims the orphaned claim" \
  || fail "reclaim stopped working behind the degraded guard: status=$(status_of F95.1)"

# 17g: the runner is the liveness source, not `docker ps`. The runtime shows
# nothing; the runner reports the agent alive; the claim must survive. This is
# the whole point of the delegation — a non-container runner's agents are
# invisible to a container scrape.
cat >| "$BIN/runner-v2-live" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) printf '%s\n' "arachne-agent-feat-f95"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/runner-v2-live"
mkclaim F95.1 feat/f95
TASKPUMP_RUNNER="$BIN/runner-v2-live" STUB_LIVE="" STUB_AHEAD=0 claim_tick F95 >/dev/null 2>&1
[[ "$(status_of F95.1)" == "in_progress" ]] \
  && pass "an agent only the runner can see is not reclaimed" \
  || fail "an agent the runner reported live was reclaimed: $(status_of F95.1)"

echo "--- Test 18: scrub integrity findings reach the pump log with their paths ---"
# do_tick used to run `scrub >/dev/null 2>&1 || warn "scrub failed (continuing)"`,
# which threw away the only actionable detail — which file is invisible — and
# could not tell a corrupt ledger from scrub itself crashing.
STATE18="$TMP/pump18.state"
tick18() {
  TASKPUMP_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 \
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
# log --oneline (the resume note's commit list). Order matters: --verify and
# --git-common-dir must be matched before the bare rev-parse arm — the bare
# arm's sha answer once became a directory the visibility guard manufactured
# in the real repo the suite ran from (issue #20).
cat >| "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--git-common-dir*)   echo "${STUB_GIT_COMMON:?}" ;;
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
  PATH="$BIN:$PATH" TASKPUMP_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 \
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
out=$(PATH="$BIN:$PATH" TASKPUMP_NOTIFY_CMD=true ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
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
out=$(PATH="$BIN:$PATH" TASKPUMP_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 \
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
have "$("$PUMP" --help)" 'no-monitor' && pass "--no-monitor is documented in --help" \
                                      || fail "--no-monitor missing from the help block"

echo "--- Test 20: naming and layout knobs, all defaulting to today's values ---"
mk F55.0 open; mk F55.1 open F55.0; mk F56.0 open; mk F57.0 open F55.1
# Branch and container naming are what join the ledger, the worktrees, and the
# live-container check. They used to be literals in five places each.
out=$(pump F56)
have "$out" 'LAUNCH +F56 +-> feat/f56' && pass "default branch prefix is feat/" \
  || fail "default branch naming changed:\n$out"
out=$(TASKPUMP_BRANCH_PREFIX="epic/" pump F56)
have "$out" 'LAUNCH +F56 +-> epic/f56' && pass "TASKPUMP_BRANCH_PREFIX renames the branch" \
  || fail "branch prefix override ignored:\n$out"
# A live container is matched through the same prefix, so renaming one without
# the other must not silently mark a running phase launchable.
out=$(STUB_LIVE="tp-agent-feat-f56" TASKPUMP_AGENT_PREFIX="tp-agent-" pump F56)
have "$out" 'RUNNING +F56' && pass "TASKPUMP_AGENT_PREFIX drives the liveness join" \
  || fail "agent prefix override ignored:\n$out"
out=$(STUB_LIVE="tp-agent-feat-f56" pump F56)
have "$out" 'LAUNCH +F56' && pass "a container under another prefix is not ours" \
  || fail "foreign container claimed as ours:\n$out"

echo "--- Test 21: brief-template resolution — configured, then shipped, and nothing else ---"
# Two rungs, and only two. A ledger-side ops/task-loop/briefs/_phase-drain-template.md
# used to be probed between them, so a project that dropped a file at that path
# had its briefs quietly replaced without ever configuring anything — and every
# project that did NOT use that one consumer's directory layout carried a rung
# whose path could not exist, advertised in the not-found message as somewhere it
# had looked (issue #37). A consumer that wants its own prose says so, the way
# examples/arachne.conf now does.
RES="$TMP/resolve"; mkdir -p "$RES/ops/task-loop/briefs"
printf 'consumer template for {{PHASE}}\n' >| "$RES/ops/task-loop/briefs/_phase-drain-template.md"
out=$(ARACHNE_PUMP_OPS_DIR="$RES/ops" "$PUMP" --render-brief F55 2>&1)
grep -qF 'consumer template for F55' <<<"$out" \
  && fail "should ignore a ledger-side _phase-drain-template.md when no template is configured: '$out'" \
  || pass "should ignore a ledger-side _phase-drain-template.md when no template is configured"
grep -qF 'drain phase F55' <<<"$out" \
  && pass "should render the shipped brief when the ledger carries an unconfigured template" \
  || fail "shipped brief did not render over the ledger-side file:\n$out"
printf 'explicit template for {{PHASE}}\n' >| "$TMP/explicit.md"
out=$(ARACHNE_PUMP_OPS_DIR="$RES/ops" TASKPUMP_BRIEF_TEMPLATE="$TMP/explicit.md" \
      "$PUMP" --render-brief F55 2>&1)
[[ "$out" == "explicit template for F55" ]] && pass "explicit config outranks the shipped brief" \
  || fail "explicit template not chosen: '$out'"
# No template at all used to be a hard die, which left a fresh project unable to
# run until it wrote one. It now falls through to the shipped default.
out=$(ARACHNE_PUMP_OPS_DIR="$TMP/no-such-ops" "$PUMP" --render-brief F55 2>&1)
grep -qF 'F55' <<<"$out" && pass "a project with no template falls back to the shipped one" \
  || fail "shipped fallback did not render:\n$out"
grep -qiF 'not found' <<<"$out" && fail "still dying on a missing template:\n$out" \
  || pass "no hard die on a missing template"
# The not-found message is the operator's map of the resolution order. Listing a
# rung the code no longer walks sends them to author a file that will never be
# read — the same wrong answer as the dead probe, printed instead of executed.
out=$(ARACHNE_PUMP_OPS_DIR="$RES/ops" TASKPUMP_BRIEF_TEMPLATE="$TMP/no-such-template.md" \
      "$PUMP" --render-brief F55 2>&1)
grep -qF 'task-loop/briefs' <<<"$out" \
  && fail "should not name the deleted ledger rung when the configured brief is missing:\n$out" \
  || pass "should not name the deleted ledger rung when the configured brief is missing"
grep -qF 'templates/phase-drain-brief.md' <<<"$out" \
  && pass "should name the shipped brief when the configured one is missing" \
  || fail "the not-found message does not name the shipped brief:\n$out"

echo "--- Test 22: TASKPUMP_STATE_DIR relocates the run's dotfiles ---"
# The state-file NAME is pinned so that half tests relocation, not the default
# spelling (the .arachne-* filename defaults flipped to .taskpump-* in G1.3).
# The pool cap has no name-in-state-dir key — an explicit TASKPUMP_POOL_CAP_FILE
# is a path resolved against the cwd — so the cap assertion necessarily reads
# the bare default name, .taskpump-pool-cap since the G1.3 flip.
SD="$TMP/state-dir"; mkdir -p "$SD"
mk F55.0 done; mk F55.1 done; mk F56.0 done; mk F57.0 done
TASKPUMP_NOTIFY_CMD=true TASKPUMP_PUMP_NO_LAUNCH=1 ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  TASKPUMP_STATE_DIR="$SD" ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  TASKPUMP_PUMP_STATE_NAME=.pinned-pump.state \
  "$PUMP" --no-health-gate --phases F55..F57 --once >/dev/null 2>&1
[[ -f "$SD/.pinned-pump.state" ]] && pass "state file follows TASKPUMP_STATE_DIR" \
  || fail "state file not written under $SD"
[[ -f "$SD/.taskpump-pool-cap" ]] && pass "pool-cap file follows TASKPUMP_STATE_DIR (default name)" \
  || fail "cap file not written under $SD"
# An individual filename still overrides the directory.
TASKPUMP_NOTIFY_CMD=true TASKPUMP_PUMP_NO_LAUNCH=1 ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  TASKPUMP_STATE_DIR="$SD" TASKPUMP_PUMP_STATE_FILE="$TMP/named.state" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate --phases F55..F57 --once >/dev/null 2>&1
[[ -f "$TMP/named.state" ]] && pass "an explicit state filename outranks the state dir" \
  || fail "TASKPUMP_PUMP_STATE_FILE ignored"
mk F55.0 open; mk F55.1 open F55.0; mk F56.0 open; mk F57.0 open F55.1

# `env` is needed, not a bare prefix: words that arrive through "$@" are not
# parsed as assignments, so bash would try to execute the first one.
rnote() { PATH="$BIN:$PATH" ARACHNE_POOL_CAP_FILE="$TMP/cap" \
  ARACHNE_PUMP_STATE_FILE="$STATE19" ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=aaaa111 \
  env "$@" "$PUMP" --no-health-gate --render-resume-note F97 2>&1; }

echo "--- Test 23a: the renderer substitutes every placeholder it documents ---"
# Drive this from a fixture template, NOT from whichever file templates/ ships.
# Asserting that the shipped brief uses {{TASK_CLI}} couples this suite to a
# file another branch owns, and it broke the moment a differently-worded — but
# perfectly valid — default arrived. What has to hold is that the RENDERER
# resolves a placeholder, not that some particular template chose to use it.
ALLTPL="$TMP/all-placeholders.md"
cat >| "$ALLTPL" <<'EOF'
phase={{PHASE}} base={{BASE}} cli={{TASK_CLI}} name={{TASK_CLI_NAME}}
dir={{TASK_DIR}} verify={{VERIFY_CMDS}} gate={{BUILD_GATE}}
brief={{PROJECT_BRIEF}}
{{DEPENDS_ON}}
EOF
out=$(ARACHNE_PUMP_NO_GH=1 TASKPUMP_BRIEF_TEMPLATE="$ALLTPL" \
      TASKPUMP_TASK_CLI="bin/tp task" \
      TASKPUMP_VERIFY_CMDS=$'make lint\nmake test' \
      TASKPUMP_PROJECT_BRIEF="Read HACKING.md first." \
      "$PUMP" --render-brief F55 2>&1)
grep -qF 'phase=F55' <<<"$out"            && pass "{{PHASE}} substitutes"      || fail "PHASE:\n$out"
grep -qF 'base=main' <<<"$out"            && pass "{{BASE}} substitutes"       || fail "BASE:\n$out"
grep -qF 'cli=bin/tp task' <<<"$out"      && pass "{{TASK_CLI}} substitutes"   || fail "TASK_CLI:\n$out"
# basename strips the directory, not the subcommand: `bin/tp task` → `tp task`,
# which is what prose should call it. (Arachne's default gives `arachne-task`.)
grep -qF 'name=tp task' <<<"$out"         && pass "{{TASK_CLI_NAME}} drops the directory, keeps the subcommand" || fail "TASK_CLI_NAME:\n$out"
grep -qF '`make lint` and `make test`' <<<"$out" && pass "{{VERIFY_CMDS}} renders as an inline phrase" || fail "VERIFY_CMDS:\n$out"
grep -qF 'gate=`make lint` and `make test`' <<<"$out" && pass "{{BUILD_GATE}} is an alias of {{VERIFY_CMDS}}" || fail "BUILD_GATE:\n$out"
grep -qF 'brief=Read HACKING.md first.' <<<"$out" && pass "{{PROJECT_BRIEF}} substitutes" || fail "PROJECT_BRIEF:\n$out"
grep -qF 'No cross-phase dependencies.' <<<"$out" && pass "{{DEPENDS_ON}} expands as a block" || fail "DEPENDS_ON:\n$out"

echo "--- Test 23b: whatever ships must render clean and name no project ---"
# These two properties hold for ANY shipped default, so they survive a template
# arriving from another branch. Anything more specific belongs in 23a.
assert_shipped() {  # <label> <rendered>
  local label="$1" out="$2"
  grep -qF '{{' <<<"$out" && fail "$label: an unsubstituted placeholder survived:\n$out" \
    || pass "$label: no placeholder survives rendering"
  grep -qiE 'cargo|arachne|CLAUDE\.md' <<<"$out" \
    && fail "$label: the shipped default names one project:\n$out" \
    || pass "$label: names no particular project"
}
assert_shipped "shipped brief" "$(ARACHNE_PUMP_OPS_DIR="$TMP/no-such-ops" ARACHNE_PUMP_NO_GH=1 \
  TASKPUMP_TASK_CLI="bin/tp task" TASKPUMP_VERIFY_CMDS="make check" \
  TASKPUMP_PROJECT_BRIEF="Read HACKING.md first." "$PUMP" --render-brief F55 2>&1)"

stall_fixture
assert_shipped "shipped resume note" "$(rnote ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  TASKPUMP_TASK_CLI="bin/tp task" TASKPUMP_VERIFY_CMDS="make check")"

# And the resume note must still carry the one sentence it exists for.
note=$(rnote ARACHNE_PUMP_OPS_DIR="$TMP/noops")
have "$note" 'RESUME CONTEXT' && pass "the resume note keeps its heading" || fail "no heading:\n$note"
have "$note" 'Do NOT start by running' && pass "the resume note keeps the next-returns-null warning" \
  || fail "the load-bearing warning is gone:\n$note"

echo "--- Test 23c: an empty VERIFY_CMDS drops the verify sections cleanly (G1.7) ---"
# The shipped default IS empty — no default can know a project's toolchain — so
# the templates' {{#VERIFY_CMDS}} sections must vanish without a dangling
# verify sentence, and reappear intact the moment a consumer sets the key.
out=$(ARACHNE_PUMP_OPS_DIR="$TMP/no-such-ops" ARACHNE_PUMP_NO_GH=1 \
  TASKPUMP_TASK_CLI="bin/tp task" \
  TASKPUMP_PROJECT_BRIEF="Read HACKING.md first." "$PUMP" --render-brief F55 2>&1)
have "$out" 'Verify with' && fail "empty VERIFY_CMDS left a dangling verify bullet:\n$out" \
  || pass "no verify bullet when VERIFY_CMDS is empty"
have "$out" 'clean on your branch' && fail "empty VERIFY_CMDS left a dangling done-criterion:\n$out" \
  || pass "no verify done-criterion when VERIFY_CMDS is empty"
grep -qF '{{' <<<"$out" && fail "section markers or placeholders survived:\n$out" \
  || pass "no section marker survives the empty case"
grep -qF "Run the task's tests." <<<"$out" && pass "the neighboring step survives the dropped section" \
  || fail "a neighboring line was lost with the section:\n$out"
out=$(ARACHNE_PUMP_OPS_DIR="$TMP/no-such-ops" ARACHNE_PUMP_NO_GH=1 \
  TASKPUMP_TASK_CLI="bin/tp task" TASKPUMP_VERIFY_CMDS="make check" \
  TASKPUMP_PROJECT_BRIEF="Read HACKING.md first." "$PUMP" --render-brief F55 2>&1)
grep -qF 'Verify with `make check`' <<<"$out" && pass "a configured VERIFY_CMDS renders its section" \
  || fail "configured VERIFY_CMDS section missing:\n$out"

# The resume note's verify sentence follows the same contract.
note=$(rnote ARACHNE_PUMP_OPS_DIR="$TMP/noops")
have "$note" 'must be clean' && fail "empty VERIFY_CMDS left a dangling clean-clause:\n$note" \
  || pass "resume note drops the verify clause when VERIFY_CMDS is empty"
grep -qF '{{' <<<"$note" && fail "resume note kept a marker or placeholder:\n$note" \
  || pass "resume note keeps no marker in the empty case"
note=$(rnote ARACHNE_PUMP_OPS_DIR="$TMP/noops" TASKPUMP_VERIFY_CMDS="make check")
grep -qF '`make check` must be clean' <<<"$note" && pass "resume note renders a configured VERIFY_CMDS" \
  || fail "resume note verify clause missing:\n$note"

echo "--- Test 24: the feed gate is a pluggable, fail-open chain ---"
GBIN="$TMP/gates"; mkdir -p "$GBIN"
mkgate() {  # mkgate <name> <exit> <message>
  cat >| "$GBIN/$1" <<EOF
#!/usr/bin/env bash
echo "$3"
exit $2
EOF
  chmod +x "$GBIN/$1"
}
mkgate feed-ok      0  "nothing to say"
mkgate pause-quota 10  "quota exhausted, retrying after reset"
mkgate pause-second 10 "the second gate would also pause"
mkgate broken       7  "the meter is on fire"
mkgate prefixed    10  "prefixed: reason after the tool name"

gate_plan() { TASKPUMP_GATES="$1" pump F56; }

out=$(gate_plan "$GBIN/feed-ok")
have "$out" 'GATE: feed-ok' && pass "a chain of one passing gate feeds" || fail "custom chain blocked:\n$out"
out=$(gate_plan "$GBIN/pause-quota")
have "$out" 'GATE: PAUSED — quota exhausted' && pass "a custom gate's reason reaches the plan" \
  || fail "custom gate reason missing:\n$out"

# Order decides which reason the operator reads, so it has to be honored.
out=$(gate_plan "$(printf '%s\n%s\n' "$GBIN/pause-quota" "$GBIN/pause-second")")
have "$out" 'quota exhausted' && pass "the first pausing gate wins" || fail "chain order ignored:\n$out"
out=$(gate_plan "$(printf '%s\n%s\n' "$GBIN/pause-second" "$GBIN/pause-quota")")
have "$out" 'the second gate would also pause' && pass "reordering changes which reason wins" \
  || fail "chain order ignored on reverse:\n$out"

# Fail-open is the whole safety story: a broken gate must not halt a multi-day
# drain, and it must say so rather than failing silently.
out=$(gate_plan "$(printf '%s\n%s\n' "$GBIN/broken" "$GBIN/feed-ok")" 2>&1)
have "$out" 'GATE: feed-ok' && pass "a gate that errors fails OPEN" || fail "broken gate halted feeding:\n$out"
have "$out" 'failed \(rc=7\)' && pass "a broken gate is reported, not swallowed" || fail "no warning for a broken gate:\n$out"
out=$(gate_plan "$GBIN/not-a-real-gate" 2>&1)
have "$out" 'gate not executable' && pass "a missing gate is reported" || fail "missing gate silent:\n$out"
have "$out" 'GATE: feed-ok' && pass "a missing gate fails OPEN" || fail "missing gate halted feeding:\n$out"

# A tool that prefixes every diagnostic with its own name should not have to
# special-case this path.
out=$(gate_plan "$GBIN/prefixed")
have "$out" 'GATE: PAUSED — reason after the tool name' && pass "a leading tool-name prefix is stripped" \
  || fail "prefix not stripped:\n$out"

# The shipped example is a working no-op, so copying it cannot break a chain.
out=$(gate_plan "$TP_ROOT/gates/example-gate")
have "$out" 'GATE: feed-ok' && pass "the shipped example gate is a no-op" || fail "example gate paused:\n$out"

# The three --no-*-gate flags still drop their entry from the DEFAULT chain.
out=$(STUB_GATE_RC=10 pump F56 --no-usage-gate)
have "$out" 'GATE: feed-ok' && pass "--no-usage-gate drops the usage gate" || fail "--no-usage-gate ignored:\n$out"
out=$(STUB_DISK_GATE_RC=10 pump F56)
have "$out" 'GATE: PAUSED' && pass "the disk gate is in the default chain" || fail "disk gate missing:\n$out"
out=$(STUB_DISK_GATE_RC=10 pump F56 --no-disk-gate)
have "$out" 'GATE: feed-ok' && pass "--no-disk-gate drops the disk gate" || fail "--no-disk-gate ignored:\n$out"

echo "--- Test 24b: dry-run names the active gate chain (G1.7) ---"
# Bare default: three gates, no net-health — it is host-hardware policy and
# ships off. TASKPUMP_HEALTH_GATE=1 opts it in at the head of the chain; the
# probe is stubbed inert so this host's real journal never reaches the suite.
# (the usage entry names this suite's stub, arachne-usage — the line shows the
# CONFIGURED binary, which is the point.)
out=$("$PUMP" --dry-run --phases F56 2>&1)
have "$out" '^gates: claude-token-fresh -> arachne-usage -> disk-low$' \
  && pass "bare default chain is token-fresh -> usage -> disk-low" \
  || fail "bare default chain wrong:\n$out"
out=$(TASKPUMP_HEALTH_GATE=1 TASKPUMP_HEALTH_PROBE_CMD=true "$PUMP" --dry-run --phases F56 2>&1)
have "$out" '^gates: net-health -> claude-token-fresh -> arachne-usage -> disk-low$' \
  && pass "TASKPUMP_HEALTH_GATE=1 opts net-health in, first" \
  || fail "opt-in chain wrong:\n$out"
out=$(TASKPUMP_HEALTH_GATE=1 TASKPUMP_HEALTH_PROBE_CMD=true "$PUMP" --no-health-gate --dry-run --phases F56 2>&1)
have "$out" '^gates: claude-token-fresh' && pass "--no-health-gate still drops net-health" \
  || fail "--no-health-gate ignored:\n$out"
out=$(TASKPUMP_GATES="$GBIN/pause-quota" pump F56)
have "$out" '^gates: pause-quota$' && pass "a custom TASKPUMP_GATES chain is named verbatim" \
  || fail "custom chain not named:\n$out"

echo "--- Test 25: pre-tick hooks are a chain too ---"
HBIN="$TMP/hooks"; mkdir -p "$HBIN"
cat >| "$HBIN/quiet" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >| "$TMP_MARK"
exit 0
EOF
cat >| "$HBIN/noisy" <<'EOF'
#!/usr/bin/env bash
echo "HOOK-SAYS: ${STUB_HOOK_MSG:-something is off}"
exit 0
EOF
cat >| "$HBIN/broken" <<'EOF'
#!/usr/bin/env bash
echo "hook exploded"
exit 4
EOF
chmod +x "$HBIN/quiet" "$HBIN/noisy" "$HBIN/broken"

HOOKMARK="$TMP/hook.mark"
NOTIFIED="$TMP/hook-notify.txt"
hook_tick() {  # extra env from the caller
  : >| "$NOTIFIED"
  TASKPUMP_NOTIFY_CMD="tee -a $NOTIFIED" \
  TASKPUMP_PUMP_NO_LAUNCH=1 \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  ARACHNE_PUMP_STATE_FILE="$TMP/hook.state" \
  ARACHNE_POOL_CAP_FILE="$TMP/cap" \
  TASKPUMP_HOOK_MARK_FILE="$HOOKMARK" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate --phases F56 --once 2>&1
}

mk F56.0 open
# A hook runs with the repo root as its argument.
TMP_MARK="$TMP/hook-arg.txt" out=$(TMP_MARK="$TMP/hook-arg.txt" TASKPUMP_PRE_TICK_HOOKS="$HBIN/quiet" hook_tick)
[[ -s "$TMP/hook-arg.txt" ]] && pass "a hook is handed the repo root" || fail "hook got no argument:\n$out"
[[ -s "$NOTIFIED" ]] && fail "a silent hook still notified" || pass "a silent hook says nothing"

# Output is logged AND notified — but only when it changes.
out=$(STUB_HOOK_MSG="the tree is dirty" TASKPUMP_PRE_TICK_HOOKS="$HBIN/noisy" hook_tick)
have "$out" 'HOOK-SAYS: the tree is dirty' && pass "hook output is logged" || fail "hook output not logged:\n$out"
grep -q 'the tree is dirty' "$NOTIFIED" && pass "hook output is notified the first time" \
  || fail "no notification: $(cat "$NOTIFIED")"
out=$(STUB_HOOK_MSG="the tree is dirty" TASKPUMP_PRE_TICK_HOOKS="$HBIN/noisy" hook_tick)
grep -q 'the tree is dirty' "$NOTIFIED" && fail "an unchanged condition notified again" \
  || pass "an unchanged condition is not re-notified"
out=$(STUB_HOOK_MSG="now something else" TASKPUMP_PRE_TICK_HOOKS="$HBIN/noisy" hook_tick)
grep -q 'now something else' "$NOTIFIED" && pass "a CHANGED condition notifies again" \
  || fail "changed condition did not notify: $(cat "$NOTIFIED")"

# A failing hook is a warning, never a reason to skip the tick.
out=$(TASKPUMP_PRE_TICK_HOOKS="$(printf '%s\n%s\n' "$HBIN/broken" "$HBIN/noisy")" hook_tick)
have "$out" "hook '.*broken' failed \\(rc=4\\)" && pass "a failing hook is reported" || fail "no warning for a failing hook:\n$out"
have "$out" 'HOOK-SAYS' && pass "a failing hook does not stop the chain" || fail "chain stopped at the failure:\n$out"
have "$out" 'GATE: feed-ok|tick:|PAUSED' && pass "the tick continues past a failing hook" || fail "tick aborted:\n$out"
out=$(TASKPUMP_PRE_TICK_HOOKS="$HBIN/nope" hook_tick)
have "$out" 'hook not executable' && pass "a missing hook is reported" || fail "missing hook silent:\n$out"

# The default chain is still the two shipped hooks.
have "$(default_hooks_of_pump)" 'gitignore-repair' && pass "gitignore-repair is in the default chain" \
  || fail "gitignore-repair missing from the default chain"
have "$(default_hooks_of_pump)" 'fs-guard' && pass "fs-guard is in the default chain" \
  || fail "fs-guard missing from the default chain"

echo "--- Test 26: --integration-base reaches every gh call ---"
# All three gh invocations used to hardcode `main`, so a run pointed at a
# release branch silently opened its PRs against main instead. Assert on the
# argv a gh stub records.
GHLOG="$TMP/gh.log"
cat >| "$BIN/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GHLOG"
# \`pr list\` must answer empty so graduate_trunk goes on to create one.
exit 0
EOF
chmod +x "$BIN/gh"

: >| "$GHLOG"
GTMP="$TMP/grad"; mkdir -p "$GTMP"
git -C "$GTMP" init -q -b main 2>/dev/null || true
mk F58.0 done
PATH="$BIN:$PATH" TASKPUMP_NOTIFY_CMD=true TASKPUMP_PUMP_NO_LAUNCH=1 \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" ARACHNE_PUMP_STATE_FILE="$TMP/gh.state" \
  ARACHNE_POOL_CAP_FILE="$TMP/cap" ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  ARACHNE_PUMP_WORKTREES_DIR="$TMP/ghwt" \
  "$PUMP" --no-health-gate --phases F58 --integration-trunk \
          --integration-base release/2.0 >/dev/null 2>&1 || true
grep -q -- '--base release/2.0' "$GHLOG" \
  && pass "gh targets the configured integration base" || fail "gh calls: $(cat "$GHLOG")"
grep -qE -- '--base main( |$)' "$GHLOG" \
  && fail "a gh call still hardcodes main: $(cat "$GHLOG")" || pass "no gh call hardcodes main"
rm -f "$BIN/gh"

echo "--- Test 28: the resume note resolves like the brief does ---"
RES2="$TMP/resolve2"; mkdir -p "$RES2/ops/task-loop/briefs"
stall_fixture

# Shipped default, when a consumer supplies nothing.
out=$(rnote ARACHNE_PUMP_OPS_DIR="$TMP/noops")
have "$out" 'RESUME CONTEXT' && pass "the shipped resume template is the fallback" \
  || fail "shipped resume template not used:\n$out"

# Same two rungs as the brief, and the same deleted third (issue #37): a file
# sitting at the ledger-side path is not configuration, and substituting it for
# the shipped note without being asked is a change of what a resumed agent reads.
printf 'consumer resume note for {{TASK_ID}} on {{BRANCH}}\n' \
  >| "$RES2/ops/task-loop/briefs/_resume-note-template.md"
out=$(rnote ARACHNE_PUMP_OPS_DIR="$RES2/ops")
grep -qF 'consumer resume note for F97.1' <<<"$out" \
  && fail "should ignore a ledger-side _resume-note-template.md when no template is configured: '$out'" \
  || pass "should ignore a ledger-side _resume-note-template.md when no template is configured"
have "$out" 'RESUME CONTEXT' \
  && pass "should render the shipped resume note when the ledger carries an unconfigured one" \
  || fail "shipped resume note did not render over the ledger-side file:\n$out"

# Explicit config outranks the shipped default.
printf 'explicit resume note for {{TASK_ID}}\n' >| "$TMP/explicit-resume.md"
out=$(rnote ARACHNE_PUMP_OPS_DIR="$RES2/ops" TASKPUMP_RESUME_TEMPLATE="$TMP/explicit-resume.md")
[[ "$out" == "explicit resume note for F97.1" ]] \
  && pass "explicit config outranks the shipped resume note" \
  || fail "explicit resume template not chosen: '$out'"

# {{BUILD_GATE}} is the shipped templates' name for the verification commands;
# both names must resolve so either template file renders through this pump.
printf 'gate: {{BUILD_GATE}} / cmds: {{VERIFY_CMDS}}\n' >| "$TMP/gate-resume.md"
out=$(rnote ARACHNE_PUMP_OPS_DIR="$TMP/noops" TASKPUMP_RESUME_TEMPLATE="$TMP/gate-resume.md" \
      TASKPUMP_VERIFY_CMDS="make check")
[[ "$out" == 'gate: `make check` / cmds: `make check`' ]] \
  && pass "{{BUILD_GATE}} and {{VERIFY_CMDS}} are the same value" \
  || fail "placeholder alias wrong: '$out'"

echo "--- Test 29: pump_expand_phases honors TASKPUMP_PHASE_SIGIL (G0.1) ---"
# A G-sigil ledger, hermetic from the F fixtures above. One open root in G56
# so the plan distinguishes LAUNCH from DONE across the range.
GTASKS="$TMP/gtasks"; mkdir -p "$GTASKS"
cat >| "$GTASKS/G56.0.md" <<'EOF'
---
id: G56.0
phase: G56
title: fixture G56.0
status: open
claimed_by: null
claimed_at: null
turn_budget_remaining: null
consecutive_failed_iterations: 0
blockers: []
completed_by_commits: []
files: []
goal: drain G56.0
---
# G56.0
EOF
gpump() { TASKPUMP_PHASE_SIGIL=G ARACHNE_TASKS_DIR="$GTASKS" "$PUMP" --no-health-gate --dry-run --phases "$1" "${@:2}"; }

# 29a: an uppercase G range plans every phase in it.
out=$(gpump G55..G59)
ok=1
for p in G55 G56 G57 G58 G59; do
  have "$out" " +(LAUNCH|DONE|WAITING|RUNNING) +$p " || { ok=0; break; }
done
[[ $ok -eq 1 ]] && pass "G55..G59 plans all five phases" || fail "missing phase $p in plan:\n$out"
have "$out" 'LAUNCH +G56' && pass "G56 launches (G56.0 eligible)" || fail "G56 not LAUNCH:\n$out"
have "$out" 'DONE +G55' && pass "empty G55 shown DONE, not dropped" || fail "G55 not DONE:\n$out"

# 29b: a lowercase range normalizes to the same canonical tokens.
out=$(gpump g55..g59)
have "$out" 'LAUNCH +G56' && pass "g55..g59 normalizes to G-phases" || fail "lowercase range not normalized:\n$out"

# 29c: comma lists and single tokens are unchanged.
out=$(gpump G55,G57)
have "$out" 'DONE +G55' && have "$out" 'DONE +G57' && ! have "$out" 'G56' \
  && pass "comma list plans exactly its members" || fail "comma list wrong:\n$out"
out=$(gpump G56)
have "$out" 'LAUNCH +G56' && pass "single token G56 plans G56" || fail "single token wrong:\n$out"

echo "--- Test 30: a malformed --phases spec aborts the run up front (G0.1) ---"
# The die used to fire inside a process substitution at the consumption sites,
# so the pump reported the error and then planned against an EMPTY phase list.
# 30a: G-sigil spelling from the acceptance criteria.
out=$(TASKPUMP_PHASE_SIGIL=G ARACHNE_TASKS_DIR="$GTASKS" \
      "$PUMP" --no-health-gate --dry-run --phases G1..X9 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "G1..X9 exits non-zero (rc=$rc)" || fail "G1..X9 exited 0:\n$out"
have "$out" "bad phase range 'G1..X9'" && pass "range error names the bad spec" || fail "no range error:\n$out"
have "$out" 'plan — phases' && fail "plan header printed despite bad range:\n$out" || pass "no plan header before the abort"

# 30b: same contract under the suite's pinned F sigil.
out=$(pump F55..X9 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "F55..X9 exits non-zero under the pinned F sigil" || fail "F55..X9 exited 0:\n$out"
have "$out" "bad phase range 'F55..X9'" && pass "pinned-sigil range error surfaced" || fail "no range error:\n$out"

echo "--- Test 30b2: the plan shows a gate that fed but had something to say ---"
# The two Claude gates ship in the default chain, so a consumer driving another
# agent runs them against credentials that will never exist. They must feed —
# and the plan must SAY they skipped, because "GATE: feed-ok" on its own cannot
# tell an operator whether the chain checked and approved or had nothing to
# check. Those are opposite facts about how protected the run is.
NOCREDHOME="$TMP/no-credentials-home"; mkdir -p "$NOCREDHOME"
out=$(TASKPUMP_AGENT_HOME="$NOCREDHOME" TASKPUMP_USAGE_CACHE="$TMP/no-usage-cache.json" \
      TASKPUMP_USAGE_GATE=1 TASKPUMP_USAGE=/nonexistent-so-the-real-gate-runs \
      "$PUMP" --no-health-gate --no-disk-gate --dry-run --phases F55 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "a host with no Claude credentials still plans (exit 0)" \
  || fail "the plan failed without credentials (rc=$rc):\n$out"
have "$out" 'GATE: feed-ok' && pass "the feed decision is unaffected by the absent credentials" \
  || fail "an absent credentials file changed the feed decision:\n$out"
have "$out" 'claude-token-fresh: skipped: no claude credentials' \
  && pass "the token gate's skip and its reason reach the plan" \
  || fail "the token gate skipped silently:\n$out"

echo "--- Test 30c: a branch prefix whose branches cannot be named fails at tick zero ---"
# Every phase in the range takes the same prefix, so a prefix that produces an
# unmappable branch is a CONFIGURATION error, not a per-launch one. `x/y/` makes
# `x/y/f55`, whose slug `x-y-f55` is also what `x/y-f55` and `x-y/f55` produce —
# liveness could not map the name back to one branch. Left unchecked the run
# launches fine and the failure surfaces much later as a phase the pump thinks
# is dead, so it launches a second agent on the same branch.
out=$(TASKPUMP_BRANCH_PREFIX=x/y/ pump F55 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "a prefix that cannot round-trip aborts the run (rc=$rc)" \
  || fail "an unmappable branch prefix was accepted:\n$out"
have "$out" 'TASKPUMP_BRANCH_PREFIX' && pass "the abort names the key to fix" \
  || fail "the error does not name the key:\n$out"
have "$out" 'x-y-f55' && pass "the abort shows the ambiguous name it would produce" \
  || fail "the error does not show the collision:\n$out"
have "$out" 'plan — phases' && fail "the plan printed despite the bad prefix:\n$out" \
  || pass "nothing is planned before the abort"
# The shipped default still works, and so does a prefix with no separator at all.
out=$(pump F55 2>&1); rc=$?
[[ $rc -eq 0 ]] && have "$out" 'plan — phases F55' && pass "the default feat/ prefix is unaffected" \
  || fail "the default prefix broke:\n$out"
out=$(TASKPUMP_BRANCH_PREFIX=wip- pump F55 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "a prefix with no '/' at all is accepted" \
  || fail "a separator-free prefix was refused:\n$out"

echo "--- Test 31: a real run requires TASKPUMP_IMAGE; --dry-run does not (G1.5) ---"
# The image default (arachne) is gone. A REAL run with no image configured must
# abort up front — before the image build and before any runner call — naming
# the key to set. --dry-run keeps planning imageless, unchanged.
mk F55.0 open; mk F55.1 open F55.0; mk F56.0 open; mk F57.0 open F55.1
IMGHOME="$TMP/agent-home"; mkdir -p "$IMGHOME"
RUNLOG="$TMP/runner-calls.log"; : >| "$RUNLOG"
cat >| "$BIN/recording-runner" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$RUNLOG"
exit 0
EOF
chmod +x "$BIN/recording-runner"
imageless_once() {  # a real --once tick (no NO_LAUNCH), fixture-homed, no image
  TASKPUMP_NOTIFY_CMD=true \
  TASKPUMP_AGENT_HOME="$IMGHOME" \
  TASKPUMP_RUNNER="$BIN/recording-runner" \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  ARACHNE_PUMP_STATE_FILE="$TMP/img.state" \
  ARACHNE_POOL_CAP_FILE="$TMP/cap" \
  ARACHNE_PUMP_LOG="$TMP/pump.log" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate --phases F55..F57 --once 2>&1
}
out=$(imageless_once); rc=$?
[[ $rc -ne 0 ]] && pass "an imageless real --once run exits non-zero (rc=$rc)" \
  || fail "imageless launch exited 0:\n$out"
have "$out" 'TASKPUMP_IMAGE' && pass "the abort names TASKPUMP_IMAGE" \
  || fail "error does not name TASKPUMP_IMAGE:\n$out"
[[ -s "$RUNLOG" ]] && fail "the runner was called despite no image:\n$(cat "$RUNLOG")" \
  || pass "no runner call before the abort"
have "$out" 'Building' && fail "the image build ran despite no image:\n$out" \
  || pass "no image build before the abort"
# Same fixture, --dry-run: the full plan still prints with no image configured.
out=$(TASKPUMP_AGENT_HOME="$IMGHOME" pump F55..F57); rc=$?
[[ $rc -eq 0 ]] && pass "--dry-run exits 0 with no image configured" \
  || fail "imageless dry-run rc=$rc:\n$out"
have "$out" 'LAUNCH +F55' && have "$out" 'LAUNCH +F56' && have "$out" 'WAITING +F57' \
  && pass "--dry-run still prints the full plan imageless" \
  || fail "imageless dry-run plan incomplete:\n$out"

echo "--- Test 32: a killed loop stamps a terminal state (G4.6 / #22) ---"
# The G3 incident: the state file kept claiming status:running with no
# supervisor process behind it, because a killed loop died wherever it was.
# The loop now traps INT/TERM/HUP (and EXIT), stamps `stopped` with the signal
# as the reason, and re-raises so the exit status still reports the signal.
# The tick is 600s so the kill always lands in the loop's interruptible sleep.
STATE32="$TMP/pump32.state"
sig_pump() {  # loop-mode pump; the CALLER backgrounds this exact command
  # exec so $! in the caller IS the supervisor's pid; stagger 0 so the first
  # tick finishes (and writes state) promptly.
  TASKPUMP_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 TASKPUMP_STAGGER=0 \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" ARACHNE_PUMP_STATE_FILE="$STATE32" \
  ARACHNE_POOL_CAP_FILE="$TMP/cap" ARACHNE_PUMP_LOG="$TMP/pump32.log" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" STUB_GATE_RC=0 \
  exec "$PUMP" --no-health-gate --phases F55..F57 --tick 600
}
await_state32() {  # poll until the state file reports $1 (the first tick has run)
  local want="$1" i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
    [[ "$(jq -r '.status // empty' "$STATE32" 2>/dev/null)" == "$want" ]] && return 0
    sleep 0.4
  done
  return 1
}

# 32a: SIGTERM mid-loop (systemctl stop, the OOM killer's polite sibling).
mk F55.0 open; mk F55.1 open F55.0; mk F56.0 open; mk F57.0 open F55.1
rm -f "$STATE32"
sig_pump >/dev/null 2>&1 &
PUMP32=$!
await_state32 running && pass "mid-loop the state file reads running" \
  || fail "loop never wrote running: $(cat "$STATE32" 2>/dev/null)"
[[ "$(jq -r '.pid // empty' "$STATE32" 2>/dev/null)" == "$PUMP32" ]] \
  && pass "state.pid is the supervisor's pid" \
  || fail "state.pid != $PUMP32: $(cat "$STATE32" 2>/dev/null)"
kill -TERM "$PUMP32" 2>/dev/null
wait "$PUMP32" 2>/dev/null; rc=$?
[[ "$rc" -eq 143 ]] && pass "the re-raise preserves the SIGTERM exit status (rc=143)" \
  || fail "SIGTERM'd pump exited rc=$rc, not 143"
[[ "$(jq -r '.status' "$STATE32" 2>/dev/null)" == "stopped" ]] \
  && pass "SIGTERM'd loop leaves status=stopped, never running (#22)" \
  || fail "state after SIGTERM: $(cat "$STATE32" 2>/dev/null)"
have "$(jq -r '.paused_reason // empty' "$STATE32" 2>/dev/null)" 'SIGTERM' \
  && pass "the stop reason names the signal" \
  || fail "reason missing SIGTERM: $(jq -r '.paused_reason' "$STATE32" 2>/dev/null)"

# 32b: a hangup (terminal closed / SSH drop) takes the same path. SIGHUP
# stands in for Ctrl-C here because SIGINT is UNDELIVERABLE to this fixture:
# a non-job-control shell starts background jobs with SIGINT ignored, and a
# signal ignored at entry cannot be trapped — while a real Ctrl-C hits a
# FOREGROUND pump, where the same three-signal handler receives it fine.
rm -f "$STATE32"
sig_pump >/dev/null 2>&1 &
PUMP32=$!
await_state32 running || fail "loop never wrote running before SIGHUP"
kill -HUP "$PUMP32" 2>/dev/null
wait "$PUMP32" 2>/dev/null; rc=$?
[[ "$(jq -r '.status' "$STATE32" 2>/dev/null)" == "stopped" ]] \
  && pass "a hangup leaves status=stopped (rc=$rc)" \
  || fail "state after SIGHUP: $(cat "$STATE32" 2>/dev/null)"
have "$(jq -r '.paused_reason // empty' "$STATE32" 2>/dev/null)" 'SIGHUP' \
  && pass "the stop reason names SIGHUP" \
  || fail "reason missing SIGHUP: $(jq -r '.paused_reason' "$STATE32" 2>/dev/null)"

# 32c: a completed drain still writes drained — the exit trap must not
# overwrite a terminal state the pump already stamped on purpose.
mk F55.0 done; mk F55.1 done; mk F56.0 done; mk F57.0 done
rm -f "$STATE32"
sig_pump >/dev/null 2>&1 &
PUMP32=$!
wait "$PUMP32" 2>/dev/null
[[ "$(jq -r '.status' "$STATE32" 2>/dev/null)" == "drained" ]] \
  && pass "a completed drain keeps status=drained (trap does not clobber it)" \
  || fail "drain state clobbered: $(cat "$STATE32" 2>/dev/null)"

echo "--- Test 33: the ledger-repo sync is quiet when there is no ledger repo (issue #41) ---"
# do_tick used to run `git -C "$OPS_DIR" pull --ff-only >/dev/null 2>&1 || warn`
# unconditionally. A consumer with no SEPARATE ledger repo — the bring-your-own-
# repo shape, where OPS_DIR is a missing ops/ or a remoteless checkout — got
# "ops pull --ff-only failed (continuing)" every tick, forever, with no reason
# attached. Harmless in itself, and that is the danger: it trains an operator to
# skim past pump stderr, which is the one channel the loud-failure discipline
# depends on. The shape is decided once at startup; a REAL pull that really
# fails must still warn, and now say why.
rm -f "$TASKS"/*.md; mk F55.0 open
STATE41="$TMP/pump41.state"
tick41() {  # tick41 <ops-dir> [extra pump args] — one hermetic --once tick
  TASKPUMP_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 \
  ARACHNE_PUMP_OPS_DIR="$1" ARACHNE_PUMP_STATE_FILE="$STATE41" \
  ARACHNE_POOL_CAP_FILE="$TMP/cap" ARACHNE_PUMP_LOG="$TMP/pump41.log" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" STUB_LIVE="" STUB_GATE_RC=0 \
  "$PUMP" --no-health-gate --once --phases F55 "${@:2}"
}

# 33a: OPS_DIR does not exist at all — the default $REPO_ROOT/ops of a consumer
# who never had a ledger submodule. There is nothing to pull, so nothing failed.
err=$(tick41 "$TMP/no-such-ops-41" 2>&1 >/dev/null)
have "$err" 'ops pull' \
  && fail "should not warn about the ops pull when the ledger repo does not exist:\n$err" \
  || pass "should stay silent on stderr when OPS_DIR is not a git checkout"
out=$(tick41 "$TMP/no-such-ops-41" 2>/dev/null)
have "$out" 'no separate ledger repo' \
  && pass "should name the no-ledger-repo shape once at startup when OPS_DIR is not a git checkout" \
  || fail "startup said nothing about the skipped pull:\n$out"
have "$out" 'not a git checkout' \
  && pass "should say why the ledger sync is skipped when OPS_DIR is not a git checkout" \
  || fail "the startup line does not name the reason:\n$out"

# 33b: OPS_DIR is a real checkout with no remote — a local-only ledger. A pull
# has nowhere to pull from, and never will.
NOREM41="$TMP/ops41-noremote"
git init -q -b main "$NOREM41"
git -C "$NOREM41" -c user.name=t -c user.email=t@e commit -q --allow-empty -m seed
err=$(tick41 "$NOREM41" 2>&1 >/dev/null)
have "$err" 'ops pull' \
  && fail "should not warn about the ops pull when the ledger repo has no remote:\n$err" \
  || pass "should stay silent on stderr when the ledger repo has no remote"
out=$(tick41 "$NOREM41" 2>/dev/null)
have "$out" 'no git remote' \
  && pass "should say why the ledger sync is skipped when the ledger repo has no remote" \
  || fail "the startup line does not name the remoteless ledger repo:\n$out"

# 33c: a configured ledger repo IS still pulled — the fix must not silence the
# sync wholesale. Seed a commit upstream and prove the tick fast-forwards to it.
SEED41="$TMP/seed41"
git init -q -b main "$SEED41"
git -C "$SEED41" -c user.name=t -c user.email=t@e commit -q --allow-empty -m seed
OPS41="$TMP/ops41"
git clone -q "$SEED41" "$OPS41" 2>/dev/null
git -C "$SEED41" -c user.name=t -c user.email=t@e commit -q --allow-empty -m upstream-work
before41=$(git -C "$OPS41" rev-parse HEAD)
tick41 "$OPS41" >/dev/null 2>&1
[[ "$(git -C "$OPS41" rev-parse HEAD)" != "$before41" ]] \
  && pass "should still fast-forward the ledger repo when one is configured" \
  || fail "the tick stopped pulling a real ledger repo (still at $before41)"
out=$(tick41 "$OPS41" 2>/dev/null)
have "$out" 'no separate ledger repo' \
  && fail "a real ledger repo was classified as absent:\n$out" \
  || pass "should not announce a skipped sync when the ledger repo is real"

# 33d: a real remote that genuinely fails still warns — every tick, loudly, and
# now with the reason the old one-line warning threw away.
BROKE41="$TMP/ops41-broken"
git clone -q "$SEED41" "$BROKE41" 2>/dev/null
git -C "$BROKE41" remote set-url origin "$TMP/gone41.git"
err=$(tick41 "$BROKE41" 2>&1 >/dev/null)
have "$err" 'ops pull --ff-only failed' \
  && pass "should still warn when a configured remote genuinely fails" \
  || fail "a real pull failure went silent:\n$err"
have "$err" 'gone41' \
  && pass "should name the reason when a configured remote genuinely fails" \
  || fail "the pull warning still carries no reason:\n$err"

# 33e: an unreachable remote (33d) is the ONE failing shape whose first output
# line happens to be git's error, so it proves nothing about which line gets
# quoted. The routine failing shape here is a DIVERGED ledger branch — tp-task
# commits task files locally on every tick while another machine pushes the
# same branch — and there git leads with the fetch banner ("From <url>", then
# the ref-update line) for the step that SUCCEEDED, pads the middle with `hint:`
# advice, and puts "fatal: Not possible to fast-forward, aborting." last.
# Quoting the first line points the operator at the remote URL and never
# mentions the divergence: a confident wrong reason, on the one stderr line
# this whole mechanism exists to make worth reading.
DIV41="$TMP/ops41-diverged"
git clone -q "$SEED41" "$DIV41" 2>/dev/null
git -C "$SEED41" -c user.name=t -c user.email=t@e commit -q --allow-empty -m upstream-diverge
git -C "$DIV41" -c user.name=t -c user.email=t@e commit -q --allow-empty -m local-diverge
err=$(tick41 "$DIV41" 2>&1 >/dev/null)
have "$err" 'ops pull --ff-only failed' \
  && pass "should still warn when the ledger branch has diverged from its remote" \
  || fail "a diverged ledger pull went silent:\n$err"
have "$err" 'Not possible to fast-forward' \
  && pass "should quote git's own error when the ledger branch has diverged" \
  || fail "the warning does not carry git's fatal:\n$err"
have "$err" 'failed \(continuing\) — From ' \
  && fail "the warning names the fetch banner — a step that succeeded — as the reason:\n$err" \
  || pass "should not name the fetch banner as the reason when the fetch succeeded"
# Tick 2 of the same divergence: the fetch is up to date now, so git prints no
# banner and leads with `hint: Diverging branches can't be fast-forwarded, you
# need to either:` — a sentence that ends on a colon with its advice stripped
# off. A persistent failure repeats every tick, so this is the line an operator
# actually lives with; it must be the fatal, not the dangling hint.
err=$(tick41 "$DIV41" 2>&1 >/dev/null)
have "$err" 'Not possible to fast-forward' \
  && pass "should quote git's error on every tick when the divergence persists" \
  || fail "the repeated warning stopped naming git's fatal:\n$err"
have "$err" 'failed \(continuing\) — hint:' \
  && fail "the warning quotes git's advice instead of git's error:\n$err" \
  || pass "should not quote git's hint advice as the reason when git named an error"

# 33f: not every git failure carries a `fatal:`/`error:` line to quote. A ledger
# checkout sitting on a branch with no upstream states its diagnosis as bare
# prose and then offers four lines of advice, so the fallback has to be the
# FIRST real line — the last non-blank one is the indented
# `git branch --set-upstream-to=…` suggestion, which is advice, not cause.
NOUP41="$TMP/ops41-noupstream"
git clone -q "$SEED41" "$NOUP41" 2>/dev/null
git -C "$NOUP41" checkout -q -b ledger-side-branch
err=$(tick41 "$NOUP41" 2>&1 >/dev/null)
have "$err" 'no tracking information' \
  && pass "should quote git's diagnosis when the ledger branch has no upstream" \
  || fail "the warning does not name the missing upstream:\n$err"
have "$err" 'failed \(continuing\) — .*set-upstream-to' \
  && fail "the warning quotes git's suggested remedy instead of the cause:\n$err" \
  || pass "should not quote git's remedy as the reason when git stated a cause"

# 33g: the bug was per-TICK, so prove it against a real loop rather than a
# single --once process. F98.0 is open behind a blocked F98.1: nothing is
# eligible, nothing is live, nothing is resumable, so the loop deadlock-exits
# after STALL_EXIT_TICKS (3) ticks — a bounded multi-tick run.
rm -f "$TASKS"/*.md; mk F98.0 open F98.1; mk F98.1 blocked
loop41=$(TASKPUMP_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 TASKPUMP_STAGGER=0 \
  ARACHNE_PUMP_OPS_DIR="$TMP/no-such-ops-41" ARACHNE_PUMP_STATE_FILE="$STATE41" \
  ARACHNE_POOL_CAP_FILE="$TMP/cap" ARACHNE_PUMP_LOG="$TMP/pump41.log" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" STUB_LIVE="" STUB_GATE_RC=0 \
  "$PUMP" --no-health-gate --phases F98 --tick 1 2>&1)
n41=$(grep -c 'ops pull' <<<"$loop41")
[[ "$n41" -eq 0 ]] \
  && pass "should not repeat the pull warning per tick when there is no ledger repo" \
  || fail "the loop warned about the ops pull $n41 time(s):\n$loop41"
n41=$(grep -c 'no separate ledger repo' <<<"$loop41")
[[ "$n41" -eq 1 ]] \
  && pass "should disclose the skipped sync exactly once per run, not once per tick" \
  || fail "the startup disclosure appeared $n41 time(s) across a multi-tick run:\n$loop41"
have "$loop41" 'ops push on stall exit failed' \
  && fail "the stall exit reported a push failure with no ledger repo to push to:\n$loop41" \
  || pass "should not report a failed stall-exit push when there is no ledger repo"

echo "--- Test 34: the cap the banner prints is the cap the ticks use (#44) ---"
# The banner printed $JOBS while every tick read CAP_FILE, so a cap file left
# behind by an earlier run silently topped the pool up to ITS number while the
# operator was told the flag's — `--jobs 1` against a leftover 4 launched four
# agents and said cap=1. Whichever of the two wins, the banner, the tick and the
# state file must all name the same number.
CAP44="$TMP/cap44"; STATE44="$TMP/pump44.state"
mk F90.0 open; mk F91.0 open
pump44() {  # pump44 <pump args...> — a hermetic run against $CAP44
  TASKPUMP_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 TASKPUMP_STAGGER=0 \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" ARACHNE_PUMP_STATE_FILE="$STATE44" \
  ARACHNE_POOL_CAP_FILE="$CAP44" ARACHNE_PUMP_LOG="$TMP/pump44.log" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate --phases F90..F91 "$@" 2>&1
}
banner_cap44() { sed -n 's/.*Pump: .*cap=\([0-9][0-9]*\).*/\1/p' <<<"$1" | head -1; }
tick_cap44()   { sed -n 's#.*live=[0-9][0-9]*/\([0-9][0-9]*\).*#\1#p' <<<"$1" | head -1; }

# 34a: an explicit --jobs against a leftover cap file of 4.
echo 4 >| "$CAP44"
out=$(pump44 --jobs 1 --once)
bc=$(banner_cap44 "$out"); tc=$(tick_cap44 "$out")
[[ "$bc" == "1" ]] \
  && pass "should print the flag's cap in the banner when --jobs 1 meets a cap file holding 4" \
  || fail "banner cap=$bc, expected 1:\n$out"
[[ -n "$tc" && "$tc" == "$bc" ]] \
  && pass "should top the pool up to the banner's cap when a leftover cap file disagrees" \
  || fail "banner said cap=$bc but the tick launched against $tc:\n$out"
[[ "$(cat "$CAP44")" == "1" ]] \
  && pass "should rewrite the live cap file to the flag when --jobs is explicit" \
  || fail "cap file holds '$(cat "$CAP44")', expected 1 (the flag never reached the file the ticks read)"
[[ "$(jq -r '.jobs' "$STATE44" 2>/dev/null)" == "1" ]] \
  && pass "should record the effective cap in the state file when --jobs wins" \
  || fail "state file jobs=$(jq -r '.jobs' "$STATE44" 2>/dev/null), expected 1"

# 34b: no flag — the cap file is the live retune knob and keeps winning, but the
# banner must stop claiming the default it is not using.
echo 3 >| "$CAP44"
out=$(pump44 --once)
bc=$(banner_cap44 "$out"); tc=$(tick_cap44 "$out")
[[ "$bc" == "3" ]] \
  && pass "should print the cap file's value in the banner when no --jobs is passed" \
  || fail "banner cap=$bc, expected 3 (the file the ticks read):\n$out"
[[ -n "$tc" && "$tc" == "$bc" ]] \
  && pass "should tick against the cap file when no --jobs is passed" \
  || fail "banner said cap=$bc but the tick launched against $tc:\n$out"
[[ "$(cat "$CAP44")" == "3" ]] \
  && pass "should leave a mid-drain retune alone when no --jobs is passed" \
  || fail "cap file rewritten to '$(cat "$CAP44")', expected the retuned 3"
# The monitor renders this file: the same number, or the same lie one channel over.
[[ "$(jq -r '.jobs' "$STATE44" 2>/dev/null)" == "3" ]] \
  && pass "should record the cap file's value in the state file when no --jobs is passed" \
  || fail "state file jobs=$(jq -r '.jobs' "$STATE44" 2>/dev/null), expected 3"

# 34c: a dry run must predict the cap the real run would use — it exits before
# the startup write, so it has to reason about the flag itself.
echo 4 >| "$CAP44"
out=$(pump44 --jobs 1 --dry-run)
have "$out" 'plan — phases F90\.\.F91, grain phase, cap 1,' \
  && pass "should predict the flag's cap in a dry run when a leftover cap file disagrees" \
  || fail "dry-run plan header disagrees with the run it previews:\n$out"
[[ "$(cat "$CAP44")" == "4" ]] \
  && pass "should not write the cap file in a dry run when --jobs is explicit" \
  || fail "dry run mutated the cap file to '$(cat "$CAP44")'"

# 34d: with no cap file at all the shipped default still seeds it (Test 22
# covers the path; this pins the number the banner quotes for it).
rm -f "$CAP44"
out=$(pump44 --once)
bc=$(banner_cap44 "$out")
[[ "$bc" == "4" && "$(cat "$CAP44")" == "4" ]] \
  && pass "should seed the cap file from the default cap when no file exists" \
  || fail "banner cap=$bc, cap file '$(cat "$CAP44" 2>/dev/null)', expected 4/4"

# 34e: a startup that ABORTS must leave the cap file exactly as it found it. The
# launch prerequisites (no image / no auth dir / no runner / failed build) die
# after the write, printing no banner and saying nothing about a cap — so the
# operator's whole evidence is "that command failed", and a cap file quietly
# rewritten behind it governs the next unflagged run. That is issue #44's own
# bug shape re-created by its fix, and it is the rule the state file already
# states one screen below ("a pump that never ticked ... must not clobber a
# previous run's file on a startup abort"). Every case above sets NO_LAUNCH,
# which skips the prerequisite block wholesale; this one deliberately does not.
echo 4 >| "$CAP44"
abort44() {  # a real (launching) run with an existing auth dir and no image
  TASKPUMP_NOTIFY_CMD=true TASKPUMP_STAGGER=0 \
  TASKPUMP_AGENT_HOME="$TMP" TASKPUMP_IMAGE= \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" ARACHNE_PUMP_STATE_FILE="$STATE44" \
  ARACHNE_POOL_CAP_FILE="$CAP44" ARACHNE_PUMP_LOG="$TMP/pump44.log" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  "$PUMP" --no-health-gate --phases F90..F91 "$@" 2>&1
}
out=$(abort44 --jobs 12 --once); rc=$?
[[ "$rc" -ne 0 ]] && have "$out" 'no container image configured' \
  && pass "should abort on the missing image when --jobs is passed to a run that cannot launch" \
  || fail "expected a prerequisite abort, got rc=$rc:\n$out"
have "$out" 'Pump: phases=' \
  && fail "an aborted startup printed the banner:\n$out" \
  || pass "should print no banner when the startup aborts on a prerequisite"
[[ "$(cat "$CAP44")" == "4" ]] \
  && pass "should leave the live cap file untouched when the startup aborts before ticking" \
  || fail "cap file rewritten to '$(cat "$CAP44")' by a run that never ticked, expected 4"
# The consequence the operator actually meets: the documented unflagged form.
out=$(pump44 --once)
bc=$(banner_cap44 "$out")
[[ "$bc" == "4" ]] \
  && pass "should govern the next unflagged run by the standing cap when an earlier --jobs run aborted" \
  || fail "next unflagged run ticks at cap=$bc — inherited from a run that never happened:\n$out"
# Same rule with no file at all: the seeding write is a courtesy for a run that
# is about to tick, so an abort must not leave a cap file behind either.
rm -f "$CAP44"
out=$(abort44 --jobs 12 --once)
[[ ! -e "$CAP44" ]] \
  && pass "should create no cap file at all when the startup aborts on a prerequisite" \
  || fail "an aborted startup seeded a cap file holding '$(cat "$CAP44")':\n$out"

# 34f: an unwritable cap file. The flag still wins (effective_cap holds it for
# the process's whole life, since the stamp that hands authority back never
# landed) — but that is precisely when the banner must NOT promise the file as
# the live retune knob one line under a warn saying that knob is off. A wrong
# provenance clause in the change whose purpose is provenance.
CAP44_REAL="$CAP44"
CAP44="$TMP/cap44-unwritable"; mkdir -p "$CAP44"   # a directory: `echo >|` fails as any user
out=$(pump44 --jobs 2 --once)
bc=$(banner_cap44 "$out")
have "$out" 'could not write .*retuning through that file is off' \
  && pass "should warn that live retuning is off when the cap file cannot be written" \
  || fail "no unwritable-cap-file warning:\n$out"
[[ "$bc" == "2" ]] \
  && pass "should still tick at the flag's cap when the cap file cannot be written" \
  || fail "banner cap=$bc, expected 2:\n$out"
have "$out" 'Pump: .*cap=2 \(--jobs \(cap file unwritable' \
  && pass "should name the flag alone as the cap's source when the cap file cannot be written" \
  || fail "banner still advertises the cap file as the live source:\n$out"
rm -rf "$CAP44"; CAP44="$CAP44_REAL"

# 34g: the stamp hands authority BACK to the cap file. --jobs outranks a stale
# file only until the flag is written into it; after that the file is the live
# retune knob again — otherwise a supervisor started with --jobs could never be
# throttled mid-drain, by an operator or by the disk watchdog, and the suite
# would not notice because every case above is --once and sees one tick.
echo 4 >| "$CAP44"
STATE44G="$TMP/pump44g.state"; rm -f "$STATE44G"
retune_pump() {  # loop-mode pump; the CALLER backgrounds this exact command
  TASKPUMP_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 TASKPUMP_STAGGER=0 \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" ARACHNE_PUMP_STATE_FILE="$STATE44G" \
  ARACHNE_POOL_CAP_FILE="$CAP44" ARACHNE_PUMP_LOG="$TMP/pump44g.log" \
  ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  exec "$PUMP" --no-health-gate --phases F90..F91 --jobs 1 --tick 1
}
await_jobs44() {  # poll until the state file's effective cap reads $1
  local want="$1" i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
    [[ "$(jq -r '.jobs // empty' "$STATE44G" 2>/dev/null)" == "$want" ]] && return 0
    sleep 0.4
  done
  return 1
}
retune_pump >/dev/null 2>&1 &
PUMP44=$!
await_jobs44 1 \
  && pass "should stamp the flag into the cap file and tick against it when --jobs starts a loop" \
  || fail "loop never ticked at the flag's cap: $(cat "$STATE44G" 2>/dev/null)"
echo 2 >| "$CAP44"
await_jobs44 2 \
  && pass "should honor a mid-drain retune of the cap file when the run started with --jobs" \
  || fail "cap file retune ignored after the startup stamp: $(cat "$STATE44G" 2>/dev/null)"
kill -TERM "$PUMP44" 2>/dev/null
wait "$PUMP44" 2>/dev/null
rm -f "$TASKS/F90.0.md" "$TASKS/F91.0.md"

echo "--- Test 35: a stranded claim as the range's last work is never DRAINED (#48) ---"
# The drain test counts `open` tasks, and a claim is not open. So an in_progress
# task this run cannot own — claimed at the other dispatch grain, or on a branch
# this naming scheme does not own — is invisible to it: neither reclaim nor
# resume will touch that branch (deliberately, it is the same test that keeps
# them off a human's), and nothing else can clear it either. While other open
# work remained the run reached the deadlock exit (3); when the stranded claim
# was the LAST thing in range, open_count hit 0 and the pump reported the range
# *drained* at rc 0 over committed, unfinished work nobody is driving. That is
# the F79 false-DRAINED arriving through the claim-ownership door instead of the
# ledger-resolution one, and the plan told the same lie at phase grain — a phase
# with no open tasks left was filed under DONE.
STATE33="$TMP/pump33.state"
stranded_fixture() {  # $1 = the branch holding the claim
  rm -f "$TASKS"/*.md; mk F98.0 done; mkclaim F98.1 "$1"
}
dplan33() {  # the plan over F98; extra flags forwarded
  PATH="$BIN:$PATH" TASKPUMP_NOTIFY_CMD=true ARACHNE_CLAIM_STALE_HOURS=99999 \
  ARACHNE_PUMP_OPS_DIR="$TMP/noops" ARACHNE_PUMP_STATE_FILE="$STATE33" \
  ARACHNE_POOL_CAP_FILE="$TMP/cap" ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  STUB_LIVE="${STUB_LIVE:-}" STUB_AHEAD="${STUB_AHEAD:-3}" STUB_HEAD=aaaa111 \
  "$PUMP" --no-health-gate --dry-run --phases F98 "$@"
}
loop33() {  # a REAL loop over F98 — the drain check only exists in loop mode
  PATH="$BIN:$PATH" TASKPUMP_NOTIFY_CMD=true ARACHNE_PUMP_NO_LAUNCH=1 \
  ARACHNE_CLAIM_STALE_HOURS=99999 ARACHNE_PUMP_OPS_DIR="$TMP/noops" \
  ARACHNE_PUMP_STATE_FILE="$STATE33" ARACHNE_POOL_CAP_FILE="$TMP/cap" \
  ARACHNE_PUMP_LOG="$TMP/pump33.log" ARACHNE_PHASE_BRIEF_TEMPLATE="$TPL" \
  STUB_LIVE="" STUB_AHEAD=3 STUB_HEAD=aaaa111 STUB_GATE_RC=0 \
  timeout 60 "$PUMP" --no-health-gate --phases F98 --tick 1 "$@"
}

# 35a: the exit code. A foreign-branch claim as the only remaining work must
# reach the same loud stall the run reaches when open work sits beside it.
stranded_fixture feat/somebody-else
rm -f "$STATE33"
rc=0; out=$(loop33 2>&1) || rc=$?
[[ "$rc" -eq 3 ]] && pass "should exit 3 when the range's last work is a claim this run cannot own" \
  || fail "exit=$rc, want 3 — the range was drained over a stranded claim:\n$out"
have "$out" 'drained' \
  && fail "the run reported the range drained over an in-flight claim:\n$out" \
  || pass "should never report DRAINED when an in-flight claim remains in range"

# 35b: the state file an operator reads during the page. `open_tasks: 0` with
# `status: stalled` is unreadable on its own — the reason has to name the claim.
[[ "$(jq -r '.status' "$STATE33" 2>/dev/null)" == "stalled" ]] \
  && pass "should stamp status=stalled when a stranded claim blocks the drain" \
  || fail "state after the stranded run: $(cat "$STATE33" 2>/dev/null)"
have "$(jq -r '.paused_reason // empty' "$STATE33" 2>/dev/null)" 'in-flight claim' \
  && pass "should name the in-flight claim in the stall reason when 0 open tasks remain" \
  || fail "stall reason does not name the claim: $(jq -r '.paused_reason' "$STATE33" 2>/dev/null)"
have "$out" 'in-flight claim' \
  && pass "should page about the in-flight claim it stalled over" \
  || fail "the stall page does not mention the in-flight claim:\n$out"

# 35c: the plan has to say the same thing the exit code does. Filing the phase
# under DONE would move the lie from the exit code into the plan text.
stranded_fixture feat/somebody-else
out=$(dplan33 2>&1)
have "$out" 'DONE +F98' \
  && fail "phase classified DONE while its last task is still claimed:\n$out" \
  || pass "should not classify a phase DONE when its last task is still claimed"
have "$out" 'WAITING +F98' && pass "should plan the stranded phase WAITING when no open tasks remain" \
  || fail "stranded phase not WAITING:\n$out"
have "$out" 'F98\.1 \(claimed by feat/somebody-else\)' \
  && pass "should name the stranded task and its claimant when it explains the wait" \
  || fail "the WAITING reason does not name the claim:\n$out"

# 35d: the issue's literal repro — claimed at phase grain, run at task grain.
# The task-grain plan already named it (`WAITING F98.1 (claimed by …)`); only
# the drain test was blind, so the run said DRAINED under an honest plan.
stranded_fixture feat/f98
out=$(dplan33 --grain task 2>&1)
have "$out" 'WAITING +F98\.1 +\(claimed by feat/f98, no live container\)' \
  && pass "should keep naming the stranded claim at task grain when the grain switched" \
  || fail "task-grain plan lost the stranded claim:\n$out"
rm -f "$STATE33"
rc=0; out=$(loop33 --grain task 2>&1) || rc=$?
[[ "$rc" -eq 3 ]] && pass "should exit 3 when a grain switch strands the range's last claim" \
  || fail "exit=$rc, want 3 at task grain:\n$out"
have "$out" 'drained' \
  && fail "task-grain run drained over the stranded claim:\n$out" \
  || pass "should never report DRAINED at task grain while a claim is in flight"

# 35e: the guard is about claims nobody is driving, not about claims. A LIVE
# container on the claiming branch is a running phase, not a stranded one.
stranded_fixture feat/f98
out=$(STUB_LIVE="arachne-agent-feat-f98" dplan33 2>&1)
have "$out" 'RUNNING +F98' && pass "should read a claim with a live container as RUNNING when no open tasks remain" \
  || fail "live claim not RUNNING:\n$out"

# 35f: and a range that genuinely finished still drains. The guard must cost the
# happy path nothing — a false stall is the same class of wrong answer.
rm -f "$TASKS"/*.md; mk F98.0 done; mk F98.1 done
rm -f "$STATE33"
rc=0; out=$(loop33 2>&1) || rc=$?
[[ "$rc" -eq 0 ]] && pass "should still exit 0 when the range genuinely drained" \
  || fail "exit=$rc, want 0 on a genuine drain:\n$out"
[[ "$(jq -r '.status' "$STATE33" 2>/dev/null)" == "drained" ]] \
  && pass "should still stamp status=drained when no claim remains in range" \
  || fail "state after a genuine drain: $(cat "$STATE33" 2>/dev/null)"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
