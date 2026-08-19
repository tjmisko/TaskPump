#!/usr/bin/env bash
# test-env-hermeticity.sh — the suites must be hermetic against pump-exported
# ledger environment (issue #18, G4.5).
#
# The pump/entrypoint export TASKPUMP_TASKS_DIR / TP_TASKS_DIR — pointing at
# the REAL ledger — into every agent session. Necessarily: that is how an
# agent's tp finds its ledger, so the exports themselves are correct. But
# lib/config.sh gives a canonical spelling the win over its legacy twin, so a
# fixture that configures itself as ARACHNE_TASKS_DIR=<tmpdir> is silently
# outranked by the inherited TASKPUMP_TASKS_DIR: the test reads the real
# ledger while believing it reads its fixture. The 2026-08-13 G3 drain agent
# saw 64 spurious failures across three suites this way, and burned session
# time proving they were not its own — the false-red mirror of the false-green
# problem TASKPUMP_NO_CONF already solved for leaked conf files.
#
# tests/suite-prologue.sh is the guard: run-all.sh and every suite source it
# before any fixture is built, and it unsets the entire inherited
# TASKPUMP_*/TP_*/ARACHNE_* namespace by enumeration. This suite pins that
# seam:
#
#   * the CONTROL — without the prologue, an inherited canonical spelling
#     really does outrank a fixture's legacy spelling (the bug's mechanism,
#     which is also the tools' correct precedence, pinned here as such);
#   * the GUARD — after sourcing the prologue the poison is gone, including
#     names invented for this test (so a hand-kept list can never quietly
#     replace the enumeration), and the fixture's own values are authoritative
#     again;
#   * the COVERAGE — every tests/test-*.sh and run-all.sh source the shared
#     prologue, so a future suite that forgets it fails here, loudly;
#   * the CENTRAL guard, end to end — run-all.sh launches a real
#     legacy-spelled suite green under the poisoned environment;
#   * the RUN STATE (B16) — the leak in the other direction. A real tick, run
#     the way a suite helper that pins nothing would run it, must not leave the
#     pump's hook mark file in the checkout the suites run FROM;
#   * the GATE that would have caught that — run-all.sh's state manifest,
#     driven for real against throwaway repos: what it sees, what it names, and
#     what it refuses to claim about who wrote a file.
#
# Two ledgers that answer `ready --count` differently are the tracer:
# whichever ledger answered is unambiguous from the number alone.
#
# Sections 1-5 exercise tp-task only; section 6 runs a real tp-pump tick, so
# this suite depends on libexec/tp-pump as well.
#
# Run: ./tests/test-env-hermeticity.sh   (offline)
set -uo pipefail

# CDPATH='' rather than `CDPATH= `: the same env prefix, but shellcheck reads
# the spelling with the space as a mistyped assignment (SC1007), and this suite
# has to lint clean for that warning to mean anything here.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
CLI="$TP_ROOT/libexec/tp-task"
PROLOGUE="$SCRIPT_DIR/suite-prologue.sh"

# Sourced by its literal path, not through $PROLOGUE: the coverage check below
# looks for a source line naming the file, and this suite must satisfy its own
# rule the same way every other suite does. $PROLOGUE stays for the control
# case, which re-sources it deliberately.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ── Fixtures ──────────────────────────────────────────────────────────────────
# The "real" ledger a pump would export (two open tasks) and the ledger a
# hermetic suite builds for itself (one open task). Plain directories, default
# T grammar, read-only verbs only.
mk() {  # mk <dir> <id>
  cat >| "$1/$2.md" <<EOF
---
id: $2
phase: ${2%%.*}
title: $2
status: open
claimed_by: null
blockers: []
completed_by_commits: []
---

# $2
EOF
}
PUMP_TASKS="$TMP/pump-ledger/tasks"; mkdir -p "$PUMP_TASKS"
mk "$PUMP_TASKS" T1
mk "$PUMP_TASKS" T2
FIXTURE_TASKS="$TMP/fixture/tasks"; mkdir -p "$FIXTURE_TASKS"
mk "$FIXTURE_TASKS" T1

# ── 1. The control: the mechanism, unguarded ─────────────────────────────────
echo "--- control: inherited canonical env vs a fixture's legacy spelling ---"

got=$(env ARACHNE_TASKS_DIR="$FIXTURE_TASKS" "$CLI" ready --count)
[[ "$got" == "1" ]] && pass "fixture ledger alone answers 1 (legacy spelling reaches the tool)" \
  || fail "fixture-only read got '$got', expected 1"

# Both spellings in the environment: the canonical one wins. That is the
# documented precedence (CONFIG.md §2) — correct for the tools, and exactly
# what made unguarded suites read the pump's ledger instead of their own.
got=$(env TASKPUMP_TASKS_DIR="$PUMP_TASKS" TP_TASKS_DIR="$PUMP_TASKS" \
        ARACHNE_TASKS_DIR="$FIXTURE_TASKS" "$CLI" ready --count)
[[ "$got" == "2" ]] && pass "control: inherited TASKPUMP_TASKS_DIR outranks the fixture's ARACHNE_TASKS_DIR (issue #18's mechanism)" \
  || fail "control read got '$got', expected 2 (the pump ledger)"

# ── 2. The guard: the prologue restores the fixture's authority ──────────────
echo
echo "--- guard: sourcing the prologue under a poisoned environment ---"

# A child shell gets the pump-poisoned environment, sources the prologue, and
# only THEN configures its fixture — the exact order every suite now follows.
# The legacy spelling must be authoritative again.
got=$(env TASKPUMP_TASKS_DIR="$PUMP_TASKS" TP_TASKS_DIR="$PUMP_TASKS" \
        TASKPUMP_ID_PATTERN='^ZZZNOPE$' TASKPUMP_PHASE_SIGIL=Z \
        bash -c '. "$1" && export ARACHNE_TASKS_DIR="$2" && exec "$3" ready --count' \
        _ "$PROLOGUE" "$FIXTURE_TASKS" "$CLI")
[[ "$got" == "1" ]] && pass "after the prologue, the fixture's legacy spelling is authoritative again" \
  || fail "guarded legacy-spelling read got '$got', expected 1"

# A suite that needs one of the scrubbed names sets it explicitly after the
# scrub — the contract's other half.
got=$(env TASKPUMP_TASKS_DIR="$PUMP_TASKS" TP_TASKS_DIR="$PUMP_TASKS" \
        bash -c '. "$1" && export TASKPUMP_TASKS_DIR="$2" && exec "$3" ready --count' \
        _ "$PROLOGUE" "$FIXTURE_TASKS" "$CLI")
[[ "$got" == "1" ]] && pass "a value set explicitly after the scrub survives it" \
  || fail "explicit post-scrub value read got '$got', expected 1"

# ── 3. The scrub is an enumeration, not a name list ──────────────────────────
echo
echo "--- scrub: enumeration over the three namespaces ---"

# Keys invented for this test stand in for every key added after the scrub was
# written; a hand-kept list would miss them. TASKPUMP_CONFIG rides along
# because an inherited explicit-config path is an instant loud error in every
# fixture invocation. The bystander proves the prefix match is anchored:
# TASKPUMPX_* is not TASKPUMP_*.
leftover=$(env TASKPUMP_TASKS_DIR="$PUMP_TASKS" TP_TASKS_DIR="$PUMP_TASKS" \
             ARACHNE_TASKS_DIR="$PUMP_TASKS" TASKPUMP_CONFIG="$TMP/no-such.conf" \
             TASKPUMP_ZZ_FUTURE_KEY=poison TP_ZZ_FUTURE_KEY=poison \
             ARACHNE_ZZ_FUTURE_KEY=poison TASKPUMPX_BYSTANDER=keep \
             bash -c '. "$1"; compgen -e TASKPUMP_; compgen -e TP_; compgen -e ARACHNE_; true' \
             _ "$PROLOGUE" | LC_ALL=C sort)
expected=$'ARACHNE_NOTIFY_CMD\nTASKPUMP_HOOK_MARK_FILE\nTASKPUMP_NOTIFY_CMD\nTASKPUMP_NO_CONF'
[[ "$leftover" == "$expected" ]] \
  && pass "the scrub leaves exactly the hermetic baseline, invented keys included" \
  || fail "post-scrub namespace was '$(tr '\n' ' ' <<<"$leftover")', expected exactly the baseline four"

got=$(env TASKPUMPX_BYSTANDER=keep \
        bash -c '. "$1"; printf "%s" "${TASKPUMPX_BYSTANDER:-gone}"' _ "$PROLOGUE")
[[ "$got" == "keep" ]] && pass "a non-namespace bystander variable survives the scrub" \
  || fail "bystander was scrubbed (got '$got')"

got=$(env TASKPUMP_NO_CONF=0 TASKPUMP_NOTIFY_CMD=notify-send ARACHNE_NOTIFY_CMD=notify-send \
        bash -c '. "$1"; printf "%s/%s/%s" "$TASKPUMP_NO_CONF" "$TASKPUMP_NOTIFY_CMD" "$ARACHNE_NOTIFY_CMD"' \
        _ "$PROLOGUE")
[[ "$got" == "1/true/true" ]] \
  && pass "the baseline is re-established after the scrub: NO_CONF=1, notify stubbed in both spellings" \
  || fail "baseline was '$got', expected '1/true/true'"

# ── 4. Coverage: every suite carries the double-guard ────────────────────────
echo
echo "--- coverage: every suite and run-all source the shared prologue ---"

missing=""
while IFS= read -r suite; do
  # A SOURCE line, not a mention: a suite that only names the prologue in a
  # comment would satisfy a bare substring match while inheriting pump env.
  grep -qE '^[[:space:]]*(\.|source)[[:space:]].*suite-prologue\.sh' "$suite" \
    || missing+=" $(basename "$suite")"
done < <(find "$SCRIPT_DIR" -maxdepth 1 -name 'test-*.sh' | LC_ALL=C sort)
[[ -z "$missing" ]] && pass "every tests/test-*.sh sources the shared prologue" \
  || fail "suites missing the shared prologue (standalone runs inherit pump env):$missing"

grep -qE '^[[:space:]]*(\.|source)[[:space:]].*suite-prologue\.sh' "$SCRIPT_DIR/run-all.sh" \
  && pass "run-all.sh sources the shared prologue (the central guard)" \
  || fail "run-all.sh does not source the shared prologue"

# ── 5. The central guard, end to end ─────────────────────────────────────────
echo
echo "--- end to end: run-all launches a legacy-spelled suite clean under poison ---"

# test-claude-usage configures itself entirely in ARACHNE_* spellings, so it is
# exactly the suite the incident environment breaks: every canonical twin below
# points somewhere that does not exist. Green through run-all.sh proves the
# central scrub reaches a real suite. (The filter cannot match this suite, so
# there is no recursion; the poison credentials paths do not exist, so nothing
# can attempt a network call even if the guard regresses.)
out=$(env TASKPUMP_TASKS_DIR="$PUMP_TASKS" TP_TASKS_DIR="$PUMP_TASKS" \
        TASKPUMP_USAGE_CACHE="$TMP/no-such-cache.json" \
        TASKPUMP_USAGE_RESET_FILE="$TMP/no-such-reset" \
        TASKPUMP_CREDENTIALS="$TMP/no-such-credentials.json" \
        TASKPUMP_ID_PATTERN='^ZZZNOPE$' TASKPUMP_PHASE_SIGIL=Z \
        bash "$SCRIPT_DIR/run-all.sh" claude-usage 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "run-all under pump-poisoned env exits 0 for a legacy-spelled suite" \
  || fail "run-all under poison exited $rc; tail: $(tail -5 <<<"$out" | tr '\n' ' ')"
grep -q 'All 1 suite(s) passed' <<<"$out" \
  && pass "the nested run reports the suite green" \
  || fail "nested run-all summary did not report 1 passing suite"

# ── 6. Run state: a fixture must not write the caller's checkout (B16) ───────
echo
echo "--- run state: the pump's hook mark file is redirected out of the checkout ---"

# The leak the other four sections do not cover runs the OTHER way. tp-pump
# resolves its dotfiles to $TASKPUMP_STATE_DIR, defaulting to the workspace
# root — and a suite helper that runs a real tick without cding or pinning a
# workspace resolves that, through the cwd rung, to the TaskPump checkout the
# suites are running FROM. run_pre_tick_hooks WRITES the mark file when the
# hooks have something to say and `rm -f`s it when they go quiet, so on
# 2026-08-19 a suite run deleted and rewrote the operator's live
# .taskpump-fsguard.notified. .gitignore lists that name, so run-all.sh's status
# probe reported the run green; its state manifest is the other half of the fix.
PUMP="$TP_ROOT/libexec/tp-pump"

mark=$(bash -c '. "$1"; printf "%s" "${TASKPUMP_HOOK_MARK_FILE:-<unset>}"' _ "$PROLOGUE")
[[ "$mark" == /* && "$mark" != "$TP_ROOT"/* ]] \
  && pass "the prologue points the hook mark file at an absolute path outside the checkout" \
  || fail "the hook mark file default is '$mark' — unset, relative, or inside $TP_ROOT"

# Behaviourally, against a directory shaped exactly like the checkout that got
# hurt: a git repo with a tasks/ probe dir is all the cwd rung needs to answer
# "this is the workspace". Nothing is pinned here on purpose — the tick
# inherits only what the prologue set, which is the situation a new suite
# helper that forgets to pin anything creates.
WS="$TMP/ws"; mkdir -p "$WS/tasks" "$TMP/noops"
git -C "$WS" init -q
mk "$WS/tasks" T1
cat >| "$TMP/hook-noisy" <<'EOF'
#!/usr/bin/env bash
printf 'a persistent condition worth notifying about once\n'
EOF
chmod +x "$TMP/hook-noisy"
( cd "$WS" && TASKPUMP_PRE_TICK_HOOKS="$TMP/hook-noisy" \
    TASKPUMP_PUMP_NO_LAUNCH=1 TASKPUMP_PUMP_OPS_DIR="$TMP/noops" \
    "$PUMP" --no-health-gate --no-usage-gate --no-disk-gate --once --phases T1 \
  ) >/dev/null 2>&1
# The tick has to have really happened, or the two assertions below are vacuous
# — and its OTHER dotfiles must still land in the workspace, because relocating
# the mark file is a test-harness redirect, not a change to where a pump keeps
# its state.
[[ -f "$WS/.taskpump-pump.state" ]] \
  && pass "the tick ran a real tick against the workspace the cwd rung resolved" \
  || fail "no state file in $WS — the tick never got far enough to prove anything"
[[ ! -e "$WS/.taskpump-fsguard.notified" ]] \
  && pass "and left no mark file there, though its hooks had plenty to say" \
  || fail "the tick wrote $WS/.taskpump-fsguard.notified — the default reached a repo again"
[[ -n "${TASKPUMP_HOOK_MARK_FILE:-}" && -f "${TASKPUMP_HOOK_MARK_FILE:-}" ]] \
  && pass "the fingerprint went to the redirect instead, so the dedup still works" \
  || fail "no mark file at the redirect '${TASKPUMP_HOOK_MARK_FILE:-<unset>}' — did the tick reach the hooks?"
rm -f "${TASKPUMP_HOOK_MARK_FILE:-}"

# ── 7. And the gate that would have caught it ────────────────────────────────
echo
echo "--- run-all's state manifest: what it sees, names, and refuses to claim ---"

# run-all.sh resolves the repo it guards from its own location, so a copy of it
# in a throwaway repo guards THAT repo — which is how this can be driven for
# real without dirtying anything. Each canary suite stands in for a helper that
# runs an unpinned tick: it touches one of the paths the manifest guards, in the
# repo it is running from.
#
# gate_repo <dir> <gitignore-body> <suite-name>:<body> ...
# The body runs with $REPO set to the throwaway repo's root.
gate_repo() {
  local dir="$1" ignore="$2"; shift 2
  rm -rf "$dir"; mkdir -p "$dir/tests"
  git -C "$dir" init -q
  printf '%s\n' "$ignore" >| "$dir/.gitignore"
  cp "$SCRIPT_DIR/run-all.sh" "$SCRIPT_DIR/suite-prologue.sh" "$dir/tests/"
  local spec
  for spec in "$@"; do
    {
      printf '#!/usr/bin/env bash\nset -uo pipefail\n'
      printf 'SCRIPT_DIR=$(CDPATH=%s cd -- "$(dirname "$0")" && pwd)\n' "''"
      printf '. "$SCRIPT_DIR/suite-prologue.sh"\n'
      printf 'REPO="$SCRIPT_DIR/.."\n'
      printf '%s\n' "${spec#*:}"
      printf 'echo "Tests: 1  Passed: 1  Failed: 0"\n'
    } >| "$dir/tests/test-${spec%%:*}.sh"
    chmod +x "$dir/tests/test-${spec%%:*}.sh"
  done
}

# 7a. The base case: one gitignored run-state file appears.
GATE="$TMP/gate"
gate_repo "$GATE" '.taskpump-*' \
  'canary:printf "litter\n" >| "$REPO/.taskpump-pump.state"'
gate_out=$(bash "$GATE/tests/run-all.sh" canary 2>&1); gate_rc=$?
[[ $gate_rc -ne 0 ]] \
  && pass "a suite that drops a gitignored run-state file fails the run" \
  || fail "run-all exited 0 with a state file planted; tail: $(tail -4 <<<"$gate_out" | tr '\n' ' ')"
# The window, not a culprit: two snapshots know WHEN a path changed and cannot
# know WHO changed it, so "during <suite>" is the whole of the attribution.
grep -qF 'created during test-canary: .taskpump-pump.state' <<<"$gate_out" \
  && pass "and names the file and the suite window it changed in, not a diff" \
  || fail "the gate did not report 'created during test-canary: .taskpump-pump.state': $(tr '\n' ' ' <<<"$gate_out")"
grep -qF "git status changed while the suites ran" <<<"$gate_out" \
  && fail "the status probe saw the canary — the fixture is not actually gitignored" \
  || pass "the status probe stayed blind to it, which is why the manifest exists"

# 7b. A name the manifest globs but .gitignore does NOT list. Both probes fire,
# so the manifest must not tell the reader the file is hidden from a check that
# just reported it one line above.
NOTIG="$TMP/gate-notignored"
gate_repo "$NOTIG" '.taskpump-pump.state' \
  'canary:printf "litter\n" >| "$REPO/.taskpump-agent.log"'
notig_out=$(bash "$NOTIG/tests/run-all.sh" canary 2>&1)
grep -qF '?? .taskpump-agent.log' <<<"$notig_out" \
  && pass "the status probe does see a manifest name .gitignore omits" \
  || fail "the status probe did not report .taskpump-agent.log: $(tr '\n' ' ' <<<"$notig_out")"
grep -qF 'These files are gitignored' <<<"$notig_out" \
  && fail "the manifest called a file gitignored that git had just listed as untracked" \
  || pass "and the manifest does not claim the paths it names are gitignored"

# 7c. .git/info/exclude: in the manifest because no status probe can see it, and
# a path no TASKPUMP_STATE_DIR pin can move — it is derived from the repo root
# via --git-common-dir, so the remedy text has to say so rather than prescribing
# a state-dir pin for it.
EXCL="$TMP/gate-exclude"
gate_repo "$EXCL" '.taskpump-*' \
  'canary:mkdir -p "$REPO/.git/info"; printf "# canary\n" >> "$REPO/.git/info/exclude"'
excl_out=$(bash "$EXCL/tests/run-all.sh" canary 2>&1)
grep -qE '(created|changed) during test-canary: .*/\.git/info/exclude' <<<"$excl_out" \
  && pass "an edit to .git/info/exclude is named, with its window" \
  || fail "the gate missed .git/info/exclude: $(tr '\n' ' ' <<<"$excl_out")"
grep -qF 'NO state-dir pin moves it' <<<"$excl_out" \
  && pass "and the remedy says a state-dir pin cannot move that one" \
  || fail "the remedy still prescribes a state-dir pin for .git/info/exclude: $(tr '\n' ' ' <<<"$excl_out")"

# 7d. Create in one suite, delete in another: the net before/after view of the
# whole run is EMPTY, so only per-suite snapshots can see this at all.
NETZERO="$TMP/gate-netzero"
gate_repo "$NETZERO" '.taskpump-*' \
  'canary-a:printf "litter\n" >| "$REPO/.taskpump-pool-cap"' \
  'canary-b:rm -f "$REPO/.taskpump-pool-cap"'
nz_out=$(bash "$NETZERO/tests/run-all.sh" canary 2>&1); nz_rc=$?
[[ $nz_rc -ne 0 ]] \
  && pass "a file created by one suite and deleted by another still fails the run" \
  || fail "run-all exited 0 on a create/delete pair that nets to zero; tail: $(tail -4 <<<"$nz_out" | tr '\n' ' ')"
grep -qF 'created during test-canary-a: .taskpump-pool-cap' <<<"$nz_out" \
  && grep -qF 'deleted during test-canary-b: .taskpump-pool-cap' <<<"$nz_out" \
  && pass "and both halves are reported against the suite window each fell in" \
  || fail "the two windows were not both reported: $(tr '\n' ' ' <<<"$nz_out")"

# 7e. A live pump in the guarded checkout writes these same files at this same
# root, and the gate cannot tell its writes from a suite's. It must report
# instead of blaming — and must not call the warned row a pass.
LIVE="$TMP/gate-live"
gate_repo "$LIVE" '.taskpump-*' \
  'canary:printf "litter\n" >| "$REPO/.taskpump-pool-cap"'
sleep 300 & live_pid=$!
printf '{\n  "status": "running",\n  "pid": %d,\n  "host": "%s"\n}\n' \
  "$live_pid" "${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}" \
  >| "$LIVE/.taskpump-pump.state"
live_out=$(bash "$LIVE/tests/run-all.sh" canary 2>&1); live_rc=$?
kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
[[ $live_rc -eq 0 ]] \
  && pass "a run-state change it cannot attribute does not fail the run while a pump is live here" \
  || fail "run-all exited $live_rc with a live pump recorded; tail: $(tail -6 <<<"$live_out" | tr '\n' ' ')"
grep -qF 'WARNING: run-state files' <<<"$live_out" \
  && grep -qF "pid $live_pid" <<<"$live_out" \
  && pass "it warns instead, naming the live pump it found as the reason" \
  || fail "no WARNING naming pid $live_pid: $(tr '\n' ' ' <<<"$live_out")"
grep -qE 'suite\(s\) passed; 1 row\(s\) above report a WARN' <<<"$live_out" \
  && pass "and the summary does not count the warned row as a passing suite" \
  || fail "the summary line does not distinguish the WARN row: $(tr '\n' ' ' <<<"$live_out")"
# A scope guard on the downgrade: a live-pump record from ANOTHER host cannot be
# verified from here, and must not be allowed to excuse a delta — one stale file
# left by a machine that no longer exists would otherwise switch this gate off
# for good. What it guards is new, so the behaviour half of it is not a
# pre-repair regression (the old gate failed this case by failing everything);
# only the wording clause is red against that version.
rm -f "$LIVE/.taskpump-pool-cap"
sleep 300 & foreign_pid=$!
printf '{\n  "status": "running",\n  "pid": %d,\n  "host": "not-this-host.invalid"\n}\n' \
  "$foreign_pid" >| "$LIVE/.taskpump-pump.state"
foreign_out=$(bash "$LIVE/tests/run-all.sh" canary 2>&1); foreign_rc=$?
kill "$foreign_pid" 2>/dev/null; wait "$foreign_pid" 2>/dev/null
[[ $foreign_rc -ne 0 ]] && grep -qF 'FAIL: run-state files' <<<"$foreign_out" \
  && pass "a live-pump record from another host does not excuse the delta" \
  || fail "a foreign-host pump record downgraded the failure (rc=$foreign_rc): $(tr '\n' ' ' <<<"$foreign_out")"

# The control, so the downgrade is not just the gate going quiet: same repo,
# same litter, no live pump recorded.
rm -f "$LIVE/.taskpump-pump.state" "$LIVE/.taskpump-pool-cap"
dead_out=$(bash "$LIVE/tests/run-all.sh" canary 2>&1); dead_rc=$?
[[ $dead_rc -ne 0 ]] \
  && pass "with no live pump identified, the same litter fails the run" \
  || fail "run-all exited 0 on the same litter with no live pump: $(tr '\n' ' ' <<<"$dead_out")"
grep -qF 'FAIL: run-state files' <<<"$dead_out" \
  && pass "and says FAIL, so the two verdicts are told apart in the text too" \
  || fail "the failure is not headed 'FAIL: run-state files': $(tr '\n' ' ' <<<"$dead_out")"

# 7f. The redirect the prologue installs moves the mark file out of the repo,
# but a suite whose last tick still had output leaves it in $TMPDIR. run-all.sh
# owns that litter for the runs it starts, so a full run cleans up after itself.
MARKGATE="$TMP/gate-mark"
gate_repo "$MARKGATE" '.taskpump-*' \
  'canary:printf "%s\n" "$TASKPUMP_HOOK_MARK_FILE" >| "$REPO/../hookmark-path"; printf "fingerprint\n" >| "$TASKPUMP_HOOK_MARK_FILE"'
bash "$MARKGATE/tests/run-all.sh" canary >/dev/null 2>&1
markpath="$(cat "$TMP/hookmark-path" 2>/dev/null)"
[[ -n "$markpath" && "$markpath" != "$MARKGATE"/* ]] \
  && pass "a suite under run-all writes its hook fingerprint outside the repo" \
  || fail "the canary's mark file was '$markpath' — empty, or inside the gate repo"
[[ ! -e "$markpath" ]] \
  && pass "and run-all's exit trap removes the fingerprint its own run left behind" \
  || fail "$markpath survived the run that created it"
rm -f "$markpath"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
