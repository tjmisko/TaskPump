#!/usr/bin/env bash
# run-all.sh — run every TaskPump suite and report.
#
# Each tests/test-*.sh is self-contained and exits non-zero on any failure. This
# wrapper runs them in sequence, keeps going after a failure so one broken suite
# does not hide the state of the rest, and prints a summary table at the end.
#
# Hermeticity is centralized in tests/suite-prologue.sh, sourced below:
# notifications stubbed to `true` in both spellings, ambient taskpump.conf
# discovery off, and the inherited TASKPUMP_*/TP_*/ARACHNE_* environment
# scrubbed.
#
# Run: ./tests/run-all.sh          (all suites)
#      ./tests/run-all.sh task     (only suites whose name contains "task")
set -uo pipefail

# CDPATH='' rather than `CDPATH= `: the spelling with the space is the same env
# prefix, but shellcheck reads it as a mistyped assignment (SC1007) and the rest
# of this file has to lint clean for that warning to mean anything.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)

# Hermeticity, both halves, shared with every suite's own prologue: turn off
# ambient taskpump.conf discovery (a leaked conf once made the pump suite
# re-enter this very script unboundedly), and scrub the inherited
# TASKPUMP_*/TP_*/ARACHNE_* environment (issue #18: the pump exports the real
# ledger's TASKPUMP_TASKS_DIR into every agent session, and the canonical
# spelling outranks the legacy one a fixture sets — 64 spurious failures
# across three suites for the 2026-08-13 G3 drain agent). Each suite sources
# the same prologue itself for standalone runs; sourcing it here as well
# guards anything this wrapper does before a suite's own prologue runs.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

filter="${1:-}"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

# ── Hermeticity gate, both halves (issue #20, B16) ────────────────────────────
#
# Suites must not litter the repo they run from (issue #20: a git stub's
# fallthrough answer to --git-common-dir once manufactured <sha>/info/exclude
# trees in the repo root on every run). Snapshot the tree's status up front;
# any delta after the suites ran is itself a failure.
#
# The status diff alone is BLIND to the damage that actually happened, though.
# The run-state names .gitignore lists are invisible to `git status --porcelain`
# — that is deliberate, TaskPump is itself a repo a pump can be pointed at — so
# it cannot see one of those appear, vanish, or change. On 2026-08-19 a suite
# run deleted and rewrote the operator's live .taskpump-fsguard.notified in the
# primary checkout and this script still printed "All 25 suite(s) passed".
#
# So a second probe runs alongside: a MANIFEST of the run-state files, by
# content. Manifest rather than `git status --ignored` for two reasons.
# `--ignored` reports PATHS, and the observed damage was a content rewrite of a
# file that existed before and after — a diff of zero. And `--ignored` reports
# every ignored path in the tree, so a developer's own .claude/, editor state,
# or build output would fail a run they had nothing to do with. The manifest is
# scoped by glob to the names a TaskPump run drops at a repo root, and it hashes
# them, so a clobber is as visible as a create. The globs are a SUPERSET of the
# .gitignore list, not a copy of it: they also cover the workspace-side names
# (.taskpump-agent.log, -phase-brief.md, -resume.md, -goal.md), which are not
# ignored and which the status probe therefore does see, and any state file
# added later without editing this line.
#
# .git/info/exclude rides along because NO status probe of any width can see
# it: apl_ensure_worktrees_visible appends the worktree negation there, and a
# suite driving that path against the real checkout edits the operator's git
# config with no working-tree trace at all.
#
# Two things this gate deliberately does NOT do, because two snapshots cannot:
#
#   * It does not name a WRITER. A snapshot pair says a path changed between two
#     moments; it says nothing about who changed it. What it can earn honestly
#     is a WINDOW, so the manifest is re-taken after every suite and each change
#     is reported as "during <suite>" — the interval it happened in, which is a
#     fact. An outside writer's change lands in some suite's window too and
#     reads exactly the same; that is the point of not claiming more.
#   * It does not call an ambiguous change the suites' fault. This repo's own
#     dogfood configuration points a pump at this checkout (taskpump.conf's
#     TASKPUMP_BUILD_GATE is './tests/run-all.sh'), and a live pump writes these
#     same files at this same root every tick. So: when a live pump is
#     identified here the manifest REPORTS and the run is not failed; when none
#     is, the suites are the only writer this run knows of and the delta fails.
#     live_pump_at_root below is the whole of that judgement.
state_manifest() {
  local exclude
  exclude="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"
  [[ -n "$exclude" && "$exclude" != /* ]] && exclude="$REPO_ROOT/$exclude"
  (
    cd "$REPO_ROOT" || return 0
    local f
    for f in .taskpump-* .arachne-* .auto-trunk* "${exclude:+$exclude/info/exclude}"; do
      [[ -e "$f" ]] || continue
      if [[ -d "$f" ]]; then
        printf '%s\t<directory>\n' "$f"
      else
        printf '%s\t%s\n' "$f" "$(cksum <"$f" 2>/dev/null)"
      fi
    done | LC_ALL=C sort
  )
}

# Name what moved, one file per line, instead of handing back an opaque diff.
# The two snapshots are TAGGED into one stream rather than handed to awk as two
# files: the usual NR==FNR idiom mis-files the whole second file as "before"
# when the first one is EMPTY, and empty is exactly what the before-snapshot of
# a clean checkout looks like — the one case this gate exists for. awk does the
# tagging because `sed 's/^/B\t/'` writes a literal t outside GNU sed.
state_manifest_delta() {  # $1=before file  $2=after file  $3=window label
  { awk '{ print "B\t" $0 }' "$1"; awk '{ print "A\t" $0 }' "$2"; } \
    | awk -F'\t' -v win="$3" '
    $1 == "B" { before[$2] = $3; next }
    { after[$2] = $3
      if (!($2 in before))          printf "  created during %s: %s\n", win, $2
      else if ($3 != before[$2])    printf "  changed during %s: %s\n", win, $2 }
    END { for (p in before) if (!(p in after)) printf "  deleted during %s: %s\n", win, p }
  ' | LC_ALL=C sort
}

# Is a pump demonstrably alive at the root this gate guards? write_state (see
# libexec/tp-pump) stamps its own pid, host and status into the state file every
# tick, so this reads a fact the tree carries rather than guessing. Prints the
# evidence and returns 0 when one is found.
#
# Same reader skepticism tp-monitor applies to the same file (issue #22): the
# state file is a HINT, not an oracle. A terminal status claims no live process;
# an unsignalable pid is alive, not dead, so /proc settles what kill -0 answers
# EPERM for. The one place the default is deliberately the opposite of
# tp-monitor's is a FOREIGN host: tp-monitor calls that unverifiable rather than
# dead, while here an unverifiable claim must not be allowed to excuse a delta —
# a stale record from another machine would switch this gate off for good.
#
# So what this cannot see, which is why the failure text says "no live pump was
# identified" and not "no pump is running": a pump whose
# TASKPUMP_PUMP_STATE_FILE points outside this root, and one recorded against
# another host.
live_pump_at_root() {
  local sf pid host status me
  for sf in "$REPO_ROOT/.taskpump-pump.state" "$REPO_ROOT/.arachne-pump.state"; do
    [[ -f "$sf" ]] || continue
    pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$sf" | head -1)"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    status="$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$sf" | head -1)"
    case "$status" in drained|stalled|stopped) continue ;; esac
    host="$(sed -n 's/.*"host"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$sf" | head -1)"
    me="${HOSTNAME:-$(hostname 2>/dev/null || true)}"
    # Short names, and only when both are known: an unrecorded host must not
    # veto the check either.
    if [[ -n "$host" && -n "$me" && "${host%%.*}" != "${me%%.*}" ]]; then continue; fi
    kill -0 "$pid" 2>/dev/null || [[ -e "/proc/$pid" ]] || continue
    printf 'pid %s, status %s, recorded in %s' "$pid" "${status:-unrecorded}" "${sf##*/}"
    return 0
  done
  return 1
}

REPO_STATUS_BEFORE="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)"
STATE_SNAPSHOT_DIR="$(mktemp -d)"
: >|"$STATE_SNAPSHOT_DIR/run-stamp"

run_all_cleanup() {
  # tests/suite-prologue.sh points each suite's pre-tick hook mark file at
  # $TMPDIR/taskpump-suite-hookmark.<pid>. The pump removes it when a tick's
  # hooks go quiet, but a run whose hooks had something to say leaves one
  # behind, so remove the ones this run left: newer than the run stamp, and with
  # no live process behind the pid. Files older than this run, and files whose
  # pid is still alive (a suite still running, here or under another run-all),
  # are left alone.
  local f pid
  for f in "${TMPDIR:-/tmp}"/taskpump-suite-hookmark.*; do
    [[ -f "$f" ]] || continue
    [[ -n "$STATE_SNAPSHOT_DIR" && "$f" -nt "$STATE_SNAPSHOT_DIR/run-stamp" ]] || continue
    pid="${f##*.}"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    if [[ "$pid" != "$$" ]] && kill -0 "$pid" 2>/dev/null; then continue; fi
    rm -f "$f"
  done
  rm -rf "$STATE_SNAPSHOT_DIR"
}
trap 'run_all_cleanup' EXIT

state_manifest >"$STATE_SNAPSHOT_DIR/prev"
LIVE_PUMP="$(live_pump_at_root || true)"
STATE_EVENTS=""

# Close the window that just ran and record what moved in it. The label is the
# interval, which is the only attribution a snapshot pair supports.
record_state_window() {  # $1=window label
  local delta
  state_manifest >"$STATE_SNAPSHOT_DIR/now"
  delta="$(state_manifest_delta "$STATE_SNAPSHOT_DIR/prev" "$STATE_SNAPSHOT_DIR/now" "$1")"
  [[ -n "$delta" ]] && STATE_EVENTS+="$delta"$'\n'
  mv -f "$STATE_SNAPSHOT_DIR/now" "$STATE_SNAPSHOT_DIR/prev"
}

suites=()
while IFS= read -r f; do
  [[ "$(basename "$f")" == "run-all.sh" ]] && continue
  [[ -n "$filter" && "$f" != *"$filter"* ]] && continue
  suites+=("$f")
done < <(find "$SCRIPT_DIR" -maxdepth 1 -name 'test-*.sh' | sort)

if [[ ${#suites[@]} -eq 0 ]]; then
  printf 'run-all: no suites matched %s\n' "${filter:-*}" >&2
  exit 1
fi

names=(); results=(); counts=()
failed=0
warned=0

for suite in "${suites[@]}"; do
  name="$(basename "$suite" .sh)"
  printf '\n=== %s ===\n' "$name"

  out="$(bash "$suite" 2>&1)"
  rc=$?
  printf '%s\n' "$out"

  # Suites print "Tests: N  Passed: N  Failed: N"; fall back to counting PASS/FAIL
  # lines for any that does not.
  tally="$(printf '%s\n' "$out" | grep -E '^Tests: ' | tail -1)"
  if [[ -z "$tally" ]]; then
    tally="Tests: $(printf '%s\n' "$out" | grep -c '^PASS')  Passed: $(printf '%s\n' "$out" | grep -c '^PASS')  Failed: $(printf '%s\n' "$out" | grep -c '^FAIL')"
  fi

  names+=("$name")
  counts+=("$tally")
  if [[ $rc -eq 0 ]]; then
    results+=("ok")
  else
    results+=("FAILED (rc=$rc)")
    failed=$((failed + 1))
  fi
  record_state_window "$name"
done

REPO_STATUS_AFTER="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)"
if [[ "$REPO_STATUS_AFTER" != "$REPO_STATUS_BEFORE" ]]; then
  printf '\nFAIL: this repo'\''s git status changed while the suites ran (hermeticity, issue #20):\n' >&2
  diff <(printf '%s\n' "$REPO_STATUS_BEFORE") <(printf '%s\n' "$REPO_STATUS_AFTER") >&2
  names+=("(repo hermeticity)")
  results+=("FAILED (littered)")
  counts+=("the run added or removed working-tree entries")
  failed=$((failed + 1))
fi

# Re-check for a live pump after the run as well as before it: one can be
# started or stopped while the suites run, and either sighting is enough to make
# the manifest's delta unattributable.
[[ -z "$LIVE_PUMP" ]] && LIVE_PUMP="$(live_pump_at_root || true)"
if [[ -n "$STATE_EVENTS" ]]; then
  state_lines="$(printf '%s' "$STATE_EVENTS" | grep -c .)"
  if [[ -n "$LIVE_PUMP" ]]; then
    printf '\nWARNING: run-state files at %s changed while the suites ran (B16):\n' "$REPO_ROOT" >&2
  else
    printf '\nFAIL: run-state files at %s changed while the suites ran (B16):\n' "$REPO_ROOT" >&2
  fi
  printf '%s' "$STATE_EVENTS" >&2
  printf 'Each line is what two manifest snapshots taken around one suite show: which\npath changed, in which direction, and during which suite'\''s window. WHO wrote it\nis not something two snapshots can say. This probe is here because `git status`\ncannot see the run-state names .gitignore lists, nor anything under .git/ at\nall — and even for a path it can see, it compares entries, not contents.\n' >&2
  if [[ -n "$LIVE_PUMP" ]]; then
    printf 'Not failing the run: this checkout records a live pump (%s),\nand a live pump writes these same files at this same root every tick. This gate\ncannot tell its writes from a suite'\''s, so it reports them rather than blaming\nthe suites. For a verdict, re-run with no pump against this checkout.\n' "$LIVE_PUMP" >&2
    names+=("(repo run state)")
    results+=("WARN (pump live)")
    counts+=("$state_lines change(s), unattributable: a live pump is recorded here")
    warned=$((warned + 1))
  else
    printf 'No live pump was identified from the state files at this root, so the suites\nare the only writer this run knows of. If a suite ran a real tick, pin its\nstate out of this tree:\n' >&2
    printf '  * TASKPUMP_STATE_DIR moves the state-dir names in one key:\n      .taskpump-pump.state, -pool-cap, -pump.log, -usage-reset,\n      -disk-watchdog.log, .auto-trunk.lock, .auto-trunk-quarantine\n' >&2
    printf '  * it does NOT move the pre-tick hook mark file — TASKPUMP_HOOK_MARK_FILE\n    outranks the state dir, and tests/suite-prologue.sh already sets it for\n    every suite, which is why .taskpump-fsguard.notified is covered\n' >&2
    printf '  * TASKPUMP_WORKSPACE_ROOT moves the workspace-side names\n      .taskpump-agent.log, -phase-brief.md, -resume.md, -goal.md\n    which follow the worktree an agent runs in, not the state dir\n' >&2
    printf '  * .git/info/exclude is derived from the repo root via --git-common-dir\n    (apl_ensure_worktrees_visible), so NO state-dir pin moves it: a suite that\n    trips it has to drive a git repo of its own\n' >&2
    names+=("(repo run state)")
    results+=("FAILED (littered)")
    counts+=("$state_lines run-state change(s) during the run")
    failed=$((failed + 1))
  fi
fi

printf '\n\n==============================================\n'
printf 'Suite summary\n'
printf '==============================================\n'
for i in "${!names[@]}"; do
  printf '%-26s %-14s %s\n' "${names[$i]}" "${results[$i]}" "${counts[$i]}"
done
printf '==============================================\n'

if [[ $failed -eq 0 ]]; then
  # A WARN row is not a pass, so it is not counted as one: saying "all N
  # passed" over a row that reports something this run could not attribute is
  # the exact species of lie the manifest was added to catch.
  if [[ $warned -eq 0 ]]; then
    printf 'All %d suite(s) passed.\n' "${#names[@]}"
  else
    printf '%d suite(s) passed; %d row(s) above report a WARN, nothing failed.\n' \
      "$(( ${#names[@]} - warned ))" "$warned"
  fi
  exit 0
fi

printf '%d of %d suite(s) FAILED.\n' "$failed" "${#names[@]}"
exit 1
